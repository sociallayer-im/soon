class GroupInviteBlueprint < Blueprinter::Base
  identifier :id

  fields :status, :role, :message, :expires_at, :receiver_address_type, :receiver_address, :created_at

  association :sender, blueprint: UserBlueprint
  association :receiver, blueprint: UserBlueprint
  association :group, blueprint: GroupBlueprint
end
