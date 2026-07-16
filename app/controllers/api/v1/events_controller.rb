class Api::V1::EventsController < Api::BaseController
  before_action :set_event, only: %i[show update destroy]

  def index
    scope = Event.where(group_id: current_user.groups).visible_to(current_user)
    render_collection scope, blueprint: EventBlueprint
  end

  def show
    authorize @event
    render json: EventBlueprint.render(@event)
  end

  def create
    event = Event.new(event_params.merge(owner: current_user))
    authorize event
    if (err = reference_error(event))
      return render_error(err)
    end
    if event.save
      render json: EventBlueprint.render(event), status: :created
    else
      render_error(event.errors.full_messages.join(", "))
    end
  end

  def update
    authorize @event
    # group_id is intentionally not updatable — moving an event into another
    # group would escape the authorization that was checked against its current
    # group. venue/track references are re-validated against the current group.
    @event.assign_attributes(event_params.except(:group_id))
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

  private

  def set_event
    @event = Event.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # Email every attending participant that the event was cancelled (with an .ics
  # calendar cancellation). Skips participants without an email.
  def notify_attendees_of_cancellation
    each_attendee_email { |email| EventMailer.cancelled(event_id: @event.id, recipient: email).deliver_later }
  end

  # Email attendees an updated invite (bumped SEQUENCE) so their calendars update.
  def notify_attendees_of_update
    each_attendee_email { |email| EventMailer.updated(event_id: @event.id, recipient: email).deliver_later }
  end

  def each_attendee_email
    @event.participants.where(status: "attending").includes(:user).find_each do |participant|
      email = participant.user&.email
      yield email if email.present?
    end
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
      return "venue does not belong to this group" unless venue.group_id == event.group_id
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
    params.require(:event).permit(:title, :content, :start_time, :end_time, :timezone,
      :status, :visibility, :group_id, :place_id, :venue_id, :track_id, :meeting_url,
      :external_url, :max_participant, :require_approval, :category, :kind,
      tags: [], requirement_tags: [])
  end
end
