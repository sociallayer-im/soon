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

ActiveRecord::Schema[8.1].define(version: 2026_07_29_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "activities", id: :string, force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.boolean "has_read", default: false
    t.string "initiator_id", null: false
    t.string "item_id"
    t.string "item_type"
    t.jsonb "payload", default: {}
    t.string "receiver_address"
    t.string "receiver_id"
    t.index ["created_at"], name: "index_activities_on_created_at"
    t.index ["initiator_id"], name: "index_activities_on_initiator_id"
    t.index ["item_type", "item_id"], name: "index_activities_on_item_type_and_item_id"
    t.index ["receiver_id"], name: "index_activities_on_receiver_id"
  end

  create_table "auth_codes", id: :string, force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.string "code", null: false
    t.string "context", null: false, comment: "signup | login | password_reset | email_verification | phone_verification"
    t.datetime "created_at", null: false
    t.string "recipient", null: false
    t.string "recipient_type", null: false, comment: "email | phone"
    t.datetime "used_at"
    t.index ["recipient", "context", "used_at"], name: "index_auth_codes_on_recipient_and_context_and_used_at"
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

  create_table "badge_classes", id: :string, force: :cascade do |t|
    t.string "badge_type", default: "badge", null: false, comment: "badge | nft | nftpass | private"
    t.string "can_send_badge", default: "owner", comment: "owner | group_member_send"
    t.text "content"
    t.integer "counter", default: 1
    t.datetime "created_at", null: false
    t.string "creator_id", null: false
    t.string "display", default: "normal", comment: "normal | hidden | pinned"
    t.boolean "encrypted", default: false, null: false
    t.string "group_id"
    t.string "image_url"
    t.text "metadata"
    t.string "name", null: false
    t.string "permissions", default: [], array: true
    t.string "ref_id"
    t.boolean "revocable", default: false, null: false
    t.string "title", null: false
    t.boolean "transferable", default: false, null: false
    t.datetime "updated_at", null: false
    t.boolean "weighted", default: false, null: false
    t.index ["creator_id"], name: "index_badge_classes_on_creator_id"
    t.index ["group_id"], name: "index_badge_classes_on_group_id"
    t.index ["ref_id"], name: "index_badge_classes_on_ref_id", where: "(ref_id IS NOT NULL)"
  end

  create_table "badges", id: :string, force: :cascade do |t|
    t.string "badge_class_id", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.string "creator_id", null: false
    t.string "display", default: "normal", null: false, comment: "normal | hidden | pinned"
    t.datetime "end_time"
    t.string "image_url"
    t.integer "index"
    t.string "owner_id", null: false
    t.string "ref_id"
    t.datetime "start_time"
    t.string "status", default: "minted", null: false, comment: "minted | burned | accepted"
    t.string "title"
    t.datetime "updated_at", null: false
    t.integer "value", default: 0
    t.string "voucher_id"
    t.index ["badge_class_id"], name: "index_badges_on_badge_class_id"
    t.index ["creator_id"], name: "index_badges_on_creator_id"
    t.index ["owner_id"], name: "index_badges_on_owner_id"
    t.index ["ref_id"], name: "index_badges_on_ref_id", where: "(ref_id IS NOT NULL)"
    t.index ["voucher_id"], name: "index_badges_on_voucher_id"
  end

  create_table "comments", id: :string, force: :cascade do |t|
    t.string "badge_id"
    t.string "comment_type", null: false, comment: "checkin | chat | comment | star | feedback"
    t.text "content"
    t.string "content_type", default: "text"
    t.datetime "created_at", null: false
    t.string "edit_parent_id"
    t.string "icon_url"
    t.string "item_id"
    t.string "item_type"
    t.boolean "removed", default: false
    t.string "reply_parent_id"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["item_type", "item_id", "removed"], name: "index_comments_on_item_type_and_item_id_and_removed"
    t.index ["user_id", "comment_type"], name: "index_comments_on_user_id_and_comment_type"
    t.index ["user_id"], name: "index_comments_on_user_id"
  end

  create_table "coupons", id: :string, force: :cascade do |t|
    t.string "applicable_ticket_ids", array: true
    t.string "code"
    t.datetime "created_at", null: false
    t.integer "discount", comment: "basis points of 10000 for ratio, smallest unit for amount"
    t.string "discount_type", comment: "ratio | amount"
    t.string "event_id", null: false
    t.datetime "expires_at"
    t.string "label"
    t.integer "max_allowed_usages"
    t.integer "order_usage_count", default: 0
    t.string "receiver_address"
    t.boolean "removed", default: false
    t.string "selector_type", comment: "code | email | badge"
    t.string "ticket_item_ids", array: true
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_coupons_on_code"
    t.index ["event_id"], name: "index_coupons_on_event_id"
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
    t.string "form_id"
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
    t.string "ref_id"
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
    t.index ["form_id"], name: "index_events_on_form_id"
    t.index ["group_id"], name: "index_events_on_group_id"
    t.index ["owner_id"], name: "index_events_on_owner_id"
    t.index ["place_id"], name: "index_events_on_place_id"
    t.index ["ref_id"], name: "index_events_on_ref_id", where: "(ref_id IS NOT NULL)"
    t.index ["track_id"], name: "index_events_on_track_id"
    t.index ["venue_id"], name: "index_events_on_venue_id"
  end

  create_table "form_answers", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "form_field_id", null: false
    t.string "form_submission_id", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["form_field_id"], name: "index_form_answers_on_form_field_id"
    t.index ["form_submission_id"], name: "index_form_answers_on_form_submission_id"
  end

  create_table "form_fields", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "field_type", null: false
    t.boolean "for_admin", default: false
    t.string "form_id", null: false
    t.string "label", null: false
    t.jsonb "options", default: []
    t.integer "position", default: 0, null: false
    t.boolean "required", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["form_id", "position"], name: "index_form_fields_on_form_id_and_position"
    t.index ["form_id"], name: "index_form_fields_on_form_id"
  end

  create_table "form_submissions", id: :string, force: :cascade do |t|
    t.text "admin_note"
    t.datetime "created_at", null: false
    t.string "form_id", null: false
    t.boolean "starred", default: false, null: false
    t.string "status", default: "pending", null: false
    t.datetime "submitted_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["form_id", "status"], name: "index_form_submissions_on_form_id_and_status"
    t.index ["form_id", "user_id"], name: "index_form_submissions_on_form_id_and_user_id", unique: true
    t.index ["form_id"], name: "index_form_submissions_on_form_id"
    t.index ["user_id"], name: "index_form_submissions_on_user_id"
  end

  create_table "forms", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by_id"
    t.text "description"
    t.boolean "published", default: false, null: false
    t.string "slug", null: false
    t.text "submission_message"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_forms_on_created_by_id"
    t.index ["slug"], name: "index_forms_on_slug", unique: true
  end

  create_table "group_invites", id: :string, force: :cascade do |t|
    t.string "badge_class_id"
    t.string "badge_id"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "group_id", null: false
    t.string "message"
    t.string "receiver_address"
    t.string "receiver_address_type", default: "id", comment: "id | email | code"
    t.string "receiver_id"
    t.string "role", default: "member", comment: "member | manager | owner"
    t.string "sender_id"
    t.string "status", default: "sending", null: false, comment: "sending | requesting | accepted | cancelled | revoked"
    t.string "ticket_id"
    t.datetime "updated_at", null: false
    t.index ["group_id"], name: "index_group_invites_on_group_id"
    t.index ["receiver_id"], name: "index_group_invites_on_receiver_id"
    t.index ["sender_id"], name: "index_group_invites_on_sender_id"
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
    t.string "ref_id"
    t.string "requirement_tag_list", default: [], array: true
    t.jsonb "social_links", default: {}
    t.date "start_date"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.string "venue_tag_list", default: [], array: true
    t.string "venue_union", array: true
    t.index ["name"], name: "index_groups_on_name", unique: true
    t.index ["parent_id"], name: "index_groups_on_parent_id"
    t.index ["ref_id"], name: "index_groups_on_ref_id", where: "(ref_id IS NOT NULL)"
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
    t.string "badge_id"
    t.datetime "created_at", null: false
    t.string "event_id", null: false
    t.string "message"
    t.string "payment_status"
    t.datetime "register_time"
    t.string "status", default: "attending", null: false, comment: "attending | declined | maybe"
    t.string "ticket_id"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.string "voucher_id"
    t.index ["event_id"], name: "index_participants_on_event_id"
    t.index ["user_id", "event_id"], name: "index_participants_on_user_id_and_event_id", unique: true
    t.index ["user_id"], name: "index_participants_on_user_id"
  end

  create_table "payment_methods", id: :string, force: :cascade do |t|
    t.string "chain"
    t.jsonb "chain_token_addresses", default: {}
    t.string "chains", default: [], array: true
    t.datetime "created_at", null: false
    t.string "item_id"
    t.string "item_type"
    t.string "kind", comment: "crypto | fiat | credit"
    t.bigint "price"
    t.string "protocol"
    t.string "receiver_address"
    t.string "token_address"
    t.string "token_name"
    t.datetime "updated_at", null: false
    t.index ["item_type", "item_id"], name: "index_payment_methods_on_item_type_and_item_id"
  end

  create_table "places", id: :string, force: :cascade do |t|
    t.string "address"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}
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

  create_table "ticket_items", id: :string, force: :cascade do |t|
    t.integer "amount"
    t.string "auth_type", comment: "free | payment | badge | invite"
    t.string "chain"
    t.string "coupon_id"
    t.datetime "created_at", null: false
    t.string "discount_data"
    t.integer "discount_value"
    t.string "event_id"
    t.string "group_id"
    t.decimal "original_price", precision: 40
    t.string "participant_id"
    t.string "payment_method_id"
    t.string "protocol"
    t.string "selector_address"
    t.string "selector_type"
    t.string "sender_address"
    t.string "status", comment: "pending | unbounded | succeeded | cancelled | timeout"
    t.string "ticket_id", null: false
    t.string "ticket_type", default: "event", comment: "event | group"
    t.string "tracks_allowed", array: true
    t.string "txhash"
    t.datetime "updated_at", null: false
    t.string "user_id"
    t.index ["coupon_id"], name: "index_ticket_items_on_coupon_id"
    t.index ["event_id", "status"], name: "index_ticket_items_on_event_id_and_status"
    t.index ["event_id"], name: "index_ticket_items_on_event_id"
    t.index ["participant_id"], name: "index_ticket_items_on_participant_id"
    t.index ["payment_method_id"], name: "index_ticket_items_on_payment_method_id"
    t.index ["ticket_id"], name: "index_ticket_items_on_ticket_id"
    t.index ["txhash"], name: "index_ticket_items_on_txhash_unique", unique: true, where: "(txhash IS NOT NULL)"
    t.index ["user_id", "status"], name: "index_ticket_items_on_user_id_and_status"
    t.index ["user_id"], name: "index_ticket_items_on_user_id"
  end

  create_table "tickets", id: :string, force: :cascade do |t|
    t.string "check_badge_class_id"
    t.string "content"
    t.datetime "created_at", null: false
    t.date "days_allowed", array: true
    t.date "end_date"
    t.datetime "end_time"
    t.string "event_id", null: false
    t.string "group_id"
    t.boolean "need_approval"
    t.integer "quantity"
    t.date "start_date"
    t.string "status", default: "normal", comment: "normal | nosale | hidden | inactive"
    t.string "ticket_type", default: "event", comment: "event | group"
    t.string "title"
    t.string "tracks_allowed", default: [], array: true
    t.datetime "updated_at", null: false
    t.index ["event_id", "status"], name: "index_tickets_on_event_id_and_status"
    t.index ["event_id"], name: "index_tickets_on_event_id"
    t.index ["group_id", "status"], name: "index_tickets_on_group_id_and_status"
    t.check_constraint "quantity IS NULL OR quantity >= 0", name: "tickets_quantity_non_negative"
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
    t.index ["name"], name: "index_tracks_on_name", unique: true
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
    t.string "ref_id"
    t.jsonb "social_links", default: {}
    t.string "sol"
    t.string "telegram_id"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["eth"], name: "index_users_on_eth", unique: true
    t.index ["name"], name: "index_users_on_name", unique: true
    t.index ["phone"], name: "index_users_on_phone", unique: true
    t.index ["ref_id"], name: "index_users_on_ref_id", where: "(ref_id IS NOT NULL)"
    t.index ["sol"], name: "index_users_on_sol", unique: true
  end

  create_table "venues", id: :string, force: :cascade do |t|
    t.text "about"
    t.string "amenities", default: [], array: true
    t.boolean "archived", default: false, null: false
    t.integer "capacity"
    t.datetime "created_at", null: false
    t.date "end_date"
    t.string "featured_image_url"
    t.string "group_id", null: false
    t.string "image_urls", default: [], array: true
    t.string "name", null: false
    t.jsonb "overrides"
    t.string "owner_id", null: false
    t.string "place_id"
    t.boolean "require_approval", default: false
    t.date "start_date"
    t.string "tags", default: [], array: true
    t.jsonb "timeslots"
    t.string "track_ids", default: [], array: true
    t.datetime "updated_at", null: false
    t.string "website"
    t.index ["archived"], name: "index_venues_on_archived"
    t.index ["group_id"], name: "index_venues_on_group_id"
    t.index ["name"], name: "index_venues_on_name", unique: true
    t.index ["owner_id"], name: "index_venues_on_owner_id"
    t.index ["place_id"], name: "index_venues_on_place_id"
  end

  create_table "vouchers", id: :string, force: :cascade do |t|
    t.string "badge_class_id", null: false
    t.string "badge_content"
    t.string "badge_image"
    t.string "badge_title"
    t.string "code"
    t.integer "counter", default: 1
    t.datetime "created_at", null: false
    t.jsonb "data"
    t.datetime "expires_at"
    t.string "message"
    t.string "receiver_address"
    t.string "receiver_id"
    t.string "ref_id"
    t.string "sender_id", null: false
    t.string "strategy", default: "code", comment: "code | account | address | email | event | remember"
    t.datetime "updated_at", null: false
    t.index ["badge_class_id"], name: "index_vouchers_on_badge_class_id"
    t.index ["receiver_id"], name: "index_vouchers_on_receiver_id"
    t.index ["ref_id"], name: "index_vouchers_on_ref_id", where: "(ref_id IS NOT NULL)"
    t.index ["sender_id"], name: "index_vouchers_on_sender_id"
  end

  add_foreign_key "activities", "users", column: "initiator_id"
  add_foreign_key "activities", "users", column: "receiver_id"
  add_foreign_key "badge_classes", "groups"
  add_foreign_key "badge_classes", "users", column: "creator_id"
  add_foreign_key "badges", "badge_classes"
  add_foreign_key "badges", "users", column: "creator_id"
  add_foreign_key "badges", "users", column: "owner_id"
  add_foreign_key "badges", "vouchers"
  add_foreign_key "comments", "badges"
  add_foreign_key "comments", "comments", column: "edit_parent_id"
  add_foreign_key "comments", "comments", column: "reply_parent_id"
  add_foreign_key "comments", "users"
  add_foreign_key "coupons", "events"
  add_foreign_key "event_roles", "events"
  add_foreign_key "events", "forms"
  add_foreign_key "events", "groups"
  add_foreign_key "events", "places"
  add_foreign_key "events", "tracks"
  add_foreign_key "events", "users", column: "owner_id"
  add_foreign_key "events", "venues"
  add_foreign_key "form_answers", "form_fields"
  add_foreign_key "form_answers", "form_submissions"
  add_foreign_key "form_fields", "forms"
  add_foreign_key "form_submissions", "forms"
  add_foreign_key "form_submissions", "users"
  add_foreign_key "group_invites", "badge_classes"
  add_foreign_key "group_invites", "badges"
  add_foreign_key "group_invites", "groups"
  add_foreign_key "group_invites", "tickets"
  add_foreign_key "group_invites", "users", column: "receiver_id"
  add_foreign_key "group_invites", "users", column: "sender_id"
  add_foreign_key "markers", "groups"
  add_foreign_key "markers", "places"
  add_foreign_key "markers", "users", column: "owner_id"
  add_foreign_key "memberships", "groups"
  add_foreign_key "memberships", "users"
  add_foreign_key "participants", "badges"
  add_foreign_key "participants", "events"
  add_foreign_key "participants", "tickets"
  add_foreign_key "participants", "users"
  add_foreign_key "participants", "vouchers"
  add_foreign_key "ticket_items", "coupons"
  add_foreign_key "ticket_items", "events"
  add_foreign_key "ticket_items", "groups"
  add_foreign_key "ticket_items", "participants"
  add_foreign_key "ticket_items", "payment_methods"
  add_foreign_key "ticket_items", "tickets"
  add_foreign_key "ticket_items", "users"
  add_foreign_key "tickets", "badge_classes", column: "check_badge_class_id"
  add_foreign_key "tickets", "events"
  add_foreign_key "tickets", "groups"
  add_foreign_key "track_roles", "tracks"
  add_foreign_key "track_roles", "users"
  add_foreign_key "tracks", "groups"
  add_foreign_key "venues", "groups"
  add_foreign_key "venues", "places"
  add_foreign_key "venues", "users", column: "owner_id"
  add_foreign_key "vouchers", "badge_classes"
  add_foreign_key "vouchers", "users", column: "receiver_id"
  add_foreign_key "vouchers", "users", column: "sender_id"
end
