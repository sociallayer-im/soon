class MembershipBlueprint < Blueprinter::Base
  identifier :id

  # admin_notification is only meaningful on an owner/manager row, but it is in
  # the default view rather than a named one so the member roster — the single
  # place the setting is shown and toggled — doesn't need a second request.
  fields :role, :active, :admin_notification, :created_at
  association :user, blueprint: UserBlueprint

  # For "which groups does this user belong to" listings.
  view :with_group do
    association :group, blueprint: GroupBlueprint
  end
end
