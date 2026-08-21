class Api::V1::CalendarsController < Api::BaseController
  # Calendar feeds are public so Apple Calendar / Google can subscribe by URL
  # (subscriptions can't carry a JWT). Only public, non-draft content is exposed.
  skip_before_action :authenticate!

  # GET /api/v1/events/:id/calendar(.ics)
  #
  # A single event as a downloadable / subscribable calendar.
  def event
    event = Event.find_by_id_or_legacy!(params[:id])
    return render_not_found unless calendar_visible?(event)

    send_calendar(EventCalendar.for_event(event, method: "PUBLISH"), filename: "event-#{event.id}.ics")
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/groups/:id/calendar(.ics)
  #
  # The group's public, published events as a subscribable feed. Subscribe in
  # Apple Calendar via webcal://<host>/api/v1/groups/:id/calendar.ics
  def group
    render_group_feed(Group.resolve!(params[:id])) # TSID or slug — subscription URLs use the slug
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /group/icalendar?group_name=<slug>   (or ?group_id=<legacy integer>)
  #
  # The path the legacy sails backend served. Calendar subscription URLs live
  # inside people's calendar apps — Apple Calendar, Google, Outlook — and cannot
  # be updated once handed out, so unlike the other legacy routes this one has
  # to keep working indefinitely rather than just through the migration. It also
  # fails silently: a subscriber sees a calendar that quietly stops updating,
  # not an error, so nobody reports it.
  #
  # Serves exactly the same feed as /api/v1/groups/:id/calendar.ics. The UID
  # scheme differs from sails' ("event-<tsid>@host" vs "sola-<integer>"), so
  # subscribers' clients replace the entries once — acceptable, and far better
  # than keeping two UID schemes alive for the same events.
  def legacy_group
    identifier = params[:group_name].presence || params[:group_id].presence
    return render_not_found if identifier.blank?

    render_group_feed(Group.resolve!(identifier))
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  private

  def render_group_feed(group)
    events = group.events
      .includes(:place)
      .where(visibility: %w[normal open_registration], status: "published")
      .where("end_time IS NULL OR end_time > ?", 90.days.ago)
      .order(:start_time)

    send_calendar(EventCalendar.feed(events, name: "#{group.display_name} — #{ApplicationMailer::BRAND_NAME}"),
      filename: "group-#{group.id}.ics")
  end

  # Is this event world-visible? Delegated to Event.visible_to(nil) — the
  # anonymous case of the one scope that defines listing visibility — rather
  # than re-stating its status list here. The hand-copied version of that list
  # had already drifted out of sync, missing both `pending` (awaiting manager
  # approval) and `cancelled`, so a cancelled event still exported a normal ICS
  # entry that a subscriber's calendar happily kept showing.
  def calendar_visible?(event)
    Event.visible_to(nil).exists?(id: event.id)
  end

  def send_calendar(ics, filename:)
    response.headers["Content-Disposition"] = %(inline; filename="#{filename}")
    render body: ics, content_type: "text/calendar; charset=utf-8"
  end
end
