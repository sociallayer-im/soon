# A bounded recommendation window, not an exhaustive directory. Shared cache stores
# IDs only; every response rechecks publication/visibility and keeps viewer data private.
class DiscoveryFeed
  POOL = 120
  GROUP_POOL = 40
  EVENT_ASSOCIATIONS = %i[group place venue owner track].freeze
  class InvalidCursor < StandardError; end

  def initialize(user:, city: "上海")
    @user = user
    @city = city == "__all__" ? nil : DiscoveryCity.normalize(city)
    @now = Time.current
  end

  def home
    events = page("events", limit: 12)
    {city: @city, cities: cities, events: events[:data], events_next_cursor: events[:next_cursor],
     groups: page("groups", limit: 12)[:data], campaigns: campaign_cards,
     upcoming: upcoming, joined_groups: joined_groups}
  end

  def community(scope: "discover")
    feed = page("topics", scope: scope, limit: 20)
    people = page("people", limit: 4)
    {city: @city, cities: cities, topics: feed[:data], topics_next_cursor: feed[:next_cursor],
     people: people[:data], people_next_cursor: people[:next_cursor],
     groups: page("groups", limit: 12)[:data], followed_groups: followed_groups}
  end

  def page(kind, scope: "discover", cursor: nil, limit: 20)
    raise InvalidCursor unless %w[events topics groups people].include?(kind) && %w[discover following].include?(scope)
    limit = limit.to_i.clamp(1, 40)
    return event_page(cursor: cursor, limit: limit) if kind == "events"
    if cursor.present?
      snapshot = verifier.verified(cursor, purpose: "discovery-page")&.stringify_keys
      raise InvalidCursor unless snapshot && snapshot.values_at("kind", "city", "viewer", "scope") == [kind, @city, @user&.id, scope]
      ids, position = snapshot.values_at("ids", "position")
    else
      ids, position = ranked_ids(kind, scope), 0
    end
    slice = ids.slice(position, limit) || []
    position += slice.length
    next_cursor = if position < ids.length
      verifier.generate({kind: kind, city: @city, viewer: @user&.id, scope: scope, ids: ids, position: position}, purpose: "discovery-page", expires_in: 15.minutes)
    end
    {data: serialize(kind, slice), next_cursor: next_cursor}
  end

  # A bounded personalized prefix followed by an exhaustive keyset timeline.
  # Cursors carry only prefix IDs and the last (start_time, id), never the directory.
  def event_page(cursor:, limit:)
    state = if cursor.present?
      verifier.verified(cursor, purpose: "discovery-events-v2")&.stringify_keys
    else
      prefix = @user ? ranked_ids("events", "discover").first(12) : []
      {"city" => @city, "viewer" => @user&.id, "prefix" => prefix, "position" => 0}
    end
    raise InvalidCursor unless state && state.values_at("city", "viewer") == [@city, @user&.id]
    prefix = state.fetch("prefix")
    position = state.fetch("position")
    ids = prefix.slice(position, limit) || []
    state["position"] = position + ids.length
    remaining = limit - ids.length
    scope = public_events.where.not(id: prefix)
    if state["after_time"]
      scope = scope.where("(events.start_time, events.id) > (?, ?)", Time.iso8601(state["after_time"]), state["after_id"])
    end
    rows = remaining.positive? ? scope.order(:start_time, :id).limit(remaining + 1).pluck(:id, :start_time) : []
    page_rows = rows.first(remaining)
    ids.concat(page_rows.map(&:first))
    if page_rows.any?
      state["after_id"], at = page_rows.last
      state["after_time"] = at.iso8601(6)
    end
    more = state["position"] < prefix.length || rows.length > remaining || (remaining.zero? && scope.exists?)
    token = more ? verifier.generate(state, purpose: "discovery-events-v2", expires_in: 2.hours) : nil
    {data: serialize("events", ids), next_cursor: token}
  end

  def public_groups
    scope = Group.where(active: true, review_status: "approved")
    @city ? scope.where(browse_city: @city) : scope
  end

  def public_events
    Event.publicly_discoverable.where(group_id: public_groups.select(:id)).where("events.end_time >= ?", @now)
  end

  def public_topics
    return Topic.none unless ENV["DISCUSSION_ENABLED"] == "true"
    DiscoverySignals.public_topics.where(group_id: public_groups.select(:id))
  end

  def context
    @context ||= if @user
      follows = Follow.where(user_id: @user.id, status: "active").pluck(:target_type, :target_id)
      {people: follows.filter_map { |type, id| id if type == "User" }.to_set,
       nodes: follows.filter_map { |type, id| id if type == "Group" }.to_set,
       joined: @user.memberships.pluck(:group_id).to_set}
    else
      {people: Set.new, nodes: Set.new, joined: Set.new}
    end
  end

  def pools
    @pools ||= Rails.cache.fetch(["discovery-pools-v1", @city, ENV["DISCUSSION_ENABLED"]], expires_in: 1.minute, race_condition_ttl: 5.seconds) do
      # Independent index-friendly queries: future events do not scan old rows first.
      future = public_events.where("start_time >= ?", @now).order(:start_time, :id).limit(POOL).pluck(:id)
      ongoing = public_events.where("start_time < ?", @now).order(:end_time, :id).limit(20).pluck(:id)
      {events: (ongoing + future).uniq.first(POOL),
       topics: public_topics.order(created_at: :desc, id: :desc).limit(POOL).pluck(:id),
       groups: public_groups.order(Arel.sql("discovery_active_at DESC NULLS LAST, groups.id DESC")).limit(GROUP_POOL).pluck(:id)}
    end
  end

  def ranked_ids(kind, scope)
    case kind
    when "events"
      rows = public_events.where(id: pools[:events]).select(:id, :owner_id, :group_id, :start_time).to_a
      registered = @user ? Event.agenda_for(@user).where(id: rows.map(&:id)).pluck(:id).to_set : Set.new
      rows.reject! { |event| registered.include?(event.id) }
      rows.sort_by! { |event| [related?(event.owner_id, event.group_id) ? 0 : 1, event.start_time, event.id] }
      diversify(rows, :group_id).map(&:id)
    when "topics"
      rows = if scope == "following"
        return [] unless @user
        # Following is chronological and may include other cities, still public only.
        DiscoverySignals.public_topics.where(user_id: context[:people].to_a)
          .or(DiscoverySignals.public_topics.where(group_id: (context[:nodes] | context[:joined]).to_a))
          .where(ENV["DISCUSSION_ENABLED"] == "true" ? nil : "1=0")
          .order(created_at: :desc, id: :desc).limit(POOL).select(:id, :user_id, :group_id, :created_at).to_a
      else
        public_topics.where(id: pools[:topics]).select(:id, :user_id, :group_id, :created_at).to_a
          .sort_by { |post| [related?(post.user_id, post.group_id) ? 0 : 1, -post.created_at.to_f, post.id] }
      end
      (scope == "following" ? rows : diversify(rows, :user_id)).map(&:id)
    when "groups"
      rows = public_groups.where(id: pools[:groups]).select(:id, :discovery_active_at).to_a
      rows.sort_by { |group| [(context[:nodes] | context[:joined]).include?(group.id) ? 0 : 1, -(group.discovery_active_at&.to_f || 0), group.id] }.map(&:id)
    when "people"
      contributions = {}
      public_events.where(id: pools[:events]).pluck(:owner_id, :created_at).each { |id, at| contributions[id] = [contributions[id], at].compact.max }
      public_topics.where(id: pools[:topics]).pluck(:user_id, :created_at).each { |id, at| contributions[id] = [contributions[id], at].compact.max }
      ids = User.publicly_discoverable.where(id: contributions.keys).where.not(name: [nil, ""]).where.not(id: context[:people].to_a + [@user&.id].compact).pluck(:id)
      common = common_members(ids)
      ids.sort_by { |id| [common.include?(id) ? 0 : 1, -contributions.fetch(id).to_f, id] }.first(POOL)
    end
  end

  def related?(person, node)
    context[:people].include?(person) || context[:nodes].include?(node) || context[:joined].include?(node)
  end

  # Preserve all candidates; defer excess rows rather than silently discard them.
  def diversify(rows, key)
    counts = Hash.new(0)
    first, deferred = rows.partition { |row| counts[row.public_send(key)] += 1; counts[row.public_send(key)] <= 2 }
    first + deferred
  end

  def serialize(kind, ids)
    return [] if ids.empty?
    case kind
    when "events"
      events = event_records(public_events.where(id: ids)).index_by(&:id)
      ids.filter_map do |id|
        event = events[id]
        next unless event
        card = JSON.parse(EventBlueprint.render(event))
        card["recommendation_reason"] = !@user ? nil : related?(event.owner_id, event.group_id) ? "来自你关注的人或群组" : @city ? "#{@city} · 即将发生" : "即将发生"
        card
      end
    when "topics"
      # Both discovery/following pages re-authorize against public scope at read time.
      visible = ENV["DISCUSSION_ENABLED"] == "true" ? DiscoverySignals.public_topics : Topic.none
      columns = Topic.column_names.reject { |name| name == "content" }.map { |name| "topics.#{name}" }
      rows = visible.where(id: ids).select(*columns, Arel.sql("LEFT(topics.content, 1200) AS content")).includes(:user, :category, :last_reply_user).index_by(&:id)
      linked = event_records(Event.publicly_discoverable.where(id: rows.values.filter_map(&:event_id))).index_by(&:id)
      ids.filter_map do |id|
        post = rows[id]
        next unless post
        card = JSON.parse(TopicBlueprint.render(post))
        card["content"] = post.content
        card["event"] = JSON.parse(EventBlueprint.render(linked[post.event_id])) if linked[post.event_id]
        card
      end.tap do |cards|
        names = Group.where(id: cards.map { |card| card["group_id"] }).pluck(:id, :nickname, :name).to_h { |id, nickname, name| [id, nickname.presence || name] }
        cards.each { |card| card["group_name"] = names[card["group_id"]] }
      end
    when "groups"
      rows = public_groups.where(id: ids).index_by(&:id)
      ids.filter_map { |id| JSON.parse(GroupBlueprint.render(rows[id], view: :card)) if rows[id] }
    when "people"
      # A signed cursor cannot keep recommending a person whose last public
      # contribution was removed after the snapshot was made.
      valid = (public_events.where(owner_id: ids).distinct.pluck(:owner_id) + public_topics.where(user_id: ids).distinct.pluck(:user_id)).uniq
      rows = User.publicly_discoverable.where(id: valid).where.not(id: context[:people].to_a + [@user&.id].compact).select(:id, :name, :nickname, :image_url, :bio, :data).index_by(&:id)
      common = common_members(rows.keys)
      ids.filter_map do |id|
        next unless rows[id]
        JSON.parse(UserSuggestionBlueprint.render(rows[id], recommendation_reason: common.include?(id) ? "与你在同一个群组" : "#{@city ? @city+' · ' : ''}近期有公开分享"))
      end
    end
  end

  def event_records(scope)
    # Never load multi-megabyte Markdown/notes for cards.
    scope.select(*(Event.column_names - %w[content notes image_note])).includes(*EVENT_ASSOCIATIONS).to_a
  end

  def common_members(ids)
    return Set.new unless @user && ids.any? && context[:joined].any?
    Membership.where(user_id: ids, group_id: context[:joined].to_a).distinct.pluck(:user_id).to_set
  end

  def upcoming
    return [] unless @user
    valid = Participant.where(user_id: @user.id, status: "attending", payment_status: [nil, "succeeded"]).select(:event_id)
    window = Event.where(status: "published").where("start_time > ?", @now)
    # Three bounded index lookups avoid an OR over the entire event history.
    mine = window.where(owner_id: @user.id).order(:start_time, :id).limit(6).pluck(:id)
    guest = window.where(id: EventRole.linked_to(@user).select(:event_id)).order(:start_time, :id).limit(6).pluck(:id)
    attending = window.where(id: valid).order(:start_time, :id).limit(6).pluck(:id)
    records = event_records(window.where(id: (mine + guest + attending).uniq).order(:start_time, :id).limit(6))
    team = Event.team_for(@user).where(id: records.map(&:id)).pluck(:id).to_set
    JSON.parse(EventBlueprint.render(records, viewer_id: @user.id, attending_ids: records.map(&:id).to_set, event_team_ids: team))
  end

  def joined_groups
    return [] unless @user
    JSON.parse(GroupBlueprint.render(Group.where(id: context[:joined].to_a).order(:name).limit(20), view: :card))
  end

  def followed_groups
    return [] unless @user
    JSON.parse(GroupBlueprint.render(Group.where(active: true, review_status: "approved", id: (context[:nodes] | context[:joined]).to_a).order(:name).limit(20), view: :card))
  end

  def campaign_cards
    # Only campaigns with an upcoming/ongoing public event enter this surface.
    events = public_events.where(id: pools[:events]).select(:id)
    ids = CampaignEvent.joins(:event, :campaign).merge(public_events).where(event_id: events,
      campaigns: {status: "published", review_status: "approved", group_id: Group.where(active: true, review_status: "approved").select(:id)})
      .group(:campaign_id).order(Arel.sql("MIN(events.start_time), campaign_id")).limit(12).pluck(:campaign_id)
    rows = Campaign.where(id: ids, status: "published").to_a
    details = CampaignEvent.joins(:event).merge(public_events).where(campaign_id: rows.map(&:id))
      .group(:campaign_id).pluck(:campaign_id, Arel.sql("MIN(events.start_time)"), Arel.sql("COUNT(*)")).to_h { |id, at, count| [id, {at: at, count: count}] }
    rows.sort_by { |campaign| [details.dig(campaign.id, :at) || 100.years.from_now, campaign.id] }.filter_map do |campaign|
      next unless details[campaign.id]
      {id: campaign.id, group_id: campaign.group_id, title: campaign.title, status: campaign.status,
       introduction: campaign.introduction.to_s.first(500), kicker: campaign.kicker, cover_url: campaign.cover_url.presence || campaign.media.first&.fetch("url", nil),
       event_ids: [], event_count: details[campaign.id][:count], next_event_at: details[campaign.id][:at]}
    end
  end

  def cities
    Rails.cache.fetch("discovery-cities-v1", expires_in: 1.minute, race_condition_ttl: 5.seconds) do
      Group.where(active: true, review_status: "approved").where.not(browse_city: [nil, ""]).distinct.order(:browse_city).pluck(:browse_city)
    end
  end

  def verifier = Rails.application.message_verifier("discovery-page")
end
