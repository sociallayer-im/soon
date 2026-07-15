class AddVoucherForeignKeyToBadges < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :badges, :vouchers unless foreign_key_exists?(:badges, :vouchers)
  end
end
