class Api::V1::CategoriesController < Api::BaseController
  include DiscussionGate
  include SlugGenerator

  before_action :require_discussion_enabled!
  skip_before_action :authenticate!, only: :index
  before_action :authenticate_optional!, only: :index
  before_action :set_category, only: %i[update destroy]

  # GET /api/v1/categories?group_id=
  #
  # Returns only the boards this caller may see. There is no show action on
  # purpose: the list is small enough to send whole, and every extra endpoint
  # is another place the visibility rule would have to be repeated.
  def index
    group = Group.resolve!(params[:group_id])
    return render_not_found unless group.discussion_enabled?

    scope = Category.visible_to(current_user, group: group).sorted
    scope = scope.listed unless params[:include_archived] == "true"
    render_collection scope, blueprint: CategoryBlueprint
  end

  def create
    group = Group.resolve!(category_params[:group_id])
    return render_not_found unless group.discussion_enabled?
    authorize group, :manage?, policy_class: GroupPolicy

    category = group.categories.new(category_params.except(:group_id, :team_ids))
    category.slug = generate_slug(category.name) { |s| group.categories.exists?(slug: s) } if category.slug.blank?
    ActiveRecord::Base.transaction do
      category.save!
      sync_teams!(category)
    end
    render json: CategoryBlueprint.render(category.reload), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def update
    authorize @category, :update?
    ActiveRecord::Base.transaction do
      @category.update!(category_params.except(:group_id, :team_ids))
      sync_teams!(@category)
    end
    render json: CategoryBlueprint.render(@category.reload)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # DELETE /api/v1/categories/:id
  #
  # Only an empty board can be deleted. topics.category_id is null: false and
  # a topic's visibility is entirely derived from its board, so deleting a
  # board with posts would mean either cascading the posts away or leaving
  # rows whose visibility is undefined. Archiving is how a board goes away.
  def destroy
    authorize @category, :destroy?
    if @category.topics.with_deleted.exists?
      return render_error("category still has topics; archive it instead",
                          status: :unprocessable_entity)
    end

    @category.destroy!
    render json: { result: "ok" }
  end

  private

  def set_category
    @category = Category.find(params[:id])
    require_group_discussion!(@category.group)
  end

  def category_params
    params.require(:category).permit(:group_id, :name, :slug, :summary, :sort,
                                     :archived, :visibility, team_ids: [])
  end

  # Which teams may see a `visibility: "team"` board. Absent means "leave as
  # is" rather than "clear", so a rename cannot silently make a private board
  # invisible to everyone.
  def sync_teams!(category)
    return if params[:category][:team_ids].nil?

    ids = Array(params[:category][:team_ids]).map(&:to_s)
    # Only this group's teams — CategoryTeam validates it too, but refusing
    # here gives a useful message instead of a validation string.
    scoped = category.group.teams.where(id: ids).pluck(:id)
    category.category_teams.where.not(team_id: scoped).destroy_all
    (scoped - category.category_teams.pluck(:team_id)).each do |team_id|
      category.category_teams.create!(team_id: team_id)
    end
  end
end
