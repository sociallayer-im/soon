# frozen_string_literal: true
#
# One-shot ETL: copy data from the legacy sails/ DB (integer PKs + TSID `key`
# column on a few tables) into soon/'s DB (TSID string PKs everywhere).
#
#   SOURCE_DB=solia_development bin/rails runner script/migrate_from_sails.rb
#
# DRY_RUN=1 builds the id maps (pass 1) and reads/transforms every source row
# (validating req/null_dup/suffix_dup rules) WITHOUT truncating or writing
# anything to the target DB — use it to sanity-check read/skip counts before
# committing to a real load. Target must always be a local dev DB: this script
# TRUNCATEs every table it migrates, so never point it at anything shared.
#
# Strategy
#   * Every source row gets a soon `id` (string TSID):
#       - tables that already carry a TSID `key` (groups/profiles/events/venues)
#         reuse it, so ids are stable across the two systems;
#       - form_* tables already use TSID string ids -> reused verbatim;
#       - everything else gets a freshly generated TSID.
#   * A per-table map {legacy_integer_id => soon_tsid} is built up front (pass 1)
#     so foreign keys — including self-referential and circular ones — can be
#     remapped in pass 2 regardless of insert order.
#   * FK triggers are disabled for the load (superuser) so ordering/self-refs/
#     circular refs (groups<->events) don't matter; NOT NULL and UNIQUE still
#     apply. Inserts use insert_all => ON CONFLICT DO NOTHING, so duplicate
#     unique values (blank emails, repeated names) are skipped, not fatal.
#   * Rows missing a NOT NULL foreign key after remap are skipped and counted.

require "set"

SOURCE_DB = ENV.fetch("SOURCE_DB", "solia_development")
DRY_RUN   = ENV["DRY_RUN"].present?
BATCH     = 1000
NOW       = Time.now

# Refuse to run against anything that looks like a shared/remote target —
# this script TRUNCATEs every table it touches. A bare database name (no
# host) is a local Unix-socket/localhost connection; a host or a full
# postgresql:// URL is not.
target_cfg = ActiveRecord::Base.connection_db_config.configuration_hash
if target_cfg[:host].present? || ENV["DATABASE_URL"].present?
  abort "Refusing to run: target DB config has a host (#{target_cfg[:host] || ENV['DATABASE_URL']}) — " \
        "this script only ever runs against a local dev DB."
end

# ---- source connection (typed reads via AR) ---------------------------------
class SourceBase < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "postgresql", database: SOURCE_DB)
end

def src(table)
  ($src ||= {})[table] ||= Class.new(SourceBase) { self.table_name = table }
end

# ---- id maps ----------------------------------------------------------------
GEN = Tsid::Generator.new
$map = Hash.new { |h, k| h[k] = {} }

# Maps are keyed by the TARGET table name (what mid() / row[:id] look up), but
# read from the SOURCE table (they differ only for profiles -> users).
# strategy: :key (reuse TSID key col), :id (already string id), :gen (fresh)
def build_map(target, source, strategy)
  m = $map[target]
  case strategy
  when :key
    src(source).connection.select_rows("SELECT id, key FROM #{source}").each do |id, key|
      m[id.to_i] = (key && !key.empty?) ? key : GEN.generate
    end
  when :id
    src(source).connection.select_rows("SELECT id FROM #{source}").each { |(id)| m[id] = id }
  when :gen
    src(source).connection.select_rows("SELECT id FROM #{source}").each { |(id)| m[id.to_i] = GEN.generate }
  end
  puts "  map #{target}: #{m.size}"
end

# Users need identity-merge, not just id-mapping: legacy data holds duplicate
# people (same email modulo case/whitespace, or same wallet) that soon's unique
# indexes reject. We keep the first occurrence as the survivor and redirect every
# duplicate's id to it, so all foreign keys (incl. NOT NULL owner_id) still
# resolve instead of dangling. Populates $map["users"] and $user_keep (source
# ids to actually insert).
$user_keep = Set.new
def build_user_map
  m = $map["users"]
  seen = {} # [kind, normalized_value] => survivor soon_id
  rows = src("profiles").connection.select_rows(
    "SELECT id, key, email, address, username, phone, sol_address FROM profiles ORDER BY id")
  rows.each do |id, key, email, address, username, phone, sol|
    id = id.to_i
    keys = []
    keys << [:email, email.strip.downcase]   if email && !email.strip.empty?
    keys << [:eth,   address.strip.downcase] if address && !address.strip.empty?
    keys << [:name,  username]               if username && !username.strip.empty?
    keys << [:phone, phone.strip]            if phone && !phone.strip.empty?
    keys << [:sol,   sol.strip]              if sol && !sol.strip.empty?
    survivor = keys.filter_map { |k| seen[k] }.first
    if survivor
      m[id] = survivor                       # redirect duplicate -> survivor
      keys.each { |k| seen[k] ||= survivor } # fold this row's other keys in too
    else
      own = (key && !key.empty?) ? key : GEN.generate
      m[id] = own
      $user_keep << id
      keys.each { |k| seen[k] = own }
    end
  end
  puts "  map users: #{m.size} (keep #{$user_keep.size}, merged #{m.size - $user_keep.size})"
end

def mid(table, val)      # remap a single foreign id (nil-safe)
  return nil if val.nil?
  $map[table][val.is_a?(String) ? val : val.to_i]
end

def mids(table, vals)    # remap an array of foreign ids, dropping any that don't survive
  Array(vals).map { |v| mid(table, v) }.compact
end

def bn(v)                # blank -> nil (for unique text columns)
  v.nil? || (v.is_a?(String) && v.strip.empty?) ? nil : v
end

def poly(type, id, type_map)  # -> [soon_item_type, soon_item_id] or [nil,nil]
  tbl = type_map[type]
  return [nil, nil] unless tbl
  out_type = { "users" => "User", "groups" => "Group", "events" => "Event",
               "venues" => "Venue", "tickets" => "Ticket", "badges" => "Badge",
               "badge_classes" => "BadgeClass", "group_invites" => "GroupInvite",
               "vouchers" => "Voucher" }[tbl]
  [out_type, mid(tbl, id)]
end

# ---- value maps -------------------------------------------------------------
# IMPORTANT: the legacy DB has already been migrated to (mostly) soon's newer
# vocabularies, so these maps only translate the *stale* leftovers and otherwise
# pass a value through. Several target columns are enum-backed (Badge#status,
# BadgeClass#display, GroupInvite#status) or inclusion-validated
# (Participant#status, Event#status/visibility, ...); insert_all bypasses those
# checks, so an out-of-set value would sit in the DB and later crash a read
# (enum) or fail a save (inclusion). Every map below is closed over the observed
# source values and produces only allowed targets.

# Event#status ∈ draft|pending|published|archived|closed|cancelled
EVENT_STATUS = Hash.new { |_, v| v }.merge(  # default: pass through
  "open" => "published", "cancel" => "cancelled").freeze
# Event#visibility ∈ public|private — legacy `display` column now holds this.
EVENT_VIS    = Hash.new("public").merge(
  "private" => "private", "hidden" => "private").freeze
# BadgeClass#display / Badge#display enum ∈ normal|hidden|pinned
DISPLAY      = Hash.new("normal").merge("hide" => "hidden", "top" => "pinned").freeze
# Badge#status enum ∈ minted|burned|accepted
BADGE_STATUS = Hash.new("minted").merge(
  "accepted" => "accepted", "minted" => "minted", "burned" => "burned",
  "burnt" => "burned", "new" => "minted", "pending" => "minted",
  "rejected" => "burned", "revoked" => "burned", "active" => "minted").freeze
# Participant#status ∈ attending|declined|maybe|pending|cancelled
PART_STATUS  = Hash.new("attending").merge(
  "attending" => "attending", "checked" => "attending", "new" => "attending",
  "approved" => "attending", "applied" => "attending", "pending" => "pending",
  "cancelled" => "cancelled", "cancel" => "cancelled", "rejected" => "declined",
  "disapproved" => "declined", "declined" => "declined", "maybe" => "maybe").freeze
# Membership#role ∈ member|manager|owner (legacy elevated roles -> manager)
MEMBER_ROLE  = Hash.new("member").merge(
  "member" => "member", "owner" => "owner", "manager" => "manager",
  "issuer" => "manager", "event_manager" => "manager", "guardian" => "manager").freeze
# GroupInvite#role ∈ member|manager|owner (same vocabulary as Membership)
INVITE_ROLE  = Hash.new("member").merge(
  "member" => "member", "owner" => "owner", "manager" => "manager",
  "admin" => "manager", "issuer" => "manager").freeze
# GroupInvite#status enum ∈ sending|requesting|accepted|cancelled|revoked
INVITE_STATUS = Hash.new { |_, v| v || "sending" }.merge("cancel" => "cancelled").freeze
# Voucher#strategy ∈ code|account|address|email|event|remember
VOUCHER_STRATEGY = Hash.new("code").merge(
  %w[code account address email event remember].to_h { |s| [s, s] }.merge(
    "event_participant" => "event")).freeze

def ts(r, *keys) # first present timestamp, else NOW
  keys.each { |k| v = r[k]; return v if v }
  NOW
end

# ---- migration specs (order is cosmetic; FK triggers are off) ---------------
MIGRATIONS = [
  { target: "users", source: "profiles", id: :key, keep_if: ->(r) { $user_keep.include?(r["id"].to_i) }, transform: ->(r) {
      { ref_id: r["id"].to_s, active: r["status"] != "freezed", bio: r["about"], data: {},
        email: bn(r["email"]), eth: bn(r["address"]), image_url: r["image_url"],
        last_signin_at: r["last_signin_at"], name: bn(r["username"]), nickname: r["nickname"],
        permissions: r["permissions"] || [], phone: bn(r["phone"]),
        social_links: r["social_links"] || {}, sol: bn(r["sol_address"]),
        telegram_id: bn(r["telegram_id"]), created_at: ts(r, "created_at"),
        updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "groups", source: "groups", id: :key, transform: ->(r) {
      { ref_id: r["id"].to_s, active: r["status"] != "freezed", banner_image_url: r["banner_image_url"],
        banner_link_url: r["banner_link_url"], banner_text: r["banner_text"], bio: r["about"],
        can_join_event: r["can_join_event"], can_publish_event: r["can_publish_event"],
        can_view_event: r["can_view_event"], created_at: ts(r, "created_at"), data: {},
        end_date: r["end_date"], event_tag_list: r["event_tags"] || [], event_union: mids("groups", r["group_union"]),
        events_count: r["events_count"] || 0,
        # sails stores homepage-curation tags with a leading colon (:top,
        # :featured, :hidden, plus location codes like :cnx) -- soon's own
        # code (GroupsController::PRIVILEGED_TAGS, DiscoverController) always
        # compares colon-less strings, so strip it here rather than needing
        # every tag comparison to handle both forms.
        group_tags: (r["group_tags"] || []).map { |t| t.to_s.sub(/\A:/, "") },
        featured_image_url: r["featured_image_url"],
        group_ticket_event_id: mid("events", r["group_ticket_event_id"]),
        image_url: r["image_url"], location: r["location"], logo_url: r["logo_url"],
        memberships_count: r["memberships_count"] || 0, name: bn(r["username"] || r["handle"]),
        nickname: r["nickname"], op_label_list: r["op_label_list"] || [],
        parent_id: mid("groups", r["parent_id"]), permissions: r["permissions"] || [],
        requirement_tag_list: r["event_requirement_tags"] || [],
        social_links: r["social_links"] || {}, start_date: r["start_date"],
        timezone: r["timezone"], updated_at: ts(r, "updated_at", "created_at"),
        venue_tag_list: [], venue_union: mids("groups", r["venue_union"]) }
    } },

  { target: "events", source: "events", id: :key, req: %i[group_id owner_id], transform: ->(r) {
      { ref_id: r["id"].to_s, category: r["category"], content: r["content"], created_at: ts(r, "created_at"),
        end_time: r["end_time"], external_url: r["external_url"], form_id: bn(r["form_id"]),
        group_id: mid("groups", r["group_id"]), image_url: r["cover_url"], kind: r["kind"],
        max_participant: r["max_participant"], meeting_url: r["meeting_url"], notes: r["notes"],
        op_assigned_users: (r["assigned_operators"] || []).map { |i| mid("users", i) }.compact,
        op_labels: r["op_labels"] || [], op_priority: r["op_priority"], op_status: r["op_status"],
        owner_id: mid("users", r["owner_id"]), participant_count: r["participants_count"] || 0,
        pinned: r["pinned"] || false, place_id: mid("places", r["place_id"]),
        recurring_id: mid("recurrings", r["recurring_id"]),
        require_approval: r["require_approval"] || false,
        requirement_tags: r["requirement_tags"] || [], slug: nil, start_time: r["start_time"],
        status: EVENT_STATUS[r["status"]] || "draft", tags: r["tags"] || [],
        timezone: r["timezone"], title: r["title"], track_id: mid("tracks", r["track_id"]),
        updated_at: ts(r, "updated_at", "created_at"), venue_id: mid("venues", r["venue_id"]),
        visibility: EVENT_VIS[r["display"]] }
    } },

  { target: "venues", source: "venues", id: :key, req: %i[group_id owner_id name], suffix_dup: :name, transform: ->(r) {
      { about: r["about"], amenities: r["amenities"] || [], archived: r["removed"] || false,
        capacity: r["capacity"], created_at: ts(r, "created_at"),
        featured_image_url: r["featured_image_url"], group_id: mid("groups", r["group_id"]),
        image_urls: r["image_urls"] || [], name: bn(r["title"]), overrides: r["overrides"],
        owner_id: mid("users", r["owner_id"]), place_id: mid("places", r["place_id"]),
        require_approval: r["require_approval"] || false, tags: r["tags"] || [],
        timeslots: r["timeslots"],
        track_ids: (r["track_ids"] || []).map { |i| mid("tracks", i) }.compact,
        updated_at: ts(r, "updated_at", "created_at"), website: r["link"] }
    } },

  { target: "tracks", source: "tracks", id: :gen, req: %i[group_id], suffix_dup: :name, transform: ->(r) {
      # soon requires a unique, non-null name; legacy `tag` is often blank, so
      # fall back to a per-row deterministic value (collisions ON CONFLICT-skip).
      name = bn(r["tag"]) || bn(r["title"]) || "track_#{r['id']}"
      { created_at: ts(r, "created_at"), description: r["about"], end_date: r["end_date"],
        group_id: mid("groups", r["group_id"]), image_url: r["icon_url"],
        is_private: r["kind"] == "private", name: name, start_date: r["start_date"],
        title: (bn(r["title"]) || name), updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "track_roles", source: "track_roles", id: :gen, req: %i[track_id user_id], transform: ->(r) {
      { created_at: ts(r, "created_at"), role: r["role"] || "member",
        track_id: mid("tracks", r["track_id"]), updated_at: ts(r, "updated_at", "created_at"),
        user_id: mid("users", r["profile_id"]) }
    } },

  { target: "places", source: "places", id: :gen, req: %i[name], transform: ->(r) {
      { address: r["address"], created_at: ts(r, "created_at"),
        data: (r["data"] ? { "place_id" => r["data"] } : {}), description: nil,
        latitude: r["geo_lat"], longitude: r["geo_lng"], name: bn(r["name"]),
        updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "memberships", source: "memberships", id: :gen, req: %i[group_id user_id], transform: ->(r) {
      { active: r["status"] != "freezed", created_at: ts(r, "created_at"), data: r["data"] || {},
        group_id: mid("groups", r["target_id"]), role: (MEMBER_ROLE[r["role"]] || "admin"),
        updated_at: ts(r, "updated_at", "created_at"), user_id: mid("users", r["profile_id"]) }
    } },

  { target: "badge_classes", source: "badge_classes", id: :gen, req: %i[creator_id name title], transform: ->(r) {
      { ref_id: r["id"].to_s, badge_type: r["badge_type"] || "badge", can_send_badge: r["can_send_badge"] || "owner",
        content: r["content"], counter: r["counter"] || 1, created_at: ts(r, "created_at"),
        creator_id: mid("users", r["creator_id"]), display: (DISPLAY[r["display"]] || "normal"),
        encrypted: r["encrypted"] || false, group_id: mid("groups", r["group_id"]),
        image_url: r["image_url"], metadata: r["metadata"], name: r["name"],
        permissions: r["permissions"] || [], revocable: r["revocable"] || false,
        title: r["title"], transferable: r["transferable"] || false,
        updated_at: ts(r, "updated_at", "created_at"), weighted: r["weighted"] || false }
    } },

  { target: "badges", source: "badges", id: :gen, req: %i[badge_class_id creator_id owner_id], transform: ->(r) {
      { ref_id: r["id"].to_s, badge_class_id: mid("badge_classes", r["badge_class_id"]), content: r["content"],
        created_at: ts(r, "created_at"), creator_id: mid("users", r["creator_id"]),
        display: (DISPLAY[r["display"]] || "normal"), end_time: r["end_time"],
        image_url: r["image_url"], index: r["index"], owner_id: mid("users", r["owner_id"]),
        start_time: r["start_time"], status: (BADGE_STATUS[r["status"]] || "minted"),
        title: r["title"], updated_at: ts(r, "updated_at", "created_at"), value: r["value"] || 0,
        voucher_id: mid("vouchers", r["voucher_id"]) }
    } },

  { target: "vouchers", source: "vouchers", id: :gen, req: %i[badge_class_id sender_id], transform: ->(r) {
      { ref_id: r["id"].to_s, badge_class_id: mid("badge_classes", r["badge_class_id"]), badge_content: r["badge_content"],
        badge_image: r["badge_image"], badge_title: r["badge_title"], code: r["code"],
        counter: r["counter"] || 1, created_at: ts(r, "created_at"), data: r["data"],
        expires_at: r["expires_at"], message: r["message"], receiver_address: r["receiver_address"],
        receiver_id: mid("users", r["receiver_id"]), sender_id: mid("users", r["sender_id"]),
        strategy: VOUCHER_STRATEGY[r["strategy"]], updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "recurrings", source: "recurrings", id: :gen, req: %i[interval start_time], transform: ->(r) {
      { created_at: NOW, end_time: r["end_time"], event_count: r["event_count"] || 0,
        interval: r["interval"], start_time: r["start_time"], timezone: r["timezone"],
        updated_at: NOW }
    } },

  { target: "tickets", source: "tickets", id: :gen, req: %i[event_id], transform: ->(r) {
      q = r["quantity"]; q = nil if q && q < 0
      { check_badge_class_id: mid("badge_classes", r["check_badge_class_id"]), content: r["content"],
        created_at: ts(r, "created_at"), days_allowed: r["days_allowed"], end_date: r["end_date"],
        end_time: r["end_time"], event_id: mid("events", r["event_id"]),
        group_id: mid("groups", r["group_id"]), need_approval: r["need_approval"], quantity: q,
        start_date: r["start_date"], status: r["status"] || "normal",
        ticket_type: r["ticket_type"] || "event", title: r["title"],
        tracks_allowed: (r["tracks_allowed"] || []).map { |i| mid("tracks", i) }.compact,
        updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "payment_methods", source: "payment_methods", id: :gen, transform: ->(r) {
      it, iid = poly(r["item_type"], r["item_id"], { "Ticket" => "tickets" })
      { chain: r["chain"], chain_token_addresses: r["chain_token_addresses"] || {},
        chains: r["chains"] || [], created_at: ts(r, "created_at"), item_id: iid, item_type: it,
        kind: r["kind"], price: r["price"], protocol: r["protocol"],
        receiver_address: r["receiver_address"], token_address: r["token_address"],
        token_name: r["token_name"], updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "coupons", source: "coupons", id: :gen, req: %i[event_id], transform: ->(r) {
      { applicable_ticket_ids: (r["applicable_ticket_ids"] || []).map { |i| mid("tickets", i) }.compact,
        code: r["code"], created_at: ts(r, "created_at"), discount: r["discount"],
        discount_type: r["discount_type"], event_id: mid("events", r["event_id"]),
        expires_at: r["expires_at"], label: r["label"], max_allowed_usages: r["max_allowed_usages"],
        order_usage_count: r["order_usage_count"] || 0, receiver_address: r["receiver_address"],
        removed: r["removed"] || false, selector_type: r["selector_type"],
        ticket_item_ids: (r["ticket_item_ids"] || []).map { |i| mid("ticket_items", i) }.compact,
        updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "participants", source: "participants", id: :gen, req: %i[event_id user_id], transform: ->(r) {
      { badge_id: mid("badges", r["badge_id"]), created_at: ts(r, "created_at"),
        event_id: mid("events", r["event_id"]), message: r["message"],
        payment_status: r["payment_status"], register_time: r["register_time"],
        status: (PART_STATUS[r["status"]] || "attending"), ticket_id: mid("tickets", r["ticket_id"]),
        updated_at: ts(r, "updated_at", "created_at"), user_id: mid("users", r["profile_id"]),
        voucher_id: mid("vouchers", r["voucher_id"]) }
    } },

  { target: "ticket_items", source: "ticket_items", id: :gen, req: %i[ticket_id], null_dup: %i[txhash], transform: ->(r) {
      { amount: r["amount"], auth_type: r["auth_type"], chain: r["chain"],
        coupon_id: mid("coupons", r["coupon_id"]), created_at: ts(r, "created_at"),
        discount_data: r["discount_data"], discount_value: r["discount_value"].to_s[/\d+/]&.to_i,
        event_id: mid("events", r["event_id"]), group_id: mid("groups", r["group_id"]),
        original_price: r["original_price"], participant_id: mid("participants", r["participant_id"]),
        payment_method_id: mid("payment_methods", r["payment_method_id"]), protocol: r["protocol"],
        selector_address: r["selector_address"], selector_type: r["selector_type"],
        sender_address: r["sender_address"], status: r["status"],
        ticket_id: mid("tickets", r["ticket_id"]), ticket_type: r["ticket_type"] || "event",
        tracks_allowed: r["tracks_allowed"], txhash: bn(r["txhash"]),
        updated_at: ts(r, "updated_at", "created_at"), user_id: mid("users", r["profile_id"]) }
    } },

  { target: "event_roles", source: "event_roles", id: :gen, req: %i[event_id item_type], transform: ->(r) {
      it, iid = poly(r["item_type"], r["item_id"], { "Profile" => "users", "Group" => "groups" })
      { created_at: ts(r, "created_at"), display_name: r["nickname"], email: r["email"],
        event_id: mid("events", r["event_id"]), image_url: r["image_url"], item_id: iid,
        item_type: it, role: r["role"] || "speaker", updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "group_invites", source: "group_invites", id: :gen, req: %i[group_id], transform: ->(r) {
      { badge_class_id: mid("badge_classes", r["badge_class_id"]), badge_id: mid("badges", r["badge_id"]),
        created_at: ts(r, "created_at"), expires_at: r["expires_at"],
        group_id: mid("groups", r["group_id"]), message: r["message"],
        receiver_address: r["receiver_address"], receiver_address_type: r["receiver_address_type"] || "id",
        receiver_id: mid("users", r["receiver_id"]), role: INVITE_ROLE[r["role"]],
        sender_id: mid("users", r["sender_id"]),
        status: INVITE_STATUS[r["status"]],
        ticket_id: mid("tickets", r["ticket_id"]), updated_at: ts(r, "created_at") }
    } },

  { target: "comments", source: "comments", id: :gen, req: %i[user_id], transform: ->(r) {
      it, iid = poly(r["item_type"], r["item_id"], { "Event" => "events", "Group" => "groups" })
      { badge_id: mid("badges", r["badge_id"]), comment_type: r["comment_type"] || "comment",
        content: r["content"], content_type: r["content_type"] || "text",
        created_at: ts(r, "created_at"), edit_parent_id: mid("comments", r["edit_parent_id"]),
        icon_url: r["icon_url"], item_id: iid, item_type: it,
        removed: (r["removed"] || r["status"] == "removed" || false),
        reply_parent_id: mid("comments", r["reply_parent_id"]), title: nil,
        updated_at: ts(r, "updated_at", "created_at"), user_id: mid("users", r["profile_id"]) }
    } },

  { target: "activities", source: "activities", id: :gen, req: %i[initiator_id action], transform: ->(r) {
      it, iid = poly(r["item_type"], r["item_id"],
        { "BadgeClass" => "badge_classes", "Badge" => "badges",
          "GroupInvite" => "group_invites", "Voucher" => "vouchers" })
      { action: r["action"], created_at: ts(r, "created_at"), has_read: r["has_read"] || false,
        initiator_id: mid("users", r["initiator_id"]), item_id: iid, item_type: it, payload: {},
        receiver_address: r["receiver_address"], receiver_id: mid("users", r["receiver_id"]) }
    } },

  { target: "markers", source: "markers", id: :gen, req: %i[group_id owner_id place_id title], transform: ->(r) {
      { about: r["about"], category: r["category"], cover_image_url: r["cover_image_url"],
        created_at: ts(r, "created_at"), data: {}, group_id: mid("groups", r["group_id"]),
        link: r["link"], owner_id: mid("users", r["owner_id"]), pin_image_url: r["pin_image_url"],
        place_id: mid("places", r["place_id"]), status: r["status"], title: r["title"],
        updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "availabilities", source: "availabilities", id: :gen, req: %i[item_id item_type], transform: ->(r) {
      it, iid = poly(r["item_type"], r["item_id"], { "Venue" => "venues" })
      { created_at: ts(r, "created_at"), day: r["day"], day_of_week: r["day_of_week"],
        intervals: r["intervals"] || {}, item_id: iid, item_type: it, role_required: r["role"],
        updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "domains", source: "domains", id: :gen, req: %i[name], transform: ->(r) {
      it, iid = poly(r["item_type"], r["item_id"], { "Profile" => "users", "Group" => "groups" })
      { created_at: ts(r, "created_at"), fullname: r["fullname"], item_id: iid, item_type: it,
        name: bn(r["handle"]), updated_at: ts(r, "updated_at", "created_at") }
    } },

  # form_* tables already use TSID string ids (reused verbatim), and their intra-
  # form FKs (form_id, form_field_id, form_submission_id) are those same strings.
  # But their *user* references (user_id, created_by_id) store the legacy integer
  # profile id as a string ("33906"), so those remap through the users map.
  { target: "forms", source: "forms", id: :id, transform: ->(r) {
      { created_at: ts(r, "created_at"), created_by_id: mid("users", r["created_by_id"].to_i), description: r["description"],
        published: r["published"] || false, slug: r["slug"], submission_message: r["submission_message"],
        title: r["title"], updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "form_fields", source: "form_fields", id: :id, transform: ->(r) {
      { created_at: ts(r, "created_at"), field_type: r["field_type"], for_admin: r["for_admin"] || false,
        form_id: r["form_id"], label: r["label"], options: r["options"] || [],
        position: r["position"] || 0, required: r["required"] || false,
        updated_at: ts(r, "updated_at", "created_at") }
    } },

  { target: "form_submissions", source: "form_submissions", id: :id, req: %i[user_id], transform: ->(r) {
      { admin_note: r["admin_note"], created_at: ts(r, "created_at"), form_id: r["form_id"],
        starred: r["starred"] || false, status: r["status"] || "pending",
        submitted_at: ts(r, "submitted_at", "created_at"), updated_at: ts(r, "updated_at", "created_at"),
        user_id: mid("users", r["user_id"].to_i) }
    } },

  { target: "form_answers", source: "form_answers", id: :id, transform: ->(r) {
      { created_at: ts(r, "created_at"), form_field_id: r["form_field_id"],
        form_submission_id: r["form_submission_id"], updated_at: ts(r, "updated_at", "created_at"),
        value: r["value"] }
    } },
].freeze

# =============================================================================
puts "Source: #{SOURCE_DB}  ->  Target: #{ActiveRecord::Base.connection_db_config.database}"

# ---- pass 1: id maps --------------------------------------------------------
puts "\n[1/3] building id maps"
MIGRATIONS.each do |s|
  s[:target] == "users" ? build_user_map : build_map(s[:target], s[:source], s[:id])
end

# ---- pass 2: load -----------------------------------------------------------
conn = ActiveRecord::Base.connection
conn.execute("SET session_replication_role = replica") unless DRY_RUN  # disable FK triggers

if DRY_RUN
  puts "\n[2/3] DRY RUN — target tables left untouched"
else
  puts "\n[2/3] truncating target tables"
  targets = MIGRATIONS.map { |s| s[:target] }
  conn.execute("TRUNCATE #{targets.map { |t| conn.quote_table_name(t) }.join(', ')} RESTART IDENTITY")
end

puts "\n[3/3] #{DRY_RUN ? 'dry-run reading' : 'loading'}"
report = []
MIGRATIONS.each do |spec|
  target, source, req = spec[:target], spec[:source], spec[:req] || []
  null_dup, suffix_dup = spec[:null_dup] || [], spec[:suffix_dup]
  klass = target.classify.constantize
  seen  = Hash.new { |h, k| h[k] = Set.new }  # per-column seen values (null_dup)
  scnt  = Hash.new(0)                          # per-value collision count (suffix_dup)
  buf = []
  read = ins = skip = 0

  flush = lambda do
    next if buf.empty?
    ins += DRY_RUN ? buf.size : klass.insert_all(buf, record_timestamps: false).rows.size
    buf.clear
  end

  keep_if = spec[:keep_if]
  src(source).find_each(batch_size: 2000) do |r|
    read += 1
    # identity-merge: skip rows folded into a survivor (their id still redirects)
    if keep_if && !keep_if.call(r)
      skip += 1; next
    end
    row = spec[:transform].call(r)
    row[:id] = $map[target][r["id"].is_a?(String) ? r["id"] : r["id"].to_i]
    # drop rows missing a required (NOT NULL) foreign key / column
    if row[:id].nil? || req.any? { |k| row[k].nil? }
      skip += 1; next
    end
    # nullable unique cols: null out a repeat so the row still loads
    null_dup.each { |c| v = row[c]; row[c] = nil if v && !seen[c].add?(v) }
    # NOT NULL unique col: suffix repeats so every row keeps a distinct value
    if suffix_dup && (v = row[suffix_dup])
      n = (scnt[v] += 1)
      row[suffix_dup] = "#{v} (#{n})" if n > 1
    end
    buf << row
    flush.call if buf.size >= BATCH
  end
  flush.call

  line = format("  %-18s read %6d  inserted %6d  skipped %5d", target, read, ins, skip)
  puts line
  report << line
rescue => e
  puts "  #{target} ERROR: #{e.class}: #{e.message}"
  report << "  #{target} ERROR: #{e.message}"
end

# ---- cleanup: null residual dangling *nullable* FKs -------------------------
# A parent can still be absent if it failed its own req/NOT-NULL check; those
# few children keep a mapped id pointing nowhere. Null them so the DB is
# FK-clean once triggers come back on. (Required FKs can't be nulled — but their
# rows were already skipped when the parent didn't resolve.)
NULLABLE_FKS = [
  %w[events venue_id venues], %w[events place_id places], %w[events track_id tracks],
  %w[events recurring_id recurrings], %w[events form_id forms],
  %w[venues place_id places], %w[markers place_id places],
  %w[tickets group_id groups], %w[tickets check_badge_class_id badge_classes],
  %w[ticket_items event_id events], %w[ticket_items group_id groups],
  %w[ticket_items coupon_id coupons], %w[ticket_items participant_id participants],
  %w[ticket_items payment_method_id payment_methods], %w[ticket_items user_id users],
  %w[participants ticket_id tickets], %w[participants badge_id badges],
  %w[participants voucher_id vouchers], %w[badges voucher_id vouchers],
  %w[badge_classes group_id groups], %w[groups parent_id groups],
  %w[groups group_ticket_event_id events], %w[comments badge_id badges],
  %w[comments edit_parent_id comments], %w[comments reply_parent_id comments],
  %w[group_invites receiver_id users], %w[group_invites sender_id users],
  %w[group_invites badge_id badges], %w[group_invites badge_class_id badge_classes],
  %w[group_invites ticket_id tickets], %w[vouchers receiver_id users],
  %w[activities receiver_id users], %w[track_roles user_id users],
].freeze
if DRY_RUN
  puts "\n[cleanup] skipped (dry run)"
else
  puts "\n[cleanup] nulling dangling optional FKs"
  NULLABLE_FKS.each do |tbl, col, ref|
    n = conn.exec_update(
      "UPDATE #{conn.quote_table_name(tbl)} SET #{col}=NULL WHERE #{col} IS NOT NULL " \
      "AND NOT EXISTS (SELECT 1 FROM #{conn.quote_table_name(ref)} r WHERE r.id=#{tbl}.#{col})")
    puts "  #{tbl}.#{col}: nulled #{n}" if n > 0
  end
  conn.execute("SET session_replication_role = origin")   # re-enable FK triggers
end
puts "\nDone.#{DRY_RUN ? ' (dry run — nothing written)' : ''}\n" + report.join("\n")
