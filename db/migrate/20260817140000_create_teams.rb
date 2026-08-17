class CreateTeams < ActiveRecord::Migration[8.1]
  def change
    # A team groups one group's members, the way a track groups its events.
    # Not a site-wide concept: group_id is null: false.
    create_table :teams, id: :string do |t|
      t.string   :group_id,      null: false
      t.string   :name,          null: false
      t.string   :slug,          null: false
      t.string   :description
      t.string   :color
      t.integer  :sort,          null: false, default: 0
      t.integer  :members_count, null: false, default: 0
      t.boolean  :archived,      null: false, default: false
      t.timestamps
      # Unique inside the group, deliberately not globally — unlike tracks,
      # whose global unique index on `name` stops two communities each having
      # something called "core".
      t.index [:group_id, :slug], unique: true
      t.index [:group_id, :sort]
    end
    add_foreign_key :teams, :groups

    create_table :team_memberships, id: :string do |t|
      t.string :team_id, null: false
      t.string :user_id, null: false
      t.timestamps
      t.index [:team_id, :user_id], unique: true
      t.index :user_id
    end
    add_foreign_key :team_memberships, :teams
    add_foreign_key :team_memberships, :users
  end
end
