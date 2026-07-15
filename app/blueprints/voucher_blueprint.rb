class VoucherBlueprint < Blueprinter::Base
  identifier :id

  fields :counter, :expires_at, :created_at, :badge_class_id, :sender_id, :receiver_id,
         :receiver_address, :strategy, :message

  association :badge_class, blueprint: BadgeClassBlueprint
  association :sender, blueprint: UserBlueprint

  view :with_code do
    field :code
  end

  view :with_badges do
    association :badges, blueprint: BadgeBlueprint
  end
end
