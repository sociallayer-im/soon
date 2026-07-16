class Api::V1::CalendarsController < Api::BaseController
  # Calendar feeds are public so Apple Calendar / Google can subscribe by URL
  # (subscriptions can't carry a JWT). Only public, non-draft content is exposed.
  skip_before_action :authenticate!

  # GET /api/v1/events/:id/calendar(.ics)
  #
  # A single event as a downloadable / subscribable calendar.
  def event
    event = Event.find(params[:id])
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
    group = Group.find(params[:id])
    events = group.events
      .where(visibility: "public", status: "published")
      .where("end_time IS NULL OR end_time > ?", 90.days.ago)
      .order(:start_time)

    send_calendar(EventCalendar.feed(events, name: "#{group.display_name} — #{ApplicationMailer::BRAND_NAME}"),
      filename: "group-#{group.id}.ics")
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  private

  # A public, non-draft/archived event is world-visible (mirrors Event.visible_to
  # for anonymous callers). Private/draft events aren't exposed through the feed.
  def calendar_visible?(event)
    event.visibility == "public" && !%w[draft archived].include?(event.status)
  end

  def send_calendar(ics, filename:)
    response.headers["Content-Disposition"] = %(inline; filename="#{filename}")
    render body: ics, content_type: "text/calendar; charset=utf-8"
  end
end
