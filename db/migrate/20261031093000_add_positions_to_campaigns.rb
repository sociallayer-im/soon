class AddPositionsToCampaigns < ActiveRecord::Migration[8.1]
  def up
    add_column :campaigns, :positions, :string, array: true, default: [], null: false
    execute <<~SQL
      UPDATE campaigns SET positions = ordered.ids
      FROM (
        SELECT campaign_id, array_agg(event_id ORDER BY position, id) AS ids
        FROM campaign_events GROUP BY campaign_id
      ) ordered WHERE campaigns.id = ordered.campaign_id
    SQL
  end

  def down
    remove_column :campaigns, :positions
  end
end
