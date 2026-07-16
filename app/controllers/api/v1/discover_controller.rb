# Public discovery surfaces: the homepage payload and global search. Both are
# anonymous — they only ever expose public, published content.
class Api::V1::DiscoverController < Api::BaseController
  skip_before_action :authenticate!

  # GET /api/v1/discover
  # The homepage: featured communities, popup cities (groups with a date range
  # + location), and the next public events.
  def index
    featured = Group.where(active: true).where("group_tags && ARRAY['featured','top']::varchar[]")
                    .order(:created_at).limit(20)
    popups = Group.where(active: true).where.not(start_date: nil).where.not(location: [nil, ""])
                  .order(end_date: :desc).limit(50)
    events = Event.includes(:group, :place, :venue, :owner, :track)
                  .where(visibility: "public", status: "published")
                  .where("end_time >= ?", Time.current).order(:start_time).limit(20)

    render json: {
      groups: JSON.parse(GroupBlueprint.render(featured)),
      popup_cities: JSON.parse(GroupBlueprint.render(popups, view: :detail)),
      events: JSON.parse(EventBlueprint.render(events))
    }
  end

  # GET /api/v1/search?keyword=
  def search
    q = params[:keyword].to_s.strip
    return render json: { events: [], groups: [], users: [], badge_classes: [] } if q.length < 2

    like = "%#{Event.sanitize_sql_like(q)}%"
    events = Event.includes(:group, :place, :venue, :owner, :track)
                  .where(visibility: "public", status: "published")
                  .where("title ILIKE ?", like).order(start_time: :desc).limit(10)
    groups = Group.where(active: true)
                  .where("name ILIKE :q OR nickname ILIKE :q", q: like).limit(10)
    users = User.where(active: true)
                .where("name ILIKE :q OR nickname ILIKE :q", q: like).limit(10)
    badge_classes = BadgeClass.where("name ILIKE :q OR title ILIKE :q", q: like).limit(10)

    render json: {
      events: JSON.parse(EventBlueprint.render(events)),
      groups: JSON.parse(GroupBlueprint.render(groups)),
      users: JSON.parse(UserBlueprint.render(users)),
      badge_classes: JSON.parse(BadgeClassBlueprint.render(badge_classes))
    }
  end
end
