class Api::V1::GroupsController < Api::BaseController
  # Group pages and the public directory are public.
  skip_before_action :authenticate!, only: %i[show directory]
  before_action :set_group, only: %i[update destroy freeze send_email]

  def index
    render_collection current_user.groups, blueprint: GroupBlueprint
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
    render_collection Group.where(active: true).order(:created_at),
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
    group = Group.with_detail_associations.resolve!(params[:id])
    render json: GroupBlueprint.render(group, view: :detail,
                                       member_group_ids: member_group_ids)
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
    group = Group.new(group_params)
    authorize group
    return render_error("you do not manage the parent group", status: :forbidden) unless parent_ok?(group.parent_id)

    ActiveRecord::Base.transaction do
      group.save!
      group.add_member(current_user.id, "owner") # counter_cache keeps memberships_count right
    end
    # Enqueued after the transaction commits, not inside it — a job picked up
    # before the commit lands would look up a group that isn't there yet.
    GroupRegisteredMailJob.perform_later(group_id: group.id)
    render json: GroupBlueprint.render(group, view: :detail,
                                       member_group_ids: member_group_ids), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
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
    @group.destroy
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
    permitted = params.require(:group).permit(:name, :nickname, :timezone, :location,
      :start_date, :end_date, :bio, :image_url, :logo_url, :parent_id,
      :banner_image_url, :banner_link_url, :banner_text, :featured_image_url,
      :can_publish_event, :can_join_event, :can_view_event, :require_event_approval,
      :discussion_enabled, :can_post_topic, :map_enabled,
      :poll_enabled, :can_create_poll,
      :hackathon_enabled, :can_create_hackathon,
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
