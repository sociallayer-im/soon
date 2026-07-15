# Changelog

All notable changes to `soon/` are recorded here.

## 2026-07-16 (latest) — fixes from a focused code review of the ticket/payment/coupon/badge flow

A second code review scoped to ticket creation, payment, group tickets, coupons, ticket-badge
gating, and payment methods surfaced 8 confirmed findings (payment-verification bypasses, coupon
accounting bugs, an unenforced gate). All fixed with regression tests; suite is green at 334 runs.

### Payment confirmation — verify against the rail, never trust the caller
- **`verify_payment` marked Stripe items paid with no verification.** The crypto-verify branch was
  guarded by `chain != "stripe"`, so a pending Stripe item skipped verification entirely and was
  marked succeeded — a free paid ticket. All three confirm paths (`verify_payment`,
  `set_payment_status`, `stripe_callback`) now funnel through a new `TicketItem#confirm_payment!`,
  and payment proof is checked per rail via `payment_proof_ok?` (Stripe → `Stripe::PaymentIntent`
  retrieve + status/amount check; crypto → `EvmPaymentVerifier` with a required txhash).
- **`set_payment_status` skipped verification when `txhash` was absent, and opened up entirely if
  `NEXT_TOKEN` was unset** (`secure_compare("", "")` is `true`). Now rejects a blank token outright
  and requires on-chain verification for crypto items with `amount > 0`.
- **`stripe_callback` was forgeable and diverged from every other path.** `stripe_event_verified?`
  now does a real `Stripe::Webhook.construct_event` signature check when `STRIPE_WEBHOOK_SECRET` is
  set and **fails closed in production** when it isn't. Success now goes through `confirm_payment!`
  (so group-ticket buyers are actually added to the group — previously skipped), only `pending`
  items transition (no resurrecting a cancelled item), and failure/expiry webhooks release the
  reserved quantity via `TicketItem#cancel`.
- **On-chain payment replay.** One transfer could redeem many tickets (TSID string PKs stringify to
  `0`, so the PayHub id-binding never matched and fell through to a generic Transfer match). Added
  an app-level "txhash already consumed by another succeeded item" check plus a partial unique index
  on `ticket_items.txhash`.

### Coupons
- **`nil max_allowed_usages` raised `NoMethodError` (500).** The column is nullable and the param is
  optional; `nil <= count` blew up on the unauthenticated `coupon_price` endpoint and mid-RSVP.
  Centralized redeemability into `Coupon#available?` (nil == unlimited), used by both the model and
  the controller.
- **Usage counter moved in the wrong direction on cancel/timeout.** `TicketItem#cancel`/`#timeout`
  *incremented* `order_usage_count` (burning a second usage on release); now they decrement to
  refund the usage consumed at RSVP. `cancel`/`timeout` are de-duplicated into a shared `close!`.
- **Usage was consumed before the item persisted and never rolled back.** The increment happened
  mid-`build_paid_ticket_item`, so a failed request (bad chain, validation error) permanently burned
  a usage. Now the coupon is consumed only after the item persists, inside the RSVP transaction and
  under a row lock (`consume_coupon!`), re-checking availability to prevent over-redemption.
- **Amount-discount chain scaling** keyed off `paymethod.chain` instead of the chain actually
  selected at checkout, so a Stripe leg of a multi-chain method got the ×10000 crypto scaling.
  `get_discounted_price` now takes the resolved `chain:`.

### Gates & integrity
- **`check_badge_class_id` (badge-gated tickets) was enforced nowhere** — any user could claim a
  members-only ticket. `rsvp` now requires the user to hold a non-burned badge of that class, and
  also honors ticket `status` (`nosale`/`inactive`/`hidden`) and `end_time` sale cutoff.
- **`participant_count` leaked upward.** It was incremented on every RSVP but never decremented on
  cancel/timeout, so capacity-limited events drifted toward "full" on abandoned checkouts. `close!`
  now decrements it. The RSVP mutation is wrapped in one transaction so a mid-flight failure rolls
  back the participant, count bump, coupon usage, and ticket_item atomically (only the separately
  committed reservation is handed back).
- **Error-shape consistency.** `build_paid_ticket_item` rendered `{result:"error"}` at HTTP 200;
  it now uses `render_error` (4xx `{error:...}`) like the rest of the API.

Added a Stripe initializer (`config/initializers/stripe.rb`) and migration
`20260316000002` (unique `txhash` index + `coupons.code` index).

## 2026-07-16 — fixes from an /code-review pass on the constraints/test-suite commit

A multi-angle code review of the previous entry's commit surfaced 5 confirmed bugs (4 correctness,
1 efficiency), all fixed with regression tests added:

- **`Group#add_member` silently swallowed validation failures.** It used non-bang `create`/`update`
  and always returned the membership object regardless of success, so three different bugs fell
  out of this one root cause:
  - `MembershipsController#create` checked `membership.persisted?` (true for any already-existing
    row, regardless of whether *this* update succeeded) instead of the actual write outcome —
    updating an existing member to an invalid role rendered a misleading `201 Created` with a role
    that was never saved.
  - The create-branch's `increment!(:memberships_count)` ran unconditionally after
    `memberships.create`, permanently corrupting the counter whenever the create failed validation.
  - `GroupInvitesController`'s `accept`/`accept_request`/`accept_with_code` (and `send_invite_to`'s
    role-update branch) all called `add_member` and rendered success without checking the result —
    accepting an invite with an invalid role silently failed to grant membership while still
    returning 200.
  
  Fixed by making `add_member` raise `ActiveRecord::RecordInvalid` on failure (bang semantics), and
  adding proper rescues at every call site (a controller-level `rescue_from` in
  `GroupInvitesController`, an inline rescue in `MembershipsController#create`, and a local rescue
  in `send_invite_to` since it needs per-address error reporting rather than aborting the whole
  batch).
- **`GroupInvite#role` allowed `"manager"`, a value `Membership#role` doesn't accept.** Since an
  invite's role is passed straight through to `add_member` on acceptance, this mismatch was exactly
  the trigger for the bug above — reconciled `GroupInvite#role`'s validation to match `Membership`'s
  vocabulary (`member|admin|owner`) exactly, so a bad role is now rejected at invite-creation time
  with immediate feedback instead of failing silently later at accept time.
- **`TicketsController#rsvp`'s failure-cleanup released ticket inventory even when the reservation
  had already been genuinely consumed.** The trailing `rescue ActiveRecord::RecordInvalid` called
  `@ticket.release!` unconditionally, but if the failure happened *after* `ticket_item.save!` had
  already committed (e.g. a bad form answer, or the group auto-join failing later in the method —
  neither of which is wrapped in a shared transaction with the reservation), the already-persisted
  `TicketItem` still legitimately held that unit of inventory while `quantity` got incremented back
  anyway — permanently overcounting available tickets. Fixed by only releasing when
  `ticket_item&.persisted?` is false, i.e. when nothing was actually saved.
- **`VouchersController#use`'s `@voucher.reload` inside `with_lock` was a redundant query** —
  `with_lock` already reloads the record under lock (via `lock!`) before yielding to the block, so
  the explicit reload just repeated the same read on a concurrency-sensitive redemption path.
  Removed.

10 new regression tests added (`test/models/group_test.rb`, `test/models/group_invite_test.rb`,
`test/controllers/api/v1/memberships_controller_test.rb`,
`test/controllers/api/v1/group_invites_controller_test.rb`,
`test/controllers/api/v1/tickets_controller_test.rb`) — 321 tests, 811 assertions, 0 failures.

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
