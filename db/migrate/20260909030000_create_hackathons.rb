class CreateHackathons < ActiveRecord::Migration[8.1]
  def change
    # Opt-in per group, same reasoning as poll_enabled. Creation defaults to
    # manager — unlike polls and topics — because running a hackathon is the
    # group speaking outward, not a member speaking inside it
    # (design/HACKATHON_MODULE.md §8).
    add_column :groups, :hackathon_enabled, :boolean, null: false, default: false
    add_column :groups, :can_create_hackathon, :string, default: "manager",
      comment: "manager | member | everyone"

    create_table :hackathons, id: :string do |t|
      t.string   :group_id, null: false
      t.string   :user_id,  null: false
      # The event that handles registration (participants, form, tickets,
      # check-in). Nullable: a hackathon with no sign-up step. Unique: one
      # event serves one hackathon. ON DELETE SET NULL so the Event side needs
      # no association — the coupling runs one way only.
      t.string   :event_id
      t.string   :title,    null: false
      t.string   :tagline
      t.text     :content
      t.string   :cover_url
      t.string   :status, null: false, default: "draft", comment: "draft | published"
      t.datetime :start_at
      t.datetime :end_at
      # The submission window, independent of the event's own dates.
      t.datetime :submit_open_at
      t.datetime :submit_close_at
      t.string   :projects_visibility, null: false, default: "after_submit",
        comment: "always | after_submit | after_review"
      t.string   :can_submit_project, null: false, default: "participant",
        comment: "participant | member | everyone"
      # [{id, title, description, color}] — ids are server-minted and stable;
      # projects reference them by id (design/HACKATHON_MODULE.md §1.3).
      t.jsonb    :tracks, null: false, default: []
      t.integer  :projects_count, null: false, default: 0,
        comment: "submitted projects, recomputed by Hackathon#refresh_counts!"

      t.datetime :flagged_at
      t.string   :flagged_by_id
      t.string   :flag_reason
      t.datetime :deleted_at
      t.string   :deleted_by_id
      t.timestamps

      t.index [ :group_id, :status ]
      t.index :event_id, unique: true, where: "event_id IS NOT NULL"
      t.index :user_id
    end
    add_foreign_key :hackathons, :groups
    add_foreign_key :hackathons, :users
    add_foreign_key :hackathons, :events, on_delete: :nullify

    create_table :hackathon_projects, id: :string do |t|
      t.string   :hackathon_id, null: false
      t.string   :track_id
      # The owner. The authority for every permission check; the "owner" role
      # on the member row is display only.
      t.string   :user_id, null: false
      t.string   :title,   null: false
      t.string   :tagline
      t.text     :content
      t.string   :cover_url
      t.string   :repo_url
      t.string   :demo_url
      t.string   :video_url
      t.string   :tech,    array: true, null: false, default: []
      t.string   :seeking, array: true, null: false, default: []
      t.boolean  :recruiting, null: false, default: false
      t.datetime :submitted_at
      t.datetime :approved_at
      t.datetime :rejected_at
      t.text     :review_note
      t.string   :award
      t.integer  :stars_count,   null: false, default: 0
      t.integer  :members_count, null: false, default: 0

      # Flaggable, but NOT soft-deletable: a hidden project would still hold
      # its members' one-project-per-hackathon slot (§1.4).
      t.datetime :flagged_at
      t.string   :flagged_by_id
      t.string   :flag_reason
      t.timestamps

      t.index [ :hackathon_id, :submitted_at ]
      t.index [ :hackathon_id, :track_id ]
      t.index [ :hackathon_id, :recruiting ]
      t.index :user_id
    end
    add_foreign_key :hackathon_projects, :hackathons
    add_foreign_key :hackathon_projects, :users

    create_table :hackathon_project_members, id: :string do |t|
      t.string :project_id,   null: false
      # Denormalised from the project purely so the one-project-per-person
      # rule can be a database constraint; a partial index cannot look across
      # to hackathon_projects.
      t.string :hackathon_id, null: false
      t.string :user_id,      null: false
      t.string :role, null: false, default: "member", comment: "owner | member"
      t.timestamps

      t.index [ :project_id, :user_id ], unique: true
      t.index [ :hackathon_id, :user_id ], unique: true,
        name: "index_hackathon_project_members_one_per_hackathon"
    end
    add_foreign_key :hackathon_project_members, :hackathon_projects, column: :project_id
    add_foreign_key :hackathon_project_members, :hackathons
    add_foreign_key :hackathon_project_members, :users

    create_table :hackathon_project_stars, id: :string do |t|
      t.string :project_id, null: false
      t.string :user_id,    null: false
      t.timestamps

      t.index [ :project_id, :user_id ], unique: true
      t.index :user_id
    end
    add_foreign_key :hackathon_project_stars, :hackathon_projects, column: :project_id
    add_foreign_key :hackathon_project_stars, :users
  end
end
