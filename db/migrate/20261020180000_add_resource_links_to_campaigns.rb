class AddResourceLinksToCampaigns < ActiveRecord::Migration[8.1]
  def change
    add_column :campaigns, :resource_links, :string, array: true, default: [], null: false
  end
end
