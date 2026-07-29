class Api::V1::EventsController < Api::BaseController
  # Raised when a nested role/ticket in an atomic create is malformed; rolls the
  # whole event create back with a precise message.
  class InvalidChild < StandardError; end

  # Event browsing/pages are public — EventPolicy/visible_to still hide
  # drafts/private events from anonymous viewers.
  skip_before_action :authenticate!, only: %i[index show]
  before_action :authenticate_optional!, only: %i[index show]
  before_action :set_event, only: %i[show update destroy approve]

  # GET /api/v1/events — the browse/schedule listing.
  # Filters: group_id (TSID or slug), collection (upcoming|past|ongoing),
  # start_date/end_date (+timezone), search_title, tags, venue_id, track_id,
  # kind, category, pinned, skip_recurring, owner_id, attendee_id, co_host_id,
  # starred_id (each of the last four accepts a TSID or username). Anonymous
  # → public events; with a token the response also carries
  # is_attending/is_starred/is_owner flags.
  def index
    scope = Event.includes(:group, :place, :venue, :owner, :track).visible_to(current_user)
    scope = apply_filters(scope)
    render_collection scope, blueprint: EventBlueprint, **personalization_options
  end

  def show
    authorize @event
    render json: EventBlueprint.render(@event, view: :extended, **personalization_options)
  end

  # Optionally accepts `event_roles: [...]` and `tickets: [...]` alongside the
  # event. When present, the event and its children are created in one
  # transaction so a child failure can't leave a half-configured event — and a
  # retry after failure starts from a clean slate instead of duplicating
  # children against a partially-created parent.
  def create
    attrs = event_params.to_h
    group = Group.find_by(id: attrs[:group_id])
    gate_pinned!(attrs, group)
    normalize_times!(attrs, group: group)
    event = Event.new(attrs.merge(owner: current_user))
    authorize event
    if (err = reference_error(event))
      return render_error(err)
    end

    ActiveRecord::Base.transaction do
      event.save!
      create_nested_roles!(event, params[:event_roles])
      create_nested_tickets!(event, params[:tickets], event.group_id)
    end
    render json: EventBlueprint.render(event), status: :created
  rescue InvalidChild => e
    render_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def update
    authorize @event
    # group_id is intentionally not updatable — moving an event into another
    # group would escape the authorization that was checked against its current
    # group. venue/track references are re-validated against the current group.
    attrs = event_params.to_h.except("group_id")
    gate_pinned!(attrs, @event.group)
    normalize_times!(attrs, group: @event.group, current_tz: @event.timezone)
    @event.assign_attributes(attrs)
    if (err = reference_error(@event))
      return render_error(err)
    end
    if @event.save
      notify_attendees_of_update if calendar_relevant_change?
      render json: EventBlueprint.render(@event)
    else
      render_error(@event.errors.full_messages.join(", "))
    end
  end

  # "Cancelling" an event must not destroy it (and cascade away every
  # participant/ticket/coupon) — it flips status to cancelled and keeps the record.
  def destroy
    authorize @event
    @event.update(status: "cancelled")
    notify_attendees_of_cancellation
    head :no_content
  end

  # GET /api/v1/events/pending_approval — events awaiting review in groups the
  # caller manages (the dashboard inbox).
  def pending_approval
    managed = current_user.memberships.where(role: %w[manager owner]).select(:group_id)
    scope = Event.includes(:group, :place, :venue, :owner, :track)
                 .where(status: "pending", group_id: managed).order(:start_time)
    render_collection scope, blueprint: EventBlueprint
  end

  # POST /api/v1/events/:id/approve — group manager publishes a pending event.
  def approve
    authorize @event
    return render_error("event is not pending approval") unless @event.status == "pending"
    @event.update!(status: "published")
    render json: EventBlueprint.render(@event)
  end

  private

  def set_event
    @event = Event.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # Narrows the browse scope by the request's filter params. Invalid dates are
  # ignored rather than 422ing — a bad filter degrades to "unfiltered".
  def apply_filters(scope)
    if params[:group_id].present?
      scope = scope.where(group_id: Group.resolve!(params[:group_id]).event_group_ids)
    elsif current_user && params[:owner_id].blank? && params[:attendee_id].blank?
      # No group/user filter: an authenticated caller browses their own groups
      # (the pre-existing "my events" behavior); anonymous callers see all
      # public events (feeds/search). Profile-tab filters (owner_id/attendee_id)
      # must NOT be narrowed to the viewer's groups.
      scope = scope.where(group_id: current_user.groups.select(:id))
    end

    now = Time.current
    scope = case params[:collection]
    when "upcoming" then scope.where("end_time >= ?", now).order(:start_time)
    when "past"     then scope.where("end_time < ?", now).order(start_time: :desc)
    when "ongoing"  then scope.where("start_time <= ? AND end_time >= ?", now, now).order(:start_time)
    else scope.order(:start_time)
    end

    # Profile-page tabs: events a user hosts / attends (public visibility rules
    # still apply through visible_to). Both accept a TSID or username.
    if params[:owner_id].present?
      scope = scope.where(owner_id: User.resolve!(params[:owner_id]).id)
    end
    if params[:attendee_id].present?
      attendee = User.resolve!(params[:attendee_id])
      scope = scope.where(id: Participant.where(user_id: attendee.id, status: "attending").select(:event_id))
    end
    if params[:co_host_id].present?
      co_host = User.resolve!(params[:co_host_id])
      scope = scope.where(id: EventRole.where(item_type: "User", item_id: co_host.id).select(:event_id))
    end
    if params[:starred_id].present?
      starrer = User.resolve!(params[:starred_id])
      scope = scope.where(id: Comment.where(user_id: starrer.id, comment_type: "star", item_type: "Event")
                                      .visible.select(:item_id))
    end

    scope = scope.where(venue_id: params[:venue_id]) if params[:venue_id].present?
    scope = scope.where(track_id: params[:track_id]) if params[:track_id].present?
    scope = scope.where(kind: params[:kind])         if params[:kind].present?
    scope = scope.where(category: params[:category]) if params[:category].present?
    scope = scope.where(pinned: true)                if params[:pinned].present?
    scope = scope.where(recurring_id: nil)           if params[:skip_recurring].present?
    if params[:search_title].present?
      scope = scope.where("title ILIKE ?", "%#{Event.sanitize_sql_like(params[:search_title])}%")
    end
    if params[:tags].present?
      scope = scope.where("tags && ARRAY[?]::varchar[]", Array(params[:tags]))
    end

    # Date-window filter, interpreted in the request's timezone (else UTC) so
    # "events on the 16th" means the 16th where the viewer/group is.
    zone = ActiveSupport::TimeZone[params[:timezone].to_s] || Time.zone
    if params[:start_date].present? && (from = zone.parse(params[:start_date].to_s) rescue nil)
      scope = scope.where("start_time >= ?", from.beginning_of_day)
    end
    if params[:end_date].present? && (to = zone.parse(params[:end_date].to_s) rescue nil)
      scope = scope.where("start_time <= ?", to.end_of_day)
    end

    scope
  end

  # With a token, the listing carries per-event viewer flags. Two plucks total —
  # the blueprint checks set membership per event (no N+1).
  def personalization_options
    return {} unless current_user
    {
      viewer_id: current_user.id,
      attending_ids: current_user.participants.where(status: "attending").pluck(:event_id).to_set,
      starred_ids: Comment.where(user_id: current_user.id, comment_type: "star", item_type: "Event", removed: false)
                          .pluck(:item_id).to_set
    }
  end

  # Email every attending participant that the event was cancelled (with an .ics
  # calendar cancellation). The walk over participants happens in the job, not
  # here, so cancelling a large event costs this request a single enqueue.
  def notify_attendees_of_cancellation
    EventAttendeeMailJob.perform_later(event_id: @event.id, mailer_action: "cancelled")
  end

  # Email attendees an updated invite (bumped SEQUENCE) so their calendars update.
  def notify_attendees_of_update
    EventAttendeeMailJob.perform_later(event_id: @event.id, mailer_action: "updated")
  end

  # Only the fields that appear in the calendar entry warrant re-inviting people.
  CALENDAR_FIELDS = %w[start_time end_time timezone title content place_id venue_id meeting_url external_url status].freeze

  def calendar_relevant_change?
    (@event.saved_changes.keys & CALENDAR_FIELDS).any?
  end

  # Validates that referenced venue/track belong to the event's group and, for a
  # venue, that the requested time is actually bookable. Returns an error string
  # or nil. Shared by create and update.
  def reference_error(event)
    if event.track_id
      track = Track.find_by(id: event.track_id)
      return "track not found" unless track
      return "track does not belong to this group" unless track.group_id == event.group_id
    end

    if event.venue_id
      venue = Venue.find_by(id: event.venue_id)
      return "venue not found" unless venue
      group = Group.find_by(id: event.group_id)
      return "venue does not belong to this group" unless group && group.venue_group_ids.include?(venue.group_id)
      if event.max_participant && venue.capacity && event.max_participant > venue.capacity
        return "event capacity exceeds the venue capacity"
      end
      ok, message = venue.check_availability(event.start_time, event.end_time, event.timezone,
        event.persisted? ? event.id : nil)
      return message unless ok
    end

    nil
  end

  def event_params
    params.require(:event).permit(:title, :content, :notes, :image_url, :pinned,
      :start_time, :end_time, :timezone,
      :status, :visibility, :group_id, :place_id, :venue_id, :track_id, :meeting_url,
      :external_url, :max_participant, :require_approval, :category, :kind,
      tags: [], requirement_tags: [])
  end

  # `pinned` features an event on the homepage/carousel — a group-curation
  # decision, so only group managers may set it. Silently drop it for everyone
  # else (rather than 403) so a non-manager's ordinary save still succeeds.
  def gate_pinned!(attrs, group)
    return unless attrs.key?("pinned")
    attrs.delete("pinned") unless group && GroupPolicy.new(current_user, group).manage?
  end

  # Create co-hosts/speakers passed inline with the event. Guards item_type
  # before build so a bad value is a clean 422, not a polymorphic NameError.
  def create_nested_roles!(event, roles)
    Array(roles).each do |role|
      permitted = role.permit(:item_id, :item_type, :role, :email, :display_name, :image_url)
      unless %w(User Group).include?(permitted[:item_type])
        raise InvalidChild, "event_role item_type must be User or Group"
      end
      event.event_roles.create!(permitted)
    end
  end

  # Create tickets (and their payment methods) passed inline with the event.
  # group_id defaults to the event's group so group tickets resolve correctly.
  def create_nested_tickets!(event, tickets, group_id)
    Array(tickets).each do |ticket|
      permitted = ticket.permit(:title, :content, :check_badge_class_id, :quantity, :end_time,
        :need_approval, :status, :ticket_type, :group_id, :start_date, :end_date,
        days_allowed: [], tracks_allowed: [],
        payment_methods_attributes: [:chain, :kind, :token_name, :token_address,
          :receiver_address, :price, :protocol, chains: []]).to_h
      permitted["group_id"] = group_id if permitted["group_id"].blank?
      event.tickets.create!(permitted)
    end
  end

  # Interpret naive start/end time strings in the event's zone so "2026-07-16 14:00"
  # means 14:00 *there*, not 14:00 UTC. An explicit offset in the string still wins
  # (TimeZone#parse honors it). Zone = the request's timezone, else the event's
  # current one (update), else the group's. With no zone anywhere, times are left
  # untouched (ActiveRecord coerces them as UTC, as before).
  #
  # Also persists the resolved zone back onto attrs[:timezone] when the caller
  # didn't set one explicitly — Venue#check_availability (called via
  # reference_error, right after this) reads event.timezone as its one
  # canonical source. Leaving it nil would make that check silently re-derive
  # the group's *current* timezone every time instead of the zone actually
  # used to interpret this event's own start/end times — fine today, but it
  # would silently drift if the group's timezone setting ever changed after
  # the event was created.
  def normalize_times!(attrs, group:, current_tz: nil)
    tzid = attrs[:timezone].presence || current_tz.presence || group&.timezone.presence
    zone = tzid && ActiveSupport::TimeZone[tzid]
    return unless zone

    attrs[:timezone] = zone.name if attrs[:timezone].blank?

    %i[start_time end_time].each do |key|
      next if attrs[key].blank?
      parsed = zone.parse(attrs[key].to_s)
      attrs[key] = parsed if parsed
    end
  end
end
