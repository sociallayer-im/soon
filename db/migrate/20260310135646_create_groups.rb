class CreateGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :groups, id: :string do |t|
      t.string :name
      t.string :image_url
      t.string :nickname
      t.string :parent_id
      t.boolean :active, default: true
      t.string :group_ticket_event_id

      t.jsonb :social_links, default: {}
      t.string :timezone
      t.string :logo_url
      t.text   :bio

      t.string :can_publish_event, default: "everyone", comment: "manager | member | everyone"
      t.string :can_join_event, default: "everyone", comment: "manager | member | everyone"
      t.string :can_view_event, default: "everyone", comment: "manager | member | everyone"

      # banner
      t.string :banner_link_url
      t.string :banner_image_url
      t.text   :banner_text

      # counts
      t.integer :memberships_count, default: 0, null: false
      t.integer :events_count, default: 0, null: false

      # tags
      t.string :group_tags, array: true, default: []
      t.string :event_tag_list, array: true, default: []
      t.string :venue_tag_list, array: true, default: []
      t.string :requirement_tag_list, array: true, default: []
      t.string :op_label_list, array: true, default: []


      # popup city info
      t.date :start_date
      t.date :end_date
      t.string :location

      # union
      t.string :event_union, array: true
      t.string :venue_union, array: true

      # permissions
      t.string :permissions, default: [], array: true
      t.jsonb :data, default: {}
      t.timestamps
    end
    add_index :groups, :parent_id
  end
end
