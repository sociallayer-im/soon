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
    if group.save
      group.memberships.create!(user: current_user, role: "owner")
      render json: GroupBlueprint.render(group), status: :created
    else
      render_error(group.errors.full_messages.join(", "))
    end
  end

  def update
    authorize @group
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
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def group_params
    params.require(:group).permit(:name)
  end
end
