class CategoryBlueprint < Blueprinter::Base
  identifier :id

  fields :group_id, :name, :slug, :summary, :sort, :topics_count, :archived,
         :visibility, :created_at

  # The invited list is a roster of people — the same kind of thing as
  # GroupInvite#receiver_address, and not something to render by default.
  # CategoriesController authorizes this view separately.
  view :members do
    association :category_members, blueprint: CategoryMemberBlueprint
  end
end
