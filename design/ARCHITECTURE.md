# soon/ — Architecture, Data Model, and Application Logic

This document describes `soon/` as it stands today: a Rails 8.1 JSON API, TSID-keyed throughout,
being built as a leaner replacement for `sails/`. See `SAILS_COMPARISON.md` for what was ported
from where and why, and `CHANGELOG.md` for a chronological log of changes. This document is the
synchronic view — how the system is actually built, independent of its migration history.

Last updated: 2026-07-16.

## 1. Architecture overview

**Stack**: Rails 8.1 (API-only, `ActionController::API`), PostgreSQL, Puma. JSON serialization via
`blueprinter`. Authorization via `pundit`. Pagination via `pagy` (v9+ `Pagy::Offset` API — no
`Pagy::Backend` mixin). Auth is stateless bearer-JWT (`jwt` gem) with email one-time-codes, no
sessions, no cookies, no OAuth. Background/async work is not yet wired up (see §9).

**Layering** (top to bottom, request path):

```
config/routes.rb
  → app/controllers/api/v1/*_controller.rb   (thin — params, auth, orchestration)
      → app/policies/*_policy.rb              (Pundit — authorization only)
      → app/models/*.rb                       (ActiveRecord — validations, associations,
                                                 business logic, callbacks)
      → app/blueprints/*_blueprint.rb          (Blueprinter — response shaping)
```

All controllers inherit from `Api::BaseController < ActionController::API`
(`app/controllers/api/base_controller.rb`), which is the single place that defines:
- JWT authentication (`authenticate!` before_action → sets `@current_user`)
- Pundit wiring (`include Pundit::Authorization`, `rescue_from Pundit::NotAuthorizedError`)
- Pagination (`render_collection`, wrapping `Pagy::Offset`)
- The two generic error renderers (`render_error`, `render_not_found`)

The one exception is `Api::V1::AuthController`, which inherits directly from
`ActionController::API` (not `Api::BaseController`) since its two actions
(`request_code`/`verify_code`) run *before* a JWT exists.

**Primary keys**: every table uses a `string` primary key — a 13-character, time-sortable,
base32-encoded TSID (`lib/tsid.rb`, `Tsid::Generator`). This is applied uniformly by
`ApplicationRecord#set_tsid_primary_key` (a `before_create` callback), so individual models never
need to think about ID generation. All foreign keys are `string` columns referencing these TSIDs,
with real Postgres `add_foreign_key` constraints (`db/schema.rb`'s `add_foreign_key` block — every
FK relationship in the schema is DB-enforced, not just app-level).

**Authorization pattern**: two tiers coexist by design, matching what was actually needed per
resource — not an inconsistency to "fix":
1. **Pundit policies** (`app/policies/`) for role/ownership checks that map cleanly to a single
   record (`GroupPolicy#update?`, `BadgePolicy#own?`, etc.) — invoked via `authorize` in
   controllers.
2. **Inline strategy checks** for actions where "authorization" *is* the business logic, not a
   separate role check — e.g. `VouchersController#use` (the redemption strategy match — code,
   account, address, email — **is** the authorization), `TicketsController#set_payment_status`
   (shared-secret `NEXT_TOKEN` webhook auth, not a user at all).

## 2. Request lifecycle

1. **Auth** (`Api::BaseController#authenticate!`): reads `Authorization: Bearer <token>`, decodes
   via `JwtService.decode` (HS256, `Rails.application.secret_key_base` or `ENV["JWT_SECRET"]`,
   30-day default expiry), loads `User.find(payload["user_id"])` into `current_user`. Any decode
   failure or missing user → `401 { error: "Unauthorized" }`.
2. **Authorization**: either `authorize record` (Pundit, raises `Pundit::NotAuthorizedError` →
   `403 { error: "Forbidden" }` globally) or an inline `render_error(..., status: :forbidden)`
   check inside the action.
3. **Params → model**: controllers use Rails strong parameters (`params.require(...).permit(...)`)
   before mass-assignment; no unfiltered `params` ever reach `Model.new`/`.update`.
4. **Model validation**: ActiveRecord validations run on `save`/`save!`/`update`/`update!`.
   Controllers either check `.save` and render `render_error(record.errors.full_messages.join(", "))`
   on failure, or use `save!`/`update!` inside a `rescue ActiveRecord::RecordInvalid => e` block
   that renders the same way — both end in the same `422 { error: "<message list>" }` shape.
5. **Response**: success responses render a Blueprinter-serialized JSON body (see §7); list
   endpoints go through `render_collection`, which wraps `Pagy::Offset` and returns
   `{ data: [...], meta: { page, limit, total, total_pages, next_page, prev_page } }`.

## 3. Data model

### 3.1 Identity & auth

| Model | Key columns | Notes |
|---|---|---|
| `User` | `email` (unique), `handle` (unique), `eth` (unique), `phone` (unique), `name` (unique), `nickname`, `image_url`, `bio`, `permissions[]`, `social_links` jsonb, `telegram_id`, `active`, `last_signin_at`, `data` jsonb | The single identity model — `sails/`'s `Profile` was **not** ported as a separate concept; social-provider handles (twitter/github/etc.) live in `social_links` jsonb rather than dedicated columns |
| `AuthCode` | `recipient`, `recipient_type` (email\|phone), `context`, `code`, `used_at` | One-time code, 15-minute expiry computed from `created_at` (no stored `expires_at` — see `AuthCode::EXPIRY`) |

### 3.2 Groups, events, and the social graph

| Model | Key columns | Notes |
|---|---|---|
| `Group` | `name`, `nickname`, `parent_id` (self-referential), `handle`-equivalent is `nickname`, `group_tags[]`, `social_links` jsonb, `memberships_count`/`events_count` (denormalized counters), `start_date`/`end_date`/`location` (popup-city mode), `can_publish_event`/`can_join_event`/`can_view_event`, `group_ticket_event_id` | `parent_id` self-reference has no default scope for cascading permissions beyond what controllers implement (see `GroupPolicy`) |
| `Membership` | `user_id`, `group_id`, `role` (member\|admin\|owner), `active`, `data` jsonb | Unique on `(user_id, group_id)` |
| `GroupInvite` | `sender_id`/`receiver_id` (optional — `receiver_id` only set once resolved), `group_id`, `role`, `status` enum, `receiver_address_type` (id\|email\|code), `receiver_address`, `expires_at`, `badge_class_id`/`badge_id`/`ticket_id` (optional grant-on-accept refs) | See §4.2 for the branching logic — **not every invite flow creates a `GroupInvite` row** |
| `Event` | `title`, `content`, `start_time`/`end_time`, `status`, `visibility`, `group_id`, `owner_id`, `place_id`/`track_id`/`venue_id`/`recurring_id`/`form_id` (all optional), `require_approval`, `participant_count`, `tags[]`, `kind` (also doubles as the `"group_ticket"` marker — see §4.5) | `op_status`/`op_priority`/`op_labels[]`/`assigned_operators[]` exist on the table but are **deliberately unused** for now (deferred to a future dedicated table) |
| `EventRole` | `event_id`, `item_id`/`item_type` (polymorphic: user\|group), `role` (member\|manager), `email`/`display_name`/`image_url` (for not-yet-registered co-hosts) | Unique on `(event_id, item_id, item_type)` |
| `Participant` | `event_id`, `user_id`, `status` (attending\|declined\|maybe\|pending), `payment_status`, `message`, `register_time`, `voucher_id`/`badge_id`/`ticket_id` (all optional — ticket/voucher integration) | Unique on `(user_id, event_id)` — one participant record per user per event, mutated in place across RSVP/cancel/re-RSVP rather than recreated |
| `Recurring` | `start_time`, `end_time`, `interval`, `event_count`, `timezone` | Groups a series of `Event`s via `events.recurring_id`; no back-reference `has_many :events` cascade rule beyond `dependent: :destroy` |
| `Place` | `name` (unique), `address`, `latitude`/`longitude`, `description` | |
| `Venue` | `name` (unique), `group_id`, `owner_id`, `place_id` (optional), `capacity`, `amenities[]`/`tags[]`, `timeslots`/`overrides` jsonb, `track_ids[]`, `require_approval` | |
| `Availability` | `item_id`/`item_type` (polymorphic), `day`/`day_of_week`, `intervals` jsonb, `role_required` | Generic weekly/date-override availability, used for venues (see top-level `CLAUDE.md`'s "Venue Availability" section — `Venue#check_availability` is not yet ported into `soon/`, only the data shape is) |
| `Track` | `group_id`, `name` (unique), `title`, `description`, `is_private`, `start_date`/`end_date` | |
| `TrackRole` | `track_id`, `user_id`, `role` (member\|organizer\|admin) | Unique on `(track_id, user_id)` |
| `Marker` | `group_id`, `place_id`, `owner_id`, `category`, `title`, `about`, `link`, `status`, `data` jsonb | |
| `Domain` | `name` (unique), `item_id`/`item_type` (polymorphic) | Generic handle/slug registry, attachable to any model via `as: :item` |

### 3.3 Badges & vouchers

| Model | Key columns | Notes |
|---|---|---|
| `BadgeClass` | `name`, `title`, `creator_id`, `group_id` (optional), `counter` (running mint index), `transferable`/`revocable`/`weighted`/`encrypted` booleans, `badge_type` (badge\|nft\|nftpass\|private), `permissions[]` (e.g. `"group_member_pass"` — see §4.4), `status` enum (active\|freezed), `display` enum (normal\|hidden\|pinned), `can_send_badge` (owner\|group_member_send) | Template for issued `Badge`s |
| `Badge` | `badge_class_id`, `creator_id`, `owner_id`, `index`, `status` enum (minted\|burned\|accepted), `display` enum, `value` (only meaningful if `badge_class.weighted`), `start_time`/`end_time` (`end_time > start_time` validated), `voucher_id` (optional — which voucher minted it) | `gen_swap_code`/`self.decode_swap_code` use `JwtService` (30-day expiry — a deliberate tightening vs. the source system's non-expiring codes) |
| `Voucher` | `sender_id`, `badge_class_id`, `badge_title`/`badge_content`/`badge_image` (per-voucher overrides), `code`, `message`, `expires_at`, `counter` (remaining redemptions), `receiver_id`/`receiver_address`/`receiver_address_type` (id\|email\|address), `strategy` (code\|account\|address\|email\|event\|remember), `data` jsonb (`value`/`start_time`/`end_time` for the minted badge) | `invalid?` checks `counter == 0 || expired` |

### 3.4 Forms

| Model | Key columns | Notes |
|---|---|---|
| `Form` | `title`, `description`, `slug` (unique, auto-defaults to `id`), `published`, `submission_message`, `created_by_id` | Attached to an `Event` via `events.form_id` (one form per event) |
| `FormField` | `form_id`, `label`, `field_type` (text\|select), `required`, `for_admin` (excluded from the required-field gate), `position`, `options` jsonb | Ordered by `position` |
| `FormSubmission` | `form_id`, `user_id`, `status` (pending, no other value currently written), `starred`, `admin_note`, `submitted_at` | Unique on `(form_id, user_id)` — one submission per user per form, upserted on resubmit |
| `FormAnswer` | `form_submission_id`, `form_field_id`, `value` | Wholesale-replaced on every resubmit (delete-then-recreate, not diffed) |

### 3.5 Tickets & payments

| Model | Key columns | Notes |
|---|---|---|
| `Ticket` | `event_id`, `group_id` (optional, auto-set — see §4.5), `title`, `content`, `check_badge_class_id` (optional gate), `quantity` (nullable = unlimited), `end_time`, `need_approval`, `status` (normal\|nosale\|hidden\|inactive), `ticket_type` (event\|group), `start_date`/`end_date`/`days_allowed[]`/`tracks_allowed[]` (group-ticket date/track gating) | |
| `PaymentMethod` | `item_id`/`item_type` (polymorphic: Ticket\|User), `chain` (legacy single-chain), `kind` enum (crypto\|fiat\|credit), `token_name`/`token_address` (legacy), `receiver_address`, `price` (smallest unit, pre-discount), `protocol`, `chains[]`/`chain_token_addresses` jsonb (multi-chain mode) | `SUPPORTED_CHAINS = %w[ethereum optimism arbitrum polygon base stripe]`; both legacy single-chain and modern multi-chain configuration coexist, with `token_address_for_chain`/`effective_chains` falling back between them |
| `Coupon` | `event_id`, `selector_type` (code\|email\|badge), `code` (auto-generated), `discount_type` (ratio\|amount), `discount`, `expires_at` (auto-defaults +30d), `max_allowed_usages`, `order_usage_count`, `applicable_ticket_ids[]`/`ticket_item_ids[]`, `removed` | `get_discounted_price` — see §4.6 for the exact math, which has real non-obvious scaling rules |
| `TicketItem` | `ticket_id`, `event_id`, `user_id`, `participant_id`, `payment_method_id`, `coupon_id`, `group_id`, `status` (pending\|unbounded\|succeeded\|cancelled\|timeout), `ticket_type` (event\|group), `auth_type` enum (free\|payment\|badge\|invite), `chain`, `txhash` (dual-purpose: on-chain tx hash **or** Stripe PaymentIntent id), `amount`, `original_price`, `discount_value`/`discount_data`, `sender_address`, `selector_type`/`selector_address` (group-ticket-invite tracking), `protocol` | The purchase/reservation record — one per RSVP attempt. Its own `id` (TSID) doubles as the external order number (no separate `order_number` column) |

## 4. Application logic by domain

### 4.1 Auth (`AuthController`)

Email one-time-code flow only — no OAuth, no wallet-signature login, no session cookies.
`request_code` creates an `AuthCode` (`recipient: user.email, recipient_type: "email",
context: "login"`) with a random 6-character code; `verify_code` looks it up via
`AuthCode.active.for_recipient(email).find_by(code:)` (active = unused and within the 15-minute
window), marks it used, and returns a `JwtService`-signed bearer token (`{"user_id" => user.id}`,
30-day expiry).

### 4.2 GroupInvite — direct-add vs. real invite

`GroupInvitesController#create` (`send_invite_to` private method) is the core branch point:
1. Resolve the receiver by `handle`, `email`, or `eth` against `User`.
2. **If a matching user exists**: call `Group#add_member` directly — **no `GroupInvite` row is
   created**. If they're already a member with a lower role, the role is upgraded in place
   (`Activity` action `group_invite/update_role`); if not yet a member, they're added
   (`group_invite/send`).
3. **If no match and the address looks like an email**: create a real `GroupInvite`
   (`status: "sending"`, `receiver_address_type: "email"`, 30-day `expires_at`). The invitee
   later hits `POST .../group_invites/:id/accept`, which validates `receiver_address ==
   current_user.email` and flips `status: "accepted"`.
4. **Reusable codes** (`send_with_code`/`accept_with_code`) are a separate flow: `status` stays
   `"sending"` forever (never flips to `"accepted"` — it's reusable by design), and anyone
   presenting the matching code via `accept_with_code` joins.
5. `Group#add_member(user_id, role)` (`app/models/group.rb`) is the single low-level primitive
   behind every path above: upsert a `Membership` (update role if it exists, else create +
   increment `groups.memberships_count`).

### 4.3 Badges — minting, transfer, and swap

Badges are minted either directly (`Badge.create!`, e.g. by controller code elsewhere) or via
`Voucher#use` (§4.4). Once minted (`status: "minted"`):
- `transfer` — owner-only (`BadgePolicy#own?`), requires `badge_class.transferable` and status
  in `minted`/`accepted`, moves `owner_id` to a `handle`-resolved target.
- `burn` — owner-only, requires `status == "minted"`, sets `status: "burned"` (terminal).
- `swap_code` / `swap` — a two-party trade: the initiating owner generates a JWT swap token
  (`Badge#gen_swap_code`) out-of-band, the counterparty calls `swap` with their own badge id +
  that token; both badges' `owner_id`s are exchanged atomically. Both badges must be
  transferable and in `minted`/`accepted` status.

### 4.4 Vouchers — multi-strategy redemption

`VouchersController#use` is the single redemption entrypoint for all 5 active strategies (`code`,
`account`, `address`, `email`, `event` — `remember` is a valid enum value with no controller logic
exercising it):

1. Reject if `voucher.invalid?` (counter exhausted or expired).
2. Strategy-specific match: `code` compares `params[:code]`; `account`/`event` compare
   `voucher.receiver_id == current_user.id`; `address` compares `voucher.receiver_address ==
   current_user.eth`; `email` compares against `current_user.email`.
3. Anti-double-claim: block if a `Badge` already exists with this `voucher_id` AND
   `owner_id == current_user.id` (a `counter > 1` code voucher **can** still be claimed by
   *different* users multiple times — the guard is per-claimant, not global).
4. Mint a `Badge`, cascading title/content/image from voucher-level overrides down to the
   `badge_class` defaults, and copying `value`/`start_time`/`end_time` out of `voucher.data` jsonb
   if present.
5. `badge_class.increment!(:counter)`, `voucher.decrement!(:counter)`.
6. If `strategy == "event"`: link the freshly minted badge back onto the `Participant` row that
   carries this `voucher_id` (ties an event-attendance badge to the RSVP).
7. If `badge_class.permissions.include?("group_member_pass")`: auto-join the redeemer to
   `badge_class.group` as a `member` (badge-as-membership-pass mechanism) — idempotent
   (`find_or_create_by`).

`create`/`send_badge`/`send_badge_by_address`/`send_badge_by_email` are the minting side: `create`
makes one multi-use `code`-strategy voucher; the three `send_badge*` variants each mint one
single-use (`counter: 1`) voucher per resolved receiver, differing only in `strategy` and how the
receiver is resolved/validated (handle-or-eth-or-email, a raw `0x...` address regex, or an
address-or-email regex, respectively).

### 4.5 Group tickets — the `kind == "group_ticket"` marker

A group can have a special "ticket-tier" `Event` designated via `groups.group_ticket_event_id`.
Any `Ticket` attached to that event with `event.kind == "group_ticket"` is automatically tagged
`ticket_type: "group"` and inherits `group_id` from the event (`Ticket#inherit_group_ticket_type`,
a `before_save` callback). `TicketsController#add_group_ticket_item` is the manager-facing action
that grants a group-ticket tier to someone by email: if they already have an account, the
`TicketItem` is immediately marked `succeeded` and `Group#add_member` runs; if not, an
`status: "unbounded"` placeholder `TicketItem` is created (`selector_type: "email"`,
`selector_address: email`), awaiting a future claim flow keyed off that email once they sign up
(this claim-on-signup wiring is not yet implemented — see §9).

### 4.6 Ticket purchase (`rsvp`) and coupon math

`TicketsController#rsvp` is the central purchase/reservation flow:
1. Guard on event closed/ended and venue capacity.
2. Decrement `ticket.quantity` if it's set (no row-level locking — see §9 for the known
   overselling race).
3. Find-or-create-or-revive the caller's `Participant` for this event (one row per user per
   event; a cancelled participant re-RSVPing gets its fields reset rather than a new row).
4. **If the ticket has `payment_methods`**: resolve the requested `PaymentMethod`, apply a coupon
   if `params[:coupon]` is present (see below), resolve which `chain` to charge on (validated
   against `payment_method.chains` for multi-chain methods), and — for `chain == "stripe"` —
   waive the entire amount to `0` if it's under `TicketsController::STRIPE_MIN_CENTS` (400 cents /
   $4, below Stripe's practical minimum charge). Status is `"succeeded"` immediately if the final
   amount is `0`, else `"pending"` awaiting `verify_payment`/webhook confirmation.
5. **Else** (no payment methods — free ticket): `TicketItem` is created `status: "succeeded"`,
   `amount: 0` immediately.
6. If the event has a `form_id` and `params[:answers]` were supplied, upserts a `FormSubmission`
   and replaces its `FormAnswer`s (same logic as the standalone `Forms` join-time flow).
7. On `succeeded`, auto-joins the group (for `ticket_type == "group"`) and calls
   `TicketItem#notify_group_owner` (currently a no-op stub pending a mailer — see §9).

**Coupon discount math** (`Coupon#get_discounted_price(amount, paymethod)`) — these are exact,
non-obvious business rules, not simplifications:
- `discount_type == "ratio"`: `discount` is in **basis points of 10,000**, not a 0–100 percentage
  (`discount: 500` = 5% off; the schema comment mentions 0–100 but the code does not use that
  scale — the code is authoritative). Final amount = `amount * discount / 10_000`. Invalid ratios
  (`< 0` or `> 10_000`) silently apply no discount.
- `discount_type == "amount"`: the stored `discount` is used **as-is** for `chain == "stripe"`,
  but **scaled ×10,000** for every other (crypto) chain — a deliberate unit-conversion baked into
  the math, not a bug. The resulting discount is clamped to never exceed the item's price (floors
  at zero, never negative).
- Expired or usage-exhausted coupons return `[amount, nil, nil]` (no discount, no error) — callers
  must check the returned `discount_value` for truthiness before treating a coupon as "applied."

### 4.7 Payment confirmation paths

Three ways a `pending` `TicketItem` becomes `succeeded`, all converging on the private
`mark_ticket_item_paid!` helper (sets `status: succeeded`, `txhash`, `sender_address`, auto-joins
group-ticket groups, syncs `participant.payment_status`, calls `notify_group_owner`):
1. **`verify_payment`** — user-initiated, self-only (`ticket_item.user_id == current_user.id`).
   For non-Stripe chains, calls `EvmPaymentVerifier.verify` (`lib/evm_payment_verifier.rb`, `eth`
   gem) against the transaction receipt logs before marking paid.
2. **`set_payment_status`** — server-to-server webhook-style endpoint, authenticated by a shared
   secret (`ActiveSupport::SecurityUtils.secure_compare` against `ENV["NEXT_TOKEN"]`), not a user
   token at all. Same `EvmPaymentVerifier` check when a `txhash` is supplied.
3. **`stripe_callback`** — Stripe webhook receiver for `charge.succeeded` events, matches the
   `TicketItem` by `txhash == payment_intent_id`.

### 4.8 Activity — typed notification/audit log

Unlike the models above, `Activity` was **redesigned**, not ported verbatim: a single `payload`
jsonb column replaces untyped `data`/`memo` strings, and every emission site passes a real
ActiveRecord object to `item:` (no polymorphic-association-holding-a-Hash bugs). Emission is
scoped to exactly the actions actually wired up: `group_invite/{send,add_member,update_role}`
(§4.2), `badge/{transfer,burn,swap}` (§4.3), `voucher/{create,use,send_badge,
send_badge_by_address,send_badge_by_email}` (§4.4). `ActivitiesController#index` is a
receiver-scoped, paginated inbox (`Activity.for_receiver(current_user)`); `mark_read` is a
bulk-update, ownership-checked against every id in the request.

### 4.9 Comments

A single flat polymorphic model covering all 5 `comment_type` values from the source design
(`checkin`, `chat`, `comment`, `star`, `feedback`) — deliberately **not** split into separate
concepts, per an explicit scoping decision. `star`/`unstar` are idempotent
create/destroy of `comment_type: "star"` rows with no `content` (this is how Event/Group
favoriting works — a lightweight join-table substitute). `remove` is a soft-delete
(`removed: true`, not a real `DELETE`); `Comment.visible` (`removed: [nil, false]`) is the scope
every list query should use. Author-only authorization on `remove` was added (the source design
had none).

## 5. Associations, constraints, and validations — cross-cutting rules

**Polymorphic associations** appear in 6 places, all following the same `item_type`/`item_id`
(string) shape: `Availability#item`, `Domain#item`, `EventRole#item`, `PaymentMethod#item`,
`Activity#item`, `Comment#item`. None of these have a DB-level polymorphic-type CHECK constraint
— validity of `item_type` is enforced at the application layer only (or, for `PaymentMethod`, via
an explicit `validates :item_type, inclusion:`).

**Uniqueness constraints**, mostly DB-backed via unique indexes (not just `validates
uniqueness:`): `users.email/handle/eth/phone/name`, `places.name`, `venues.name`, `domains.name`,
`forms.slug`, `memberships(user_id, group_id)`, `participants(user_id, event_id)`,
`event_roles(event_id, item_id, item_type)`, `track_roles(track_id, user_id)`,
`form_submissions(form_id, user_id)`. One exception: `Track#name` has `validates uniqueness:` at
the model level but **no** matching unique index in the `tracks` table — a race condition (two
concurrent creates with the same name) could still produce duplicates. Worth adding the index if
this is ever a real risk.

**`dependent:` cascade rules** are chosen per-association based on whether the child record has
meaning without its parent: `:destroy` for owned/dependent records that cascade further
(`Group#memberships` is actually `:delete_all` — no callbacks needed since memberships have no
children of their own; `Event#participants` is `:destroy` since participants have `ticket_item`
references worth cleaning up via callbacks); `:nullify` where the child is meaningful
independently (`Place#events`, `Track#events`, `Venue#events`, `Group#tickets`).

**Numeric/comparison validations**: `Place#latitude/longitude` (-90..90), `Venue#capacity`
(positive integer), `Recurring#event_count` (non-negative integer), `Event#end_time`/
`Recurring#end_time`/`Badge#end_time` (must be after the corresponding start time, via a custom
validation method for `Event`/`Recurring` and `comparison:` for `Badge`), `Voucher#counter`
(non-negative), `PaymentMethod#chains` (custom validator — every entry must be in
`SUPPORTED_CHAINS`).

**Enums** (Rails `enum`, backed by plain string columns, not Postgres native enum types — chosen
for schema flexibility): `BadgeClass#status/display`, `Badge#status/display`,
`GroupInvite#status`, `PaymentMethod#kind`, `TicketItem#auth_type`.

## 6. Error handling

Every error response is JSON, one of three shapes:

| Situation | Status | Body | Producer |
|---|---|---|---|
| No/invalid/expired JWT | `401` | `{ "error": "Unauthorized" }` | `Api::BaseController#authenticate!` |
| Pundit policy returns false | `403` | `{ "error": "Forbidden" }` | global `rescue_from Pundit::NotAuthorizedError` |
| Inline authorization failure (non-Pundit) | `403` | `{ "error": "<message>" }` | `render_error(msg, status: :forbidden)` calls scattered in controllers (e.g. cross-user ticket history, coupon listing, comment removal) |
| Record not found | `404` | `{ "error": "Not found" }` | `render_not_found`, called from `rescue ActiveRecord::RecordNotFound` blocks |
| Validation/business-rule failure | `422` | `{ "error": "<message(s)>" }` | `render_error(record.errors.full_messages.join(", "))` on failed `.save`, or a hand-written message for a business-rule check (`"event closed"`, `"voucher code is empty or incorrect"`, etc.) |

There is **no** generic top-level `rescue_from StandardError` — an unhandled exception in any
controller still produces Rails' default 500 response (a debug page in development, a blank 500 in
production). This is intentional: every error path a controller action can *actually* reach is
enumerated above, and letting truly unexpected exceptions surface as 500s (rather than being
silently coerced into a misleading 4xx) makes them visible in logs/monitoring rather than hidden.

Controllers that wrap multi-step writes in a transaction (`ParticipantsController#create`'s form
answer upsert, `TicketsController#rsvp`, `FormsController#save_event_form`) use `save!`/`create!`
inside `ActiveRecord::Base.transaction do ... end` and catch `ActiveRecord::RecordInvalid` at the
action level — this guarantees partial writes never persist (e.g. a `Participant` is never saved
without its corresponding `TicketItem`, or vice versa).

## 7. Serialization (Blueprinter)

Every model with an API-facing representation has a `*Blueprint` in `app/blueprints/`. Patterns
worth knowing:
- `identifier :id` + `fields :...` is the norm; associations are nested via `association :x,
  blueprint: XBlueprint`.
- **Named views** (`view :extended do ... end`) add fields/associations only when explicitly
  requested (`Blueprint.render(record, view: :extended)`) — used for expensive-to-load nested data
  that most callers don't need (e.g. `EventBlueprint`'s `event_roles`/`participants`,
  `FormBlueprint`'s `fields`, `VoucherBlueprint`'s `code`/`badges`).
- Some blueprints deliberately **omit** fields present on the model for security reasons —
  e.g. `CouponBlueprint`'s base view excludes `code` (only the `:with_code` view, used right after
  creation, exposes it) so that bulk-listing an event's coupons never leaks redemption codes.
- List endpoints go through `Api::BaseController#render_collection`, which always wraps the
  blueprint output in `{ data: [...], meta: {...} }` — single-record endpoints render the
  blueprint's JSON directly with no wrapper.

## 8. State machines & workflows

This section makes the state transitions implied by §4 explicit — every status/enum field that
has more than one legal value, what triggers each transition, and who's allowed to trigger it.
**⚠️ marks a transition or gap that's a real risk** (missing authorization, missing state
transition, race condition) — not a hypothetical, something that could bite a caller today.

### 8.1 Event registration (`Participant#status`) and approval

```
                    POST /events/:id/participants
                              │
              ┌───────────────┴───────────────┐
              │ event.require_approval OR      │ neither condition
              │ event.form_id present,         │
              │ AND caller is not a group      │
              │ admin/owner                    │
              ▼                                 ▼
          [pending]                       [attending]
              │
              │  ⚠️ no manager-side "approve" action exists — a pending
              │     participant can only change their own status via
              │     PATCH (self-only), never promoted to attending by
              │     an event manager/admin. The `need_approval` intent
              │     on Ticket and `require_approval` on Event currently
              │     have no corresponding approval endpoint.
              ▼
     [attending | declined | maybe]   ← reachable via self-service PATCH
                                          from ANY prior status, including
                                          from "attending" back to "declined"
                                          etc. (no forward-only constraint)

DELETE /events/:id/participants/:id → row removed entirely (self-only).
This is NOT a state transition to "declined" — the Participant record is gone,
along with its FK links to ticket_item/voucher/badge (which are simply orphaned
unless the caller cleans those up separately).
```

- **Guard**: `is_manager = current_user.memberships.exists?(group: event.group, role:
  %w[admin owner])` — checked once, at creation time only. Being promoted to admin *after*
  already being `pending` does not retroactively unlock anything.
- **Required-form-fields gate** runs *before* the pending/attending decision: any required,
  non-`for_admin` `FormField` without a present value blocks creation entirely (`422`), it does
  not fall through to `pending`.
- **`payment_status`** (`nil`/`pending`/`cancelled`/`succeeded`) is a *separate* field, driven
  entirely by the `TicketItem` lifecycle (§8.2) — never written directly by
  `ParticipantsController`. A free (no-ticket) RSVP never touches `payment_status` at all (stays
  `nil` forever), so don't treat `payment_status.nil?` as "unpaid" — it may just mean "no ticket
  involved."

### 8.2 Ticket purchase & payment (`TicketItem#status`)

```
                         POST .../tickets/:id/rsvp
                                    │
                     ┌──────────────┴──────────────┐
                     │ ticket has payment_methods    │ no payment_methods
                     ▼                                ▼
         amount == 0 after coupon/Stripe-waiver   [succeeded]  (amount: 0,
                     │           │                              immediate)
              yes ───┘           └─── no
               │                       │
               ▼                       ▼
          [succeeded]              [pending]
       (immediate, no                  │
        payment step)      ┌───────────┼───────────────┬─────────────────┐
                            │           │               │                 │
                    verify_payment  set_payment_status  stripe_callback  cancel_unpaid_item
                    (self, EVM tx)  (server webhook,     (Stripe webhook, (self, own item)
                                     NEXT_TOKEN secret)   charge.succeeded)
                            │           │               │                 │
                            ▼           ▼               ▼                 ▼
                       [succeeded] [succeeded]     [succeeded]       [cancelled]
                                                                    (coupon usage
                                                                     count is
                                                                     INCREMENTED,
                                                                     not refunded —
                                                                     see §4.6/8.3)

                    (background timeout sweep, not implemented — §9)
                                    │
                                    ▼
                              [timeout]  (same coupon-increment side effect as cancel)
```

- **⚠️ `Ticket#quantity` decrement** (`decrement!`, no row lock) happens *before* payment is
  confirmed, at `rsvp` time — two concurrent requests against the last unit can both succeed in
  decrementing (a classic non-atomic check-then-write race). Not new to `soon/`, inherited as-is.
- **⚠️ No state transition back from `pending` to available inventory on cancel/timeout** —
  `Ticket#quantity` is never incremented back when a `TicketItem` is cancelled or times out. A
  cancelled reservation permanently consumes one unit of `quantity`.
- **Terminal states**: `succeeded`, `cancelled`, `timeout` are all effectively terminal — no
  controller action transitions *out* of them. A `succeeded` item can never be refunded/reversed
  through this API surface.
- **`unbounded`** is a distinct non-terminal state, entered only via
  `add_group_ticket_item` for an email with no matching `User` yet (§4.5) — it has no
  self-transition path either; ⚠️ becoming `succeeded` requires a signup-time claim hook that
  does not exist yet (see §9).
- Every transition into `succeeded` funnels through `mark_ticket_item_paid!`, which is also where
  `Participant#payment_status` gets synced to `"succeeded"` and group-ticket auto-membership
  happens — so **the `TicketItem` state machine and the `Participant` state machine are coupled**,
  but only in this one direction (ticket → participant, never the reverse).

### 8.3 Coupon discount application (per-attempt, not a persistent state machine)

Coupons don't have a lifecycle of their own beyond `order_usage_count` counting up — there's no
"applied/consumed/expired" status field. Every `rsvp` call with `params[:coupon]` re-evaluates
from scratch:

```
lookup by (selector_type: "code", event_id, code) ──▶ not found ──▶ inline error, no ticket_item created
        │ found
        ▼
expired? OR order_usage_count >= max_allowed_usages ──▶ yes ──▶ inline error, no ticket_item created
        │ no
        ▼
Coupon#get_discounted_price(amount, paymethod)  (see §4.6 for the exact math)
        │
        ▼
discount_value truthy? ──▶ no  ──▶ ticket_item created at full price, coupon.order_usage_count NOT incremented
        │ yes
        ▼
coupon.increment!(:order_usage_count)  +  ticket_item.coupon_id = coupon.id
```

- **⚠️ `order_usage_count` is incremented again on `cancel`/`timeout`** (§8.2) — meaning a single
  successful-then-cancelled redemption consumes **two** usage slots against `max_allowed_usages`,
  not one. This is a deliberately preserved business rule (anti-abuse), not a bug — but it means
  `order_usage_count` is *not* "number of currently-active redemptions," it's closer to "number of
  redemption attempts that got far enough to apply the discount."
- **⚠️ No uniqueness/idempotency guard** on which `TicketItem` used a coupon beyond the counter —
  nothing stops the *same* user from using the same code-strategy coupon multiple times across
  separate RSVPs (as long as `max_allowed_usages` isn't exhausted), since the strategy match is
  purely against the code string, not against `(coupon_id, user_id)`.

### 8.4 Group membership — adding members and promoting admins

Two independent, unrelated entry points exist for becoming a member — this is the one place
where "workflow" is really "two workflows that don't know about each other":

```
Path A — self-service join (direct, no approval):
  POST /groups/:id/memberships  →  Membership.create(user: current_user, role: "member")
  ⚠️ NO AUTHORIZATION CHECK on this action at all — any authenticated user can join any
     group at will, regardless of the group's own can_join_event-style settings (which,
     note, govern *event* joining, not group joining — there is no analogous
     can_join_group setting enforced here).

Path B — invite-mediated (see §4.2 for full detail):
  known user  → Group#add_member called directly by an admin/owner (no invite record)
  unknown email → GroupInvite[sending] → accept → Group#add_member
  reusable code → GroupInvite[sending, permanent] → accept_with_code → Group#add_member
  join request  → GroupInvite[requesting] → accept_request (admin/owner only) → Group#add_member
                  ⚠️ no reject/decline action exists for a "requesting" invite — it can only
                     be left pending indefinitely or accepted, never explicitly declined
                     (the generic cancel/revoke actions operate on sending-status invites
                     in the GroupInvitesController flow, not requesting-status ones — verify
                     before assuming they cover this case)
```

**Role promotion** (`member → admin/owner` or any other role change) is a single, separate,
non-workflow action: `PATCH /groups/:id/memberships/:id` with `{ membership: { role: "..." } }`,
gated by `authorize_group_admin!` (must already be `admin`/`owner`). There's no request/approve
cycle for promotions — an admin can unilaterally set anyone's role to anything.
⚠️ **`Membership#role` has no `inclusion` validation** — the schema comment documents
`member | admin | owner` but nothing stops `PATCH` from writing an arbitrary string, which would
then silently fail every `role: %w[admin owner]` check downstream (i.e., a typo'd role value
doesn't error, it just quietly locks that membership out of admin-gated actions).

**Leaving**: `DELETE /groups/:id/memberships/:id`, self or admin/owner
(`authorize_leave!`) — no distinct "removed by admin" vs. "left voluntarily" state, both just
destroy the row.

### 8.5 Badge issuance and claiming (`BadgeClass` → `Voucher` → `Badge`)

```
BadgeClass (template, status: active|freezed — freezed is set but never
            checked/enforced anywhere in BadgesController/VouchersController;
            ⚠️ freezing a badge class does NOT currently stop new badges
            being minted from it)
     │
     │  VouchersController#create / send_badge / send_badge_by_address / send_badge_by_email
     ▼
Voucher (strategy: code|account|address|email|event, counter: N)
     │
     │  VouchersController#use — strategy-matched redemption (§4.4)
     │  guarded by: not expired, counter > 0, not already claimed by this user
     ▼
Badge[minted] ──────────────┬─────────────────┬──────────────────────
     │                       │                 │
     │ transfer               │ burn             │ swap_code + swap
     │ (owner-only,           │ (owner-only,     │ (two-party, both badges
     │  badge_class           │  status must be  │  must be transferable +
     │  .transferable,        │  "minted")       │  minted/accepted)
     │  status minted/        │                  │
     │  accepted)             ▼                  ▼
     ▼                    Badge[burned]     owner_id exchanged between
Badge[minted]              (terminal —       two Badge rows; both stay
(new owner_id)              no transition     in whatever status they
                             out of burned)    were already in
     
     ⚠️ status "accepted" is a valid enum value with NO code path that ever
        sets it — nothing in BadgesController/VouchersController transitions
        a badge into "accepted". Any policy/UI logic written against
        "accepted" as a reachable state should be treated as currently dead.
```

- **Voucher-side guards**, evaluated in order on every `use` call: `voucher.invalid?`
  (`counter == 0 || expired`) → strategy match → per-user double-claim check. **⚠️ the
  double-claim check is per-`(voucher_id, owner_id)`, not global** — a `counter: 10` code voucher
  is correctly claimable by 10 *different* users, but nothing stops those 10 claims from
  happening concurrently past the `counter` cap (same non-atomic `decrement!` pattern as
  `Ticket#quantity`, §8.2) — ⚠️ possible over-redemption under concurrent load.
- **`badge_class.counter`** (the running mint index used as `Badge#index`) is captured *before*
  increment, so the first badge minted from a class gets `index == badge_class.counter`'s value
  at call time, not `+1` — off-by-one-looking but intentional (see the source comment in
  `VouchersController#use`).
- **`"group_member_pass"` permission**: any `BadgeClass` with this string in its `permissions[]`
  array auto-grants group membership on successful redemption (§4.4) — this is *not* visible in
  the `Badge`/`Voucher` state machine itself, it's a side effect that silently also runs
  `Group#add_member`, i.e. redeeming a badge can trigger the Path-B membership workflow (§8.4)
  as a side channel.

## 9. Known gaps / explicitly deferred

These are not oversights to silently fix — they're deliberate stopping points, listed here so
they're not mistaken for bugs during review. §8 flags additional risk points inline with ⚠️ at the
exact state-machine step they affect — the three most severe are pulled up here too:

- **`MembershipsController#create` has no authorization check** — any authenticated user can join
  any group at will (§8.4). If group privacy/approval is an intended feature, this needs a policy
  before it ships, not just documentation.
- **No manager-approval action for `pending` participants** — `Event#require_approval` and
  `Ticket#need_approval` both express *intent* to gate registration, but no controller action
  lets a manager move a participant from `pending` to `attending`; only the registrant's own
  self-service `PATCH` can change their status (§8.1).
- **`Membership#role` has no `inclusion` validation** — `PATCH /memberships/:id` accepts any
  string as `role`, silently breaking every downstream `role: %w[admin owner]` check for a
  typo'd value instead of raising a `422` (§8.4).
- **Mailers**: `TicketItem#notify_group_owner`, `Comment#create`'s feedback-type notification, and
  `GroupInvite`'s email-invite delivery are all stubbed (`# TODO` comments in the source) pending
  soon/'s mail setup (`resend` gem is in the Gemfile but not yet wired to a mailer class).
- **Stripe webhook signature verification**: `TicketsController#stripe_callback` does not yet call
  `Stripe::Webhook.construct_event` — the endpoint currently trusts the payload as-is
  (`stripe_event_verified?` is a stub returning `true`).
- **Ticket quantity race condition**: `Ticket#quantity` is decremented via a plain
  `decrement!`, not a locked/atomic check-and-decrement — concurrent RSVPs against the last unit
  could oversell. Same caveat inherited from the source design, not newly introduced.
- **Group-ticket claim-on-signup**: `add_group_ticket_item`'s `"unbounded"` placeholder
  `TicketItem` (for emails without an account yet) has no corresponding "claim on signup" hook —
  `AuthController#request_code`/`verify_code` don't check for pending unbounded ticket items.
- **`Venue#check_availability`**: the `Availability` data model is ported, but the canonical
  overlap-checking method described in the top-level `CLAUDE.md` (used by event/recurring
  controllers in the source design) has not been ported into `soon/`'s `Venue`/`Event` models yet.
- **No background job runner configured**: nothing in `soon/` currently needs one (all writes are
  synchronous), but if async mail delivery or payment-timeout sweeping (`TicketItem#timeout`) is
  wired up later, Rails 8's default (Solid Queue) is the intended choice — not the `good_job` gem
  the source design used (deliberately excluded, see `SAILS_COMPARISON.md`).
