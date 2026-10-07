class Api::V1::UsersController < Api::BaseController
  # Profile pages are public — auth is optional and only unlocks private fields.
  skip_before_action :authenticate!, only: %i[show groups]
  before_action :authenticate_optional!, only: :show

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
    scope = user.memberships.joins(:group).includes(:group).where(active: true, groups: { active: true })
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

    if params[:user]&.key?(:name) && naming_blocked_pending_phone?
      return render_error("bind a phone number first")
    end

    if current_user.update(user_params)
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

  # A WeChat account has to finish binding its phone before it can take a
  # username, and this is where that is actually enforced — the frontend's
  # redirect chain only suggests the order, and typing /register bypasses it.
  #
  # It matters more than an ordering preference. A blank `name` is the whole
  # merge window (AuthController#mergeable?): while it is blank, binding a phone
  # that already has its own account folds the two together, and once it is set
  # that same bind hard-fails. Since the phone step cannot be skipped, naming
  # first would leave the user permanently stuck on a screen with no way past.
  #
  # Only the FIRST naming is blocked. Once a name exists the window is closed
  # anyway, so refusing a later edit would cost something and protect nothing.
  def naming_blocked_pending_phone?
    phone_login_enabled? &&
      current_user.name.blank? &&
      current_user.phone.blank? &&
      (current_user.wechat_openid.present? || current_user.wechat_unionid.present?)
  end

  # email is intentionally excluded — it's the login identity, not updatable here.
  def user_params
    params.require(:user).permit(:name, :nickname, :bio, :image_url)
  end
end
