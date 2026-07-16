class Api::V1::RecurringController < Api::BaseController
  # GET /api/v1/recurring/:id
  def show
    recurring = Recurring.find(params[:id])
    render json: RecurringBlueprint.render(recurring, view: :with_events)
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

    start_time = parse_time(params[:start_time])
    end_time   = parse_time(params[:end_time])
    return render_error("invalid start_time/end_time") unless start_time && end_time && end_time > start_time
    duration = end_time - start_time

    venue = params[:venue_id].present? ? resolve_venue(group) : nil
    return if performed?

    occurrences = occurrence_starts(start_time, count, interval)

    if venue
      occurrences.each do |occ_start|
        ok, message = venue.check_availability(occ_start, occ_start + duration, params[:timezone])
        return render_error("#{message} (#{occ_start.to_date})") unless ok
      end
    end

    recurring = nil
    ActiveRecord::Base.transaction do
      recurring = Recurring.create!(
        start_time: start_time, end_time: occurrences.last + duration,
        interval: interval, event_count: count, timezone: params[:timezone]
      )
      occurrences.each do |occ_start|
        Event.create!(event_attributes.merge(
          group: group, owner: current_user, recurring_id: recurring.id,
          venue_id: venue&.id, start_time: occ_start, end_time: occ_start + duration
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
  # Optional start_time_diff/end_time_diff (seconds) shift each occurrence; a new
  # venue_id re-checks availability for every affected occurrence first.
  def update
    events = selected_events(params[:recurring_id], selector: params[:selector], pivot_id: params[:after_event_id])
    return if performed?
    authorize events.first, :update?

    start_diff = params[:start_time_diff].to_i
    end_diff   = params[:end_time_diff].to_i

    venue = params[:venue_id].present? ? resolve_venue(events.first.group) : nil
    return if performed?

    if venue
      events.each do |event|
        s = event.start_time + start_diff.seconds
        e = event.end_time + end_diff.seconds
        ok, message = venue.check_availability(s, e, event.timezone, event.id)
        return render_error(message) unless ok
      end
    end

    attrs = event_attributes
    ActiveRecord::Base.transaction do
      events.each do |event|
        changes = attrs.dup
        changes[:start_time] = event.start_time + start_diff.seconds if params.key?(:start_time_diff)
        changes[:end_time]   = event.end_time + end_diff.seconds if params.key?(:end_time_diff)
        changes[:venue_id]   = venue.id if venue
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

  def resolve_venue(group)
    venue = Venue.find_by(id: params[:venue_id], group_id: group.id)
    render_error("venue does not belong to this group") unless venue
    venue
  end

  def occurrence_starts(start_time, count, interval)
    unit = Recurring::INTERVALS[interval]
    Array.new(count) { |i| start_time.advance(unit => i) }
  end

  def parse_time(value)
    return nil if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def event_attributes
    params.permit(:title, :content, :timezone, :status, :visibility, :place_id,
      :track_id, :meeting_url, :external_url, :max_participant, :require_approval,
      :category, :kind, tags: [], requirement_tags: []).to_h.symbolize_keys
  end
end
