class DropRedundantBadgeVoucherColumns < ActiveRecord::Migration[8.1]
  def change
    # badges: unused / never-populated / pure denormalized copies of badge_class
    remove_column :badges, :last_value_used_at, :datetime
    remove_column :badges, :domain, :string
    remove_column :badges, :hashtags, :string, array: true
    remove_column :badges, :metadata, :text # verbatim copy of badge_classes.metadata

    # badge_classes: never settable via the API / dead feature flag
    remove_column :badge_classes, :domain, :string
    remove_column :badge_classes, :hashtags, :string, array: true
    remove_column :badge_classes, :status, :string, default: "active" # "freezed" was never enforced

    # vouchers: fully derivable from `strategy`
    remove_column :vouchers, :receiver_address_type, :string
  end
end
