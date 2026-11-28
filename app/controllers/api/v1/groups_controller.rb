class Api::V1::GroupsController < Api::BaseController
  include IdempotentCreation
  # Group pages and the public directory are public.
  skip_before_action :authenticate!, only: %i[show directory]
  before_action :set_group, only: %i[update destroy freeze send_email resubmit]

  def index
    scope = current_user.groups
    scope = scope.where(city: params[:city].to_s.strip) if params[:city].present?
    render_collection scope, blueprint: GroupBlueprint
  end

  # GET /api/v1/groups/directory — every active group, paginated.
  #
  # Distinct from #index, which is "the groups I belong to" and needs a token.
  # This is the public browse-all list behind /communities, and the only place
  # an admin can reach a group that carries no curation tag yet — the homepage
  # payload only ever returns tagged ones, so an untagged group was previously
  # unreachable from any list and could never be tagged through the UI.
  #
  # :card, because the cards show member/event counts and the tag state the
  # admin controls read.
  def directory
    authenticate_optional!
    scope = Group.where(active: true).order(:created_at)
    scope = scope.where(city: params[:city].to_s.strip) if params[:city].present?
    if params[:purpose].present?
      return render_error("请先登录", status: :unauthorized) unless current_user
      return render_error("invalid purpose") unless %w[event post campaign].include?(params[:purpose])
      if params[:purpose] == "campaign"
        scope = scope.where(id: current_user.memberships.active.where(role: %w[owner manager]).select(:group_id)) unless current_user.platform_admin?
        return render_collection scope, blueprint: GroupBlueprint, view: :card
      end
      allowed = scope.select do |group|
        if params[:purpose] == "event"
          EventPolicy.new(current_user, Event.new(group: group)).create?
        else
          group.discussion_enabled? && Category.visible_to(current_user, group: group).listed.any? { |category| TopicPolicy.new(current_user, Topic.new(group: group, category: category)).create? }
        end
      end.map(&:id)
      scope = scope.where(id: allowed)
    end
    render_collection scope,
      blueprint: GroupBlueprint, view: :card
  end

  # :id accepts a TSID or the group's slug (Group.resolve!).
  def show
    # Personalizes in exactly one way: a member of the group sees its private
    # team badges on the roster, an outsider sees only the public ones. Still
    # safe to cache for anonymous callers — cache_when_anonymous! no-ops as
    # soon as there is a current_user, so a signed-in response is never stored.
    authenticate_optional!
    cache_when_anonymous!(max_age: 30)
    compact = ActiveModel::Type::Boolean.new.cast(params[:compact])
    scope = compact ? Group.includes(:parent, :children, tracks: :group) : Group.with_detail_associations
    group = scope.resolve!(params[:id])
    return render_not_found unless group.review_status == "approved" || GroupPolicy.new(current_user, group).manage?
    render json: GroupBlueprint.render(group, view: :detail,
                                       compact: compact, viewer: current_user, member_group_ids: member_group_ids, review_history: GroupPolicy.new(current_user,group).manage?)
  end

  # POST /api/v1/groups/:id/freeze
  # Freezing deactivates a group without destroying anything — owner only.
  def freeze
    authorize @group
    @group.update!(active: false)
    render json: GroupBlueprint.render(@group, view: :detail, member_group_ids: member_group_ids)
  end

  # POST /api/v1/groups/:id/send_email — manager broadcast to members.
  # With test_recipient set, sends ONLY to that address (preview mode).
  def send_email
    authorize @group, :manage?
    subject = params[:subject].to_s.strip
    content = params[:content].to_s.strip
    return render_error("subject and content are required") if subject.blank? || content.blank?

    if params[:test_recipient].present?
      GroupMailer.member_broadcast(group_id: @group.id, subject: subject,
        content: content, recipient: params[:test_recipient]).deliver_later
      return render json: { sent_count: 1, test: true }
    end

    # The per-member fan-out happens in the job; the request only needs to
    # report how many people it will reach, which is the same scope counted.
    GroupBroadcastMailJob.perform_later(group_id: @group.id, subject: subject, content: content)
    render json: { sent_count: @group.member_emails.size, test: false }
  end

  def create
    attrs = group_params.to_h
    if SurfGroupVisibility.group_ids
      id = Group.generate_tsid
      # Scope this request to the new application too. Future requests still use the allowlist.
      SurfGroupVisibility.group_ids = SurfGroupVisibility.group_ids + [id]
      attrs = { discussion_enabled: true, can_post_topic: "everyone" }.with_indifferent_access.merge(attrs).merge(id: id)
    end
    group = Group.new(attrs.merge(review_status: "pending", active: false))
    authorize group
    group.name = "g#{SecureRandom.hex(9)}" if group.name.blank?
    return render_error("you do not manage the parent group", status: :forbidden) unless parent_ok?(group.parent_id)

    manager_ids = Array(params[:manager_ids]).map(&:to_s).reject(&:blank?).uniq - [current_user.id]
    return render_error("最多指定10位管理员") if manager_ids.length > 10
    managers = User.where(id: manager_ids, active: true).to_a
    return render_error("请选择有效且可用的管理员账号") unless managers.length == manager_ids.length
    ActiveRecord::Base.transaction do
      group.save!
      group.add_member(current_user.id, "owner") # creator remains owner, never demoted
      managers.each do |manager|
        group.add_member(manager.id, "manager")
        SiteNotifications.emit(receiver: manager, item: group, action: "membership_role", title: "你已被设为群组管理员",
          body: "你已成为「#{group.nickname.presence || group.name}」的管理员。群组目前等待平台审核。", actor: current_user,
          key: "group-manager:#{group.id}:#{manager.id}")
      end
      ReviewNotifications.submitted(group, applicant: current_user, cycle: "created")
    end
    # Enqueued after the transaction commits, not inside it — a job picked up
    # before the commit lands would look up a group that isn't there yet.
    GroupRegisteredMailJob.perform_later(group_id: group.id)
    render json: GroupBlueprint.render(group, view: :detail,
                                       member_group_ids: member_group_ids), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def resubmit
    authorize @group, :manage?
    @group.with_lock do
      return render_error("仅已拒绝的申请可重新提交", status: :conflict) unless @group.review_status == "rejected"
      @group.group_review_logs.create!(reviewer: current_user, decision: "resubmitted", reason: @group.review_reason)
      @group.update!(review_status: "pending", active: false, review_reason: nil, reviewed_at: nil, reviewed_by_id: nil)
      ReviewNotifications.submitted(@group, applicant: current_user)
    end
    GroupRegisteredMailJob.perform_later(group_id: @group.id)
    render json: GroupBlueprint.render(@group, view: :detail)
  end

  def update
    authorize @group
    return render_error("you do not manage the parent group", status: :forbidden) unless parent_ok?(group_params[:parent_id])

    if @group.update(group_params)
      render json: GroupBlueprint.render(@group, view: :detail,
                                         member_group_ids: member_group_ids)
    else
      render_error(@group.errors.full_messages.join(", "))
    end
  end

  def destroy
    authorize @group
    return render_error(@group.errors.full_messages.join(", ")) unless @group.destroy
    head :no_content
  end

  private

  def set_group
    @group = Group.find(params[:id])
  end

  # You can only nest a group under a parent you actually manage — otherwise
  # anyone could attach their group as a child of someone else's.
  def parent_ok?(parent_id)
    return true if parent_id.blank?
    parent = Group.find_by(id: parent_id)
    parent && GroupPolicy.new(current_user, parent).manage?
  end

  # Tags a group cannot grant itself — homepage curation belongs to platform
  # admins, not to whoever owns the group. `pin` is here for the same reason as
  # the other two: it decides what shows in the homepage community grid, so
  # leaving it open would let any group put itself on the front page.
  PRIVILEGED_TAGS = %w[featured top pin].freeze

  def group_params
    permitted = params.require(:group).permit(:name, :nickname, :timezone, :location, :city, :latitude, :longitude,
      :start_date, :end_date, :bio, :image_url, :logo_url, :parent_id,
      :banner_image_url, :banner_link_url, :banner_text, :featured_image_url,
      :can_publish_event, :can_join_event, :can_view_event, :require_event_approval,
      :discussion_enabled, :can_post_topic, :map_enabled,
      :poll_enabled, :can_create_poll,
      :hackathon_enabled, :can_create_hackathon,
      :community_projects_enabled, :community_projects_intro,
      social_links: {}, group_tags: [], event_tag_list: [],
      requirement_tag_list: [], venue_tag_list: [])

    # Strip privileged tags a caller tries to add (platform admins are the
    # curators and may set them); keep ones the group already has.
    if permitted[:group_tags] && !current_user.platform_admin?
      existing = @group ? (@group.group_tags & PRIVILEGED_TAGS) : []
      permitted[:group_tags] = (permitted[:group_tags] - PRIVILEGED_TAGS) | existing
    end
    permitted
  end
end
