class CreatePolls < ActiveRecord::Migration[8.1]
  def change
    # Opt-in, same reasoning as discussion_enabled / map_enabled: a poll tab
    # appearing on every existing group overnight is not a feature launch.
    add_column :groups, :poll_enabled, :boolean, null: false, default: false
    add_column :groups, :can_create_poll, :string, default: "member",
      comment: "manager | member | everyone"

    create_table :polls, id: :string do |t|
      t.string   :group_id, null: false
      t.string   :user_id,  null: false
      t.string   :title,    null: false
      t.text     :content
      t.string   :poll_type,  null: false, default: "single",
        comment: "single | multiple | number"
      t.integer  :min_value
      t.integer  :max_value
      t.string   :visibility, null: false, default: "public",
        comment: "public | participants | secret"
      t.string   :results,    null: false, default: "always",
        comment: "always | on_vote | on_close | manager_only"

      # Nullable timestamps rather than a status enum, as on topics.
      t.datetime :close_at
      t.datetime :closed_at
      # First vote ever cast. Starts the 10-minute edit grace window after
      # which options and title are locked (design/POLL_MODULE.md §1.2).
      t.datetime :first_voted_at
      t.integer  :votes_count, null: false, default: 0,
        comment: "distinct voters, recomputed by Poll#refresh_counts!"

      t.datetime :flagged_at
      t.string   :flagged_by_id
      t.string   :flag_reason
      t.datetime :deleted_at
      t.string   :deleted_by_id
      t.timestamps

      t.index [ :group_id, :created_at ], where: "deleted_at IS NULL AND flagged_at IS NULL",
        name: "index_polls_on_group_and_created"
      # The auto-close sweep's whole scan.
      t.index :close_at, where: "closed_at IS NULL AND deleted_at IS NULL",
        name: "index_polls_pending_close"
      t.index :user_id
    end
    add_foreign_key :polls, :groups
    add_foreign_key :polls, :users

    create_table :poll_options, id: :string do |t|
      t.string  :poll_id,  null: false
      t.string  :title,    null: false
      t.integer :position, null: false, default: 0
      t.integer :votes_count, null: false, default: 0
      t.timestamps
      t.index [ :poll_id, :position ]
    end
    add_foreign_key :poll_options, :polls

    create_table :poll_votes, id: :string do |t|
      t.string  :poll_id,   null: false
      t.string  :user_id,   null: false
      t.string  :option_id            # nil for number polls
      t.integer :value                # number polls only
      t.timestamps
      # One row per (voter, option). A single-choice poll's "exactly one row
      # per voter" cannot be a partial index — the type lives on polls, and a
      # partial index may only reference its own table — so PollVote enforces
      # it in the model instead (design/POLL_MODULE.md §1).
      t.index [ :poll_id, :user_id, :option_id ], unique: true,
        name: "index_poll_votes_unique"
      t.index [ :poll_id, :user_id ]
      t.index :option_id
    end
    add_foreign_key :poll_votes, :polls
    add_foreign_key :poll_votes, :users
    add_foreign_key :poll_votes, :poll_options, column: :option_id
  end
end
