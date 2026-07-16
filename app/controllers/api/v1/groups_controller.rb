class Api::V1::GroupsController < Api::BaseController
  before_action :set_group, only: %i[show update destroy]

  def index
    render_collection current_user.groups, blueprint: GroupBlueprint
  end

  def show
    render json: GroupBlueprint.render(@group)
  end

  def create
    group = Group.new(group_params)
    authorize group
    return render_error("you do not manage the parent group", status: :forbidden) unless parent_ok?(group.parent_id)

    ActiveRecord::Base.transaction do
      group.save!
      group.add_member(current_user.id, "owner") # counter_cache keeps memberships_count right
    end
    render json: GroupBlueprint.render(group), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def update
    authorize @group
    return render_error("you do not manage the parent group", status: :forbidden) unless parent_ok?(group_params[:parent_id])

    if @group.update(group_params)
      render json: GroupBlueprint.render(@group)
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

  def group_params
    params.require(:group).permit(:name, :nickname, :timezone, :location,
      :start_date, :end_date, :bio, :image_url, :logo_url, :parent_id)
  end
end
