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

ActiveRecord::Schema[8.1].define(version: 2026_08_09_120001) do
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
    t.string "can_join_event", default: "everyone", comment: "manager | member | everyone"
    t.string "can_publish_event", default: "everyone", comment: "manager | member | everyone"
    t.string "can_view_event", default: "everyone", comment: "manager | member | everyone"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}
    t.date "end_date"
    t.string "event_tag_list", default: [], array: true
    t.string "event_union", array: true
    t.integer "events_count", default: 0, null: false
    t.string "featured_image_url"
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
    t.boolean "admin_notification", default: true, null: false
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
    t.datetime "cancelled_at"
    t.datetime "checked_in_at"
    t.datetime "created_at", null: false
    t.string "event_id", null: false
    t.string "message"
    t.string "payment_status", comment: "derived summary of this participant's ticket_items; see Participant#refresh_payment_status!"
    t.datetime "registered_at"
    t.string "status", default: "attending", null: false, comment: "attending | pending | declined | maybe | cancelled — see Participant"
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.string "voucher_id"
    t.index ["event_id", "status"], name: "index_participants_on_event_id_and_status"
    t.index ["event_id"], name: "index_participants_on_event_id"
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
    t.integer "amount", null: false, comment: "minor units; equal to the item amount for a full refund"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.text "error"
    t.boolean "full_refund", default: true, null: false, comment: "full refunds release the seat; partial move money only"
    t.string "provider_ref", comment: "Stripe re_… id"
    t.string "reason"
    t.string "requested_by_user_id", null: false
    t.string "status", default: "pending", null: false, comment: "pending | succeeded | failed"
    t.string "ticket_item_id", null: false
    t.datetime "updated_at", null: false
    t.index ["ticket_item_id"], name: "index_refunds_on_ticket_item_id"
    t.index ["ticket_item_id"], name: "index_refunds_one_live_full_refund_per_item", unique: true, where: "(full_refund AND ((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('succeeded'::character varying)::text])))"
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
    t.boolean "admin", default: false, null: false
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
