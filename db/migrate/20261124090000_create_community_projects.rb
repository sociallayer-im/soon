class CreateCommunityProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :groups, :community_projects_enabled, :boolean, null: false, default: false
    add_column :groups, :community_projects_intro, :text

    create_table :community_projects, id: :string do |t|
      t.references :group, type: :string, null: false, foreign_key: true
      t.references :user, type: :string, null: false, foreign_key: true
      t.string :title, null: false
      t.string :tagline
      t.text :content
      t.string :icon_url
      t.string :cover_url
      t.string :website_url
      t.jsonb :gallery, null: false, default: []
      t.string :status, null: false, default: "draft"
      t.datetime :published_at
      t.timestamps
      t.index [:group_id, :status, :published_at]
    end

    create_table :community_project_members, id: :string do |t|
      t.references :community_project, type: :string, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :string, null: false, foreign_key: true
      t.string :role
      t.datetime :accepted_at
      t.timestamps
      t.index [:community_project_id, :user_id], unique: true
    end

    create_table :community_project_comments, id: :string do |t|
      t.references :community_project, type: :string, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :string, null: false, foreign_key: true
      t.text :content, null: false
      t.timestamps
    end
  end
end
