class CreateFederationTables < ActiveRecord::Migration[8.1]
  # Phase 0 federation tables (design/FEDERATION_PLAN.md §2.5). No behavior
  # change — nothing reads these until the federation routes ship.
  def change
    # Remote actor cache. public_key_pem is what nebula's remote_users lacked;
    # without it every signature verification refetches the actor.
    create_table :fed_actors, id: :string do |t|
      t.string :uri, null: false, index: {unique: true}
      t.string :domain, null: false, index: true
      t.string :actor_type
      t.string :preferred_username
      t.string :name
      t.text :summary
      t.string :icon_url
      t.string :inbox_url, null: false
      t.string :shared_inbox_url
      t.string :outbox_url
      t.string :followers_url
      t.text :public_key_pem
      t.string :key_id
      t.datetime :last_fetched_at
      t.datetime :blocked_at
      t.jsonb :raw
      t.timestamps
    end

    # Follow edges, both directions. `uri` is the Follow activity id — Undo and
    # Accept match on it.
    create_table :fed_follows, id: :string do |t|
      t.string :local_type, null: false # User | Group
      t.string :local_id, null: false
      t.string :fed_actor_id, null: false, index: true
      t.string :direction, null: false  # inbound (remote follows local) | outbound
      t.string :state, null: false, default: "accepted" # pending | accepted | rejected
      t.string :uri, null: false
      t.timestamps
      t.index [:local_type, :local_id, :fed_actor_id, :direction],
              unique: true, name: "idx_fed_follows_uniq"
      t.index :uri, unique: true
    end
    add_foreign_key :fed_follows, :fed_actors

    # Inbound idempotency: one row per processed activity id. Replay protection
    # that both reference prototypes (nebula, writefreely) skipped.
    create_table :fed_inbound_activities, id: :string do |t|
      t.string :uri, null: false, index: {unique: true}
      t.string :activity_type
      t.string :fed_actor_id, index: true
      t.string :status, null: false, default: "processed" # processed | failed | ignored
      t.datetime :created_at, null: false
    end

    # Outbox delivery queue (design/FEDERATION_PLAN.md §2.6): rows are written
    # in the same transaction as the business change, then drained rate-limited
    # by the sweeper. Never fan out HTTP inline.
    create_table :fed_deliveries, id: :string do |t|
      t.jsonb :payload, null: false
      t.string :sender_type, null: false # User | Group | instance
      t.string :sender_id
      t.string :inbox_url, null: false
      t.string :status, null: false, default: "pending", index: true
      # pending | delivering | delivered | failed_permanent
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.string :last_error
      t.timestamps
      t.index [:status, :next_attempt_at]
    end
  end
end
