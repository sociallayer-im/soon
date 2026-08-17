class ReplaceCategoryMembersWithTeams < ActiveRecord::Migration[8.1]
  # A private board named a list of user ids. It now names one or more teams,
  # which is the same restriction with a meaning attached — "the volunteers"
  # rather than a set of opaque ids — and one that is maintained in a single
  # place instead of per board.
  #
  # categories/category_members exist in main but have never been deployed, so
  # this drops rather than migrates. That window closes at the first deploy.
  def up
    create_table :category_teams, id: :string do |t|
      t.string :category_id, null: false
      t.string :team_id,     null: false
      t.timestamps
      t.index [:category_id, :team_id], unique: true
      t.index :team_id
    end
    add_foreign_key :category_teams, :categories
    add_foreign_key :category_teams, :teams

    drop_table :category_members
    execute "UPDATE categories SET visibility = 'team' WHERE visibility = 'invited'"
    change_column_comment :categories, :visibility, from: "public | member | manager | invited",
      to: "public | member | manager | team"
  end

  def down
    create_table :category_members, id: :string do |t|
      t.string :category_id, null: false
      t.string :user_id,     null: false
      t.timestamps
      t.index [:category_id, :user_id], unique: true
      t.index :user_id
    end
    execute "UPDATE categories SET visibility = 'invited' WHERE visibility = 'team'"
    drop_table :category_teams
  end
end
