class Api::V1::UsersController < Api::BaseController
  # Profile pages are public — auth is optional and only unlocks private fields.
  skip_before_action :authenticate!, only: %i[show groups suggestions]
  before_action :authenticate_optional!, only: %i[show suggestions]

  # Authenticated picker: rank only public contributions, never sign-in times.
  def role_candidates
    events = Event.publicly_discoverable
    activity = events.group(:owner_id).maximum(:created_at)
    Topic.joins(:category, :group).where(groups: {active: true}, categories: {visibility: "public", archived: false}, event_id: nil, flagged_at: nil, deleted_at: nil).group(:user_id).maximum(:created_at).each do |id, time|
      activity[id] = [activity[id], time].compact.max
    end
    ids = activity.sort_by { |id, time| [-time.to_f, id] }.map(&:first)
    keyword = params[:keyword].to_s.strip
    scope = User.publicly_discoverable
    if keyword.present?
      like = "%#{User.sanitize_sql_like(keyword)}%"
      scope = scope.where("name ILIKE :q OR nickname ILIKE :q", q: like).order(:id)
      return render_collection scope, blueprint: UserBlueprint, view: :profile
    end
    scope = scope.where(id: ids)
    if ids.any?
      clauses = ids.each_with_index.map { |id, index| "WHEN #{User.connection.quote(id)} THEN #{index}" }.join(" ")
      scope = scope.order(Arel.sql("CASE users.id #{clauses} END"))
    end
    render_collection scope, blueprint: UserBlueprint, view: :profile
  end

  # Discover public organizers, never an unrestricted directory of accounts.
  def suggestions
    events = Event.publicly_discoverable
                  .where("events.end_time >= ?", Time.current)
    city = params[:city].to_s.strip
    return render_error("city is too long") if city.length > 100
    events = events.where(groups: { city: city }) if city.present?
    scope = User.where(active: true, id: events.select(:owner_id)).where.not(name: [nil, ""])
                .where("COALESCE(users.data->>'visibility', 'public') = 'public'")
    if current_user
      followed = Follow.where(user: current_user, target_type: "User", status: %w[active pending]).select(:target_id)
      scope = scope.where.not(id: current_user.id).where.not(id: followed)
    end
    # Stable order makes page changes deterministic; no random ordering or PII.
    render_collection scope.order(created_at: :desc, id: :desc), blueprint: UserSuggestionBlueprint,
                      recommendation_reason: city.present? ? "同城活动发起人" : "公开活动发起人"
  end

  # :id accepts "me", a TSID, or a username (User.resolve!).
  def show
    if params[:id] == "me"
      return render json: { error: "Unauthorized" }, status: :unauthorized unless current_user
      return render json: UserBlueprint.render(current_user, view: :self)
    end

    user = User.resolve!(params[:id])
    # Own record gets private fields (email); everyone else the public profile.
    view = user.id == current_user&.id ? :self : :profile
    render json: UserBlueprint.render(user, view: view)
  end

  # GET /api/v1/users/by_email?email= — platform-admin-only. Email is the login
  # identity and is never exposed on a public profile, so an open lookup would
  # be an account-enumeration oracle; restricting it to admins (who already
  # hold `merge`) keeps it an operator tool. Returns the public profile shape —
  # the caller supplied the email, so echoing it back adds nothing.
  def by_email
    return render_error("forbidden", status: :forbidden) unless current_user.platform_admin?

    email = User.normalize_value_for(:email, params[:email].to_s)
    return render_error("email is required") if email.blank?

    user = User.find_by(email: email)
    return render_error("User not found", status: :not_found) unless user

    render json: UserBlueprint.render(user, view: :profile)
  end

  # GET /api/v1/users/:id/groups?role=owner,admin — a user's public group
  # memberships (their profile page's "communities"), optionally by role.
  def groups
    user = User.resolve!(params[:id])
    authenticate_optional!
    scope = user.memberships.joins(:group).includes(:group).where(active: true)
    scope = if current_user&.id == user.id
      scope.where("groups.active = TRUE OR groups.review_status IN ('pending', 'rejected')")
    else
      scope.where(groups: { active: true })
    end
    scope = scope.where(role: params[:role].to_s.split(",")) if params[:role].present?
    # Ordered by when this user joined each group, not when the group itself
    # was created — sails' equivalent happened to sort by group creation
    # (an artifact of `Group.where(id: ...)`'s natural PK order, not a
    # deliberate choice), but join time is the more sensible sort for "this
    # person's communities" and is what we intentionally keep here.
    authenticate_optional!
    render json: MembershipBlueprint.render(scope.includes(user: :teams).order(created_at: :asc, id: :asc),
                                            view: :with_group, member_group_ids: member_group_ids)
  end

  def update
    # The model allows a nil name (wallet users pre-registration), but you
    # can't blank out a name you already picked — it's your public identity.
    if params[:user]&.key?(:name) && params[:user][:name].blank?
      return render_error("name can't be blank")
    end

    attributes = user_params.to_h
    if attributes["social_links"]
      attributes["social_links"] = current_user.social_links.to_h.merge(attributes["social_links"])
    end
    if attributes["data"]
      attributes["data"] = current_user.data.to_h.merge(attributes["data"])
    end
    if current_user.update(attributes)
      render json: UserBlueprint.render(current_user, view: :self)
    else
      render_error(current_user.errors.full_messages.join(", "))
    end
  end

  # POST /api/v1/users/merge {from_id, into_id} — platform-admin-only. Moves
  # every piece of data `from_id` owns onto `into_id` (memberships, events,
  # badges, comments, ...; deduping anywhere a unique index would otherwise
  # collide) and destroys `from_id`. Irreversible. Does NOT carry login
  # identity (email/phone/eth/sol/wechat) — that is a narrower, separate
  # operation (AuthController#merge_wechat_account!).
  def merge
    return render_error("forbidden", status: :forbidden) unless current_user.platform_admin?

    from = User.resolve!(params[:from_id])
    into = User.resolve!(params[:into_id])

    begin
      UserMerger.call(from: from, into: into)
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      return render_error(e.message)
    end

    render json: UserBlueprint.render(into, view: :self)
  end

  private

  # email is intentionally excluded — it's the login identity, not updatable here.
  def user_params
    params.require(:user).permit(:name, :nickname, :bio, :image_url, data: [:city], social_links: [:website, :twitter, :github, :telegram, :discord, :ens, :lens, :nostr])
  end
end
