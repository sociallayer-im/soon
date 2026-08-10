# Public discovery surfaces: the homepage payload and global search. Both are
# anonymous — they only ever expose public, published content.
class Api::V1::DiscoverController < Api::BaseController
  skip_before_action :authenticate!

  # GET /api/v1/discover
  # The homepage: featured communities, popup cities, and the next public events.
  #
  # "Popup cities" is a curated list, not "any group that happens to have
  # dates" — homepage curation is a deploy-side decision (see
  # GroupsController::PRIVILEGED_TAGS), matching sails' equivalent
  # `event/discover` (Group tagged "top", excluding "hidden", ordered by
  # start_date desc). The frontend further splits "featured" out of this same
  # list client-side by checking group_tags for "featured" — see
  # sola-sdk/popup_city.ts — so "featured" groups must also carry "top" to
  # appear in the popup-city carousel at all, same as sails.
  def index
    featured = Group.where(active: true).where("group_tags && ARRAY['featured','top']::varchar[]")
                    .order(:created_at).limit(20)
    popups = Group.where(active: true).where("group_tags && ARRAY['top']::varchar[]")
                  .where.not("group_tags && ARRAY['hidden']::varchar[]")
                  .order(start_date: :desc).limit(50)
    events = Event.includes(:group, :place, :venue, :owner, :track)
                  .where(visibility: "public", status: "published")
                  .where("end_time >= ?", Time.current).order(:start_time).limit(20)

    # Every active community, not a curated slice — this is the homepage's
    # "社区" list, and a group should appear there by existing, not by being
    # tagged. `groups` above stays tag-gated because it feeds curation
    # (featured/top); the two answer different questions and a group can be in
    # one without the other.
    #
    # Ordered oldest-first, which is simply the order the API returns: the
    # frontend renders the list as given rather than re-sorting. The limit is a
    # guard against an unbounded homepage payload, not a product decision — if
    # a deployment ever passes it, this needs paging rather than a bigger number.
    communities = Group.where(active: true).order(:created_at).limit(100)

    render json: {
      groups: JSON.parse(GroupBlueprint.render(featured)),
      # :card, not the default view — the community card shows member and event
      # counts, and those two fields only exist there.
      communities: JSON.parse(GroupBlueprint.render(communities, view: :card)),
      popup_cities: JSON.parse(GroupBlueprint.render(popups, view: :card)),
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
