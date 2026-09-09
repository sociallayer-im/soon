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

ActiveRecord::Schema[8.1].define(version: 2026_09_09_030000) do
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

  create_table "after_sale_items", id: :string, force: :cascade do |t|
    t.string "after_sale_request_id", null: false
    t.integer "amount", null: false
    t.datetime "created_at", null: false
    t.string "order_item_id", null: false
    t.integer "quantity", null: false
    t.datetime "updated_at", null: false
    t.index ["after_sale_request_id", "order_item_id"], name: "idx_on_after_sale_request_id_order_item_id_6e7fef7f50", unique: true
    t.index ["order_item_id"], name: "index_after_sale_items_on_order_item_id"
    t.check_constraint "quantity > 0", name: "after_sale_items_quantity_positive"
  end

  create_table "after_sale_requests", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deadline_at", comment: "seller silence past this is taken as agreement — see ShoppingAfterSaleTimeoutJob"
    t.text "description"
    t.string "evidence_urls", default: [], null: false, array: true
    t.boolean "include_shipping", default: false, null: false, comment: "who pays the return postage; derived from `reason`, adjustable by the seller"
    t.string "kind", null: false, comment: "refund_only | return_refund"
    t.string "order_id", null: false
    t.string "reason", null: false, comment: "no_reason | quality | wrong_item | damaged | other"
    t.integer "refund_amount", null: false
    t.string "request_no", null: false
    t.datetime "requested_at", null: false
    t.datetime "resolved_at"
    t.string "return_carrier"
    t.string "return_tracking_no"
    t.string "seller_note"
    t.string "shop_id", null: false
    t.string "status", default: "requested", null: false, comment: "requested | approved | rejected | shipping | received | refunded | cancelled | closed"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["order_id"], name: "index_after_sale_requests_on_order_id"
    t.index ["request_no"], name: "index_after_sale_requests_on_request_no", unique: true
    t.index ["shop_id", "status", "created_at"], name: "index_after_sale_requests_on_shop_id_and_status_and_created_at"
    t.index ["status", "deadline_at"], name: "index_after_sale_requests_on_status_and_deadline_at"
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

  create_table "cart_items", id: :string, force: :cascade do |t|
    t.string "cart_id", null: false
    t.datetime "created_at", null: false
    t.string "product_variant_id", null: false
    t.integer "quantity", default: 1, null: false
    t.datetime "updated_at", null: false
    t.index ["cart_id", "product_variant_id"], name: "index_cart_items_on_cart_id_and_product_variant_id", unique: true
    t.check_constraint "quantity > 0", name: "cart_items_quantity_positive"
  end

  create_table "carts", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "items_count", default: 0, null: false
    t.string "shop_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["user_id", "shop_id"], name: "index_carts_on_user_id_and_shop_id", unique: true
  end

  create_table "categories", id: :string, force: :cascade do |t|
    t.boolean "archived", default: false, null: false
    t.datetime "created_at", null: false
    t.string "group_id", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.integer "sort", default: 0, null: false
    t.string "summary"
    t.integer "topics_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "visibility", default: "public", null: false, comment: "public | member | manager | team"
    t.index ["group_id", "slug"], name: "index_categories_on_group_id_and_slug", unique: true
    t.index ["group_id", "sort"], name: "index_categories_on_group_id_and_sort"
    t.index ["group_id", "visibility"], name: "index_categories_on_group_id_and_visibility"
  end

  create_table "category_teams", id: :string, force: :cascade do |t|
    t.string "category_id", null: false
    t.datetime "created_at", null: false
    t.string "team_id", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id", "team_id"], name: "index_category_teams_on_category_id_and_team_id", unique: true
    t.index ["team_id"], name: "index_category_teams_on_team_id"
  end

  create_table "comments", id: :string, force: :cascade do |t|
    t.string "badge_id"
    t.string "comment_type", null: false, comment: "checkin | chat | comment | star | feedback"
    t.text "content"
    t.string "content_type", default: "text"
    t.datetime "created_at", null: false
    t.string "edit_parent_id"
    t.string "fed_actor_id"
    t.string "fed_uri"
    t.string "icon_url"
    t.string "item_id"
    t.string "item_type"
    t.boolean "removed", default: false
    t.string "reply_parent_id"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "user_id"
    t.index ["fed_uri"], name: "index_comments_on_fed_uri", unique: true, where: "(fed_uri IS NOT NULL)"
    t.index ["item_type", "item_id", "removed"], name: "index_comments_on_item_type_and_item_id_and_removed"
    t.index ["user_id", "comment_type"], name: "index_comments_on_user_id_and_comment_type"
    t.index ["user_id"], name: "index_comments_on_user_id"
  end

  create_table "coupon_redemptions", id: :string, force: :cascade do |t|
    t.string "coupon_id", null: false
    t.datetime "created_at", null: false
    t.integer "discount_amount", null: false
    t.string "order_id", null: false
    t.datetime "released_at", comment: "same meaning as orders.released_at: exactly-once, never inferred from status"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["coupon_id", "order_id"], name: "index_coupon_redemptions_on_coupon_id_and_order_id", unique: true
    t.index ["coupon_id", "user_id"], name: "index_coupon_redemptions_on_coupon_id_and_user_id", where: "(released_at IS NULL)"
    t.index ["order_id"], name: "index_coupon_redemptions_on_order_id"
  end

  create_table "coupons", id: :string, force: :cascade do |t|
    t.string "applicable_product_ids", default: [], array: true
    t.string "applicable_ticket_ids", array: true
    t.string "code"
    t.datetime "created_at", null: false
    t.integer "discount", comment: "basis points of 10000 for ratio, smallest unit for amount"
    t.string "discount_type", comment: "ratio | amount"
    t.string "event_id"
    t.datetime "expires_at"
    t.string "label"
    t.integer "max_allowed_usages"
    t.integer "min_order_amount", comment: "spend threshold in minor units; the ticket side never had one"
    t.integer "order_usage_count", default: 0
    t.string "owner_id"
    t.string "owner_type", comment: "Event | Shop"
    t.integer "per_user_limit", comment: "null = unlimited"
    t.string "receiver_address"
    t.boolean "removed", default: false
    t.string "selector_type", comment: "code | email | badge"
    t.string "ticket_item_ids", array: true
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_coupons_on_code"
    t.index ["event_id"], name: "index_coupons_on_event_id"
    t.index ["owner_type", "owner_id"], name: "index_coupons_on_owner_type_and_owner_id"
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
    t.string "image_note"
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
    t.string "visibility", default: "normal", comment: "normal | open_registration | unlisted"
    t.index ["form_id"], name: "index_events_on_form_id"
    t.index ["group_id"], name: "index_events_on_group_id"
    t.index ["owner_id"], name: "index_events_on_owner_id"
    t.index ["place_id"], name: "index_events_on_place_id"
    t.index ["ref_id"], name: "index_events_on_ref_id", where: "(ref_id IS NOT NULL)"
    t.index ["track_id"], name: "index_events_on_track_id"
    t.index ["venue_id"], name: "index_events_on_venue_id"
  end

  create_table "fed_actors", id: :string, force: :cascade do |t|
    t.string "actor_type"
    t.jsonb "also_known_as", default: [], null: false
    t.datetime "blocked_at"
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.string "followers_url"
    t.string "icon_url"
    t.string "inbox_url", null: false
    t.string "key_id"
    t.datetime "last_fetched_at"
    t.string "moved_to"
    t.string "name"
    t.string "outbox_url"
    t.string "preferred_username"
    t.text "public_key_pem"
    t.jsonb "raw"
    t.string "shared_inbox_url"
    t.text "summary"
    t.datetime "updated_at", null: false
    t.string "uri", null: false
    t.index ["domain"], name: "index_fed_actors_on_domain"
    t.index ["uri"], name: "index_fed_actors_on_uri", unique: true
  end

  create_table "fed_deliveries", id: :string, force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "inbox_url", null: false
    t.string "last_error"
    t.datetime "next_attempt_at"
    t.jsonb "payload", null: false
    t.string "sender_id"
    t.string "sender_type", null: false
    t.string "signing_key_id"
    t.text "signing_key_pem"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["status", "next_attempt_at"], name: "index_fed_deliveries_on_status_and_next_attempt_at"
    t.index ["status"], name: "index_fed_deliveries_on_status"
  end

  create_table "fed_domain_policies", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.string "domain", null: false
    t.string "policy", null: false
    t.string "reason"
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_fed_domain_policies_on_domain", unique: true
  end

  create_table "fed_domain_stats", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "delivered_count", default: 0, null: false
    t.string "domain", null: false
    t.integer "failed_count", default: 0, null: false
    t.integer "inbound_count", default: 0, null: false
    t.integer "inbound_rejected_count", default: 0, null: false
    t.string "last_error"
    t.datetime "last_failure_at"
    t.datetime "last_success_at"
    t.date "unavailable_since"
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_fed_domain_stats_on_domain", unique: true
  end

  create_table "fed_events", id: :string, force: :cascade do |t|
    t.string "address"
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "end_time"
    t.string "external_participation_url"
    t.string "fed_actor_id"
    t.string "html_url"
    t.string "image_url"
    t.string "join_mode", default: "free"
    t.datetime "last_fetched_at"
    t.decimal "latitude", precision: 10, scale: 6
    t.string "location_name"
    t.decimal "longitude", precision: 10, scale: 6
    t.integer "max_participant"
    t.integer "participant_count", default: 0
    t.jsonb "raw"
    t.datetime "remote_updated_at"
    t.datetime "start_time"
    t.string "status", default: "CONFIRMED"
    t.string "summary"
    t.string "tags", default: [], array: true
    t.string "timezone"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "uri", null: false
    t.index ["fed_actor_id"], name: "index_fed_events_on_fed_actor_id"
    t.index ["start_time"], name: "index_fed_events_on_start_time"
    t.index ["uri"], name: "index_fed_events_on_uri", unique: true
  end

  create_table "fed_follows", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "direction", null: false
    t.string "fed_actor_id", null: false
    t.datetime "last_confirmed_at"
    t.string "local_id", null: false
    t.string "local_type", null: false
    t.integer "probe_count", default: 0, null: false
    t.datetime "probed_at"
    t.string "state", default: "accepted", null: false
    t.datetime "updated_at", null: false
    t.string "uri", null: false
    t.index ["fed_actor_id"], name: "index_fed_follows_on_fed_actor_id"
    t.index ["local_type", "local_id", "fed_actor_id", "direction"], name: "idx_fed_follows_uniq", unique: true
    t.index ["uri"], name: "index_fed_follows_on_uri", unique: true
  end

  create_table "fed_inbound_activities", id: :string, force: :cascade do |t|
    t.string "activity_type"
    t.string "body_digest"
    t.datetime "created_at", null: false
    t.string "fed_actor_id"
    t.string "status", default: "received", null: false
    t.string "uri", null: false
    t.index ["fed_actor_id"], name: "index_fed_inbound_activities_on_fed_actor_id"
    t.index ["uri"], name: "index_fed_inbound_activities_on_uri", unique: true
  end

  create_table "fed_instance_keys", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "private_key", null: false
    t.text "public_key", null: false
    t.integer "singleton_guard", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["singleton_guard"], name: "index_fed_instance_keys_on_singleton_guard", unique: true
  end

  create_table "fed_participations", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "fed_event_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "uri", null: false
    t.string "user_id", null: false
    t.index ["uri"], name: "index_fed_participations_on_uri", unique: true
    t.index ["user_id", "fed_event_id"], name: "index_fed_participations_on_user_id_and_fed_event_id", unique: true
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
    t.boolean "public_submissions", default: false, null: false
    t.boolean "published", default: false, null: false
    t.string "slug", null: false
    t.text "submission_message"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_forms_on_created_by_id"
    t.index ["slug"], name: "index_forms_on_slug", unique: true
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "callback_priority"
    t.text "callback_queue_name"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "discarded_at"
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
    t.text "on_discard"
    t.text "on_finish"
    t.text "on_success"
    t.jsonb "serialized_properties"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id", null: false
    t.datetime "created_at", null: false
    t.interval "duration"
    t.text "error"
    t.text "error_backtrace", array: true
    t.integer "error_event", limit: 2
    t.datetime "finished_at"
    t.text "job_class"
    t.uuid "process_id"
    t.text "queue_name"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lock_type", limit: 2
    t.jsonb "state"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "key"
    t.datetime "updated_at", null: false
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id"
    t.uuid "batch_callback_id"
    t.uuid "batch_id"
    t.text "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "cron_at"
    t.text "cron_key"
    t.text "error"
    t.integer "error_event", limit: 2
    t.integer "executions_count"
    t.datetime "finished_at"
    t.boolean "is_discrete"
    t.text "job_class"
    t.text "labels", array: true
    t.integer "lock_type", limit: 2
    t.datetime "locked_at"
    t.uuid "locked_by_id"
    t.datetime "performed_at"
    t.integer "priority"
    t.text "queue_name"
    t.uuid "retried_good_job_id"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["concurrency_key", "created_at"], name: "index_good_jobs_on_concurrency_key_and_created_at"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["created_at"], name: "index_good_jobs_on_created_at"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at_only", where: "(finished_at IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_on_discarded", order: :desc, where: "((finished_at IS NOT NULL) AND (error IS NOT NULL))"
    t.index ["id"], name: "index_good_jobs_on_unfinished_or_errored", where: "((finished_at IS NULL) OR (error IS NOT NULL))"
    t.index ["job_class"], name: "index_good_jobs_on_job_class"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "created_at"], name: "index_good_jobs_jobs_on_priority_created_at_when_unfinished", order: { priority: "DESC NULLS LAST" }, where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_for_candidate_dequeue_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_on_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at"], name: "index_good_jobs_on_priority_scheduled_at_unfinished_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at", "id"], name: "index_good_jobs_on_queue_name_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["queue_name", "scheduled_at"], name: "index_good_jobs_on_queue_name_and_scheduled_at", where: "(finished_at IS NULL)"
    t.index ["queue_name"], name: "index_good_jobs_on_queue_name"
    t.index ["scheduled_at", "queue_name"], name: "index_good_jobs_on_scheduled_at_and_queue_name"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
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
    t.string "can_create_hackathon", default: "manager", comment: "manager | member | everyone"
    t.string "can_create_poll", default: "member", comment: "manager | member | everyone"
    t.string "can_join_event", default: "everyone", comment: "manager | member | everyone"
    t.string "can_post_topic", default: "member", comment: "manager | member | everyone"
    t.string "can_publish_event", default: "everyone", comment: "manager | member | everyone"
    t.string "can_view_event", default: "everyone", comment: "manager | member | everyone"
    t.datetime "created_at", null: false
    t.string "custom_domain"
    t.string "custom_domain_pending"
    t.string "custom_domain_token"
    t.datetime "custom_domain_verified_at"
    t.jsonb "data", default: {}
    t.boolean "discussion_enabled", default: false, null: false
    t.date "end_date"
    t.string "event_tag_list", default: [], array: true
    t.string "event_union", array: true
    t.integer "events_count", default: 0, null: false
    t.string "featured_image_url"
    t.jsonb "fed_also_known_as", default: [], null: false
    t.text "fed_ed25519_private_key"
    t.string "fed_ed25519_public_key"
    t.string "fed_moved_to"
    t.text "fed_private_key"
    t.text "fed_public_key"
    t.string "group_tags", default: [], array: true
    t.string "group_ticket_event_id"
    t.boolean "hackathon_enabled", default: false, null: false
    t.string "image_url"
    t.string "location"
    t.string "logo_url"
    t.boolean "map_enabled", default: false, null: false
    t.integer "memberships_count", default: 0, null: false
    t.string "name"
    t.string "nickname"
    t.string "op_label_list", default: [], array: true
    t.string "parent_id"
    t.string "permissions", default: [], array: true
    t.boolean "poll_enabled", default: false, null: false
    t.string "ref_id"
    t.boolean "require_event_approval", default: false, null: false
    t.string "requirement_tag_list", default: [], array: true
    t.jsonb "social_links", default: {}
    t.date "start_date"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.string "venue_tag_list", default: [], array: true
    t.string "venue_union", array: true
    t.index ["custom_domain"], name: "index_groups_on_custom_domain", unique: true, where: "(custom_domain IS NOT NULL)"
    t.index ["name"], name: "index_groups_on_name", unique: true
    t.index ["parent_id"], name: "index_groups_on_parent_id"
    t.index ["ref_id"], name: "index_groups_on_ref_id", where: "(ref_id IS NOT NULL)"
  end

  create_table "hackathon_project_members", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hackathon_id", null: false
    t.string "project_id", null: false
    t.string "role", default: "member", null: false, comment: "owner | member"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["hackathon_id", "user_id"], name: "index_hackathon_project_members_one_per_hackathon", unique: true
    t.index ["project_id", "user_id"], name: "index_hackathon_project_members_on_project_id_and_user_id", unique: true
  end

  create_table "hackathon_project_stars", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "project_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["project_id", "user_id"], name: "index_hackathon_project_stars_on_project_id_and_user_id", unique: true
    t.index ["user_id"], name: "index_hackathon_project_stars_on_user_id"
  end

  create_table "hackathon_projects", id: :string, force: :cascade do |t|
    t.datetime "approved_at"
    t.string "award"
    t.text "content"
    t.string "cover_url"
    t.datetime "created_at", null: false
    t.string "demo_url"
    t.string "flag_reason"
    t.datetime "flagged_at"
    t.string "flagged_by_id"
    t.string "hackathon_id", null: false
    t.integer "members_count", default: 0, null: false
    t.boolean "recruiting", default: false, null: false
    t.datetime "rejected_at"
    t.string "repo_url"
    t.text "review_note"
    t.string "seeking", default: [], null: false, array: true
    t.integer "stars_count", default: 0, null: false
    t.datetime "submitted_at"
    t.string "tagline"
    t.string "tech", default: [], null: false, array: true
    t.string "title", null: false
    t.string "track_id"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.string "video_url"
    t.index ["hackathon_id", "recruiting"], name: "index_hackathon_projects_on_hackathon_id_and_recruiting"
    t.index ["hackathon_id", "submitted_at"], name: "index_hackathon_projects_on_hackathon_id_and_submitted_at"
    t.index ["hackathon_id", "track_id"], name: "index_hackathon_projects_on_hackathon_id_and_track_id"
    t.index ["user_id"], name: "index_hackathon_projects_on_user_id"
  end

  create_table "hackathons", id: :string, force: :cascade do |t|
    t.string "can_submit_project", default: "participant", null: false, comment: "participant | member | everyone"
    t.text "content"
    t.string "cover_url"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "deleted_by_id"
    t.datetime "end_at"
    t.string "event_id"
    t.string "flag_reason"
    t.datetime "flagged_at"
    t.string "flagged_by_id"
    t.string "group_id", null: false
    t.integer "projects_count", default: 0, null: false, comment: "submitted projects, recomputed by Hackathon#refresh_counts!"
    t.string "projects_visibility", default: "after_submit", null: false, comment: "always | after_submit | after_review"
    t.datetime "start_at"
    t.string "status", default: "draft", null: false, comment: "draft | published"
    t.datetime "submit_close_at"
    t.datetime "submit_open_at"
    t.string "tagline"
    t.string "title", null: false
    t.jsonb "tracks", default: [], null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["event_id"], name: "index_hackathons_on_event_id", unique: true, where: "(event_id IS NOT NULL)"
    t.index ["group_id", "status"], name: "index_hackathons_on_group_id_and_status"
    t.index ["user_id"], name: "index_hackathons_on_user_id"
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
    t.boolean "admin_notification", default: true, null: false
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}
    t.datetime "expires_at"
    t.string "group_id", null: false
    t.string "role", null: false, comment: "member | admin | owner"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["expires_at"], name: "index_memberships_on_expires_at"
    t.index ["group_id", "role"], name: "index_memberships_on_group_id_and_role"
    t.index ["group_id"], name: "index_memberships_on_group_id"
    t.index ["user_id", "group_id"], name: "index_memberships_on_user_id_and_group_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "oauth_access_tokens", id: :string, force: :cascade do |t|
    t.string "application_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: [], null: false, array: true
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["token_digest"], name: "index_oauth_access_tokens_on_token_digest", unique: true
    t.index ["user_id", "application_id"], name: "index_oauth_access_tokens_on_user_id_and_application_id"
  end

  create_table "oauth_applications", id: :string, force: :cascade do |t|
    t.string "allowed_scopes", default: [], null: false, array: true
    t.string "client_id", null: false
    t.string "client_secret_digest"
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "group_id"
    t.string "homepage_url"
    t.string "logo_url"
    t.string "name", null: false
    t.string "owner_id", null: false
    t.string "redirect_uris", default: [], null: false, array: true
    t.datetime "reviewed_at"
    t.string "status", default: "draft", null: false
    t.boolean "trusted", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["client_id"], name: "index_oauth_applications_on_client_id", unique: true
    t.index ["group_id"], name: "index_oauth_applications_on_group_id"
    t.index ["owner_id"], name: "index_oauth_applications_on_owner_id"
  end

  create_table "oauth_authorization_codes", id: :string, force: :cascade do |t|
    t.string "application_id", null: false
    t.string "code_challenge", null: false
    t.string "code_challenge_method", default: "S256", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "nonce"
    t.string "redirect_uri", null: false
    t.string "scopes", default: [], null: false, array: true
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.string "user_id", null: false
    t.index ["application_id"], name: "index_oauth_authorization_codes_on_application_id"
    t.index ["token_digest"], name: "index_oauth_authorization_codes_on_token_digest", unique: true
    t.index ["user_id"], name: "index_oauth_authorization_codes_on_user_id"
  end

  create_table "oauth_grants", id: :string, force: :cascade do |t|
    t.string "application_id", null: false
    t.datetime "created_at", null: false
    t.string "scopes", default: [], null: false, array: true
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["user_id", "application_id"], name: "index_oauth_grants_on_user_id_and_application_id", unique: true
  end

  create_table "oauth_refresh_tokens", id: :string, force: :cascade do |t|
    t.string "access_token_id", null: false
    t.string "application_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "family_id", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["access_token_id"], name: "index_oauth_refresh_tokens_on_access_token_id"
    t.index ["family_id"], name: "index_oauth_refresh_tokens_on_family_id"
    t.index ["token_digest"], name: "index_oauth_refresh_tokens_on_token_digest", unique: true
  end

  create_table "order_items", id: :string, force: :cascade do |t|
    t.string "badge_id", comment: "the badge this line issued, if any"
    t.datetime "created_at", null: false
    t.string "image_url"
    t.string "order_id", null: false
    t.string "product_id", null: false
    t.string "product_title", null: false
    t.string "product_variant_id", null: false
    t.integer "quantity", null: false
    t.integer "refunded_amount", default: 0, null: false
    t.integer "refunded_quantity", default: 0, null: false
    t.string "sku"
    t.string "status", default: "normal", null: false, comment: "normal | refunding | refunded"
    t.integer "subtotal_amount", null: false
    t.integer "unit_amount", null: false
    t.datetime "updated_at", null: false
    t.string "variant_title", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_variant_id"], name: "index_order_items_on_product_variant_id"
    t.check_constraint "quantity > 0", name: "order_items_quantity_positive"
  end

  create_table "orders", id: :string, force: :cascade do |t|
    t.string "buyer_message"
    t.string "cancel_reason"
    t.datetime "cancelled_at"
    t.string "chain"
    t.datetime "completed_at"
    t.string "coupon_id", comment: "redemption itself is a coupon_redemptions row"
    t.datetime "created_at", null: false
    t.string "currency", default: "cny", null: false
    t.integer "discount_amount", default: 0, null: false
    t.string "group_id", null: false, comment: "denormalised, for the seller's lists"
    t.string "idempotency_key", comment: "client-generated, one per checkout attempt; a retry returns the same order"
    t.integer "items_amount", null: false
    t.string "order_no", null: false, comment: "human-readable; the PK is still a TSID"
    t.datetime "paid_at"
    t.string "payment_method_id"
    t.string "payment_provider", comment: "wechat | stripe | evm | free"
    t.integer "platform_fee_amount"
    t.string "provider_ref"
    t.integer "refunded_amount", default: 0, null: false
    t.datetime "released_at", comment: "stock and coupon released exactly once, guarded here — never inferred from status"
    t.datetime "reserved_until", comment: "the sweeper expires unpaid orders past this"
    t.string "settlement_status"
    t.datetime "shipped_at"
    t.jsonb "shipping_address", default: {}, null: false, comment: "snapshot, not a reference"
    t.integer "shipping_amount", default: 0, null: false
    t.string "shop_id", null: false
    t.string "status", default: "pending", null: false, comment: "pending | paid | shipped | completed | cancelled | timeout | closed"
    t.string "stripe_setting_id"
    t.integer "total_amount", null: false
    t.string "txhash"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.string "wechat_pay_setting_id", comment: "the merchant that took the money; refunds go back through it"
    t.index ["order_no"], name: "index_orders_on_order_no", unique: true
    t.index ["provider_ref"], name: "index_orders_on_provider_ref", unique: true, where: "(provider_ref IS NOT NULL)"
    t.index ["shop_id", "status", "created_at"], name: "index_orders_on_shop_id_and_status_and_created_at"
    t.index ["status", "reserved_until"], name: "index_orders_sweeper"
    t.index ["txhash"], name: "index_orders_on_txhash", unique: true, where: "(txhash IS NOT NULL)"
    t.index ["user_id", "created_at"], name: "index_orders_on_user_id_and_created_at"
    t.index ["user_id", "idempotency_key"], name: "index_orders_idempotency_per_user", unique: true, where: "(idempotency_key IS NOT NULL)"
  end

  create_table "participants", id: :string, force: :cascade do |t|
    t.string "badge_id"
    t.datetime "cancelled_at"
    t.datetime "checked_in_at"
    t.datetime "created_at", null: false
    t.string "event_id", null: false
    t.string "fed_actor_id"
    t.string "fed_join_uri"
    t.string "message"
    t.string "payment_status", comment: "derived summary of this participant's ticket_items; see Participant#refresh_payment_status!"
    t.datetime "registered_at"
    t.string "status", default: "attending", null: false, comment: "attending | pending | declined | maybe | cancelled — see Participant"
    t.datetime "updated_at", null: false
    t.string "user_id"
    t.string "voucher_id"
    t.index ["event_id", "status"], name: "index_participants_on_event_id_and_status"
    t.index ["event_id"], name: "index_participants_on_event_id"
    t.index ["fed_actor_id", "event_id"], name: "index_participants_on_fed_actor_id_and_event_id", unique: true, where: "(fed_actor_id IS NOT NULL)"
    t.index ["fed_join_uri"], name: "index_participants_on_fed_join_uri", unique: true, where: "(fed_join_uri IS NOT NULL)"
    t.index ["user_id", "event_id"], name: "index_participants_on_user_id_and_event_id", unique: true
    t.index ["user_id"], name: "index_participants_on_user_id"
  end

  create_table "payment_methods", id: :string, force: :cascade do |t|
    t.string "chain"
    t.jsonb "chain_token_addresses", default: {}
    t.string "chains", default: [], array: true
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "item_id"
    t.string "item_type"
    t.string "kind", comment: "crypto | fiat | credit"
    t.bigint "price"
    t.string "protocol"
    t.string "receiver_address"
    t.string "stripe_setting_id", comment: "which of the event owner's keys this method charges to"
    t.string "token_address"
    t.string "token_name"
    t.datetime "updated_at", null: false
    t.string "wechat_pay_setting_id", comment: "which merchant collects this method's WeChat payments"
    t.index ["item_type", "item_id"], name: "index_payment_methods_on_item_type_and_item_id"
    t.index ["stripe_setting_id"], name: "index_payment_methods_on_stripe_setting_id"
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
    t.index ["name"], name: "index_places_on_name"
  end

  create_table "poll_options", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "poll_id", null: false
    t.integer "position", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "votes_count", default: 0, null: false
    t.index ["poll_id", "position"], name: "index_poll_options_on_poll_id_and_position"
  end

  create_table "poll_votes", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "option_id"
    t.string "poll_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.integer "value"
    t.index ["option_id"], name: "index_poll_votes_on_option_id"
    t.index ["poll_id", "user_id", "option_id"], name: "index_poll_votes_unique", unique: true
    t.index ["poll_id", "user_id"], name: "index_poll_votes_on_poll_id_and_user_id"
  end

  create_table "polls", id: :string, force: :cascade do |t|
    t.datetime "close_at"
    t.datetime "closed_at"
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "deleted_by_id"
    t.string "eligible_group_ids", default: [], null: false, array: true
    t.string "eligible_team_ids", default: [], null: false, array: true
    t.datetime "first_voted_at"
    t.string "flag_reason"
    t.datetime "flagged_at"
    t.string "flagged_by_id"
    t.string "group_id", null: false
    t.integer "max_value"
    t.integer "min_value"
    t.string "poll_type", default: "single", null: false, comment: "single | multiple | number"
    t.string "results", default: "always", null: false, comment: "always | on_vote | on_close | manager_only"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.string "visibility", default: "public", null: false, comment: "public | participants | secret"
    t.integer "votes_count", default: 0, null: false, comment: "distinct voters, recomputed by Poll#refresh_counts!"
    t.index ["close_at"], name: "index_polls_pending_close", where: "((closed_at IS NULL) AND (deleted_at IS NULL))"
    t.index ["group_id", "created_at"], name: "index_polls_on_group_and_created", where: "((deleted_at IS NULL) AND (flagged_at IS NULL))"
    t.index ["user_id"], name: "index_polls_on_user_id"
  end

  create_table "product_variants", id: :string, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "compare_at_amount", comment: "struck-through price, display only"
    t.datetime "created_at", null: false
    t.string "image_url"
    t.integer "member_price_amount", comment: "reserved, not implemented"
    t.string "option_values", default: [], null: false, comment: "same order as products.options", array: true
    t.integer "price_amount", null: false, comment: "minor units (分)"
    t.string "product_id", null: false
    t.string "sku", comment: "seller's own code; unique where present"
    t.integer "sold_count", default: 0, null: false
    t.integer "sort", default: 0, null: false
    t.integer "stock", default: 0, null: false
    t.integer "stock_locked", default: 0, null: false
    t.string "title", null: false, comment: "display name, e.g. 「黑色 / L」"
    t.datetime "updated_at", null: false
    t.integer "weight_gram", default: 0, null: false
    t.index ["product_id", "option_values"], name: "index_product_variants_on_product_id_and_option_values", unique: true
    t.index ["product_id", "sort"], name: "index_product_variants_on_product_id_and_sort"
    t.index ["sku"], name: "index_product_variants_on_sku", unique: true, where: "(sku IS NOT NULL)"
    t.check_constraint "price_amount >= 0", name: "product_variants_price_non_negative"
    t.check_constraint "stock >= 0", name: "product_variants_stock_non_negative"
    t.check_constraint "stock_locked >= 0", name: "product_variants_stock_locked_non_negative"
  end

  create_table "products", id: :string, force: :cascade do |t|
    t.string "badge_class_id", comment: "issued on payment (P4), null = none"
    t.string "buyer_scope", default: "everyone", null: false, comment: "manager | member | everyone"
    t.text "content", comment: "markdown; heavy, only rendered in the :detail view"
    t.string "cover_image_url"
    t.datetime "created_at", null: false
    t.boolean "free_shipping", default: false, null: false
    t.string "fulfillment_type", default: "physical", null: false, comment: "physical | digital | redeemable | booking — only physical is implemented"
    t.string "group_id", null: false, comment: "denormalised; avoids a join on every list query"
    t.string "image_urls", default: [], null: false, array: true
    t.integer "max_price_amount"
    t.integer "min_price_amount"
    t.boolean "no_reason_return_excluded", default: false, null: false, comment: "see design/SHOP_COMPLIANCE_NOTES.md §2"
    t.string "no_reason_return_excluded_reason"
    t.jsonb "options", default: [], null: false
    t.integer "purchase_limit", comment: "per-buyer cap, null = unlimited"
    t.string "shipping_rate_id", comment: "null = the shop's default template (P1)"
    t.string "shop_id", null: false
    t.integer "sold_count", default: 0, null: false
    t.integer "sort", default: 0, null: false
    t.string "status", default: "draft", null: false, comment: "draft | active | soldout | archived"
    t.integer "stock_total", default: 0, null: false
    t.string "summary"
    t.string "tag_list", default: [], null: false, array: true
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id", "status"], name: "index_products_on_group_id_and_status"
    t.index ["shop_id", "status", "sort"], name: "index_products_on_shop_id_and_status_and_sort"
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

  create_table "refunds", id: :string, force: :cascade do |t|
    t.string "after_sale_request_id", comment: "the shop's after-sale case this refund settles, when there is one"
    t.integer "amount", null: false, comment: "minor units; equal to the item amount for a full refund"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.text "error"
    t.boolean "full_refund", default: true, null: false, comment: "full refunds release the seat; partial move money only"
    t.string "provider_ref", comment: "Stripe re_… id"
    t.string "reason"
    t.string "refundable_id"
    t.string "refundable_type", comment: "TicketItem | Order"
    t.string "requested_by_user_id", null: false
    t.string "status", default: "pending", null: false, comment: "pending | succeeded | failed"
    t.string "ticket_item_id"
    t.datetime "updated_at", null: false
    t.index ["refundable_type", "refundable_id"], name: "index_refunds_on_refundable_type_and_refundable_id"
    t.index ["refundable_type", "refundable_id"], name: "index_refunds_one_live_full_refund_per_refundable", unique: true, where: "(full_refund AND ((status)::text = ANY ((ARRAY['pending'::character varying, 'succeeded'::character varying])::text[])))"
    t.index ["ticket_item_id"], name: "index_refunds_on_ticket_item_id"
    t.index ["ticket_item_id"], name: "index_refunds_one_live_full_refund_per_item", unique: true, where: "(full_refund AND ((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('succeeded'::character varying)::text])))"
  end

  create_table "replies", id: :string, force: :cascade do |t|
    t.text "content", null: false
    t.string "content_type", default: "text"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "deleted_by_id"
    t.string "flag_reason"
    t.datetime "flagged_at"
    t.string "flagged_by_id"
    t.string "reply_to_id"
    t.integer "stars_count", default: 0, null: false
    t.string "topic_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["deleted_at"], name: "index_replies_on_deleted_at"
    t.index ["flagged_at"], name: "index_replies_on_flagged_at"
    t.index ["reply_to_id"], name: "index_replies_on_reply_to_id"
    t.index ["topic_id", "created_at"], name: "index_replies_on_topic_and_created_alive", where: "((deleted_at IS NULL) AND (flagged_at IS NULL))"
    t.index ["topic_id", "created_at"], name: "index_replies_on_topic_id_and_created_at"
    t.index ["user_id"], name: "index_replies_on_user_id"
  end

  create_table "shipment_items", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "order_item_id", null: false
    t.integer "quantity", null: false
    t.string "shipment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["order_item_id"], name: "index_shipment_items_on_order_item_id"
    t.index ["shipment_id", "order_item_id"], name: "index_shipment_items_on_shipment_id_and_order_item_id", unique: true
    t.check_constraint "quantity > 0", name: "shipment_items_quantity_positive"
  end

  create_table "shipments", id: :string, force: :cascade do |t|
    t.string "carrier", null: false, comment: "code from Shipment::CARRIERS"
    t.string "carrier_name", null: false, comment: "snapshot of the label at the time"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "operator_user_id", null: false, comment: "which manager sent it"
    t.string "order_id", null: false
    t.datetime "shipped_at", null: false
    t.string "status", default: "shipped", null: false, comment: "shipped | delivered | returned"
    t.string "tracking_no", null: false
    t.datetime "updated_at", null: false
    t.index ["carrier", "tracking_no"], name: "index_shipments_on_carrier_and_tracking_no"
    t.index ["order_id"], name: "index_shipments_on_order_id"
  end

  create_table "shipping_addresses", id: :string, force: :cascade do |t|
    t.string "city", null: false
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "detail", null: false
    t.string "district", null: false
    t.boolean "is_default", default: false, null: false
    t.string "name", null: false
    t.string "phone", null: false
    t.string "postcode"
    t.string "province", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["user_id"], name: "index_shipping_addresses_on_user_id", where: "(deleted_at IS NULL)"
  end

  create_table "shipping_rate_zones", id: :string, force: :cascade do |t|
    t.integer "additional_amount", default: 0, null: false
    t.integer "additional_quantity", default: 1, null: false
    t.datetime "created_at", null: false
    t.integer "first_amount", null: false
    t.integer "first_quantity", default: 1, null: false
    t.string "provinces", default: [], null: false, comment: "empty = the fallback zone", array: true
    t.string "shipping_rate_id", null: false
    t.boolean "unavailable", default: false, null: false, comment: "this zone is not shipped to at all"
    t.datetime "updated_at", null: false
    t.index ["shipping_rate_id"], name: "index_shipping_rate_zones_on_shipping_rate_id"
  end

  create_table "shipping_rates", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "free_above_amount", comment: "free shipping at/above this subtotal FOR THIS TEMPLATE's lines, not the whole order"
    t.boolean "is_default", default: false, null: false
    t.string "name", null: false
    t.string "shop_id", null: false
    t.string "unit", default: "piece", null: false, comment: "piece | weight — only piece is implemented"
    t.datetime "updated_at", null: false
    t.index ["shop_id"], name: "index_shipping_rates_on_shop_id"
  end

  create_table "shops", id: :string, force: :cascade do |t|
    t.text "announcement", comment: "markdown"
    t.integer "auto_complete_days", default: 7, null: false
    t.string "contact_name"
    t.string "contact_phone"
    t.datetime "created_at", null: false
    t.string "currency", default: "cny", null: false
    t.string "group_id", null: false
    t.string "name", null: false
    t.integer "no_reason_return_days", default: 7, null: false, comment: "0 = this shop offers no no-reason returns"
    t.datetime "opened_at", null: false
    t.string "opened_by_user_id", null: false, comment: "the platform admin who approved this shop"
    t.integer "products_count", default: 0, null: false
    t.integer "reserve_minutes", default: 15, null: false, comment: "how long an unpaid order holds its stock"
    t.jsonb "return_address", default: {}, null: false, comment: "same shape as orders.shipping_address"
    t.string "status", default: "draft", null: false, comment: "draft | open | closed — only `open` accepts orders"
    t.datetime "updated_at", null: false
    t.index ["group_id"], name: "index_shops_on_group_id", unique: true
  end

  create_table "stripe_events", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.string "event_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.string "stripe_setting_id", null: false, comment: "which key's endpoint received it"
    t.datetime "updated_at", null: false
    t.index ["event_type", "created_at"], name: "index_stripe_events_on_event_type_and_created_at"
    t.index ["stripe_setting_id"], name: "index_stripe_events_on_stripe_setting_id"
  end

  create_table "stripe_settings", id: :string, force: :cascade do |t|
    t.string "account_id", comment: "Stripe acct_…, captured at validation time"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.string "mode", default: "live", null: false, comment: "live | test — auto-detected from key prefix"
    t.string "name", null: false, comment: "user-facing label shown in key pickers"
    t.text "secret_key", null: false, comment: "plaintext by decision; only the masked tail ever leaves the server"
    t.string "status", default: "active", null: false, comment: "active | invalid"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.string "webhook_endpoint_id", comment: "Stripe we_… id, for deletion on key removal"
    t.text "webhook_secret", comment: "per-endpoint signing secret"
    t.index ["user_id"], name: "index_stripe_settings_on_user_id"
  end

  create_table "team_memberships", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "team_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["team_id", "user_id"], name: "index_team_memberships_on_team_id_and_user_id", unique: true
    t.index ["user_id"], name: "index_team_memberships_on_user_id"
  end

  create_table "teams", id: :string, force: :cascade do |t|
    t.boolean "archived", default: false, null: false
    t.string "color"
    t.datetime "created_at", null: false
    t.string "description"
    t.string "group_id", null: false
    t.boolean "is_public", default: false, null: false
    t.integer "members_count", default: 0, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.integer "sort", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["group_id", "slug"], name: "index_teams_on_group_id_and_slug", unique: true
    t.index ["group_id", "sort"], name: "index_teams_on_group_id_and_sort"
  end

  create_table "ticket_items", id: :string, force: :cascade do |t|
    t.integer "amount"
    t.string "auth_type", comment: "free | payment | badge | invite"
    t.string "chain"
    t.string "coupon_id"
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "discount_data"
    t.integer "discount_value"
    t.string "event_id"
    t.string "group_id"
    t.decimal "original_price", precision: 40
    t.datetime "paid_at"
    t.string "participant_id"
    t.string "payment_method_id"
    t.string "payment_provider", comment: "stripe | evm | free"
    t.string "protocol"
    t.string "provider_ref", comment: "Checkout Session / PaymentIntent id for stripe; txhash stays the crypto column"
    t.datetime "released_at", comment: "inventory released exactly once, guarded here — never inferred from status"
    t.datetime "reserved_until", comment: "sweeper expires unpaid orders past this"
    t.string "selector_address"
    t.string "selector_type"
    t.string "sender_address"
    t.string "status", comment: "pending | succeeded | cancelled | timeout | refunded | partially_refunded | disputed — see TicketItem"
    t.string "stripe_setting_id"
    t.string "ticket_id", null: false
    t.string "ticket_type", default: "event", comment: "event | group"
    t.string "tracks_allowed", array: true
    t.string "txhash"
    t.datetime "updated_at", null: false
    t.string "user_id"
    t.string "wechat_pay_setting_id", comment: "the merchant that took the money; refunds go back through it"
    t.index ["coupon_id"], name: "index_ticket_items_on_coupon_id"
    t.index ["event_id", "status"], name: "index_ticket_items_on_event_id_and_status"
    t.index ["event_id"], name: "index_ticket_items_on_event_id"
    t.index ["participant_id"], name: "index_ticket_items_on_participant_id"
    t.index ["payment_method_id"], name: "index_ticket_items_on_payment_method_id"
    t.index ["provider_ref"], name: "index_ticket_items_on_provider_ref", unique: true, where: "(provider_ref IS NOT NULL)"
    t.index ["status", "reserved_until"], name: "index_ticket_items_sweeper"
    t.index ["stripe_setting_id"], name: "index_ticket_items_on_stripe_setting_id", where: "(stripe_setting_id IS NOT NULL)"
    t.index ["ticket_id"], name: "index_ticket_items_on_ticket_id"
    t.index ["txhash"], name: "index_ticket_items_on_txhash_unique", unique: true, where: "(txhash IS NOT NULL)"
    t.index ["user_id", "status"], name: "index_ticket_items_on_user_id_and_status"
    t.index ["user_id"], name: "index_ticket_items_on_user_id"
    t.index ["wechat_pay_setting_id"], name: "index_ticket_items_on_wechat_pay_setting_id"
  end

  create_table "ticketing_activities", id: :string, force: :cascade do |t|
    t.string "action", null: false, comment: "see Ticketing::Activity::ACTIONS"
    t.string "actor_user_id", comment: "only when a person caused it"
    t.datetime "created_at", null: false
    t.string "from_status"
    t.jsonb "metadata", default: {}, null: false
    t.string "reason"
    t.string "source", null: false, comment: "api | webhook | sweeper | reconciliation | system | backfill"
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.string "to_status"
    t.index ["action", "created_at"], name: "index_ticketing_activities_on_action_and_created_at"
    t.index ["actor_user_id"], name: "index_ticketing_activities_on_actor_user_id"
    t.index ["subject_type", "subject_id", "created_at"], name: "idx_on_subject_type_subject_id_created_at_cf5a9e860e"
  end

  create_table "tickets", id: :string, force: :cascade do |t|
    t.string "check_badge_class_id"
    t.string "check_group_ids", array: true
    t.string "content"
    t.datetime "created_at", null: false
    t.date "days_allowed", array: true
    t.date "end_date"
    t.datetime "end_time"
    t.string "event_id", null: false
    t.string "group_id"
    t.integer "membership_duration_days", default: 30, null: false
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

  create_table "topics", id: :string, force: :cascade do |t|
    t.string "category_id", null: false
    t.datetime "closed_at"
    t.text "content"
    t.string "content_type", default: "text"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "deleted_by_id"
    t.string "flag_reason"
    t.datetime "flagged_at"
    t.string "flagged_by_id"
    t.string "group_id", null: false
    t.string "image_url"
    t.bigint "last_active_mark", null: false
    t.string "last_reply_id"
    t.string "last_reply_user_id"
    t.datetime "pinned_at"
    t.datetime "replied_at"
    t.integer "replies_count", default: 0, null: false
    t.integer "stars_count", default: 0, null: false
    t.string "tags", default: [], array: true
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["category_id", "last_active_mark"], name: "index_topics_on_category_and_active", where: "((deleted_at IS NULL) AND (flagged_at IS NULL))"
    t.index ["deleted_at"], name: "index_topics_on_deleted_at"
    t.index ["flagged_at"], name: "index_topics_on_flagged_at"
    t.index ["group_id", "last_active_mark"], name: "index_topics_on_group_and_active", where: "((deleted_at IS NULL) AND (flagged_at IS NULL))"
    t.index ["group_id", "pinned_at"], name: "index_topics_on_group_id_and_pinned_at"
    t.index ["tags"], name: "index_topics_on_tags", using: :gin
    t.index ["user_id"], name: "index_topics_on_user_id"
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
    t.boolean "admin", default: false, null: false
    t.text "bio"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}
    t.string "email"
    t.string "eth"
    t.jsonb "fed_also_known_as", default: [], null: false
    t.text "fed_ed25519_private_key"
    t.string "fed_ed25519_public_key"
    t.string "fed_moved_to"
    t.text "fed_private_key"
    t.text "fed_public_key"
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
    t.string "wechat_openid"
    t.string "wechat_unionid"
    t.index ["admin"], name: "index_users_on_admin", where: "admin"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["eth"], name: "index_users_on_eth", unique: true
    t.index ["name"], name: "index_users_on_name", unique: true
    t.index ["phone"], name: "index_users_on_phone", unique: true
    t.index ["ref_id"], name: "index_users_on_ref_id", where: "(ref_id IS NOT NULL)"
    t.index ["sol"], name: "index_users_on_sol", unique: true
    t.index ["wechat_openid"], name: "index_users_on_wechat_openid", unique: true, where: "(wechat_openid IS NOT NULL)"
    t.index ["wechat_unionid"], name: "index_users_on_wechat_unionid", unique: true, where: "(wechat_unionid IS NOT NULL)"
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

  create_table "wechat_pay_events", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.string "event_type", null: false, comment: "TRANSACTION.SUCCESS | REFUND.SUCCESS | REFUND.ABNORMAL | REFUND.CLOSED"
    t.jsonb "payload", default: {}, null: false, comment: "envelope with resource replaced by its decrypted contents"
    t.datetime "processed_at"
    t.datetime "updated_at", null: false
    t.string "wechat_pay_setting_id", null: false, comment: "which merchant's endpoint received it"
    t.index ["event_type", "created_at"], name: "index_wechat_pay_events_on_event_type_and_created_at"
    t.index ["wechat_pay_setting_id"], name: "index_wechat_pay_events_on_wechat_pay_setting_id"
  end

  create_table "wechat_pay_settings", id: :string, force: :cascade do |t|
    t.text "apiv3_key", null: false, comment: "32-byte APIv3 key; AES-256-GCM-decrypts callback resources"
    t.string "app_id", null: false, comment: "the 公众号 appid; MUST be the one that issued payer.openid"
    t.string "cert_serial", null: false, comment: "商户API证书序列号, sent as the signature's serial_no"
    t.datetime "created_at", null: false
    t.string "currency", default: "cny", null: false
    t.string "mchid", null: false, comment: "商户号"
    t.string "name", null: false, comment: "label, e.g. the registered merchant name"
    t.text "private_key", null: false, comment: "apiclient_key.pem contents; signs every outbound request"
    t.text "public_key", comment: "微信支付公钥 PEM; verifies callback signatures"
    t.string "public_key_id", comment: "微信支付公钥 ID (PUB_KEY_ID_…), sent as Wechatpay-Serial on callbacks"
    t.string "status", default: "active", null: false, comment: "active | invalid"
    t.string "sub_mchid", comment: "特约商户号 — 服务商 mode only, null in single-merchant mode"
    t.datetime "updated_at", null: false
    t.string "user_id", comment: "null = platform-owned (single-merchant mode); set = per-organizer sub-merchant"
    t.index ["mchid", "sub_mchid"], name: "index_wechat_pay_settings_on_mchid_and_sub_mchid", unique: true
    t.index ["user_id"], name: "index_wechat_pay_settings_on_user_id"
  end

  create_table "withdrawals", id: :string, force: :cascade do |t|
    t.bigint "amount", null: false
    t.string "bank_account_name", null: false
    t.string "bank_account_number", null: false
    t.string "bank_name", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "cny", null: false
    t.string "group_id", null: false
    t.text "note"
    t.datetime "processed_at"
    t.string "processed_by_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["group_id"], name: "index_withdrawals_on_group_id"
    t.index ["processed_by_id"], name: "index_withdrawals_on_processed_by_id"
    t.index ["user_id", "status"], name: "index_withdrawals_on_user_id_and_status"
    t.index ["user_id"], name: "index_withdrawals_on_user_id"
  end

  add_foreign_key "activities", "users", column: "initiator_id"
  add_foreign_key "activities", "users", column: "receiver_id"
  add_foreign_key "after_sale_items", "after_sale_requests"
  add_foreign_key "after_sale_items", "order_items"
  add_foreign_key "after_sale_requests", "orders"
  add_foreign_key "after_sale_requests", "shops"
  add_foreign_key "after_sale_requests", "users"
  add_foreign_key "badge_classes", "groups"
  add_foreign_key "badge_classes", "users", column: "creator_id"
  add_foreign_key "badges", "badge_classes"
  add_foreign_key "badges", "users", column: "creator_id"
  add_foreign_key "badges", "users", column: "owner_id"
  add_foreign_key "badges", "vouchers"
  add_foreign_key "cart_items", "carts"
  add_foreign_key "cart_items", "product_variants"
  add_foreign_key "carts", "shops"
  add_foreign_key "carts", "users"
  add_foreign_key "categories", "groups"
  add_foreign_key "category_teams", "categories"
  add_foreign_key "category_teams", "teams"
  add_foreign_key "comments", "badges"
  add_foreign_key "comments", "comments", column: "edit_parent_id"
  add_foreign_key "comments", "comments", column: "reply_parent_id"
  add_foreign_key "comments", "fed_actors", on_delete: :cascade
  add_foreign_key "comments", "users"
  add_foreign_key "coupon_redemptions", "coupons"
  add_foreign_key "coupon_redemptions", "orders"
  add_foreign_key "coupon_redemptions", "users"
  add_foreign_key "coupons", "events"
  add_foreign_key "event_roles", "events"
  add_foreign_key "events", "forms"
  add_foreign_key "events", "groups"
  add_foreign_key "events", "places"
  add_foreign_key "events", "tracks"
  add_foreign_key "events", "users", column: "owner_id"
  add_foreign_key "events", "venues"
  add_foreign_key "fed_events", "fed_actors", on_delete: :cascade
  add_foreign_key "fed_follows", "fed_actors"
  add_foreign_key "fed_participations", "fed_events"
  add_foreign_key "fed_participations", "users"
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
  add_foreign_key "hackathon_project_members", "hackathon_projects", column: "project_id"
  add_foreign_key "hackathon_project_members", "hackathons"
  add_foreign_key "hackathon_project_members", "users"
  add_foreign_key "hackathon_project_stars", "hackathon_projects", column: "project_id"
  add_foreign_key "hackathon_project_stars", "users"
  add_foreign_key "hackathon_projects", "hackathons"
  add_foreign_key "hackathon_projects", "users"
  add_foreign_key "hackathons", "events", on_delete: :nullify
  add_foreign_key "hackathons", "groups"
  add_foreign_key "hackathons", "users"
  add_foreign_key "markers", "groups"
  add_foreign_key "markers", "places"
  add_foreign_key "markers", "users", column: "owner_id"
  add_foreign_key "memberships", "groups"
  add_foreign_key "memberships", "users"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "users"
  add_foreign_key "oauth_applications", "groups"
  add_foreign_key "oauth_applications", "users", column: "owner_id"
  add_foreign_key "oauth_authorization_codes", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_authorization_codes", "users"
  add_foreign_key "oauth_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_grants", "users"
  add_foreign_key "oauth_refresh_tokens", "oauth_access_tokens", column: "access_token_id"
  add_foreign_key "oauth_refresh_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_refresh_tokens", "users"
  add_foreign_key "order_items", "orders"
  add_foreign_key "orders", "shops"
  add_foreign_key "orders", "users"
  add_foreign_key "participants", "badges"
  add_foreign_key "participants", "events"
  add_foreign_key "participants", "fed_actors", on_delete: :cascade
  add_foreign_key "participants", "users"
  add_foreign_key "participants", "vouchers"
  add_foreign_key "poll_options", "polls"
  add_foreign_key "poll_votes", "poll_options", column: "option_id"
  add_foreign_key "poll_votes", "polls"
  add_foreign_key "poll_votes", "users"
  add_foreign_key "polls", "groups"
  add_foreign_key "polls", "users"
  add_foreign_key "product_variants", "products"
  add_foreign_key "products", "groups"
  add_foreign_key "products", "shops"
  add_foreign_key "replies", "topics"
  add_foreign_key "replies", "users"
  add_foreign_key "shipment_items", "order_items"
  add_foreign_key "shipment_items", "shipments"
  add_foreign_key "shipments", "orders"
  add_foreign_key "shipments", "users", column: "operator_user_id"
  add_foreign_key "shipping_addresses", "users"
  add_foreign_key "shipping_rate_zones", "shipping_rates"
  add_foreign_key "shipping_rates", "shops"
  add_foreign_key "shops", "groups"
  add_foreign_key "shops", "users", column: "opened_by_user_id"
  add_foreign_key "team_memberships", "teams"
  add_foreign_key "team_memberships", "users"
  add_foreign_key "teams", "groups"
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
  add_foreign_key "topics", "categories"
  add_foreign_key "topics", "groups"
  add_foreign_key "topics", "users"
  add_foreign_key "track_roles", "tracks"
  add_foreign_key "track_roles", "users"
  add_foreign_key "tracks", "groups"
  add_foreign_key "venues", "groups"
  add_foreign_key "venues", "places"
  add_foreign_key "venues", "users", column: "owner_id"
  add_foreign_key "vouchers", "badge_classes"
  add_foreign_key "vouchers", "users", column: "receiver_id"
  add_foreign_key "vouchers", "users", column: "sender_id"
  add_foreign_key "withdrawals", "groups"
  add_foreign_key "withdrawals", "users"
  add_foreign_key "withdrawals", "users", column: "processed_by_id"
end
