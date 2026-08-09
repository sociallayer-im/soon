# Payments plan — Stripe integration for `soon`

Status: **IMPLEMENTED — 2026-07-30.** All decisions settled and all phases
built; see §7 for what shipped, what changed along the way, and what is
still open. Not yet deployed: SG needs `ginger deploy` (which runs the
migration that deletes the legacy `unbounded` rows).

Scope: fiat (Stripe) ticketing in `soon`,
plus the `seastar-app` / `sola-sdk` surface it needs. The crypto (EVM PayHub)
rail is in scope where it shares code with fiat — coupons, reservations, order
state — and the state machine is designed to absorb a future refactor of the
crypto flow.

Decisions confirmed so far:

1. **Card entry, SCA/3DS etc. happen on Stripe's hosted page** (Checkout
   Session), not in our frontend.
2. **Per-organizer Stripe API keys, stored in a new `stripe_settings` table**,
   configured by each user in their personal settings — not platform env
   vars, and not Stripe Connect.
3. **The order state machine is redesigned** to cover both rails, leaving room
   for the future crypto-payment refactor.
4. The two coupon bugs (`applicable_ticket_ids` unenforced, `removed`
   ignored) are confirmed for fixing.
5. **Money goes to the event owner's account** — the event owner's
   `stripe_settings` collects every ticket sale for that event.
6. **Refunds are supported.** Authorized to the **event owner and co-hosts**
   (`EventRole role: "manager"`); for **group tickets**, additionally the
   **group owner**. Deliberately narrower than `EventPolicy#update?` (which
   also grants group managers) → a dedicated `EventPolicy#refund?`.
7. **Restricted keys are recommended, not required** for now — settings UI
   copy suggests `rk_` keys, but any valid key is accepted.
8. **No more free-ticket waiver.** A stripe payment method priced under the
   minimum is **rejected at ticket creation** with a message telling the
   organizer to use crypto payment instead — never silently given away at
   checkout.
9. **Coupon floor**: the after-coupon payable amount must be **≥ the same
   minimum ($4) or exactly 0**. In-between → the coupon is rejected for that
   payment method ("coupon not applicable"). Exactly 0 stays a valid free
   path (deliberate 100% coupons). One constant serves both the
   creation-time and checkout-time checks. (Stripe's own hard floor is
   actually $0.50; $4 is our deliberately higher product floor — small
   charges are mostly eaten by Stripe's $0.30 + 2.9% fee anyway.)
10. **Full-refund side-effects**: a full refund releases the quantity unit,
    returns the coupon usage, flips the participant to `cancelled` (and
    decrements `participant_count`), and revokes a group-ticket membership
    granted by the purchase auto-join. A **partial refund moves money only**
    — the seat, coupon usage, and membership stay.
11. **v1 refund UI is full-refund-only** (one button); the API accepts an
    `amount` param from day one.
12. **Refunds are organizer-initiated only.** No buyer self-service refund
    flow in v1.
13. **Stripe is enabled only on the SG deployment (`app.sola.day` /
    `api.sola.day`), gated by deployment env vars** — not on CN
    (juluo.xyz). Both sides gate:
    - Backend: `STRIPE_ENABLED=true` in `soon/ginger.yml`'s `env:` (SG
      only; absent on CN). When unset, the API rejects creating stripe
      payment methods, refuses checkout-session creation, hides the
      stripe_settings endpoints, and skips webhook-endpoint provisioning —
      so CN can't accumulate half-configured stripe state.
    - Frontend: `NEXT_PUBLIC_STRIPE_ENABLED=true` in `seastar-app`'s
      `.env.production` only, not `.env.cn.production` (the CN build's
      env-swap pipeline already bakes `NEXT_PUBLIC_*` at build time) —
      hides the stripe option in `TicketForm`, checkout, and settings.
    The backend check is the authoritative one; the frontend flag is UX.
14. **Multiple keys per user, test keys allowed.** A user may store several
    `stripe_settings` rows (each with a label), including `sk_test_`/`rk_test_`
    keys — mode is auto-detected from the prefix and badged TEST MODE.
    Which key a ticket charges to is **chosen at ticket-creation time** from
    the event owner's keys, stored as `payment_methods.stripe_setting_id`.

All line references are to the tree **before** this work landed; §7 records
what was actually built and where it diverged.

---

## 1. Starting point (historical): Stripe was a non-functional stub

This was the state before the work in §7. Kept because it explains why the
design is a fresh build rather than a repair.

| Thing | State |
|---|---|
| `Stripe.api_key` | `config/initializers/stripe.rb:1` reads `STRIPE_APP_SECRET`; `.env.example:34` documents `STRIPE_SECRET_KEY`. Neither is set in `.env.production` or `.env.cn.production`. |
| Consequence | Every Stripe call raises `Stripe::AuthenticationError`. Swallowed by `rescue Stripe::StripeError` at `tickets_controller.rb:427` → permanent `"stripe payment not confirmed"`. `stripe_client_secret` has no rescue → 500. |
| `STRIPE_PUBLIC_KEY` | Read at `tickets_controller.rb:209`, defined nowhere. Always `nil`. |
| `STRIPE_WEBHOOK_SECRET` | Unset → `stripe_event_verified?` (`tickets_controller.rb:489`) returns `!Rails.env.production?` → in production all webhooks are ignored. |
| Frontend | No `@stripe/stripe-js`. `getStripeClientSecret` / `getStripeConfig` (`packages/sola-sdk/src/event/ticket.ts:251,264`) have zero callers. `TicketForm.tsx:510` filters `stripe` out of organizer options. `DialogTicket.tsx` implements only the EVM PayHub path. |

No live money, no migration burden — hence a fresh design. All five rows
above are now resolved (§7.1).

---

## 2. Target architecture

### 2.1 Per-organizer Stripe accounts via `stripe_settings` (decided)

Each organizer connects their **own** Stripe account by saving their own API
key in personal settings. Every organizer is their own merchant-of-record —
their Stripe account receives the money, handles payouts, taxes, and
chargebacks directly. The platform routes orders to the right account and
never touches the funds.

This is the modern version of what `sails` half-built —
`Config(name: stripe_public_key | stripe_secret_key, group_id)`
(`sails/app/models/config.rb:5`) with the lookup left as a todo
(`sails/app/controllers/api/ticket_controller.rb:286`).

**A user can have multiple keys** (decided): e.g. one test key and one live
key, or different Stripe accounts for different events. Each row is one key;
the ticket creator **chooses which key at ticket-creation time** (see below).

New table `stripe_settings`:

```
stripe_settings
  id            (tsid, like everything else)
  user_id       null: false, index (NOT unique — multiple keys per user)
  name          user-facing label ("My company", "Test") shown in pickers
  secret_key    plaintext by decision — only the masked tail ever leaves the server
  webhook_secret per-endpoint signing secret, see §2.3
  webhook_endpoint_id  Stripe we_… — so the endpoint can be removed with the key
  account_id    Stripe acct_… — captured at validation time, for display/reconciliation
  mode          live | test — auto-detected from the key prefix (sk_test_/rk_test_),
                shown as a TEST MODE badge everywhere the key or its tickets appear
  currency      default currency for this key's checkouts
  status        active | invalid  — flipped when a call fails with AuthenticationError
  created_at / updated_at
```

**Key selection at ticket creation** (decided): `payment_methods` gains a
`stripe_setting_id` column. When adding a stripe payment method to a ticket,
the creator picks from the **event owner's** active keys (shown as label +
masked tail + mode badge — never the secret; safe to show to a co-host or
manager editing the ticket). Single-key owners get it preselected. A
test-mode key makes the whole ticket visibly TEST MODE in the organizer UI
and event page. Webhook endpoints are already per-row (§2.3), so multiple
keys need no extra webhook design.

Handling rules for the key:

- **Stored plaintext — no encryption at rest** (decided 2026-07-30,
  superseding the earlier encrypt-at-rest plan; no `AR_ENCRYPTION_*` keys
  needed). Remaining protections: masked-only serialization, parameter-log
  filtering, and the restricted-key recommendation.
- **Never serialize the secret.** No blueprint ever includes `secret_key` /
  `webhook_secret`; the settings UI shows only a masked tail (`sk_live_…abc4`)
  and the validation status.
- **Validate on save**: call `Stripe::Account.retrieve` (or `Balance`) with
  the submitted key; store `account_id` from the response; reject keys that
  fail. Test keys are allowed and badged (decision #14).
- **Scoped client per call**: `Stripe::StripeClient.new(api_key: setting.secret_key)`
  (or per-request `stripe_account`/key options) — never mutate the global
  `Stripe.api_key`, which is process-wide and races across threads.
  `config/initializers/stripe.rb` keeps only `api_version` and
  `max_network_retries`; the global key disappears.

Trade-off, stated once for the record: the platform custodies other people's
live secret keys. A leaked DB + encryption key = attacker can refund/move
money on every connected account. Mitigations: encryption at rest, never
logging the key (`filter_parameter_logging`), masked display, and documenting
that organizers should create a **restricted key** (Stripe supports scoped
keys — charges+refunds+checkout only) rather than their full secret key.
Recommending restricted keys in the settings UI copy costs nothing and
meaningfully caps the blast radius.

**Key resolution for an order (decided)**: the **event owner's**
`stripe_settings`. If the event owner has no active setting, a stripe payment
method cannot be added to the ticket — surfaced at ticket-creation time in
the UI, not discovered by a buyer at checkout. (For `group_ticket` events the
event owner is in practice the group owner, so group-ticket money lands with
the group owner without a special case.)

**Snapshot the account onto the order.** At session-creation time, stamp
`ticket_items.stripe_setting_id` (and the `account_id`) onto the order.
Everything later — sweeper verification, webhook attribution, and above all
**refunds** — must use the account that *took* the payment, resolved from the
order snapshot, never re-resolved from "current event owner". Otherwise a
rotated key, a deleted setting, or an event-ownership change strands or —
worse — misroutes verification and refunds. Corollaries:

- Deleting/replacing a `stripe_settings` row with non-final orders
  (`awaiting_payment`, or `paid` within the refund window) is blocked or at
  minimum loudly warned — without that key we can neither verify nor refund
  those orders.
- If a stored key has gone invalid (`AuthenticationError`), the sweeper marks
  the setting `status: invalid` and flags affected orders for manual
  attention instead of silently retrying forever.

### 2.2 Stripe-hosted Checkout Session (decided)

- Backend creates a `Stripe::Checkout::Session` with the organizer's key:
  `line_items` from the quoted price, `metadata.ticket_item_id`,
  `expires_at` aligned with our reservation TTL, `success_url` / `cancel_url`
  pointing back at the event page on `seastar-app`.
- Frontend **redirects** to `session.url`. Card entry, SCA/3DS, wallets,
  receipts are all on Stripe's page.
- Because there is no Elements/PaymentIntent in the browser, the frontend
  needs **no publishable key at all** — `stripe_config` and
  `getStripeClientSecret`/`getStripeConfig` (both currently dead) can be
  deleted rather than fixed.
- After redirect back, the order page **polls order status until the webhook
  (or verify fallback) confirms**. The browser never sets any state. Polling
  target: a small `GET /api/v1/tickets/item_status?id=` (owner-only) or the
  existing ticket-item read — decide in implementation, no new state either
  way.
- **One open session per order.** `checkout_session` is idempotent per
  ticket_item: if the order already has an un-expired session, return its
  URL (retrieve, check `status == "open"`) instead of minting a new one; if
  it exists but expired, expire-then-recreate. A buyer who closes the tab and
  clicks "pay" again must land on the *same* session, not orphan the old one.

### 2.3 Webhooks under per-organizer keys

Events for a purchase are emitted by the **organizer's** account, so one
platform-level webhook secret cannot verify them. Plan:

- One endpoint: `POST /api/v1/webhooks/stripe/:stripe_setting_id`.
- When a user saves a valid key, the backend **programmatically creates the
  webhook endpoint** on their account
  (`Stripe::WebhookEndpoint.create(url: …/webhooks/stripe/<id>, enabled_events: […])`)
  — the response contains the endpoint's signing `secret`, returned **only at
  creation time**; store it encrypted in `stripe_settings.webhook_secret`.
  No manual dashboard steps for the user.
- Verify each delivery against that row's `webhook_secret`; persist to
  `stripe_events` (event id as PK = idempotency); enqueue; 200 fast.
- On key removal/rotation, delete the old endpoint via the API.
- Enabled events: `checkout.session.completed`, `checkout.session.expired`,
  `payment_intent.payment_failed`, `charge.refunded`,
  `charge.dispute.created`, `charge.dispute.closed`.

**Webhooks stay an optimization**: the sweeper (§3.7) re-verifies pending
orders against Stripe's API directly, so a lost webhook or a user who deleted
the endpoint from their dashboard delays confirmation, never corrupts it.

### 2.4 Non-negotiable hygiene

- Idempotency keys on every Stripe write.
- `metadata.ticket_item_id` on every Stripe object.
- Pin `Stripe.api_version` (sails pinned `2020-08-27`; soon pins nothing —
  payload shapes shift silently when an account's default version upgrades).
  With per-organizer accounts this matters *more*: different accounts have
  different default versions; pinning makes payloads uniform.
- `Stripe.max_network_retries = 2`.
- Integer minor units + explicit `currency`; verify `amount_total` **and**
  `currency` server-side before confirming.

---

## 3. Findings in the original code — all fixed

Ordered by how much money or data each could cost. Retained as the record of
what was wrong and why the fix is shaped the way it is; see §7 for the
commits.

### 3.1 Ticket orders

1. **Authorization hole**: `stripe_client_secret` (`tickets_controller.rb:196-205`)
   does `TicketItem.find` with no ownership check — any authenticated user can
   mint a client_secret for anyone's order. (Moot once the endpoint is deleted
   in favour of Checkout Sessions, but do not ship anything in between.)
2. **`STRIPE_MIN_CENTS = 400` gives tickets away**: `:473` zeroes any stripe
   amount under $4 and `:474` marks it `succeeded` — a $3.50 ticket, or any
   ticket a coupon discounts below $4, becomes free and instantly confirmed.
   Stripe's real minimum is $0.50. Carried verbatim from
   `sails/app/controllers/api/ticket_controller.rb:85`.
   **Fix (decided)**: delete the waiver; instead **validate at ticket
   creation** — a stripe payment method with `price < STRIPE_MIN_CENTS` is
   rejected with an error telling the organizer to use crypto payment for
   sub-minimum prices (model validation on `PaymentMethod`, surfaced through
   the ticket create/update endpoints and mirrored client-side in
   `TicketForm`). The residual checkout edge — a coupon discounting a valid
   price into `(0, min)` — is covered by decision #9: reject the coupon,
   allow exactly 0.
3. **Silent intent-id loss**: `:201` non-bang `update(txhash: intent.id)` —
   a failure is swallowed, the caller still gets a client_secret, customer
   pays, webhook can't find the order. Repeat calls orphan earlier intents.
4. **`txhash` overloaded** — carries on-chain hashes and Stripe ids under one
   unique index. Split: `payment_provider` + `provider_ref`; `txhash` stays
   crypto-only.
5. **Currency hardcoded** `"usd"` at `:200`; no currency column anywhere.

### 3.2 Refunds — there is no refund path at all

- `TicketItem` statuses (`ticket_item.rb:10`) have no refunded/disputed states;
  `cancel_unpaid_item` refuses anything but `pending`; no `Stripe::Refund`
  call, no refunds table, no organizer endpoint.
- sails carried the todo (`event_controller.rb:480`); it arrived unimplemented.
- Knock-on: `confirm_payment!` auto-joins the buyer to the group
  (`ticket_item.rb:57`); a refund must decide whether to revoke that
  membership (§6.3).

### 3.3 Resource locking

1. `Ticket#reserve!` (`ticket.rb:17`) is correct — row lock, non-negative,
   released on every rsvp failure path. Keep.
2. **`TicketItem#timeout` has zero callers** — no sweeper job, cron disabled
   (`good_job.rb:31`), no `reserved_until` column. Every abandoned checkout
   permanently burns a quantity unit, a `participant_count`, and a coupon
   usage.
3. **Venue capacity is racy** — `:69-71` reads `participant_count`, `:105`
   increments it; not atomic. Concurrent RSVPs oversell.

### 3.4 Coupons

1. **`applicable_ticket_ids` never enforced** *(confirmed fix)* — permitted
   (`:508`), serialized (`coupon_blueprint.rb:5`), but `build_paid_ticket_item:457`
   looks up by `event_id`+`code` only; a tier-scoped coupon works on every tier.
   Fix: after lookup, reject when
   `coupon.applicable_ticket_ids.present? && !coupon.applicable_ticket_ids.include?(@ticket.id)`;
   same check in `coupon_price` so the quote agrees with checkout.
2. **`coupons.removed` never read** *(confirmed fix)* — `Coupon#available?`
   (`coupon.rb:11`) ignores it; a "deleted" coupon still redeems. Fix: first
   line of `available?` returns false when `removed`. Also make `set_coupon`'s
   `_destroy` actually set `removed: true` (soft delete) — today `_destroy` is
   permitted (`:507`) but `coupons_attributes=` doesn't exist unless the model
   declares it; verify that path while fixing.
3. No non-expiring coupons — `assign_defaults` (`coupon.rb:51`) forces
   `expires_at = 30.days.from_now` when blank.
4. Fiat detection by chain name (`coupon.rb:37`,
   `chain == "stripe" || chain.nil?`) — should key off a
   `payment_methods.currency`/decimals column, not a chain string.
5. Pricing math duplicated between `coupon_price` (`:276`) and
   `build_paid_ticket_item` (`:467`) — one `Ticketing::Quote` for both.
6. `consume_coupon!` (`:359-367`) is correct (row-locked re-check +
   `CouponUnavailable` rollback). Leave alone.

### 3.5 Webhook handling (current endpoint)

- `payment_intent.canceled` branch is dead — `:178` digs
  `data.object.payment_intent`, but for that event `data.object` *is* the
  intent (`id`, not `payment_intent`); never fires.
- Only `charge.*` handled; the verified `construct_event` return value is
  discarded (`:491`) and the handler reads unverified `params`.
- No idempotency store; processing inline in the request.
- **`set_payment_status` (`:153-172`) must stop accepting stripe orders**:
  authenticated by the shared `NEXT_TOKEN` and it *skips verification
  entirely* for `chain == "stripe"` (`:166`) — anyone holding that token can
  mint paid tickets.

### 3.6 State machine — redesigned for both rails (decided)

One order model (`ticket_items`) covering fiat and crypto, with the
provider-specific part isolated behind `payment_provider`:

```
                      ┌────────────────────────────────────────────────┐
free/comp ────────────┤                                                │
                      ▼                                                │
reserved ──(session/intent created)──► awaiting_payment ──(verified)──► paid
   │                                        │                            │
   │                                        ├─(payment_failed)──► awaiting_payment   (retry)
   │                                        │                            ├─(refund verified)──► refunded | partially_refunded
   └──(sweeper TTL │ session.expired │ user cancel)──► expired | cancelled
                                                                         └─(dispute.created)──► disputed ──(dispute.closed won)──► paid
```

- **States** *(implementation note, Phase 3)*: the wire keeps the existing
  names — `pending` (= awaiting_payment), `succeeded` (= paid), `timeout`
  (= expired), `cancelled` — because the deployed frontend/SDK match on
  those strings and renaming is cosmetic; `refunded`, `partially_refunded`,
  `disputed` are added. The conceptual model below is unchanged.
  Original naming for reference: `reserved`, `awaiting_payment`, `paid`,
  `cancelled`, `expired`, `refunded`, `partially_refunded`, `disputed`.
  Legacy mapping for existing rows: `pending → awaiting_payment`, `succeeded → paid`,
  `timeout → expired`, `cancelled → cancelled`. `unbounded` (sails' "granted
  to an email with no account yet, waiting to be claimed" state) is
  **removed entirely** (decided 2026-07-30): the grant-to-unregistered-email
  flow is fully replaced by `GroupInvite` + auto-accept-on-verify; soon
  writes no new `unbounded` rows and has no claim path for old ones. The
  **227 imported legacy rows are deleted** in the status migration — they
  are 2024-era unclaimed grants, deliberately not carried forward (no
  GroupInvite conversion). Then the status leaves the vocabulary.
- **Columns**: `payment_provider` (`stripe | evm | free`), `provider_ref`
  (Checkout Session / PaymentIntent id, or crypto txhash), `reserved_until`,
  `released_at`, `currency`, `paid_at`.
- **Rules**:
  - Transitions only through `Ticketing::Order#transition!(to, …)` — one
    method asserting the allowed-transition table, writing an audit row.
  - Inventory (quantity, participant_count, coupon usage) released **exactly
    once**, guarded by `released_at` — never inferred from status.
  - `paid` is set only after **server-side verification**: for stripe, a
    verified webhook or `checkout.Session/PaymentIntent.retrieve`; for
    crypto, `EvmPaymentVerifier` — both rails converge on the same
    transition, which is what makes the future crypto refactor a drop-in.
  - Dispute does **not** auto-release inventory; refund releases per policy
    (§6.3).
- **Crypto rail room**: the current crypto flow (client submits txhash →
  `verify_payment`) plugs in as
  `Payments::Evm::Verify → order.transition!(:paid)`. A future refactor
  (watcher service, deposit-address model, whatever) only replaces the
  verifier, not the order model. `set_payment_status`'s crypto use survives
  as a thin wrapper over the same transition; its stripe use is removed.

### 3.7 Cleanup / reconciliation

Nothing exists today. Needed:

- `reserved_until` set at reservation, aligned with the Checkout Session's
  `expires_at` (30 min floor).
- `enable_cron = true` + `Ticketing::ExpireStaleOrders` every 5 min: for each
  overdue `reserved`/`awaiting_payment` order, **ask Stripe first**
  (retrieve session/intent — a payment may have landed while a webhook was
  lost), then either confirm or expire; release exactly once via
  `released_at`. Crypto orders get the same sweep with their own verifier.
- Reverse reconciliation in the same job: locally `paid` but
  refunded/disputed at Stripe.
- Daily per-organizer report: local paid count/sum vs
  `Checkout::Session.list` on their account.
- Constraint: GoodJob runs async in Puma, `GOOD_JOB_MAX_THREADS=1`, 22 usable
  DB connections total (see CLAUDE.md). Webhook + sweeper jobs share that one
  thread with mail. Dedicated queue, measure before raising any pool.

---

## 4. Phased plan (all phases built — see §7)

### Phase 1 — coupon fixes (confirmed, independent, can ship first)

`applicable_ticket_ids` enforcement + `removed` honoured (§3.4.1–2), with
tests. No schema change. Also kill the `STRIPE_MIN_CENTS` waiver in the same
pass: remove the zero-out at `:473` and add the creation-time
`PaymentMethod` price validation (decision #8).

### Phase 2 — migrations

- `stripe_settings` (§2.1) — includes setting up Active Record encryption.
- `ticket_items`: `payment_provider`, `provider_ref`, `reserved_until`,
  `released_at`, `currency`, `paid_at`; status vocabulary migrated (§3.6),
  including **deleting** the 227 legacy `unbounded` rows (decided — a
  destructive prod-data step, so the migration logs the deleted ids and the
  deploy waits for explicit go-ahead per the working agreements).
- `payment_methods`: `stripe_setting_id` (§2.1 key selection).
- `stripe_events` (event id PK, type, payload, processed_at, error).
- `refunds` (ticket_item_id, provider_ref, amount, currency, reason, status,
  requested_by_user_id).
- `payment_methods`: `currency`.
- `coupons`: allow null `expires_at`.

### Phase 3 — service layer + state machine

`app/services/` (`Ticketing::Reserve`, `Ticketing::Quote`,
`Ticketing::Order` transitions, `Ticketing::Expire`,
`Payments::Stripe::{Client, CreateCheckoutSession, HandleEvent, Refund}`,
`Payments::Evm::Verify` wrapping the existing verifier).
`tickets_controller.rb` (511 lines, three rails, two webhooks) slims to HTTP
handling.

### Phase 4 — stripe_settings UI + API

`GET/POST/PATCH/DELETE /api/v1/stripe_settings` (own rows only; masked
read; list returns label + tail + mode + status for pickers), validation via
`Account.retrieve` on create/update, programmatic webhook endpoint creation
(§2.3), deletion blocked while non-final orders reference the row (§2.1).
`seastar-app`: settings page (multi-key list, add/remove, TEST MODE badges)
+ the key picker in `TicketForm`'s stripe payment-method editor. Organizer-
facing copy recommends restricted keys.

### Phase 5 — checkout flow

`POST /api/v1/tickets/checkout_session` (replaces `stripe_client_secret`;
ownership-checked), rsvp path branches: free → instant paid; crypto →
unchanged; stripe → session + redirect URL. Frontend: un-filter stripe in
`TicketForm.tsx:510` gated on the organizer having an active
`stripe_settings`; DialogTicket redirects; return page polls. Delete dead SDK
functions.

### Phase 6 — webhooks + sweeper

§2.3 endpoint + `stripe_events` + job; §3.7 sweeper + reconciliation;
`set_payment_status` rejects stripe.

### Phase 7 — refunds

`POST /api/v1/tickets/:ticket_item_id/refund`, authorized by a new
`EventPolicy#refund?`: event owner or co-host (`EventRole role: "manager"`);
plus the group owner when `ticket_type == "group"`. Note this is *narrower*
than `update?` — group managers do not get refund rights on regular events.
`Stripe::Refund.create` with the key **snapshotted on the order** (§2.1) +
idempotency key, `pending` refund row finalized by `charge.refunded`.
Side-effects per decision #10: full refund releases quantity, returns coupon
usage, cancels the participant (decrementing `participant_count`), revokes
the group-ticket auto-join membership; partial refund moves money only.
Concurrent-click guard per §6.6.

### Phase 8 — tests

stripe-mock / fixture payloads with computed signatures (test env currently
bypasses verification entirely — blank secret short-circuits to true);
rewrite `tickets_controller_test.rb:717-833`; add duplicate delivery,
out-of-order (success after expiry), amount/currency mismatch, concurrent
RSVP on `quantity: 1`, refund flow, key-validation failures, webhook from a
rotated/deleted key.

---

## 5. Quick wins (done, folded into the phases above)

1. `STRIPE_APP_SECRET` vs `STRIPE_SECRET_KEY` mismatch (moot after
   `stripe_settings`, but fix `.env.example` now).
2. `payment_intent.canceled` dead branch (`:178`).
3. Pin `Stripe.api_version`, `max_network_retries = 2`.
4. `set_payment_status`: reject `chain == "stripe"` (`:166`).
5. Crude 30-min sweeper for `TicketItem#timeout` until the real one lands.

---

## 6. Open questions

Resolved (all now in the decision list / design sections above): key
resolution, refund authorization, restricted keys, sub-minimum prices,
coupon floor (≥ $4 or exactly 0), full-refund side-effects (release all
four), full-refund-only UI, organizer-initiated-only refunds, SG-only
deployment gating (`STRIPE_ENABLED` / `NEXT_PUBLIC_STRIPE_ENABLED`),
multiple keys per user with test keys allowed (decision #14), legacy
`unbounded` disposition (§3.6: delete the 227 legacy rows outright —
GroupInvite already covers the flow — and drop the status).

The remaining items below were **all accepted as proposed** (2026-07-30) —
kept here with their rationale; they are decisions now, not questions:

1. **Currency scope.** Per `stripe_settings` (one currency per seller) or per
   `payment_method` (per-ticket)? Proposal: per stripe_settings for v1;
   `payment_methods.currency` column added now but single-valued.
2. **Webhook fallback aggressiveness.** If programmatic endpoint creation
   fails (e.g. a restricted key without webhook-endpoint scope — possible now
   that any key type is accepted), block saving the key, or accept it and run
   in sweeper-only mode (confirmation latency = sweep interval)? Proposal:
   accept + surface "delayed confirmation" in settings.
3. **Buyer email receipts** — rely on Stripe's receipt (sent from the event
   owner's account) or keep sending our own `EventMailer.ticket_purchased`
   too? Proposal: both; ours is the ticket, theirs is the payment receipt.
4. **Concurrent refund clicks.** Owner and co-host both hit "refund" at
   once. Proposal: unique partial index on `refunds(ticket_item_id) where
   status in ('pending','succeeded')` for full refunds + the Stripe
   idempotency key — second click gets "refund already in progress". Cheap,
   do it.
5. **Session TTL vs reservation TTL.** Checkout Sessions live ≥ 30 min
   (Stripe's floor). That forces stripe reservations to hold inventory ~35
   min (session TTL + slack), while crypto/free could expire faster. One
   uniform TTL (simpler) or per-rail (`stripe: 35m, evm: 15m`)? Proposal:
   uniform 35 min for v1 — scarcity-critical events are rare here, and one
   TTL means one sweeper rule.

---

## 7. What shipped (2026-07-30)

All phases are built; `bin/rails test` is green at 739 runs. **Not deployed
yet** — SG needs `ginger deploy`, and that deploy runs the migration which
deletes the legacy `unbounded` rows.

### 7.1 Backend commits, in order

| Commit | Contents |
|---|---|
| `ae8a143` | Phase 1: coupon scoping + soft delete, `STRIPE_MIN_CENTS` waiver replaced by creation-time validation |
| `f44af53` | Phase 2 schema: `stripe_settings`, `stripe_events`, `refunds`, order columns, legacy `unbounded` deleted |
| `23c6a20` | Phase 3: order state machine + `Ticketing::Quote` |
| `0526b75` | Phase 4: `stripe_settings` API behind `STRIPE_ENABLED`, `StripeGateway` |
| `056f485` | Phases 5–7: checkout session, per-setting webhooks, sweeper, refunds |
| `e9177ea`, `4da9d88` | `stripe_setting_id` permitted on both ticket-creation paths |
| `324627d` | Key restricted to the event owner; at-rest encryption dropped |
| `067b5be` | Daily reconciliation + dashboard-issued refunds |
| `812980a` | `STRIPE_ENABLED` / `API_URL` in `ginger.yml` (SG only) |
| `fc847c6` | Webhook events bound to their receiving account; session creation serialized |
| `de095b2` | Rotation guard, refund balance, sweeper caution, card-only sessions |
| `2c42d15`, `552787b`, `99a2d49` | Key-validation fixes found on first real use |
| `293cddc`, `65be293`, `d9f7795` | Participant: registration vs check-in, soft delete, state machine |
| `dacb126` | Group ticket event made designatable |
| `beae855` | Second unpaid order for the same ticket refused |

Frontend (`seastar-app`): `6eb291f` (keys, ticket form, checkout, refunds),
`b255955` (owner's keys when editing), `53ceca9`, `68b03b4`, `5f86321`,
`d9aad23`, `5d9f611`, `e90150c`.

### 7.2 Where the implementation differs from the plan

- **No encryption at rest.** Decision #2's `encrypts` was dropped mid-build
  (superseded in §2.1): keys are plaintext, protected by masked-only
  serialization and parameter-log filtering. No `AR_ENCRYPTION_*` env keys
  are needed.
- **A restricted key that cannot read `/v1/account` is accepted**, not
  rejected. Stripe answers `PermissionError` there, which the first cut
  treated as invalid — locking users out of exactly the `rk_` keys the UI
  recommends. `account_id` is left nil for such keys.
- **The order state machine kept the legacy wire names** (`pending`,
  `succeeded`, `timeout`) rather than renaming to
  `awaiting_payment`/`paid`/`expired`, because the deployed frontend matches
  on those strings. `succeeded → cancelled` is permitted for **free** orders
  only (nothing to refund); `transition!` enforces that, not just the
  controller.
- **Every webhook lookup is bound to the receiving account.** Not in the
  original design: `metadata.ticket_item_id` is attacker-controlled at
  session creation, so a validly-signed event from account A could otherwise
  confirm, expire or "refund" an order whose money sits in account B.
  Mismatches are recorded on the `stripe_event` and transition nothing.
- **Checkout-session creation runs under the order's row lock.** Two
  double-clicked requests could otherwise both mint payable sessions for one
  order.
- **The sweeper never expires an order it could not ask Stripe about.** An
  outage or an invalid key is not evidence of non-payment; such orders are
  skipped with a warning until Stripe answers.
- **Sessions are card-only** (`payment_method_types: ["card"]`). Async rails
  would introduce a complete-but-unpaid limbo plus `async_payment_*` events
  this integration does not handle.
- **`refunds.full_refund`**, not `full` — `full` is a reserved word in the
  index predicate.
- **The group ticket event is designated by `groups.group_ticket_event_id`
  alone** (`dacb126`). It was previously readable but unsettable, so
  membership-granting tickets could not be turned on at all; and
  `Ticket#inherit_group_ticket_type` keyed off `kind == "group_ticket"`, a
  value nothing ever wrote, so it had never fired. `kind` means the event's
  category and carries no ticket meaning. Managers designate it from the
  event form's ticket section; at most one per group.

### 7.3 Bugs found during the build that the plan had not predicted

Beyond §3's list:

1. **Buying a ticket bypassed approval entirely.** `rsvp` hardcoded
   `status: "attending"` and never consulted `require_approval`, `form_id`,
   or the ticket's own `need_approval` — while the free join path honoured
   all three. Paying now lands in `pending` and holds no seat until approved.
   (`tickets.need_approval` had been permitted but never enforced anywhere.)
2. **`register_time` meant two things.** RSVP stamped it as the registration
   time; the door-scan `check_in` re-stamped it as the check-in time. Anything
   reading it as "checked in" therefore saw every registrant as checked in.
   Split into `registered_at` + `checked_in_at`.
3. **Cancelling participation 500'd on every ticketed event.**
   `participants#destroy` hard-deleted the row while
   `ticket_items.participant_id` still referenced it. Withdrawal is now a
   soft delete (`cancelled` + `cancelled_at`); a paid order deliberately
   stays `succeeded` so the organizer can still refund it.
4. **Cancelling one order withdrew the whole participant**, dropping an
   attendance already paid for when a second checkout was abandoned.
5. **`approve`/`reject` never advanced the application form's submission**, so
   a decided applicant still read as `pending` in the submissions list.
6. **`rsvp` reserved inventory on every call**, so a double-click — or a retry
   during the post-payment confirmation window — held two units for one seat.
   Guarded per-ticket, so a different ticket type stays purchasable.
7. **`participants.ticket_id` was write-only** and could not be correct once a
   participant holds orders for several ticket types. Dropped.
8. **`payment_status` had four independent writers** and could contradict the
   orders it described. It is now derived
   (`Participant#refresh_payment_status!`).

### 7.4 Still open

- **Nothing has touched a real Stripe API** except key validation, which is
  how `2c42d15` (a wrong `Account.retrieve` signature) and `552787b` were
  found. Expect more field-level surprises on the first end-to-end test-mode
  run: session parameters, real webhook payload shapes, `expand:
  latest_charge`.
- **Webhook signature verification has only been exercised against
  library-computed signatures**, never a real Stripe delivery (timestamp
  tolerance, body encoding).
- **The frontend has been typechecked, linted and built, but not clicked
  through** end to end.
- **Single-threaded GoodJob**: webhook, sweeper, reconciliation and mail jobs
  share one thread and a 22-connection budget. Queue latency under real load
  is unmeasured.
- **Buyer-facing "continue payment"**: the UI now blocks a second order while
  one is pending, but offers no button to resume the existing Checkout
  Session (the API already returns it). Worth adding.
- **Deployment prerequisites**: `STRIPE_ENABLED` and `API_URL` are in
  `ginger.yml`; `NEXT_PUBLIC_STRIPE_ENABLED` is in `seastar-app`'s
  (gitignored) `.env.production`. The first deploy also deletes the 227
  legacy `unbounded` ticket_items.

### 7.5 Suggested first-run checklist (test mode)

1. Organizer saves an `sk_test_`/`rk_test_` key in personal settings →
   expect TEST MODE, and `delayed_confirmation` on any host where Stripe
   cannot register the webhook (localhost).
2. Create an event with a card ticket ≥ $4, key preselected.
3. Buy with `4242 4242 4242 4242` → redirected to Stripe, back to the event
   page, banner polls until confirmed.
4. Refund from the order list → `charge.refunded` finalizes; seat, coupon and
   group membership released.
5. Refund one from the Stripe dashboard instead → the daily reconciliation
   job picks it up.
6. Abandon a checkout → the sweeper expires it and returns the hold.

---

## 8. The order audit trail (2026-08-08)

§3.6 specified that transitions would go "through `Ticketing::Order#transition!`
— one method asserting the allowed-transition table, **writing an audit row**".
The transition table shipped; the audit row did not. This is that half, built
once WeChat Pay made a second money rail live.

Rail-agnostic on purpose — it is documented here rather than in
WECHAT_INTEGRATION because it describes the order model, not a provider.

### 8.1 Why a current status was not enough

An order keeps one status. Everything about its past was being reconstructed
from timestamps, which turned out to be both incomplete and quietly wrong:

- **`updated_at` is not the time of a transition.** It is the last write of any
  kind. `apply_refund_success!` transitions and then writes `released_at`, so
  the refund's own timestamp was already gone by the time anyone looked.
- **A lost dispute was indistinguishable from a voluntary refund.** Losing at
  the provider runs `transition!(:refunded)` with **no Refund row**
  (`stripe_webhook_job.rb`), so afterwards it looks exactly like an organizer
  refunding on purpose. Those two facts mean opposite things — one is a
  decision, the other is money taken back.
- **Retries left nothing at all.** A buyer who abandons the payment sheet and
  pays again never changes status.
- **Nothing recorded who acted.** `refunds.requested_by_user_id` covered
  refunds and only refunds; a sweeper expiry, a webhook confirmation and a
  manual cancel were indistinguishable afterwards.

### 8.2 Shape

`ticketing_activities`, model `Ticketing::Activity`. Named for the domain
rather than the table: `Ticketing` is already the namespace for the services
and the sweeper, and `Ticketing::Activity` does not collide with the top-level
`Activity`, which is the user notification feed.

Two decisions worth keeping:

- **The subject is polymorphic AND `NOT NULL`.** Polymorphic so a coupon
  redemption or a ticket-type change can live here without a migration; not
  null because the property that makes this usable in a chargeback is *"this
  subject's history is exactly these rows"*. A log with an optional owner
  degrades into a dumping ground and stops being evidence.
- **`action` is the required column, not `to_status`.** The vocabulary is
  deliberately wider than the status machine, because the events that most
  need explaining afterwards are not transitions: `payment_retried`,
  `callback_rejected`, `prepay_created`. A table called "transitions" would
  have missed precisely the interesting cases — which is why it isn't one.

Rows are **append-only**, enforced by `readonly?` rather than by convention: a
row is an observation, and observations are not edited. Anything that changes
is a later row.

`Ticketing::Activity.record!` never raises into its caller. A lost audit row
is bad; a lost payment confirmation is worse.

### 8.3 The bug this found

Designing it surfaced the only place in the codebase that bypassed
`transition!`: `add_group_ticket_item` did `update(status: "succeeded")`
directly. That skipped the allowed-transition table, so **re-granting a ticket
to an email whose order had expired silently reopened a closed order** — one
whose seat and coupon had already been handed back, leaving two people holding
one unit. It goes through `transition!` now and answers with an error.

### 8.4 Backfill

`rails ticketing:backfill` reconstructs history for orders predating the table
(1450 locally, 5 on CN). Every row is stamped `source: "backfill"` and
`Ticketing::Activity.recorded` excludes them, because a derivation must never
be able to pass as an observation — the frontend labels them "(estimated)".

They inherit every weakness listed in §8.1: approximate closure times, no
retries, and lost disputes rendered as ordinary refunds. What could not be
recovered was not invented.

### 8.5 Accountability

A refund is the one organizer action that moves money out, so the actor is
recorded **twice** — `refunds.requested_by_user_id` and the `refund_requested`
activity — and both are rendered by name, not as a bare id. One place to look
is one place to lose.

The **absence** of an actor is equally deliberate: a callback or a sweeper run
has none, so `refund_succeeded` shows no name. That blank is what distinguishes
"a manager ordered this refund" from "the provider settled it".
