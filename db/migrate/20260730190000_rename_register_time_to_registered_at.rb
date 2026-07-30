class RenameRegisterTimeToRegisteredAt < ActiveRecord::Migration[8.1]
  # Matches checked_in_at's naming now that the two timestamps are distinct
  # (register_time used to carry both meanings — see
  # AddCheckedInAtToParticipants).
  def change
    rename_column :participants, :register_time, :registered_at
  end
end
