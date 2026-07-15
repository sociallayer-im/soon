# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_11_193614) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "auth_codes", id: :string, force: :cascade do |t|
    t.string "code", null: false
    t.string "context", null: false, comment: "signup | login | password_reset | email_verification | phone_verification"
    t.datetime "created_at", null: false
    t.string "recipient", null: false
    t.string "recipient_type", null: false, comment: "email | phone"
    t.datetime "used_at"
  end

  create_table "availabilities", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "day"
    t.string "day_of_week"
    t.jsonb "intervals", default: {}
    t.string "item_id", null: false
    t.string "item_type", null: false
    t.string "role_required"
    t.datetime "updated_at", null: false
    t.index ["item_id", "item_type", "day"], name: "index_availabilities_on_item_id_and_item_type_and_day"
  end

  create_table "domains", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "fullname"
    t.string "item_id"
    t.string "item_type"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_domains_on_name", unique: true
  end

  create_table "event_roles", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "email"
    t.string "event_id", null: false
    t.string "image_url"
    t.string "item_id"
    t.string "item_type", null: false, comment: "user | group"
    t.string "role", null: false, comment: "member | manager"
    t.datetime "updated_at", null: false
    t.index ["event_id", "item_id", "item_type"], name: "index_event_roles_on_event_id_and_item_id_and_item_type", unique: true
    t.index ["event_id"], name: "index_event_roles_on_event_id"
  end

  create_table "events", id: :string, force: :cascade do |t|
    t.string "category"
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "end_time"
    t.string "external_url"
    t.string "group_id", null: false
    t.string "image_url"
    t.string "kind"
    t.integer "max_participant"
    t.string "meeting_url"
    t.text "notes"
    t.string "op_assigned_users", default: [], array: true
    t.string "op_labels", default: [], array: true
    t.string "op_priority"
    t.string "op_status"
    t.string "owner_id", null: false
    t.integer "participant_count", default: 0
    t.boolean "pinned", default: false
    t.string "place_id"
    t.string "recurring_id"
    t.boolean "require_approval", default: false
    t.string "requirement_tags", array: true
    t.string "slug"
    t.datetime "start_time"
    t.string "status", default: "draft", comment: "draft | pending | published | archived | closed | cancelled"
    t.string "tags", default: [], array: true
    t.string "timezone"
    t.string "title"
    t.string "track_id"
    t.datetime "updated_at", null: false
    t.string "venue_id"
    t.string "visibility", default: "public", comment: "public | private"
    t.index ["group_id"], name: "index_events_on_group_id"
    t.index ["owner_id"], name: "index_events_on_owner_id"
    t.index ["place_id"], name: "index_events_on_place_id"
    t.index ["track_id"], name: "index_events_on_track_id"
    t.index ["venue_id"], name: "index_events_on_venue_id"
  end

  create_table "groups", id: :string, force: :cascade do |t|
    t.boolean "active", default: true
    t.string "banner_image_url"
    t.string "banner_link_url"
    t.text "banner_text"
    t.text "bio"
    t.string "can_join_event", default: "everyone", comment: "manager | member | everyone"
    t.string "can_publish_event", default: "everyone", comment: "manager | member | everyone"
    t.string "can_view_event", default: "everyone", comment: "manager | member | everyone"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}
    t.date "end_date"
    t.string "event_tag_list", default: [], array: true
    t.string "event_union", array: true
    t.integer "events_count", default: 0, null: false
    t.string "group_tags", default: [], array: true
    t.string "group_ticket_event_id"
    t.string "image_url"
    t.string "location"
    t.string "logo_url"
    t.integer "memberships_count", default: 0, null: false
    t.string "name"
    t.string "nickname"
    t.string "op_label_list", default: [], array: true
    t.string "parent_id"
    t.string "permissions", default: [], array: true
    t.string "requirement_tag_list", default: [], array: true
    t.jsonb "social_links", default: {}
    t.date "start_date"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.string "venue_tag_list", default: [], array: true
    t.string "venue_union", array: true
    t.index ["parent_id"], name: "index_groups_on_parent_id"
  end

  create_table "markers", id: :string, force: :cascade do |t|
    t.text "about"
    t.string "category"
    t.string "cover_image_url"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}
    t.string "group_id", null: false
    t.string "link"
    t.string "owner_id", null: false
    t.string "pin_image_url"
    t.string "place_id", null: false
    t.string "status"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id"], name: "index_markers_on_group_id"
    t.index ["owner_id"], name: "index_markers_on_owner_id"
    t.index ["place_id"], name: "index_markers_on_place_id"
  end

  create_table "memberships", id: :string, force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}
    t.string "group_id", null: false
    t.string "role", null: false, comment: "member | admin | owner"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["group_id", "role"], name: "index_memberships_on_group_id_and_role"
    t.index ["group_id"], name: "index_memberships_on_group_id"
    t.index ["user_id", "group_id"], name: "index_memberships_on_user_id_and_group_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "participants", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_id", null: false
    t.string "status", default: "attending", null: false, comment: "attending | declined | maybe"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["event_id"], name: "index_participants_on_event_id"
    t.index ["user_id", "event_id"], name: "index_participants_on_user_id_and_event_id", unique: true
    t.index ["user_id"], name: "index_participants_on_user_id"
  end

  create_table "places", id: :string, force: :cascade do |t|
    t.string "address"
    t.datetime "created_at", null: false
    t.text "description"
    t.decimal "latitude", precision: 10, scale: 6
    t.decimal "longitude", precision: 10, scale: 6
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_places_on_name", unique: true
  end

  create_table "recurrings", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "end_time"
    t.integer "event_count", default: 0
    t.string "interval", null: false
    t.datetime "start_time", null: false
    t.string "timezone"
    t.datetime "updated_at", null: false
  end

  create_table "track_roles", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "role", null: false, comment: "member | manager"
    t.string "track_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["track_id", "user_id"], name: "index_track_roles_on_track_id_and_user_id", unique: true
    t.index ["track_id"], name: "index_track_roles_on_track_id"
    t.index ["user_id"], name: "index_track_roles_on_user_id"
  end

  create_table "tracks", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.date "end_date"
    t.string "group_id", null: false
    t.string "image_url"
    t.boolean "is_private"
    t.string "name", null: false
    t.date "start_date"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id"], name: "index_tracks_on_group_id"
  end

  create_table "users", id: :string, force: :cascade do |t|
    t.boolean "active", default: true
    t.text "bio"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}
    t.string "email"
    t.string "eth"
    t.string "image_url"
    t.datetime "last_signin_at"
    t.string "name"
    t.string "nickname"
    t.string "permissions", default: [], array: true
    t.string "phone"
    t.jsonb "social_links", default: {}
    t.string "telegram_id"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["eth"], name: "index_users_on_eth", unique: true
    t.index ["name"], name: "index_users_on_name", unique: true
    t.index ["phone"], name: "index_users_on_phone", unique: true
  end

  create_table "venues", id: :string, force: :cascade do |t|
    t.text "about"
    t.string "amenities", default: [], array: true
    t.integer "capacity"
    t.datetime "created_at", null: false
    t.string "featured_image_url"
    t.string "group_id", null: false
    t.string "image_urls", default: [], array: true
    t.string "name", null: false
    t.jsonb "overrides"
    t.string "owner_id", null: false
    t.string "place_id"
    t.boolean "require_approval", default: false
    t.string "tags", default: [], array: true
    t.jsonb "timeslots"
    t.string "track_ids", default: [], array: true
    t.datetime "updated_at", null: false
    t.string "website"
    t.index ["group_id"], name: "index_venues_on_group_id"
    t.index ["name"], name: "index_venues_on_name", unique: true
    t.index ["owner_id"], name: "index_venues_on_owner_id"
    t.index ["place_id"], name: "index_venues_on_place_id"
  end

  add_foreign_key "event_roles", "events"
  add_foreign_key "events", "groups"
  add_foreign_key "events", "places"
  add_foreign_key "events", "tracks"
  add_foreign_key "events", "users", column: "owner_id"
  add_foreign_key "events", "venues"
  add_foreign_key "markers", "groups"
  add_foreign_key "markers", "places"
  add_foreign_key "markers", "users", column: "owner_id"
  add_foreign_key "memberships", "groups"
  add_foreign_key "memberships", "users"
  add_foreign_key "participants", "events"
  add_foreign_key "participants", "users"
  add_foreign_key "track_roles", "tracks"
  add_foreign_key "track_roles", "users"
  add_foreign_key "tracks", "groups"
  add_foreign_key "venues", "groups"
  add_foreign_key "venues", "places"
  add_foreign_key "venues", "users", column: "owner_id"
end
