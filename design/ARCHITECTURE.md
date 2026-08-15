# soon/ — Architecture, Data Model, and Application Logic

This document describes `soon/` as it stands today: a Rails 8.1 JSON API, TSID-keyed throughout,
being built as a leaner replacement for `sails/`. See `SAILS_COMPARISON.md` for what was ported
from where and why, and `CHANGELOG.md` for a chronological log of changes. This document is the
synchronic view — how the system is actually built, independent of its migration history.

Last updated: 2026-07-29 (mail + background jobs wired up; wallet/trusted sign-in, calendars,
uploads, discovery and remember documented; §9 gaps re-audited).

**Testing**: Rails Minitest (`bin/rails test`), no fixtures (soon/'s TSID PKs are
callback-generated; `test/support/factory_helpers.rb` provides `create_user`/`create_group`/etc.
instead). 45 files across `test/controllers/api/v1/` (one per controller), `test/models/`
(the validations/constraints called out in §8), `test/mailers/` (template rendering),
`test/jobs/`, `test/services/`, and `test/integration/` (which endpoint fires which email).
615 runs, 1,760 assertions, 0 failures as of this revision.

## 1. Architecture overview

**Stack**: Rails 8.1 (API-only, `ActionController::API`), PostgreSQL, Puma. JSON serialization via
`blueprinter`. Authorization via `pundit`. Pagination via `pagy` (v9+ `Pagy::Offset` API — no
`Pagy::Backend` mixin). Auth is stateless bearer-JWT (`jwt` gem) — no sessions, no cookies, no
Doorkeeper/OAuth server; see §4.1 for the four ways a token is minted. Background work via
**GoodJob** running inside the Puma process (`execution_mode :async`) — no separate worker to
deploy, but jobs are rows in `good_jobs`, so a restart doesn't drop queued mail. All outgoing
email goes through it; see §1.1.

**Choices worth naming**, since each had a plausible alternative:

| Choice | Instead of | Why |
|---|---|---|
| TSID string PKs | bigint / UUID | Time-sortable like an autoincrement, but safe to expose and mint client-side-independently. `TicketItem`'s own id doubles as the order number. |
| Blueprinter | Jbuilder (what sails used) | Serialization is a class with explicit views, not a template resolved by controller/action path — grep-able, testable, and it can't accidentally render a different shape per action. |
| Rails `enum` on plain string columns | Postgres native enum types | Adding a value is a code change, not a migration + type alter. |
| GoodJob `:async` | Solid Queue (Rails 8's default) | §1.1. |
| `siwe-rb` | the unmaintained `siwe` gem | The original (spruceid) gem's last real commit was 2023-07. Full `lib/` reviewed before adopting the replacement. |
| Bearer JWT | server-side sessions | The API has three separate frontends (app, auth service, dashboard) on different origins; a bearer token avoids cross-origin cookie work entirely. |

**External services** — each is reachable only through one wrapper, so swapping or stubbing is a
single-file change:

| Service | Wrapper | Used for |
|---|---|---|
| Resend | `config.action_mailer.delivery_method = :resend` (prod only) | All outgoing mail (§1.1) |
| Cloudflare Images | `app/services/cloudflare_images.rb` → `UploadsController#image` | Every user-uploaded image; models store the returned delivery URL in a `*_url` column, never a blob |
| Stripe | `stripe` gem, in `TicketsController` only | Fiat ticket payment + webhook (§4.7) |
| EVM JSON-RPC | `lib/evm_payment_verifier.rb` (`httpx`) | On-chain payment proof (§4.7) |
| — | `app/services/event_calendar.rb` (`icalendar`) | `.ics` generation for invites and feeds (§4.11) |
| — | `app/services/jwt_service.rb` | Auth tokens and badge swap codes |

### 1.1 Background jobs

- `config.active_job.queue_adapter = :good_job` (`config/application.rb`); tuning lives in
  `config/initializers/good_job.rb`. `config/environments/test.rb` overrides the adapter to
  `:test`, so the suite asserts on enqueues and never executes anything.
- **Everything that sends mail is async** except `AuthMailer#login_code`, which stays
  `deliver_now` on purpose so a delivery failure surfaces on the request that asked for the code.
- `deliver_later` routes through `MailDeliveryJob` (`config.action_mailer.delivery_job`), which
  carries the retry policy: backoff on `Resend::Error` and socket errors, discard on
  `ActiveRecord::RecordNotFound` (the mailers look their subject up by id, so a deleted record has
  nothing left to send).
- Two fan-out jobs keep per-recipient loops out of the request: `EventAttendeeMailJob`
  (cancel/update → every attending participant) and `GroupBroadcastMailJob` (manager broadcast →
  `Group#member_emails`). Each recipient gets its own `MailDeliveryJob`, so one bad address
  retries alone instead of stalling the batch.
- Because jobs share the Puma process they also share the Active Record pool — `config/database.yml`
  sizes it `RAILS_MAX_THREADS + GOOD_JOB_MAX_THREADS + 2` (the `+2` covers GoodJob's Notifier,
  which holds a connection open to `LISTEN`).
- Chosen over Rails 8's default Solid Queue because Solid Queue wants a supervisor process (or a
  Puma plugin) and a second database, whereas GoodJob's `:async` mode is exactly the
  one-container, one-Postgres shape this app deploys in. sails also used GoodJob, so its
  operational behaviour is already familiar.

**Layering** (top to bottom, request path):

```
config/routes.rb
  → app/controllers/api/v1/*_controller.rb   (thin — params, auth, orchestration)
      → app/policies/*_policy.rb              (Pundit — authorization only)
      → app/models/*.rb                       (ActiveRecord — validations, associations,
                                                 business logic, callbacks)
      → app/services/*.rb                     (external I/O behind one wrapper each:
                                                 Cloudflare Images, JWT, .ics generation)
      → app/blueprints/*_blueprint.rb          (Blueprinter — response shaping)

  ⇢ app/jobs/*.rb                             (GoodJob — everything off the request path)
      → app/mailers/*.rb → app/views/*_mailer/*.{html,text}.erb
```

Anything that talks to a third party sits in `app/services/` or `lib/`, never inline in a
controller — which is what makes the whole suite runnable with no network access.

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
| `User` | `name` (unique — **this is the handle**; there is no separate `handle` column), `email` (unique), `eth` (unique), `sol` (unique), `phone` (unique), `ref_id`, `nickname`, `image_url`, `bio`, `permissions[]`, `social_links` jsonb, `telegram_id`, `active`, `last_signin_at`, `data` jsonb | The single identity model — `sails/`'s `Profile` was **not** ported as a separate concept; social-provider handles (twitter/github/etc.) live in `social_links` jsonb rather than dedicated columns. At least one of `email`/`eth`/`sol` must be present (`has_login_identity` validation) — an account is always reachable by some login path. `sol` exists only to hold the 50 migrated Solana accounts; the frontend sign-in option was removed 2026-07-29 |
| `AuthCode` | `recipient`, `recipient_type` (email\|phone), `context` (login\|bind_email), `code`, `used_at`, `attempts` | One-time code, 15-minute expiry computed from `created_at` (no stored `expires_at` — see `AuthCode::EXPIRY`), max 5 attempts. `context` keeps a bind-email code from being replayed as a login code |

### 3.2 Groups, events, and the social graph

| Model | Key columns | Notes |
|---|---|---|
| `Group` | `name`, `nickname`, `parent_id` (self-referential), `handle`-equivalent is `nickname`, `group_tags[]`, `social_links` jsonb, `memberships_count`/`events_count` (denormalized counters), `start_date`/`end_date`/`location` (popup-city mode), `can_publish_event`/`can_join_event`/`can_view_event`, `group_ticket_event_id` | `parent_id` self-reference has no default scope for cascading permissions beyond what controllers implement (see `GroupPolicy`) |
| `Membership` | `user_id`, `group_id`, `role` (member\|admin\|owner), `active`, `data` jsonb | Unique on `(user_id, group_id)` |
| `GroupInvite` | `sender_id`/`receiver_id` (optional — `receiver_id` only set once resolved), `group_id`, `role`, `status` enum, `receiver_address_type` (id\|email\|code), `receiver_address`, `expires_at`, `badge_class_id`/`badge_id`/`ticket_id` (optional grant-on-accept refs) | See §4.2 for the branching logic — **not every invite flow creates a `GroupInvite` row** |
| `Event` | `title`, `content`, `start_time`/`end_time`, `status`, `visibility`, `group_id`, `owner_id`, `place_id`/`track_id`/`venue_id`/`recurring_id`/`form_id` (all optional), `require_approval`, `participant_count`, `tags[]`, `kind` (also doubles as the `"group_ticket"` marker — see §4.5) | `op_status`/`op_priority`/`op_labels[]` exist on the table but are **deliberately unused** for now (deferred to a future dedicated table) |
| `EventRole` | `event_id`, `item_id`/`item_type` (polymorphic: user\|group), `role` (member\|manager), `email`/`display_name`/`image_url` (for not-yet-registered co-hosts) | Unique on `(event_id, item_id, item_type)` |
| `Participant` | `event_id`, `user_id`, `status` (attending\|declined\|maybe\|pending), `payment_status`, `message`, `register_time`, `voucher_id`/`badge_id`/`ticket_id` (all optional — ticket/voucher integration) | Unique on `(user_id, event_id)` — one participant record per user per event, mutated in place across RSVP/cancel/re-RSVP rather than recreated |
| `Recurring` | `start_time`, `end_time`, `interval`, `event_count`, `timezone` | Groups a series of `Event`s via `events.recurring_id`; no back-reference `has_many :events` cascade rule beyond `dependent: :destroy` |
| `Place` | `name` (unique), `address`, `latitude`/`longitude`, `description` | |
| `Venue` | `name` (unique), `group_id`, `owner_id`, `place_id` (optional), `capacity`, `amenities[]`/`tags[]`, `image_urls[]`/`featured_image_url`, `website`, `about`, `track_ids[]`, `require_approval`, `start_date`/`end_date` (bookable window), `archived` | `archived` is a **soft delete** — `#destroy` flips the flag rather than removing the row, since events still reference the venue; `index` filters it out. `timeslots`/`overrides` jsonb exist on the table but are unused — availability lives in `Availability` rows |
| `Availability` | `item_id`/`item_type` (polymorphic), `day`/`day_of_week`, `intervals` jsonb, `role_required` | Weekly slots (`day_of_week`) plus date overrides (`day`), an override winning over the weekly slot for that date; empty `intervals` = closed; **no rows at all = open 7×24**. `Venue#check_availability(start, end, timezone, event_id = nil)` is the canonical check, used by both the event and recurring paths (pass `event_id` to exclude the event being edited from the overlap query) |
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
| `FormField` | `form_id`, `label`, `field_type` (text\|select\|image\|file), `required`, `for_admin` (excluded from the required-field gate), `position`, `options` jsonb | Ordered by `position`. `image`/`file` store the uploaded URL in the answer's `value` like any other text — see `POST /upload/file` |
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

`AuthController` is the only controller inheriting `ActionController::API` directly, since its
actions run before a JWT exists. Every path ends at the same place: `render_token`, a
`JwtService`-signed bearer token (`{"user_id" => user.id}`, 30-day expiry). There are no sessions,
no cookies, and soon/ is not an OAuth *server* — where OAuth appears (Google), it is verified by
the auth frontend and arrives here as a trusted server-to-server call.

Four ways in:

1. **Email one-time code** — `request_code` creates an `AuthCode` (`recipient_type: "email"`,
   `context: "login"`) with a random 6-character code and mails it; `verify_code` matches it via
   `consume_code!` (unused, inside the 15-minute window, under the attempt cap), marks it used, and
   **creates the account if the address is new** — signup and signin are the same endpoint.
2. **SIWE wallet** — `nonce` mints a single-use nonce, `verify_wallet` parses and verifies the
   Sign-In with Ethereum message, then finds-or-creates by `eth` (downcased). The message's
   `domain` field is checked against `ALLOWED_SIWE_DOMAINS` (default `auth.sola.day,auth.juluo.xyz`;
   localhost is additionally allowed outside production) so a signature harvested by another site
   can't be replayed here.
3. **`trusted_signin`** — for flows the auth frontend verifies *itself* (Google OAuth; historically
   Solana signatures), gated by `secure_compare` against the `NEXT_TOKEN` shared secret. Takes
   either `email` or `sol_address`. This is the one endpoint where soon/ trusts an assertion it did
   not verify, so the secret must be treated accordingly.
4. **`bind_email`** — attaches an email to a wallet-first account, using a code minted under
   `context: "bind_email"` so it can't be replayed as a login. The email is the login identity, so
   it can only be set **once**, and never to an address already belonging to another account.

Both paths that establish an email (`verify_code`, `bind_email`) then call
`GroupInvite.auto_accept_ticket_invites_for(user)` — see §4.5.

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

`VouchersController#use` is the single redemption entrypoint for 5 of the 6 strategies (`code`,
`account`, `address`, `email`, `event`). The sixth, `remember`, is a real strategy but deliberately
has no branch here — `RememberController` creates its voucher and mints from it through its own
threshold-gated flow (§4.13):

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
`TicketItem` is immediately marked `succeeded` and `Group#add_member` runs.

**If they don't have an account yet**, a `GroupInvite` carrying the `ticket_id` is created instead
(`receiver_address_type: "email"`, `status: "sending"`). The claim happens automatically the moment
that address becomes a real login identity: `AuthController`'s `verify_code` and `bind_email` both
call `GroupInvite.auto_accept_ticket_invites_for(user)`, which accepts every pending ticket-bearing
invite for that email — joining the group and materialising the `TicketItem` via `grant_ticket!`.
An earlier revision of this doc described a `status: "unbounded"` placeholder `TicketItem` awaiting
an unimplemented claim hook; that design was replaced by this one. `"unbounded"` survives only as a
value in `TicketItem`'s status inclusion list with nothing writing it.

### 4.6 Ticket purchase (`rsvp`) and coupon math

`TicketsController#rsvp` is the central purchase/reservation flow:
1. Guard on event closed/ended and venue capacity.
2. `@ticket.reserve!` — atomically (row-locked via `with_lock`) claims one unit of `quantity`, or
   is a no-op that always succeeds if `quantity` is `nil` (unlimited). Returns `false` (→ "run out
   of ticket") if sold out. Fixed 2026-07-16 — previously a raw `decrement!` with no locking, which
   could oversell under concurrent RSVPs against the last unit. Any abort later in `rsvp` (payment
   method not found, coupon error, `RecordInvalid`) calls `@ticket.release!` to give the unit back.
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
7. On `succeeded`, auto-joins the group (for `ticket_type == "group"`), emails the buyer their
   confirmation (`EventMailer#ticket_purchased`, with the `.ics` attached), and calls
   `TicketItem#notify_group_owner`, which mails the group's owner
   (`GroupMailer#ticket_purchased`). Both are `deliver_later` (§1.1).

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

Three ways a `pending` `TicketItem` becomes `succeeded`, all converging on the model method
`TicketItem#confirm_payment!` (sets `status: succeeded`, optionally `txhash`/`sender_address`,
auto-joins group-ticket groups, syncs `participant.payment_status`, calls `notify_group_owner` — all
in one transaction). **Verification is always done per-rail before confirming**, via the controller's
`payment_proof_ok?`: Stripe items are checked against `Stripe::PaymentIntent` (status + amount),
crypto items against `EvmPaymentVerifier` with a required, non-replayed `txhash`.
1. **`verify_payment`** — user-initiated, self-only (`ticket_item.user_id == current_user.id`).
   Runs the per-rail proof check for any `amount > 0` item (including Stripe — there is no longer a
   Stripe bypass).
2. **`set_payment_status`** — server-to-server webhook-style endpoint, authenticated by a shared
   secret (`secure_compare` against `ENV["NEXT_TOKEN"]`, which must be **non-blank** — an unset
   token is rejected). Crypto items with `amount > 0` still require an `EvmPaymentVerifier` pass.
3. **`stripe_callback`** — Stripe webhook receiver. `stripe_event_verified?` does a real
   `Stripe::Webhook.construct_event` signature check when `STRIPE_WEBHOOK_SECRET` is configured and
   **fails closed in production** otherwise. Only `pending` items transition; `charge.succeeded`
   confirms via `confirm_payment!`, and failure/cancel events release the reservation via `cancel`.
   A replay guard (app-level check + partial unique index on `ticket_items.txhash`) stops one
   payment from redeeming multiple orders.

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

### 4.10 Discovery and search (`DiscoverController`)

Both actions are fully anonymous (`skip_before_action :authenticate!`) and only ever read public,
published content, so there is no viewer to scope by.

- **`GET /discover`** — the homepage payload in one round trip: featured groups, popup cities, and
  the next 20 public events. "Popup city" is **curation, not inference**: it means a `Group` tagged
  `top` (excluding `hidden`), not "any group that happens to have `start_date`/`end_date` set".
  `featured` is a second tag that the frontend filters out of the same list client-side, which
  means a group must carry **both** `featured` and `top` to appear in the carousel. Tag assignment
  is privileged (`GroupsController::PRIVILEGED_TAGS`).
- **`GET /search?keyword=`** — one ILIKE pass each over events (public+published, by title), groups,
  users, and badge classes, 10 apiece. Queries under 2 characters short-circuit to empty rather than
  scanning. No ranking, no full-text index — deliberately the simplest thing that serves the
  header search box.

### 4.11 Calendar feeds (`CalendarsController`, `EventCalendar`)

`.ics` output serves two different purposes and both go through `app/services/event_calendar.rb`:

- **Attachments on transactional mail** — `EventMailer` attaches the invite with an explicit iTIP
  `METHOD` MIME parameter (`REQUEST` on approve/purchase/update, `CANCEL` on cancellation). Without
  the parameter a client treats the part as a file to open rather than an invite to act on. Updates
  reuse the same UID with a bumped `SEQUENCE`, so a calendar edits the existing entry in place
  instead of creating a duplicate.
- **Subscribable feeds** — `GET /events/:id/calendar.ics` and `GET /groups/:id/calendar.ics`. These
  are **public by necessity**: a calendar client subscribing to a URL cannot carry a bearer token.
  So they apply their own visibility gate (`calendar_visible?`: public, not draft/archived) rather
  than the usual policy layer, and the group feed additionally trims to events ending within the
  last 90 days. Group feeds resolve by slug as well as TSID, since the slug is what ends up in a
  `webcal://` URL a human pasted.

### 4.12 Uploads (`UploadsController`, `CloudflareImages`)

`POST /upload/image` is authenticated, caps at 10 MB, and allowlists PNG/JPEG/GIF/WebP/SVG. The
file is forwarded to Cloudflare Images and only the returned delivery URL comes back to the
caller, who stores it on some model's `*_url` column. **soon/ never stores image bytes** — there is
no Active Storage attachment anywhere in the schema, which is why every image field is a plain
string.

### 4.13 Remember (`RememberController`)

A shared commemorative badge for a set of people who were physically in the same place. One user
creates a "remember", shows a QR code, others scan and `join`; once the joiner threshold is met
(`REQUIRED_JOINERS`, creator included) the creator calls `mint` and every joiner receives an
identical badge. Which `BadgeClass` it mints from is **discovered, not hardcoded** — it's whichever
class carries `badge_type: "remember"` (sails hardcoded the id). `meta`/`show`/`related_groups` are
public so a scanner can see what they're joining before signing in.

### 4.14 Places and markers

`Place` is a shared, deduplicated location record referenced by events, venues, and markers;
`Marker` is a pin on a group's community map. Both have public read paths, but with different
shapes: `places#search` is an open ILIKE lookup used by the location picker, whereas
`markers#index` is public **only with a `group_id` filter** — an anonymous request without one is
rejected `422` rather than serving a firehose of every group's map. An authenticated caller with no
filter gets markers across their own groups. `markers#index` also excludes `status: "removed"`,
a soft-delete that only exists in migrated legacy data (soon's own `#destroy` hard-deletes).

## 5. Associations, constraints, and validations — cross-cutting rules

**Polymorphic associations** appear in 6 places, all following the same `item_type`/`item_id`
(string) shape: `Availability#item`, `Domain#item`, `EventRole#item`, `PaymentMethod#item`,
`Activity#item`, `Comment#item`. None of these have a DB-level polymorphic-type CHECK constraint
— validity of `item_type` is enforced at the application layer only (or, for `PaymentMethod`, via
an explicit `validates :item_type, inclusion:`).

**Uniqueness constraints** are DB-backed via unique indexes, not just `validates uniqueness:`:
`users.email/eth/sol/phone/name`, `venues.name`, `domains.name`, `forms.slug`, `tracks.name`,
`memberships(user_id, group_id)`, `participants(user_id, event_id)`,
`event_roles(event_id, item_id, item_type)`, `track_roles(track_id, user_id)`,
`form_submissions(form_id, user_id)`. Plus one partial unique index on `ticket_items.txhash`, which
is what stops a single payment from being replayed against several orders (§4.7).

`places.name` is the deliberate exception: it has a plain (non-unique) index, and its unique index
was **dropped** — two genuinely different places can legitimately share a name.

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
              │  POST .../participants/:id/approve — event owner or group
              │  admin/owner only (EventPolicy#update?), added 2026-07-16.
              │  Only transitions FROM "pending"; 422 otherwise. Fixed the
              │  gap where require_approval/need_approval expressed intent
              │  with no way to act on it.
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

- **Fixed 2026-07-16**: `Ticket#quantity` claim/release is now atomic (`Ticket#reserve!`/`#release!`,
  row-locked via `with_lock`, backed by a DB `CHECK (quantity IS NULL OR quantity >= 0)` constraint)
  and symmetric — `TicketItem#cancel`/`#timeout` call `ticket.release!` to give the unit back, so a
  cancelled reservation no longer permanently consumes inventory. Previously a raw `decrement!` with
  no lock and no refund path (both flagged as risks in an earlier revision of this doc).
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
Coupon#available? (nil max_allowed_usages == unlimited) ──▶ no ──▶ inline error, no ticket_item created
        │ yes
        ▼
Coupon#get_discounted_price(amount, paymethod, chain:)  (see §4.6 for the exact math)
        │
        ▼
discount_value truthy? ──▶ no  ──▶ ticket_item created at full price, coupon NOT consumed
        │ yes
        ▼
ticket_item.coupon_id = coupon.id  ──▶ (after the item persists) consume_coupon! increments
                                        order_usage_count under a row lock, inside the RSVP txn
```

- **`order_usage_count` is consumed only once, after the item persists**, inside the RSVP
  transaction and under a row lock (`consume_coupon!`) — an aborted request (bad chain, validation
  failure) no longer burns a usage, and concurrent RSVPs can't over-redeem the last unit.
- **`cancel`/`timeout` refund the usage** (`decrement!`) so a successful-then-cancelled order nets
  zero, matching the reservation being released. `order_usage_count` therefore tracks
  currently-consumed redemptions.
- **⚠️ No uniqueness/idempotency guard** on which `TicketItem` used a coupon beyond the counter —
  nothing stops the *same* user from using the same code-strategy coupon multiple times across
  separate RSVPs (as long as `max_allowed_usages` isn't exhausted), since the strategy match is
  purely against the code string, not against `(coupon_id, user_id)`.

### 8.4 Group membership — adding members and promoting admins

**Fixed 2026-07-16**: membership can now only be gained through `GroupInvite` (Path B below) —
there is no self-join path anymore. `POST /groups/:id/memberships` used to have zero authorization
(any authenticated user could join any group directly); it's now admin-only direct-add
(`authorize @group, :manage?`, `user_id` param), which is really just Path B's "known-user direct
add" branch exposed as its own endpoint for a manager who already knows who they want to add.

```
POST /groups/:id/memberships (admin/owner only) OR invite-mediated (see §4.2 for full detail):
  known user  → Group#add_member called directly by an admin/owner (no invite record)
  unknown email → GroupInvite[sending] → accept → Group#add_member
  reusable code → GroupInvite[sending, permanent] → accept_with_code → Group#add_member
  join request  → GroupInvite[requesting] → accept_request (admin/owner only) → Group#add_member
                  Confirmed: the generic revoke action (POST .../group_invites/:id/revoke) also
                  works on "requesting"-status invites as a reject/decline — no separate action
                  was needed. group_admin? gates it since a request has no sender_id.
```

**Role promotion** (`member → admin/owner` or any other role change) is a single, separate,
non-workflow action: `PATCH /groups/:id/memberships/:id` with `{ membership: { role: "..." } }`,
gated by `authorize_group_admin!` (must already be `admin`/`owner`). There's no request/approve
cycle for promotions — an admin can unilaterally set anyone's role to anything.
**Fixed 2026-07-16**: `Membership#role` now validates `inclusion: { in: %w(member admin owner) }` —
previously any string silently passed and would quietly break every `role: %w[admin owner]` check
downstream.

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
  (`counter == 0 || expired`) → strategy match → per-user double-claim check. The double-claim
  check is per-`(voucher_id, owner_id)`, not global — a `counter: 10` code voucher is correctly
  claimable by 10 *different* users. **Fixed 2026-07-16**: the double-claim re-check, badge
  creation, and counter decrement now all happen inside `voucher.with_lock` (row-locked), with
  `invalid?`/double-claim re-verified after acquiring the lock — closes what was previously a
  non-atomic race allowing over-redemption past the `counter` cap under concurrent claims.
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
exact state-machine step they affect.

**Closed 2026-07-16** (previously listed here as the three most severe gaps — see
`CHANGELOG.md`'s 2026-07-16 "constraints, application-logic gaps" entry for full detail):
`MembershipsController#create`'s missing authorization, the missing manager-approval action for
`pending` participants (now `ParticipantsController#approve`), and `Membership#role`'s missing
`inclusion` validation.

Also fixed in the same pass, and covered by a new 311-test Minitest suite
(`test/controllers/api/v1/`, `test/models/`) built at the same time: two `DoubleRenderError`-causing
missing `return`s (`MembershipsController`, `EventRolesController`), `EventRole#item_type`'s
lowercase-vs-constant-name validation mismatch, an authorization bypass in
`BadgeClassesController#create` (checked the wrong params key), a `groups.handle`-vs-`nickname`
column mistake in `BadgeClassesController#index`, and `Participant#status` missing `"cancelled"`
from its inclusion list (silently broke ticket-cancellation's participant sync). `Ticket#quantity`
and `Voucher#counter` are now both atomic/row-locked (§8.2, §8.5) — the concurrency races flagged
in earlier revisions of this doc are closed.

**Closed since**, and listed only so an old note elsewhere isn't mistaken for current state:

- **Mailers** — all wired up. Five mailer classes (`Auth`/`Event`/`Group`/`Comment` + the shared
  `ApplicationMailer` holding brand config), delivered through Resend, queued on GoodJob (§1.1).
  `TicketItem#notify_group_owner`, the feedback-comment notification, and `GroupInvite`'s email
  delivery — all three named as stubs in earlier revisions — are implemented.
- **Group-ticket claim-on-signup** — implemented, via a redesign rather than the mechanism the old
  note anticipated (§4.5): a ticket-bearing `GroupInvite`, auto-accepted the moment the address
  becomes a login identity.
- **`Venue#check_availability`** — ported (§3.2), including the date-override-beats-weekly-slot
  rule and the `event_id` exclusion for edits.

Still open:

- **Stripe webhook secret provisioning**: `stripe_event_verified?` does a real
  `Stripe::Webhook.construct_event` check when `STRIPE_WEBHOOK_SECRET` is set and **fails closed in
  production** when it is not. The code is done; the secret still has to be provisioned per
  environment. Until it is, production rejects Stripe webhooks rather than trusting them — the safe
  failure, but payment confirmation then depends entirely on `verify_payment`/`set_payment_status`.
- **TODO — payment-timeout sweeping**: `TicketItem#timeout` has no scheduler, so a `pending` item
  whose payment never lands sits there indefinitely holding its reserved unit. GoodJob supports
  cron and could run the sweep, but `config.good_job.enable_cron` is deliberately off.
  **Deferred to a future pass over the payment system as a whole** — the sweep interacts with
  reservation release and refund semantics, and is not worth wiring in isolation.
- **Dead enum values**: `Badge#status`'s `"accepted"` and `BadgeClass#status`'s `"freezed"` are
  legal values that **nothing ever sets or checks** (§8.5) — notably, freezing a badge class does
  not stop new badges being minted from it. `TicketItem`'s `"unbounded"` is likewise now unwritten
  (§4.5). Treat any policy or UI logic keyed on these as dead until a code path is added.
- **Event operations columns**: `op_status`/`op_priority`/`op_labels[]` exist on `events` but are
  unused, pending a dedicated operations table rather than more columns on `Event`.
