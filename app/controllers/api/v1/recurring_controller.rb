class Api::V1::RecurringController < Api::BaseController
  # A recurring series belongs to a public event page (the "Repeating Events"
  # list on event/detail), which anonymous visitors can read — and the frontend
  # fetches it with no token both server-side and from RecurringListBtn. Without
  # this skip every anonymous view of a recurring event 500'd the whole page on
  # a 401. Mirrors events#index/#show: public read, visibility enforced below
  # rather than by requiring a session.
  skip_before_action :authenticate!, only: :show
  before_action :authenticate_optional!, only: :show

  # GET /api/v1/recurring/:id
  def show
    recurring = Recurring.find(params[:id])
    # Same rule as events#index — an anonymous viewer sees only the public,
    # non-draft occurrences; the owner and group managers still see all of them.
    # Passed in explicitly because the blueprint's association would otherwise
    # render the unfiltered `recurring.events`.
    events = recurring.events.visible_to(current_user).order(:start_time)
    render json: RecurringBlueprint.render(recurring, view: :with_events, visible_events: events)
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/recurring
  # Creates a Recurring series plus one Event per occurrence. If a venue is
  # given, EVERY occurrence must pass the venue overlap/availability check before
  # anything is created — the whole series is created atomically or not at all.
  def create
    group = Group.find_by(id: params[:group_id])
    return render_not_found unless group
    authorize Event.new(group: group, owner: current_user), :create?

    interval = params[:interval].to_s
    return render_error("invalid interval (day|week|month)") unless Recurring::INTERVALS.key?(interval)
    count = params[:event_count].to_i
    return render_error("event_count must be positive") unless count.positive?

    # Parse in the series' own zone (the request's timezone, else the group's,
    # else UTC): a naive "2026-07-16 18:00" then means 18:00 local (not 18:00
    # UTC), and occurrences advance in that zone so a weekly 18:00 stays 18:00
    # across a DST transition (see occurrence_starts).
    zone = resolve_zone(params[:timezone], group)
    start_time = parse_time(params[:start_time], zone)
    end_time   = parse_time(params[:end_time], zone)
    return render_error("invalid start_time/end_time") unless start_time && end_time && end_time > start_time
    duration = end_time - start_time

    venue = params[:venue_id].present? ? resolve_venue(group) : nil
    return if performed?

    occurrences = occurrence_starts(start_time, count, interval)

    # `zone` (already resolved above with the request→group fallback) is the
    # one canonical timezone source for this series — used for the occurrence
    # times themselves, the availability check, and persisted onto both the
    # Recurring and every Event it creates, so a later edit (see #update)
    # reading event.timezone always finds the exact zone this series was
    # actually created in, not a re-derived (and possibly since-changed)
    # group timezone.
    if venue
      occurrences.each do |occ_start|
        ok, message = venue.check_availability(occ_start, occ_start + duration, zone.name)
        return render_error("#{message} (#{occ_start.to_date})") unless ok
      end
    end

    recurring = nil
    ActiveRecord::Base.transaction do
      recurring = Recurring.create!(
        start_time: start_time, end_time: occurrences.last + duration,
        interval: interval, event_count: count, timezone: zone.name
      )
      occurrences.each do |occ_start|
        Event.create!(event_attributes.merge(
          group: group, owner: current_user, recurring_id: recurring.id,
          venue_id: venue&.id, start_time: occ_start, end_time: occ_start + duration,
          timezone: zone.name
        ))
      end
    end

    render json: RecurringBlueprint.render(recurring.reload, view: :with_events), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/recurring/:recurring_id
  # Updates the events in a series. selector "after" (with after_event_id) limits
  # the change to that occurrence onward; anything else updates the whole series.
  # Optional start_time_diff/end_time_diff (seconds) shift each occurrence; every
  # affected occurrence is re-checked against its venue first — its *new* venue if
  # venue_id is given, otherwise the venue it already has (a time-only shift on a
  # series that already has a venue must still respect that venue's hours; it used
  # to only check when venue_id was explicitly re-sent, silently allowing a
  # time-only edit to move a series into a slot its own venue is closed for).
  def update
    events = selected_events(params[:recurring_id], selector: params[:selector], pivot_id: params[:after_event_id])
    return if performed?
    authorize events.first, :update?

    start_diff = params[:start_time_diff].to_i
    end_diff   = params[:end_time_diff].to_i

    new_venue = params[:venue_id].present? ?
      resolve_venue(events.first.group, current_venue_id: events.first.venue_id) : nil
    return if performed?
    # Resolved once, up front, same as #create — so the check below and what
    # actually gets persisted (via event_attributes, which already includes
    # :timezone when the request sends one) never disagree.
    new_tz = params[:timezone].presence

    events.each do |event|
      venue = new_venue || event.venue
      next unless venue

      s = event.start_time + start_diff.seconds
      e = event.end_time + end_diff.seconds
      ok, message = venue.check_availability(s, e, new_tz || event.timezone, event.id)
      return render_error(message) unless ok
    end

    attrs = event_attributes
    ActiveRecord::Base.transaction do
      events.each do |event|
        changes = attrs.dup
        changes[:start_time] = event.start_time + start_diff.seconds if params.key?(:start_time_diff)
        changes[:end_time]   = event.end_time + end_diff.seconds if params.key?(:end_time_diff)
        changes[:venue_id]   = new_venue.id if new_venue
        event.update!(changes)
      end
    end

    render json: RecurringBlueprint.render(Recurring.find(params[:recurring_id]), view: :with_events)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # POST /api/v1/recurring/:recurring_id/cancel
  # Soft-cancels the selected occurrences (status → cancelled). Never destroys.
  def cancel
    events = selected_events(params[:recurring_id], selector: params[:selector], pivot_id: params[:event_id])
    return if performed?
    authorize events.first, :update?

    Event.where(id: events.map(&:id)).update_all(status: "cancelled", updated_at: Time.current)
    render json: { result: "ok", cancelled: events.size }
  end

  private

  # Loads the series' events (optionally from a pivot occurrence onward), oldest
  # first. Renders 404/422 and returns nil when the selection is empty/invalid.
  def selected_events(recurring_id, selector:, pivot_id:)
    recurring = Recurring.find_by(id: recurring_id)
    unless recurring
      render_not_found
      return nil
    end

    scope = recurring.events.order(:start_time)
    if selector == "after" && pivot_id.present?
      pivot = scope.find_by(id: pivot_id)
      unless pivot
        render_not_found
        return nil
      end
      scope = scope.where("start_time >= ?", pivot.start_time)
    end

    events = scope.to_a
    if events.empty?
      render_error("no events in the selection")
      return nil
    end
    events
  end

  # current_venue_id is the venue the series is already sitting in. An archived
  # venue is only acceptable as "unchanged" — the client resubmits the whole
  # form, so venue_id comes back on a time-only edit too, and rejecting it there
  # would make a series whose venue was later removed permanently uneditable.
  # Moving a series INTO an archived venue is still refused. Mirrors
  # EventsController#reference_error's venue_id_changed? guard.
  def resolve_venue(group, current_venue_id: nil)
    venue = Venue.find_by(id: params[:venue_id], group_id: group.venue_group_ids)
    venue = nil if venue&.archived? && venue.id != current_venue_id
    render_error("venue does not belong to this group") unless venue
    venue
  end

  # Advance in the start_time's own zone. On a TimeWithZone, advance(:weeks/:months)
  # preserves the wall-clock time across DST transitions (unlike adding raw
  # seconds/advancing a UTC time, which would shift a weekly 18:00 by an hour).
  def occurrence_starts(start_time, count, interval)
    unit = Recurring::INTERVALS[interval]
    Array.new(count) { |i| start_time.advance(unit => i) }
  end

  # A user-supplied time is interpreted in `zone`; an explicit offset in the
  # string still wins (Time.zone.parse honors it).
  def parse_time(value, zone)
    return nil if value.blank?
    zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def resolve_zone(tzid, group = nil)
    candidate = tzid.presence || group&.timezone.presence
    (candidate && ActiveSupport::TimeZone[candidate]) || Time.find_zone!("UTC")
  end

  def event_attributes
    params.permit(:title, :content, :timezone, :status, :visibility, :place_id,
      :track_id, :meeting_url, :external_url, :max_participant, :require_approval,
      :category, :kind, :image_url, :image_note, tags: [], requirement_tags: []).to_h.symbolize_keys
  end
end
