# soon/ vs sails/ — full comparison and migration plan

`soon/` is meant to fully replace `sails/` (the production Rails 7.2 API) as a leaner, cleaner
rewrite. This document is the working comparison: what's already ported, what still needs to
move over (and how it should change in the process), and what should simply be dropped.

Last updated: 2026-07-16.

**Status**: `GroupInvite`, `BadgeClass`/`Badge`, `Form`/`FormField`/`FormSubmission`/`FormAnswer`,
`Voucher`, `Ticket`/`TicketItem`/`Coupon`/`PaymentMethod`, `Activity` (redesigned), and `Comment`
have all been ported — see `CHANGELOG.md`'s 2026-07-16 entry for exactly what changed in the
process. The user also finalized scope for several items §2c/§2d had left open: `GoodJob`,
`Doorkeeper`, `Vote*`, and the Grape API layer are confirmed **out of scope entirely**; `events`'
`op_status`/`op_priority`/`op_labels[]`/`assigned_operators[]` are deferred (will become their own
table later); `GroupInvite`'s direct-add-for-known-users behavior was confirmed to already exist in
sails/ and was ported as-is; `Profile` was confirmed equivalent to `User` with social-provider
columns collapsing into the existing `social_links` jsonb. Sections below are left as originally
written for historical context on the reasoning — treat §2b/§2c items as done, not pending.

## 1. ID scheme

**sails/**: every table uses Rails' default `bigint` auto-increment PK — *except* the `forms`
cluster (`forms`, `form_fields`, `form_submissions`, `form_answers`), which already uses
`id: :string` + `Tsid::Generator` (the exact same TSID scheme `soon/` uses), and the 4
`good_job_*` infra tables, which use `id: :uuid`.

**soon/**: already standardized on `id: :string` TSID (13-char base32, time-sortable) for every
table, via `ApplicationRecord#set_tsid_primary_key` (`lib/tsid.rb`, ported from sonnet/).

**Conclusion**: no new decision needed — soon/'s existing TSID scheme is the target. Every
sails/ table ported into soon/ gets a `t.string` PK, matching what we already did for the first
17 tables. This also matches the direction sails/ itself was already heading (the forms
subsystem got there first).

## 2. Table inventory: sails/ (45 tables) vs soon/ (17 tables)

sails/ has 45 tables: 8 are infrastructure (5 GoodJob queue tables, 3 Doorkeeper OAuth tables),
37 are app-domain tables.

### 2a. Already ported to soon/ (enrich, don't re-port)

| sails/ table | soon/ table | Notes |
|---|---|---|
| `groups` | `groups` | soon/ already has the rich field set (handle, social_links, group_tags[], etc.) from the sonnet/ migration — closest of any table to 1:1 parity already |
| `events` | `events` | soon/ already has start/end_time, status, visibility, venue/track refs. sails/ adds `badge_class_id`, `form_id`, `key`, `theme`, `op_status/priority/labels[]`, `assigned_operators[]` — port these once Badge/Form land |
| `memberships` | `memberships` | sails/ names the group FK `target_id` (polymorphic-shaped) not `group_id`, and adds `cap`, `data` jsonb, `admin_notification` — soon/'s explicit `group_id` is cleaner, keep it; consider adding `cap`/`data` if group capacity limits are needed |
| `participants` | `participants` | sails/ is richer: `voucher_id`, `badge_id`, `ticket_id`, `payment_status/data/chain`, `check_time`, `register_time` — port only once Voucher/Badge/Ticket are in scope |
| `places` | `places` | sails/ uses `geo_lat`/`geo_lng` + `location_viewport` + google `data`; soon/ uses plain `latitude`/`longitude` — soon/'s is simpler and fine to keep |
| `venues` | `venues` | sails/ adds `visibility`, `removed` (soft-delete flag — avoid, prefer real deletes or a documented soft-delete convention if truly needed), `key`, `link`, `start_date`/`end_date` |
| `tracks` | `tracks` | sails/ adds `tag`, `kind`, `manager_ids[]` — port `manager_ids[]` as a real `track_roles`-based check instead (soon/ already has `TrackRole`, don't reintroduce a denormalized array) |
| `track_roles` | `track_roles` | sails/ adds `group_id` (denormalized from track) and `receiver_address` — skip both, derivable/unnecessary |
| `availabilities` | `availabilities` | 1:1 match already |
| `markers` | `markers` | sails/ adds `event_id`, `badge_class_id`, `voucher_id`, `highlight`, `message`, `map_checkins_count`, `marker_state` — port once Badge/Voucher/map_checkins are in scope |
| `event_roles` | `event_roles` | 1:1 match (sails/ calls the field `nickname`, soon/ calls it `display_name` — cosmetic) |
| `domains` | `domains` | 1:1 match |
| `recurrings` | `recurrings` | 1:1 match |
| `profile_tokens` / `mail_tokens` | `auth_codes` | soon/'s `AuthCode` (recipient/recipient_type/context/code/used_at) already **is** the clean merge of these two overlapping sails/ tables — nothing to port, this is already the improvement |
| `profiles` | `users` | see §3 — biggest open item, not a simple port |

### 2b. Not yet in soon/ — core, must migrate

| sails/ table(s) | Verdict | What changes on the way in |
|---|---|---|
| `group_invites` | **Core** | Fundamental group feature (already documented in the monorepo's top-level CLAUDE.md). sails/ couples invite-acceptance to badge/ticket grants directly in the model — decouple that; invite acceptance should just create a `Membership`, with badge/ticket grants (if any) as a separate side-effect hook once those subsystems exist |
| `badge_classes`, `badges` | **Core** (if badges stay in scope — confirm with user) | Documented core domain model. Port as-is structurally, but review the JWT-based swap-code minting flow for the same "single clean auth path" simplification applied to `AuthCode` |
| `forms`, `form_fields`, `form_submissions`, `form_answers` | **Core** — but **pick this system, not `custom_forms`** | Already TSID-keyed in sails/, actively used for event registration. This is the one to port |

### 2c. Not yet in soon/ — secondary (defer, self-contained subsystems)

| sails/ table(s) | Subsystem | Notes |
|---|---|---|
| `tickets`, `ticket_items`, `coupons`, `payment_methods` | Paid ticketing | Stripe + multi-chain crypto payment, complex state machines. Coupon's manual discount math is worth rewriting cleanly rather than porting. Only needed once soon/ supports paid events |
| `point_classes`, `point_balances`, `point_transfers` | Points/credits | Self-contained per-group currency system |
| `vouchers` | Redemption codes | Coupled to `badges` — bring in alongside Badge if/when badges ship |
| `comments` | Comments | sails/ overloads one polymorphic table for 5 unrelated purposes (checkin/chat/comment/star/feedback via a `comment_type` field) — **flatten this**, don't port the overload; likely wants to become 2-3 distinct concepts |
| `contacts`, `followings` | Social graph | Two separate, overlapping tables (contact = mutual/blocked relationship, following = one-way) with no dedicated routes beyond `profile_controller.rb` — low priority, and consider merging into one table with a `kind` column rather than two |
| `activities` | Activity/notification feed | Generic polymorphic catch-all (`data`/`memo` as untyped strings) — needs a real redesign (typed event payloads), not a straight port, if/when it's built |
| `signin_activities` | Login audit log | Low priority, nice-to-have |
| `vote_proposals`, `vote_options`, `vote_records` | Group governance voting | Self-contained, not blocking core |
| `configs` | Per-group/item config store | Only needed once Stripe/webhooks (which read from it) are ported |
| `group_passes`, `group_pass_types` | Zupass-based access passes | Niche auth-adjacent feature tied to one identity provider — low priority unless Zupass support is a stated goal |
| `estores`, `products`, `product_items`, `orders`, `order_items` | Storefront/e-commerce | Not referenced in the model/controller audit's core list — validate real usage before committing to porting; likely bundle with the ticketing subsystem if pursued at all |
| `operator_notes` | Internal staff notes on events | Only referenced by itself + a likely-dead `app/api/` stub (see §4) — low priority even if kept |

### 2d. Candidates to drop entirely

| sails/ table(s) | Why |
|---|---|
| `venue_overrides`, `venue_timeslots` | **Zero references anywhere outside their own model files.** Dead. soon/'s already-ported `Availability` (`day`/`day_of_week` + `intervals` jsonb) is the clean, already-adopted successor design — these were superseded and never cleaned up in sails/ |
| `custom_forms`, `submissions` | Duplicate/parallel form system alongside `forms`/`form_fields`/`form_submissions`/`form_answers`. Looks like an in-progress, never-finished migration between two form implementations inside sails/ itself. Keep the TSID-keyed `forms` cluster (§2b), drop this one |
| `oauth_access_grants`, `oauth_access_tokens`, `oauth_applications` (Doorkeeper) | soon/'s single clean `AuthCode` + bearer-JWT flow is already simpler than sails/'s **three parallel auth paths** (Doorkeeper OAuth + raw JWT + signed cookie sessions). Don't reintroduce OAuth client/token tables — if a specific integration needs OAuth later, add it deliberately, not as a carry-over |
| `good_job_batches`, `good_job_executions`, `good_job_processes`, `good_job_settings`, `good_jobs` | Queue-adapter infra, not domain data — sails' rows are **not** migrated. soon/ has since adopted GoodJob itself (see ARCHITECTURE §1.1) and creates these tables fresh via its own `CreateGoodJobs` migration; nothing carries over |

## 3. Auth: `Profile` → `User` (the biggest single reconciliation item)

sails/'s `Profile` is **not** a simple port target — it's a sprawling model with:
- Integer PK, `email`/`address` (wallet)/`handle`/`username`, ~10 social-provider handle fields
  (twitter/github/discord/telegram/ens/lens/nostr/farcaster), multiple wallet-address fields
  (`sol_address`, `mina_address`, `fuel_address`, `far_fid`), Zupass fields, Google Calendar OAuth
  fields, `chain_index`/`chain_space`, `address_type`, `status`, `location`
- Mailer-trigger methods baked directly into the model (design smell, don't carry over)
- **Three parallel auth paths**: Doorkeeper OAuth2 → raw JWT (`{id: profile.id}`, global
  `$hmac_secret`) → signed cookie session (`cookies.signed[:profile_id]`) — plus **10+ routed
  social sign-in methods** (Google, zkEmail, Solana, Farcaster, World ID, Mina, Fuel, Telegram,
  multi-Zupass); unclear how many are actually implemented vs. stubbed — needs verification
  before any of this is treated as "must migrate"

soon/'s `User` (already ported) has a real head start: `name`, `email`, `eth`, `phone`,
`nickname`, `image_url`, `bio`, `permissions[]`, `social_links` jsonb, `last_signin_at`,
`telegram_id`, `active`, `data` jsonb — already covering the common core of Profile's fields
through a single, clean JWT + `AuthCode` (email OTP) flow.

**Recommendation**: don't port `Profile` structurally. Instead:
1. Keep soon/'s single JWT + `AuthCode` auth path as the permanent design (already strictly
   better than sails/'s three-path system)
2. Add to `User` only the fields with real product need: `handle` (public slug/identifier),
   `status`, and — if multi-wallet login is actually required — additional address columns
   following the existing `eth` pattern, added one at a time as each chain is actually wired up,
   not all six speculatively
3. Explicitly decide, before building anything: which of the 10+ social sign-in methods are
   real product requirements vs. sails/-era experiments never fully wired up. Treat "port every
   auth provider" as a scope trap, not a default

## 4. The Grape API layer (`sails/app/api/core/api.rb`) — orphaned, do not port

sails/ runs **two parallel API implementations** mounted side by side in `routes.rb`:
`Core::Api` (Grape, mounted at `/api/*`) and the documented Rails-controller tree
(`Api::` namespace, mounted at root paths, `path: ""`). The Grape layer:
- Duplicates several endpoint names from the Rails controllers (`profile/me`, `event/get`,
  `event/list`, `event/discover`) with unclear precedence between the two
- Also defines endpoints that exist **only** in Grape and appear **nowhere** in `api.md`
  (`event/my_starred`, `social/attending_events`, `participant/csv`, `profile/organizers`, etc.)
- Is undocumented in `api.md`, which only covers the Rails-controller routes

This is a strong signal of an earlier API generation the sails/ team partially migrated off of
and never finished removing. **Recommendation: treat the whole Grape layer as dead, don't port
it.** soon/'s `Api::V1` controller structure (already established) is the one clean lineage to
continue — confirm with whoever owns sails/ before assuming any Grape-only endpoint is still
needed by a live client, but default to not carrying it forward.

## 5. Summary — suggested migration order

1. ~~Groups/Events/Venues/Tracks/Markers/Membership/Participant/Place/Availability/Domain/Recurring/EventRole/TrackRole~~ — **done** (sonnet/ → soon/ migration)
2. **Next**: `GroupInvite` (simplified), `BadgeClass`/`Badge` (if in scope), `Form`/`FormField`/`FormSubmission`/`FormAnswer` (the TSID-keyed system only — drop `CustomForm`/`Submission`)
3. **User enrichment**: add `handle`/`status` to `User`; explicitly scope which social auth providers are real requirements
4. **Defer**: Ticket/Coupon/PaymentMethod, Point*, Voucher, Comment (redesigned), Contact/Following (merged), Activity (redesigned), Vote*, Config, GroupPass*, Estore/Product/Order*
5. **Never port**: `venue_overrides`, `venue_timeslots`, `custom_forms`/`submissions`, Doorkeeper OAuth tables, GoodJob tables, the Grape API layer, `operator_notes` (pending confirmation)

This document should be kept in sync as items move from "not yet" to "done" — update it
alongside `CHANGELOG.md` entries when each subsystem lands.
