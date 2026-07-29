class AddFeaturedImageUrlToGroups < ActiveRecord::Migration[8.1]
  def change
    add_column :groups, :featured_image_url, :string
  end
end
