class CreateFedEventsAndParticipations < ActiveRecord::Migration[8.1]
  # Outbound direction (design/FEDERATION_PLAN.md Phase 4): remote events are
  # mirrored so local users can browse and join them.
  #
  # Remote participation gets its own table rather than more nullable columns
  # on `participants`: that table carries the local ticketing, form and
  # capacity machinery, none of which applies when the authoritative copy
  # lives on another instance.
  def change
    create_table :fed_events, id: :string do |t|
      t.string :uri, null: false, index: {unique: true}
      t.string :fed_actor_id, index: true # attributedTo — the owning group/person
      t.string :title
      t.text :content
      t.string :summary
      t.datetime :start_time
      t.datetime :end_time
      t.string :timezone
      t.string :status, default: "CONFIRMED" # CONFIRMED | CANCELLED | TENTATIVE
      t.string :join_mode, default: "free"   # free | restricted | invite | external
      t.string :external_participation_url
      t.integer :max_participant
      t.integer :participant_count, default: 0
      t.string :location_name
      t.string :address
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      t.string :image_url
      t.string :html_url
      t.string :tags, array: true, default: []
      t.jsonb :raw
      t.datetime :last_fetched_at
      t.timestamps
      t.index :start_time
    end
    add_foreign_key :fed_events, :fed_actors

    create_table :fed_participations, id: :string do |t|
      t.string :user_id, null: false
      t.string :fed_event_id, null: false
      # pending — Join sent, awaiting the origin's Accept
      t.string :status, null: false, default: "pending"
      t.string :uri, null: false # our Join activity id; Accept/Reject match on it
      t.timestamps
      t.index [:user_id, :fed_event_id], unique: true
      t.index :uri, unique: true
    end
    add_foreign_key :fed_participations, :fed_events
    add_foreign_key :fed_participations, :users
  end
end
