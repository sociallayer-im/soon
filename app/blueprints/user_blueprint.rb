class UserBlueprint < Blueprinter::Base
  identifier :id

  # email is PII and is NOT in the public/default view — it must never leak through
  # member lists, badge owner/creator, participants, etc.
  fields :name, :nickname, :image_url, :created_at

  # Private fields, only rendered for the user viewing their own record.
  view :self do
    fields :email
  end

  view :extended do
    association :groups, blueprint: GroupBlueprint
  end
end
