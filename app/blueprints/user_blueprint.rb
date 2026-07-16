class UserBlueprint < Blueprinter::Base
  identifier :id

  # email is PII and is NOT in the public/default view — it must never leak through
  # member lists, badge owner/creator, participants, etc.
  fields :name, :nickname, :image_url, :created_at

  # Public profile page: bio and public identifiers (wallet, social links).
  view :profile do
    fields :bio, :eth, :social_links
  end

  # Private fields, only rendered for the user viewing their own record.
  view :self do
    include_view :profile
    fields :email, :permissions
  end

  view :extended do
    association :groups, blueprint: GroupBlueprint
  end
end
