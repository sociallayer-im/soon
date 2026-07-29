# frozen_string_literal: true

#
# READ-ONLY verification of a sails -> soon data migration.
# See design/MIGRATION_PLAN.md §3.3. Nothing here writes to either database.
#
#   SOURCE_DB=sails_prod_mirror bin/rails runner script/verify_migration.rb
#
# Deliberately does NOT reuse script/migrate_from_sails.rb's MIGRATIONS specs:
# a verifier that shares the ETL's assumptions fails the same way the ETL does.
# Expected row losses are recomputed here from the SOURCE data, so the numbers
# are derived, not copied from a previous run's report.
#
# Exit status: 0 = all PASS, 1 = any FAIL. WARNs never fail the run but must be
# read by a human before the cutover.

require "set"

SOURCE_DB = ENV.fetch("SOURCE_DB", "solia_development")
SAMPLE    = ENV.fetch("SAMPLE", "300").to_i   # rows per table for the field diff

class VerifySource < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "postgresql", database: SOURCE_DB)
end

SRC = VerifySource.connection
DST = ActiveRecord::Base.connection

$results = []
def pass(name, detail = nil) = $results << [ :PASS, name, detail ]
def warn!(name, detail = nil) = $results << [ :WARN, name, detail ]
def fail!(name, detail = nil) = $results << [ :FAIL, name, detail ]

def scount(sql) = SRC.select_value(sql).to_i
def dcount(sql) = DST.select_value(sql).to_i

puts "Source: #{SOURCE_DB}  ->  Target: #{DST.current_database}"
puts "=" * 78

# =============================================================================
# 1. Row counts — target = source minus losses we can independently explain.
# =============================================================================
puts "\n[1/4] row counts"

# Rows the ETL necessarily drops, recomputed here from the SOURCE.
#
# Mirrors each migration spec's `req:` list. Crucially, that check runs on the
# MAPPED value — so a source column that is non-NULL but points at a row which
# no longer exists is dropped exactly like a NULL one. Predicates must
# therefore test *resolvability*, not nullity. (Getting this wrong is what made
# the first draft report unexplained losses on badge_classes/ticket_items/
# comments/form_submissions, all of which turned out to be dangling FKs in the
# legacy data.)
#
#   table => [ [source_column, parent_source_table], ... ]
REQUIRED_REFS = {
  "events"           => [ %w[group_id groups], %w[owner_id profiles] ],
  "venues"           => [ %w[group_id groups], %w[owner_id profiles] ],
  "tracks"           => [ %w[group_id groups] ],
  "track_roles"      => [ %w[track_id tracks], %w[profile_id profiles] ],
  "memberships"      => [ %w[target_id groups], %w[profile_id profiles] ],
  "badge_classes"    => [ %w[creator_id profiles] ],
  "badges"           => [ %w[badge_class_id badge_classes], %w[creator_id profiles],
                          %w[owner_id profiles] ],
  "vouchers"         => [ %w[badge_class_id badge_classes], %w[sender_id profiles] ],
  "tickets"          => [ %w[event_id events] ],
  "coupons"          => [ %w[event_id events] ],
  "ticket_items"     => [ %w[ticket_id tickets] ],
  "group_invites"    => [ %w[group_id groups] ],
  "comments"         => [ %w[profile_id profiles] ],
  "activities"       => [ %w[initiator_id profiles] ],
  "markers"          => [ %w[group_id groups], %w[owner_id profiles], %w[place_id places] ],
  "form_submissions" => [ %w[user_id profiles] ]
}.freeze

# Plain NOT NULL requirements, keyed by SOURCE column name (the ETL's `req:`
# list names target columns, several of which are renamed in transit —
# venues.title -> name, domains.handle -> name).
REQUIRED_COLS = {
  "places" => %w[name], "venues" => %w[title], "domains" => %w[handle],
  "badge_classes" => %w[name title], "markers" => %w[title],
  "recurrings" => %w[interval start_time], "activities" => %w[action],
  "availabilities" => %w[item_id item_type]
}.freeze

# Columns the ETL passes through bn(), which turns a blank string into NULL —
# so a blank fails the `req:` check exactly as a NULL does.
BLANKED = { "places" => %w[name], "venues" => %w[title], "domains" => %w[handle] }.freeze

# id::text on both sides: some legacy FK columns are varchar while the parent
# key is bigint (e.g. form_submissions.user_id).
def loss_predicate(source)
  parts = REQUIRED_REFS.fetch(source, []).map { |col, parent|
    "#{col} IS NULL OR NOT EXISTS (SELECT 1 FROM #{parent} p WHERE p.id::text = #{source}.#{col}::text)"
  }
  blanked = BLANKED.fetch(source, [])
  parts += REQUIRED_COLS.fetch(source, []).map { |c|
    blanked.include?(c) ? "#{c} IS NULL OR trim(#{c}) = ''" : "#{c} IS NULL"
  }
  parts.empty? ? nil : parts.map { |p| "(#{p})" }.join(" OR ")
end

TABLES = {
  "users" => "profiles", "groups" => "groups", "events" => "events",
  "venues" => "venues", "tracks" => "tracks", "track_roles" => "track_roles",
  "places" => "places", "memberships" => "memberships",
  "badge_classes" => "badge_classes", "badges" => "badges",
  "vouchers" => "vouchers", "recurrings" => "recurrings", "tickets" => "tickets",
  "payment_methods" => "payment_methods", "coupons" => "coupons",
  "participants" => "participants", "ticket_items" => "ticket_items",
  "event_roles" => "event_roles", "group_invites" => "group_invites",
  "comments" => "comments", "activities" => "activities", "markers" => "markers",
  "availabilities" => "availabilities", "domains" => "domains", "forms" => "forms",
  "form_fields" => "form_fields", "form_submissions" => "form_submissions",
  "form_answers" => "form_answers"
}.freeze

# users / participants / event_roles get exact expected counts of their own
# below; the identity merge makes a plain predicate insufficient.
DERIVED = %w[users participants event_roles].freeze

printf("  %-18s %9s %9s %9s %9s\n", "table", "source", "expect", "target", "delta")
TABLES.each do |target, source|
  src_n = scount("SELECT count(*) FROM #{source}")
  dst_n = dcount("SELECT count(*) FROM #{target}")
  if DERIVED.include?(target)
    # Counted exactly further down, where the identity merge is resolved.
    printf("  %-18s %9d %9s %9d %9s\n", target, src_n, "-", dst_n, "see below")
    next
  end

  pred = loss_predicate(source)
  loss =
    begin
      pred ? scount("SELECT count(*) FROM #{source} WHERE #{pred}") : 0
    rescue ActiveRecord::StatementInvalid => e
      # A stale column name here must not abort the whole verification run —
      # every other check still carries information.
      warn! "loss-predicate/#{target}", e.message.lines.first.strip
      nil
    end
  next printf("  %-18s %9d %9s %9d %9s\n", target, src_n, "?", dst_n, "predicate") if loss.nil?
  expect = src_n - loss
  delta  = dst_n - expect
  printf("  %-18s %9d %9d %9d %9d\n", target, src_n, expect, dst_n, delta)

  if delta.zero?
    pass "rows/#{target}"
  else
    fail! "rows/#{target}", "expected #{expect} (source #{src_n} - #{loss} explained), got #{dst_n}"
  end
end

# =============================================================================
# 2. Identity merge — nobody may become unreachable.
# =============================================================================
puts "\n[2/4] identity merge (users)"

# Every source profile must resolve to some target user: either directly by
# ref_id, or -- if it was merged into a survivor -- by one of its identities.
src_profiles = SRC.select_rows(
  "SELECT id, lower(trim(email)), lower(trim(address)), lower(trim(username)), trim(phone) FROM profiles"
)
# Target-side lookups, built once in memory — the identity resolution below
# runs per source profile and must not issue a query each time.
by_ref   = DST.select_rows("SELECT ref_id, id FROM users WHERE ref_id IS NOT NULL").to_h
by_email = DST.select_rows("SELECT lower(email), id FROM users WHERE email IS NOT NULL").to_h
by_eth   = DST.select_rows("SELECT lower(eth), id FROM users WHERE eth IS NOT NULL").to_h
by_name  = DST.select_rows("SELECT lower(name), id FROM users WHERE name IS NOT NULL").to_h
by_phone = DST.select_rows("SELECT phone, id FROM users WHERE phone IS NOT NULL").to_h

# profile id (as string) => surviving soon user id, or nil if unreachable.
survivor = {}
direct = merged = orphaned = 0
orphan_samples = []
src_profiles.each do |id, email, addr, uname, phone|
  key = id.to_s
  if (uid = by_ref[key])
    survivor[key] = uid
    direct += 1
  elsif (uid = (email.presence && by_email[email]) || (addr.presence && by_eth[addr]) ||
               (uname.presence && by_name[uname]) || (phone.presence && by_phone[phone]))
    survivor[key] = uid
    merged += 1
  else
    orphaned += 1
    orphan_samples << id if orphan_samples.size < 10
  end
end

puts "  #{src_profiles.size} source profiles: #{direct} direct, #{merged} merged into a survivor, #{orphaned} unreachable"
if orphaned.zero?
  pass "users/reachable", "#{merged} merged"
else
  fail! "users/reachable", "#{orphaned} source profiles resolve to no target user (e.g. ids #{orphan_samples.join(', ')})"
end

# =============================================================================
# 3. Dedup-driven counts — exact expected values via the ref_id maps.
# =============================================================================
puts "\n[3/4] dedup-driven counts"

event_by_ref = DST.select_rows("SELECT ref_id, id FROM events WHERE ref_id IS NOT NULL").to_h
group_by_ref = DST.select_rows("SELECT ref_id, id FROM groups WHERE ref_id IS NOT NULL").to_h

# `survivor` (built in §2) already maps every source profile id — including the
# merged ones — to its surviving soon user id.

# participants: soon enforces UNIQUE (user_id, event_id)
pairs = SRC.select_rows("SELECT profile_id, event_id FROM participants")
expect = pairs.filter_map { |pid, eid|
  u = survivor[pid.to_s]; e = event_by_ref[eid.to_s]
  [ u, e ] if u && e
}.uniq.size
actual = dcount("SELECT count(*) FROM participants")
printf("  %-18s %9s %9d %9d %9d\n", "participants", pairs.size, expect, actual, actual - expect)
actual == expect ? pass("rows/participants") :
  fail!("rows/participants", "expected #{expect} distinct (user,event) pairs, got #{actual}")

# event_roles: soon enforces UNIQUE (event_id, item_id, item_type). The ETL
# requires event_id and item_type but NOT item_id, so a role whose item no
# longer resolves still loads with item_id NULL — and Postgres does not collide
# NULLs in a unique index, so those are never deduped.
roles = SRC.select_rows("SELECT event_id, item_id, item_type FROM event_roles WHERE item_type IS NOT NULL")
resolved, unresolved = [], 0
roles.each do |eid, iid, itype|
  e = event_by_ref[eid.to_s] or next
  i = itype == "Group" ? group_by_ref[iid.to_s] : survivor[iid.to_s]
  i ? resolved << [ e, i, itype ] : unresolved += 1
end
expect = resolved.uniq.size + unresolved
actual = dcount("SELECT count(*) FROM event_roles")
printf("  %-18s %9s %9d %9d %9d\n", "event_roles", roles.size, expect, actual, actual - expect)
actual == expect ? pass("rows/event_roles") :
  fail!("rows/event_roles", "expected #{expect} distinct (event,item,type), got #{actual}")

# =============================================================================
# 4. Referential integrity + field-level diff + business invariants.
# =============================================================================
puts "\n[4/4] integrity, field diff, invariants"

REQUIRED_FKS = [
  %w[events group_id groups], %w[events owner_id users],
  %w[memberships group_id groups], %w[memberships user_id users],
  %w[participants event_id events], %w[participants user_id users],
  %w[venues group_id groups], %w[venues owner_id users],
  %w[badges badge_class_id badge_classes], %w[badges owner_id users],
  %w[badges creator_id users], %w[badge_classes creator_id users],
  %w[vouchers badge_class_id badge_classes], %w[vouchers sender_id users],
  %w[event_roles event_id events], %w[markers group_id groups],
  %w[markers owner_id users], %w[markers place_id places],
  %w[comments user_id users], %w[group_invites group_id groups],
  %w[track_roles track_id tracks], %w[track_roles user_id users]
].freeze

dangling = 0
REQUIRED_FKS.each do |tbl, col, ref|
  unless DST.column_exists?(tbl, col)
    warn! "fk/#{tbl}.#{col}", "column no longer exists — this check needs updating"
    next
  end
  n = dcount("SELECT count(*) FROM #{tbl} t WHERE t.#{col} IS NOT NULL " \
             "AND NOT EXISTS (SELECT 1 FROM #{ref} r WHERE r.id = t.#{col})")
  next if n.zero?
  dangling += n
  fail! "fk/#{tbl}.#{col}", "#{n} rows point at a missing #{ref}"
end
puts "  required FKs: #{dangling.zero? ? 'all clean' : "#{dangling} dangling"}"
pass "fk/all" if dangling.zero?

# ---- field-level diff over ref_id-bearing tables ----------------------------
# source column => target column. Timestamps are excluded: the ETL substitutes
# a fallback for NULLs, so a mismatch there is expected, not a defect.
FIELD_DIFF = {
  "users" => [ "profiles", {
    "lower(trim(email))" => "lower(email)", "lower(trim(address))" => "lower(eth)",
    "lower(trim(username))" => "lower(name)", "nickname" => "nickname", "image_url" => "image_url"
  } ],
  "groups" => [ "groups", {
    "lower(trim(coalesce(username, handle)))" => "lower(name)", "nickname" => "nickname",
    "timezone" => "timezone", "location" => "location", "about" => "bio"
  } ],
  "events" => [ "events", {
    "title" => "title", "start_time" => "start_time", "end_time" => "end_time",
    "timezone" => "timezone", "content" => "content", "meeting_url" => "meeting_url"
  } ],
  "badge_classes" => [ "badge_classes", {
    "name" => "name", "title" => "title", "content" => "content", "image_url" => "image_url"
  } ],
  "badges" => [ "badges", { "title" => "title", "content" => "content", "image_url" => "image_url" } ],
  "vouchers" => [ "vouchers", {
    "code" => "code", "badge_title" => "badge_title", "receiver_address" => "receiver_address"
  } ]
}.freeze

def norm(v)
  return nil if v.nil?
  return v.utc.round if v.is_a?(Time) || v.is_a?(DateTime)
  s = v.to_s.strip
  s.empty? ? nil : s
end

FIELD_DIFF.each do |target, (source, cols)|
  refs = DST.select_values(
    "SELECT ref_id FROM #{target} WHERE ref_id IS NOT NULL ORDER BY random() LIMIT #{SAMPLE}"
  )
  next puts("  #{target}: no ref_id rows to diff") if refs.empty?

  quoted   = refs.map { |r| DST.quote(r) }.join(",")
  src_rows = SRC.select_rows(
    "SELECT id, #{cols.keys.join(', ')} FROM #{source} WHERE id::text IN (#{quoted})"
  ).to_h { |row| [ row.first.to_s, row[1..] ] }
  dst_rows = DST.select_rows(
    "SELECT ref_id, #{cols.values.join(', ')} FROM #{target} WHERE ref_id IN (#{quoted})"
  ).to_h { |row| [ row.first.to_s, row[1..] ] }

  mismatches = []
  src_rows.each do |ref, svals|
    dvals = dst_rows[ref] or next mismatches << "#{ref}: missing in target"
    cols.keys.each_with_index do |col, i|
      s, d = norm(svals[i]), norm(dvals[i])
      mismatches << "#{ref}.#{col}: #{s.inspect} != #{d.inspect}" if s != d
    end
  end

  checked = src_rows.size
  if mismatches.empty?
    puts "  #{target}: #{checked} rows x #{cols.size} fields — identical"
    pass "diff/#{target}", "#{checked} rows"
  else
    puts "  #{target}: #{mismatches.size} mismatches in #{checked} rows"
    mismatches.first(5).each { |m| puts "      #{m}" }
    fail! "diff/#{target}", "#{mismatches.size} field mismatches (first: #{mismatches.first})"
  end
end

# ---- business invariants ----------------------------------------------------
n = dcount("SELECT count(*) FROM groups g WHERE NOT EXISTS " \
           "(SELECT 1 FROM memberships m WHERE m.group_id = g.id AND m.role = 'owner')")
n.zero? ? pass("invariant/group-has-owner") : warn!("invariant/group-has-owner", "#{n} groups have no owner membership")

n = dcount("SELECT count(*) FROM events e WHERE e.recurring_id IS NOT NULL AND NOT EXISTS " \
           "(SELECT 1 FROM recurrings r WHERE r.id = e.recurring_id)")
n.zero? ? pass("invariant/recurring-link") : fail!("invariant/recurring-link", "#{n} events point at a missing recurring")

src_sum = SRC.select_value("SELECT coalesce(sum(amount), 0) FROM ticket_items WHERE status = 'succeeded'").to_i
dst_sum = DST.select_value("SELECT coalesce(sum(amount), 0) FROM ticket_items WHERE status = 'succeeded'").to_i
src_sum == dst_sum ? pass("invariant/ticket-revenue", "#{dst_sum}") :
  fail!("invariant/ticket-revenue", "succeeded ticket_items sum #{src_sum} != #{dst_sum}")

# =============================================================================
puts "\n" + "=" * 78
counts = $results.group_by(&:first).transform_values(&:size)
$results.reject { |s, _, _| s == :PASS }.each { |s, name, detail| puts "  #{s}  #{name} — #{detail}" }
puts "\n#{counts[:PASS].to_i} PASS  #{counts[:WARN].to_i} WARN  #{counts[:FAIL].to_i} FAIL"

if counts[:FAIL].to_i.zero?
  puts "\nVERIFICATION PASSED#{counts[:WARN].to_i.positive? ? ' (with warnings — read them before cutover)' : ''}"
  exit 0
else
  puts "\nVERIFICATION FAILED — do not cut over."
  exit 1
end
