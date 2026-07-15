# Changelog

All notable changes to `soon/` are recorded here.

## 2026-07-16 (later) — constraints, application-logic gaps, and a full test suite

Closed the gaps `ARCHITECTURE.md` had flagged as design-vs-implementation mismatches, and built a
Minitest suite (Rails' built-in framework, matching sails/'s own testing approach — integration
tests hitting real routes, no fixtures since soon/'s TSID PKs are callback-generated and fixture
loading bypasses callbacks; `test/support/factory_helpers.rb` provides `create_user`/`create_group`/etc.
instead). **311 tests, 786 assertions, 0 failures**, stable across repeated runs.

**Constraints/application-logic added** (Part A):
- `Membership#role` now validates inclusion in `member|admin|owner` (was previously unchecked).
- `tracks.name` gained a DB-level unique index backing the existing model validation.
- `MembershipsController#create` is now **admin-only direct-add** (`user_id` param,
  `authorize @group, :manage?`) — closes a real self-join hole where any authenticated user could
  join any group directly, completely bypassing `GroupInvite`'s invite/request flow.
- Added `Api::V1::ParticipantsController#approve` (`POST .../participants/:id/approve`) — the
  event owner or a group admin/owner can move a `pending` (requires-approval) participant to
  `attending`. This was previously undocumented-missing: `require_approval`/`need_approval`
  expressed intent with no way to act on it.
- `Ticket#reserve!`/`#release!` — atomic (row-locked) quantity claim/refund, replacing a
  non-atomic `decrement!` that could oversell under concurrent RSVPs. `TicketItem#cancel`/`#timeout`
  now call `release!`. A DB `CHECK (quantity IS NULL OR quantity >= 0)` constraint backs it.
- `VouchersController#use` — the double-claim check, badge minting, and counter decrement are now
  wrapped in `voucher.with_lock`, with `invalid?`/double-claim re-checked *inside* the lock — closes
  a concurrent-over-redemption race on high-`counter` vouchers.

**Real bugs found and fixed while building test coverage** (not part of Part A's plan — surfaced
by actually exercising every flow):
- `MembershipsController#update`/`#destroy` and `EventRolesController#create`/`#update`/`#destroy`
  — inline `authorize_*!` helpers rendered a 403 but didn't halt execution, so the action continued
  and hit Rails' `DoubleRenderError`. Added `return if performed?` after each.
- `EventRole#item_type` inclusion validation checked lowercase `"user"|"group"`, but Rails'
  polymorphic `belongs_to` needs the real constant name (`User`/`Group`) to resolve — any code path
  touching `.item` risked a `NameError`. Fixed the validation list; added a `valid_item_type?` guard
  in the controller so bad input now gets a clean `422` instead of crashing.
- `BadgeClassesController#create` had an **authorization bypass**: it checked `params[:group_id]`
  (top-level) to decide whether to run the group-admin check, but `group_id` is only ever sent
  nested under `params[:badge_class][:group_id]` like every other controller — so a normally-shaped
  request skipped the `authorize` call entirely. Fixed to read from the permitted params.
- `BadgeClassesController#index`'s `group_handle` filter joined a nonexistent `groups.handle`
  column (should be `groups.nickname`, same mistake already made and fixed once this session in
  `TicketsController`).
- `Participant#status` inclusion validation was missing `"cancelled"` — `TicketItem#cancel`/`#timeout`
  call `participant.update(status: "cancelled", ...)` (non-bang), which was silently failing
  validation and no-opping, so a cancelled ticket purchase never actually marked its participant
  cancelled.

**Confirmed-as-designed, not changed** (flagged during test-writing, correctly left alone):
- `MarkersController` still has no `authorize` calls despite `MarkerPolicy` defining real rules —
  pre-existing gap from the original sonnet/ port, out of scope for this pass.
- `TicketPolicy`/`CouponPolicy` are currently dead code — `TicketsController` always authorizes via
  `EventPolicy` through the parent event, never instantiates these two classes.
- `Coupon#get_discounted_price`'s lenient silent-no-discount behavior (expired/exhausted → full
  price, no error) vs. `TicketsController#rsvp`'s stricter hard-rejection of expired/exhausted
  coupons before charging — a deliberate two-tier policy, not an inconsistency.

## 2026-07-16

Ported the next tier of sails/ functionality into soon/, per the scoping decisions in
`SAILS_COMPARISON.md` (GoodJob, Doorkeeper, Vote*, the Grape API layer, and several other
sails/ subsystems were explicitly excluded — see that doc for the full list). All phases below
were individually verified end-to-end via live HTTP round-trips, not just model-layer tests.

- **Cross-cutting**: added `users.handle` (unique) — needed by nearly every new controller's
  `find_by(handle:)` lookups. `sails/`'s `Profile` was not ported as a separate concept; `User`
  (with its existing `social_links` jsonb from the sonnet/ port) remains the single identity model.
- **GroupInvite**: ported with the already-existing sails/ behavior where known users are added to
  a group directly (`Group#add_member`, new helper) — no invite record — and `GroupInvite` is used
  only for inviting people without an account yet (email invites) or generating reusable join
  codes. Fixed a bug where sails/ passed a plain Hash to `Activity.create(item: ...)` instead of
  an AR record.
- **Badges** (`BadgeClass`, `Badge`): swap-code minting now uses soon/'s `JwtService` (30-day
  expiry, a deliberate tightening vs. sails/'s non-expiring codes). Fixed: `meta`'s
  `badge.badge.title` typo, `BadgeController#update`'s total lack of authorization, `transfer`'s
  `params[:target]`-vs-`params[:target_id]` mismatch, and `swap` logging the wrong Activity action
  string. Dropped the never-written on-chain columns (`chain_index`/`chain_space`/`chain_txhash`).
- **Forms** (`Form`/`FormField`/`FormSubmission`/`FormAnswer`, the TSID-keyed system — the legacy
  `custom_forms`/`submissions` duplicate was not ported): wired into
  `Api::V1::ParticipantsController#create` for required-field validation and answer upsert on
  event join. Fixed a boolean-casting bug (`nil` instead of `false` for unset `required`/`for_admin`)
  that silently broke the required-field query.
- **Voucher**: full multi-strategy redemption (`code`/`account`/`address`/`email`/`event`) ported
  faithfully, including the `group_member_pass` auto-membership side effect. Skipped sails/'s
  `JSON.parse(voucher.data)` call on the already-deserialized jsonb column (confirmed unnecessary),
  and fixed `send_badge_by_email`'s copy-pasted Activity action string/receiver type.
- **Ticket / TicketItem / Coupon / PaymentMethod**: ported faithfully per sails/'s actual
  implementation, including the coupon discount math exactly as-is (ratio is basis-points-of-10000,
  not 0–100 despite the schema comment; amount discounts scale ×10000 on non-Stripe chains) and the
  Stripe sub-$4 waiver. Redesigned `order_number` to just use the `TicketItem`'s own TSID `id`
  (sails/'s `id + 1_000_000` scheme was integer-PK-specific). Added `EvmPaymentVerifier`
  (`eth` gem) and Stripe (`stripe` gem) as new dependencies. Closed real authorization gaps sails/
  had: `list` (ticket purchase history, was fully public), `coupons`/`coupon`/`list_group_ticket_types`
  (were fully public). Dropped several dead/wrongly-typed columns (zupass fields, legacy
  single-chain payment columns superseded by `PaymentMethod`, `ticket_items.token_address`/
  `receiver_address` which were `integer` despite holding hex addresses). Enriched `Participant`
  with `payment_status`/`voucher_id`/`badge_id`/`ticket_id`/`register_time` to support the
  integration (this also fixed a latent crash in the Voucher `'event'`-strategy redemption path).
- **Activity**: redesigned from sails/'s untyped `data`/`memo` strings into a `payload` jsonb
  column, scoped to only the domains actually needed (`group_invite/*`, `badge/*`, `voucher/*` —
  `point/*` is out of scope since Point* wasn't ported). Every call site now passes a real AR
  record to `item:`.
- **Comment**: ported as a single flat model (not split into Comment+Reaction) covering all 5
  `comment_type` values. Fixed the `title` column's `integer` type (should be `string`) and added
  author-only authorization to `remove` (sails/ had none).

## 2026-07-15 (later)

- Audited `sonnet/` vs `soon/` for anything missed in the prior migration. Found `config/initializers/tsid.rb` was never ported (sets `g.orm :active_record, primary_key_type: :string` for `rails generate model` defaults) — added it. Everything else it configures (`require "tsid"`, `Tsid::Generator` availability) was already working via `config.autoload_lib`, so this was a dev-convenience gap only, not a functional one.
- Confirmed intentionally excluded: Kamal deploy config (`.kamal/`, `bin/kamal`, `config/deploy.yml` — soon deploys via Fly.io per the monorepo's own convention), `action_policy`/`turbo-rails` gems (superseded by `pundit`/Stimulus-only per earlier decisions), and sonnet's own `CLAUDE.md` (soon inherits the monorepo-level one).
- Diffed all remaining shared config/boilerplate files (`application.rb`, environments, `cable.yml`, `puma.rb`, `Dockerfile`, mailers/jobs/helpers, `package.json`, `Procfile.dev`, `seeds.rb`) — differences are only app-name/version cosmetics from the two apps' separate `rails new` scaffolds, nothing missing.

## 2026-07-15

- Migrated database schema, models, and API controller structure from `/Users/jiang/paris/sonnet`:
  - Ported 17 migrations (+ 1 new deferred-FK migration to fix a table-ordering bug: `events` referenced `places`/`tracks`/`venues` before those tables existed) and `lib/tsid.rb` (string TSID primary keys via `ApplicationRecord#set_tsid_primary_key`).
  - Fixed 7 columns that were integer-typed leftovers from an integer-PK schema but need to be string to match TSID PKs: `events.recurring_id`, `events.op_assigned_users`, `groups.parent_id`, `groups.group_ticket_event_id`, `groups.event_union`, `groups.venue_union`, `venues.track_ids`.
  - Ported and enriched 17 models to match the richer (migration-file) schema rather than sonnet's stale `db/schema.rb`: notably `Event#owner` (was `#user`), plus new `Event#venue`/`#track`, `Venue#group`/`#owner`/`#place`, `Group#parent`/`#children`/`#tracks`/`#venues`, `Track#group`. Rewrote `AuthCode` for its new `recipient`/`recipient_type`/`context` schema (no more `user_id`/`expires_at`; expiry is now a 15-minute `created_at` window).
  - Ported `JwtService`, 10 Blueprinter serializers, and all 11 `api/v1` controllers + `auth_controller`.
  - Rewrote authorization from `action_policy` to `pundit` (`ApplicationPolicy`/`EventPolicy`/`GroupPolicy`/`MarkerPolicy`, `Api::BaseController` uses `Pundit::Authorization`), matching the monorepo's `sails/` convention.
  - Fixed `VenueBlueprint` referencing a nonexistent `address` column, and rewrote `render_collection`'s pagination for the installed `pagy` 43.x, whose `Pagy::Backend`/`pagy(scope)` helper API was removed in favor of `Pagy::Offset.new(...).records(scope)` — sonnet's original code (same pagy version) would have hit this too.
  - Verified end-to-end: fresh `db:migrate`, model/policy smoke test, and a live server round-trip through `request_code` → `verify_code` → JWT-authenticated `GET /users/me` and `POST /groups` (Pundit-authorized, Pagy-paginated `GET /groups`).
- Configured CORS (`config/initializers/cors.rb`) to allow all origins (`*`) for all resources and methods.
- Removed `turbo-rails` gem and `@hotwired/turbo-rails` JS package (Stimulus is used standalone); dropped `data-turbo-track` attributes from the application layout.
- Removed `allow_browser versions: :modern` from `ApplicationController`.
- Renamed development/test databases to `sails_db_development` / `sails_db_test` in `config/database.yml`.
- Added core API gems: `blueprinter`, `pagy`, `jwt`, `pundit`, `rack-cors`, `oga`, `resend`, `icalendar`, `httpx`.
- Added `dotenv-rails` (development/test) for loading environment variables from `.env`.
- Initial commit: Rails 8.1 app scaffold.
