# Payments plan — Stripe integration for `soon`

Status: **assessment + proposal**, nothing here is implemented yet.
Written 2026-07-30. Scope: fiat (Stripe) ticketing in `soon`, plus the
`seastar-app` / `sola-sdk` surface it needs. The crypto (EVM PayHub) rail is
in scope only where it shares code with fiat — coupons, reservations, order
state.

All line references are to the tree as of 2026-07-30.

---

## 1. Headline: Stripe is a non-functional stub, not a working integration

Before any design critique — `soon` cannot currently take a card payment.

| Thing | State |
|---|---|
| `Stripe.api_key` | `config/initializers/stripe.rb:1` reads `STRIPE_APP_SECRET`; `.env.example:34` documents `STRIPE_SECRET_KEY`. **Neither is set** in `.env.production` or `.env.cn.production`. |
| Consequence | Every Stripe call raises `Stripe::AuthenticationError`. It is swallowed by `rescue Stripe::StripeError` at `tickets_controller.rb:427` → permanent `"stripe payment not confirmed"`. `stripe_client_secret` has no rescue → 500. |
| `STRIPE_PUBLIC_KEY` | Read at `tickets_controller.rb:209`, defined nowhere. Always `nil`. |
| `STRIPE_WEBHOOK_SECRET` | Unset → `stripe_event_verified?` (`tickets_controller.rb:489`) returns `!Rails.env.production?` → in production **all webhooks are ignored**. Fail-closed, which is correct, but it means zero webhook processing. |
| Frontend | No `@stripe/stripe-js`, no Elements. `getStripeClientSecret` / `getStripeConfig` (`packages/sola-sdk/src/event/ticket.ts:251,264`) have **zero callers**. `TicketForm.tsx:510` explicitly filters `stripe` out of the organizer's payment-method options. `DialogTicket.tsx` implements only the EVM PayHub path. |

This is good news: there is no live money and no migration burden, so the
integration can be designed properly rather than repaired.

---

## 2. Target architecture

Decisions in dependency order — #1 constrains everything below it.

### 2.1 Stripe Connect (Express) + destination charges

This product is a marketplace: group organizers sell tickets, the platform
takes a cut. Today `tickets_controller.rb:200` creates the PaymentIntent on
the **platform** account with no `on_behalf_of`, no
`transfer_data.destination`, and no `application_fee_amount`. Consequences if
shipped as-is:

- All ticket revenue lands in the platform's Stripe balance with no payout
  path to organizers.
- The platform becomes merchant-of-record for every event worldwide — tax,
  chargeback liability, refund obligations.

The crypto rail already models this correctly: `payment_methods.receiver_address`
is per-ticket. Fiat has no equivalent.

Historical note: `sails` had a `Config(name, value, group_id)` model whose
permitted names were `stripe_public_key` / `stripe_secret_key`
(`sails/app/models/config.rb:5`), with `# todo : stripe_secret_key from config`
at `sails/app/controllers/api/ticket_controller.rb:286`. The multi-tenant
intent was right; per-organizer **API keys** is the wrong implementation of it
(the platform would custody other people's secrets). Connect is the correct
version of the same idea. `soon` dropped `Config` entirely and hardcoded a
single platform-wide env key.

Required: `groups.stripe_account_id`, `groups.stripe_charges_enabled`,
`AccountLink` onboarding endpoints, and an `account.updated` webhook to keep
`stripe_charges_enabled` fresh.

### 2.2 Hosted Checkout Session over Payment Element (for v1)

Stripe hosts SCA/3DS, wallets, receipts, and address/tax collection, and emits
`checkout.session.expired` — which does half the reservation-TTL work for
free. Payment Element is the upgrade path once in-app checkout UX matters.

### 2.3 Webhook is the only source of truth

The browser's `return_url` is a UI hint, never a state transition. Persist raw
events, dedupe on Stripe's `event.id`, process in a job, return 200 fast.

### 2.4 Non-negotiable hygiene

- **Idempotency keys** on every Stripe write call.
- **`metadata.ticket_item_id`** on every Stripe object, so an order is
  resolvable even when the local write failed.
- **Pin `Stripe.api_version`.** `sails` pinned `2020-08-27`
  (`sails/app/controllers/api/ticket_controller.rb:1`); `soon` pins nothing, so
  webhook payload shapes shift silently when the account's default version is
  upgraded.
- **`Stripe.max_network_retries = 2`.**
- **Integer minor units + an explicit `currency` column.** Never a float.
  Verify `amount_received` *and* `currency` server-side before confirming.

---

## 3. Findings

Ordered within each category by how much money or data it can cost.

### 3.1 Ticket orders

1. **Authorization hole in `stripe_client_secret`.**
   `tickets_controller.rb:196-205` does `TicketItem.find(params[:ticket_item_id])`
   with **no ownership check** — any authenticated user can mint a
   `client_secret` for anyone else's order. Compare `verify_payment:126` and
   `cancel_unpaid_item:146`, both of which check
   `ticket_item.user_id == current_user.id`.

2. **`STRIPE_MIN_CENTS = 400` gives tickets away.**
   `tickets_controller.rb:473` sets `amount = 0 if selected_chain == "stripe" && amount < STRIPE_MIN_CENTS`,
   and `:474` then sets `status = "succeeded"`. A $3.50 ticket — or any ticket
   a coupon discounts below $4 — becomes **free and immediately confirmed**.
   Stripe's actual minimum charge is $0.50. Carried verbatim from
   `sails/app/controllers/api/ticket_controller.rb:85`. This is the single most
   likely way to lose real money on day one.

3. **Silent loss of the PaymentIntent id.**
   `tickets_controller.rb:201` uses non-bang `update(txhash: payment_intent.id)`.
   A validation or unique-index failure is swallowed and the caller still
   receives a `client_secret` → the customer pays and no webhook can find the
   order. There is no `metadata` fallback to recover from it either.

4. **Repeat calls orphan intents.** Each call to `stripe_client_secret` creates
   a *new* PaymentIntent and overwrites `txhash`. If the customer completes
   payment on an earlier Elements instance, that money is unlinkable to any
   order. No idempotency key, and no reuse of an existing open intent.

5. **`txhash` is overloaded.** It carries both on-chain tx hashes and Stripe
   intent ids under one unique index (`schema.rb`,
   `index_ticket_items_on_txhash_unique`). Split into `provider_ref`.

6. **Currency hardcoded** `"usd"` at `tickets_controller.rb:200`; no `currency`
   column on `ticket_items` or `payment_methods`. Multi-currency is impossible.

### 3.2 Refunds

**There is no refund path at all.**

- `TicketItem` status is `pending|unbounded|succeeded|cancelled|timeout`
  (`app/models/ticket_item.rb:10`) — no `refunded`, `partially_refunded`, or
  `disputed`.
- `cancel_unpaid_item` (`tickets_controller.rb:145`) refuses anything but
  `pending`.
- No `Stripe::Refund` call anywhere, no `refunds` table, no organizer-facing
  endpoint.
- `TicketItem#close!` (`ticket_item.rb:83`) *would* release inventory and
  coupon usage, but calling it on a succeeded item would release inventory
  without returning any money.
- `sails` carried `# todo : refund or require more action when cancelling paid participants`
  (`sails/app/controllers/api/event_controller.rb:480`). The todo came across
  unimplemented.
- Knock-on: `confirm_payment!` auto-joins the buyer to the group
  (`ticket_item.rb:57`). A refund must decide whether to revoke that
  membership; today nothing would.

### 3.3 Resource locking

1. **`Ticket#reserve!` is correct in isolation.** `app/models/ticket.rb:17`
   takes a row lock, never lets quantity go negative, and `rsvp` releases on
   every failure path (`tickets_controller.rb:94`, `:115`, `:118`). Keep this.

2. **`TicketItem#timeout` has zero callers — inventory leaks permanently.**
   `ticket_item.rb:41` is dead code. There is no sweeper job (`app/jobs/` holds
   only `application_job`, `event_attendee_mail_job`, `group_broadcast_mail_job`,
   `mail_delivery_job`), `config/initializers/good_job.rb:31` sets
   `enable_cron = false`, and `ticket_items` has no `reserved_until` column to
   sweep on. **Every abandoned checkout permanently burns one unit of
   `tickets.quantity`, one `events.participant_count`, and one coupon usage.**
   A crash between `reserve!` and the transaction commit leaks without even
   leaving a row to find.

3. **Venue capacity is racy.** `tickets_controller.rb:69-71` reads
   `@event.participant_count`, and `:105` increments it — not atomic, not under
   the ticket lock. Concurrent RSVPs oversell a capacity-limited venue.

### 3.4 Coupons

1. **`applicable_ticket_ids` is never enforced.** It is permitted
   (`tickets_controller.rb:508`) and serialized (`coupon_blueprint.rb:5`), but
   `build_paid_ticket_item:457` looks the coupon up by `event_id` + `code`
   only. A coupon scoped to one ticket tier works on every tier of the event.

2. **`coupons.removed` is never read anywhere.** `Coupon#available?`
   (`app/models/coupon.rb:11`) ignores it, so a "deleted" coupon still
   redeems.

3. **No non-expiring coupons.** `assign_defaults` (`coupon.rb:51`) forces
   `expires_at = 30.days.from_now` whenever it is blank.

4. **Fiat detection by chain name.** Amount-discount scaling branches on
   `chain == "stripe" || chain.nil?` (`coupon.rb:37`) as a stand-in for "this
   is a 2-decimal fiat amount". That belongs as a `currency` / `decimals`
   column on `payment_methods`.

5. **Pricing math is duplicated** between `coupon_price`
   (`tickets_controller.rb:276`) and `build_paid_ticket_item` (`:467`). One
   `Ticketing::Quote` should serve both, or the quote and the charge will
   drift.

6. **The usage-consumption lock is correct.** `consume_coupon!`
   (`tickets_controller.rb:359-367`) re-checks availability under a row lock so
   concurrent RSVPs cannot over-redeem the last unit, and raises
   `CouponUnavailable` to roll back. Leave it alone.

### 3.5 Order state machine

There isn't one. Status is checked ad hoc at `tickets_controller.rb:128`,
`:131`, `:145`, `:163`, `:182` and `ticket_item.rb:85`, with three payment
rails writing it. Target:

```
reserved ─(session created)→ awaiting_payment ─(payment_intent.succeeded)→ paid
   │                            │                       ├─(charge.refunded)→ refunded | partially_refunded
   │                            ├─(payment_failed)→ awaiting_payment (retryable)
   └─(sweeper | session.expired | user cancel)→ expired | cancelled
                                                         └─(dispute.created)→ disputed
```

Rules:

- Transitions happen only through the service layer, in one method, with the
  allowed set asserted.
- Every transition writes an audit row.
- Inventory is released **exactly once**, guarded by a `released_at` timestamp
  — never inferred from the status value.
- `paid` is set only by a signature-verified webhook or a server-side
  `PaymentIntent.retrieve`. Never by a client call.

A hand-rolled `TRANSITIONS` hash is sufficient at this size; the win is having
one method, not adding `state_machines-activerecord`.

### 3.6 Webhook events

1. **The `payment_intent.canceled` branch is dead code.**
   `tickets_controller.rb:178` extracts the id via
   `params.dig(:data, :object, :payment_intent)`. For that event `data.object`
   *is* the PaymentIntent — it has `id`, not `payment_intent`. `intent_id` is
   always nil, so the branch never fires.

2. **Only `charge.*` is handled** (`:183-190`: `charge.succeeded`,
   `charge.failed`, `charge.expired`). Missing entirely:
   `payment_intent.succeeded`, `payment_intent.payment_failed` (the actual
   decline signal in PaymentIntent flows), `checkout.session.completed`,
   `checkout.session.expired`, `charge.refunded`, `charge.dispute.created`,
   `charge.dispute.closed`, and `account.updated` (needed for Connect).

3. **The verified event object is discarded.**
   `stripe_event_verified?` (`:491`) calls `Stripe::Webhook.construct_event`
   and throws away its return value; the handler then reads `params`. Use the
   verified object.

4. **No idempotency store.** There is no `stripe_events` table keyed on
   `event.id`. Deduplication relies incidentally on the `status == "pending"`
   guard at `:182`, which happens to cover the success path but nothing else.

5. **Processing is inline in the request** — DB writes, `group.add_member`,
   mail enqueue. Stripe retries on any 5xx or timeout. Enqueue and return 200.

6. **`set_payment_status` should not accept stripe orders at all.**
   `tickets_controller.rb:153-172` authenticates with one shared secret
   (`NEXT_TOKEN`, `.env.production:10` — the same token that authorizes
   `auth_controller.rb:95`'s trusted-signin), and for `chain == "stripe"` it
   **skips payment verification entirely** (`:166`), flipping the order to
   succeeded on the caller's word with only `params[:amount] >= ticket_item.amount`
   as a check. Anyone holding `NEXT_TOKEN` can mint paid tickets. Once real
   Stripe webhooks exist this endpoint must reject `chain == "stripe"`.

### 3.7 Resource cleanup / reconciliation

Nothing exists. Needed:

- `reserved_until` on `ticket_items`, aligned with the Checkout Session's
  `expires_at` (sessions allow 30 min – 24 h; 30 min is the natural floor).
- `enable_cron = true` plus a 5-minute `Ticketing::ExpireStaleOrders` that,
  for each stale `reserved` / `awaiting_payment` order, **retrieves the
  PaymentIntent before expiring it** — a payment may have succeeded while a
  webhook was lost — and then releases inventory, coupon usage and
  `participant_count` exactly once.
- The same job reconciles the reverse direction: locally `paid` but
  refunded/disputed at Stripe.
- A daily reconciliation report comparing local `paid` count and sum against
  `Stripe::PaymentIntent.list`. Cheap, and it catches every failure mode above.

**The sweeper, not the webhook, is what you trust.** Webhooks are an
optimization for latency.

**Infrastructure constraint.** GoodJob runs `execution_mode :async` inside the
Puma process with `GOOD_JOB_MAX_THREADS=1` against a 22-connection Postgres
budget (see `CLAUDE.md`). Webhook jobs are cheap, but they would share that
single thread with mail delivery. Give them a dedicated queue and measure
end-to-end confirmation latency before making payment confirmation depend on
it.

---

## 4. Phased plan

### Phase 0 — decide (product, blocking)

1. Stripe Connect, or platform-collects-and-settles-out-of-band?
2. Hosted Checkout Session, or Payment Element?
3. Refund policy: who may refund; partial refunds allowed?; does a refund
   release inventory?; does it return the coupon usage?; does it revoke a
   group membership granted by a group ticket?; is the platform's
   `application_fee` refunded (`refund_application_fee`)?
4. Which currencies?

Nothing below can be built correctly without answers to 1 and 3.

### Phase 1 — migrations

- `ticket_items`: add `reserved_until`, `currency`, `payment_provider`,
  `provider_ref`, `released_at`; extend `status` with `refunded`,
  `partially_refunded`, `disputed`, `expired`. Keep `txhash` for the crypto
  rail only.
- New `stripe_events`: Stripe's `event.id` as the primary key (that alone
  provides idempotency), plus `type`, `payload` jsonb, `processed_at`, `error`.
- New `refunds`: `ticket_item_id`, `provider_ref`, `amount`, `currency`,
  `reason`, `status`, `requested_by_user_id`, timestamps.
- `groups`: add `stripe_account_id`, `stripe_charges_enabled`.
- `payment_methods`: add `currency`.
- `coupons`: allow null `expires_at`; start honouring `removed`.

### Phase 2 — service layer

`app/services/` already exists (`cloudflare_images`, `event_calendar`,
`jwt_service`) — the right home. `tickets_controller.rb` is 511 lines carrying
reservation, pricing, coupons, three payment rails and two webhook endpoints.
Split into:

- `Ticketing::Reserve` — inventory + participant + capacity, atomically
- `Ticketing::Quote` — price + coupon; the single source shared by
  `coupon_price` and `rsvp`
- `Ticketing::Expire` — the sweeper
- `Payments::Stripe::CreateCheckoutSession`
- `Payments::Stripe::HandleEvent` — one method per event type
- `Payments::Stripe::Refund`

This is what makes the state machine testable without going through HTTP.

### Phase 3 — state machine

Implement §3.5 in one place, with `released_at` guarding the
release-exactly-once rule.

### Phase 4 — webhooks

- Dedicated `Api::V1::Webhooks::StripeController`, `skip_before_action :authenticate!`.
- Use the return value of `construct_event`.
- `StripeEvent.create!(id: event.id, …)`; rescue `ActiveRecord::RecordNotUnique`
  as "already seen" and return 200 immediately.
- `StripeWebhookJob.perform_later(event.id)`; return 200 in well under a second.
- Handle: `checkout.session.completed`, `checkout.session.expired`,
  `payment_intent.succeeded`, `payment_intent.payment_failed`,
  `charge.refunded`, `charge.dispute.created`, `charge.dispute.closed`,
  `account.updated`.
- Resolve the order from `metadata.ticket_item_id` first, `provider_ref`
  second.
- Re-verify `amount_received`, `currency`, and (under Connect) the transfer
  destination against the local order before transitioning to `paid`.

### Phase 5 — reservations and cleanup

Implement §3.7: `reserved_until`, the cron sweeper that asks Stripe first, the
reverse reconciliation, and the daily report.

### Phase 6 — refunds

- `POST /api/v1/tickets/:ticket_item_id/refund`, `authorize event, :update?`
  (organizer), taking amount and reason.
- `Stripe::Refund.create(payment_intent:, amount:, reverse_transfer: true, refund_application_fee: <policy>, idempotency_key: "refund-#{ticket_item.id}-#{attempt}")`.
- Do **not** mark the order refunded synchronously. Write a `pending` refund
  row and let `charge.refunded` finalize it — refunds can fail asynchronously.
- Apply the Phase 0 decisions on inventory, coupon usage, participant status,
  and group-membership revocation.
- `charge.dispute.created` → mark `disputed`, notify, and do **not** auto-release
  inventory.

### Phase 7 — frontend (`seastar-app`)

- Un-filter `stripe` at `TicketForm.tsx:510`, gated on
  `group.stripe_charges_enabled`.
- Add Connect onboarding to organizer settings ("connect your Stripe account
  before selling fiat tickets").
- Redirect to the Checkout Session URL (no Elements bundle needed for v1), then
  land on an order page that **polls until the webhook confirms**. Never mark
  paid client-side.
- Wire up or delete `getStripeClientSecret` / `getStripeConfig`
  (`packages/sola-sdk/src/event/ticket.ts:251,264`).

### Phase 8 — tests

- Use `stripe-mock` (or `stripe-ruby-mock`); drive webhook tests with real
  fixture payloads and computed signatures.
- Tighten the test environment so genuine signature verification is exercised.
  Today `STRIPE_WEBHOOK_SECRET` is blank in test, so `stripe_event_verified?`
  short-circuits to `true` and the verification path is never covered.
- Existing tests at `test/controllers/api/v1/tickets_controller_test.rb:717-833`
  assert the current `charge.succeeded` payload shape and will need rewriting
  alongside the new event set.
- Add: duplicate webhook delivery; out-of-order delivery (success arriving
  after expiry); amount-mismatch rejection; concurrent RSVP against
  `quantity: 1`; the full refund flow.

---

## 5. Quick wins, independent of the above

Each is small, self-contained, and worth doing regardless of the Phase 0
decisions.

1. Fix the `STRIPE_APP_SECRET` vs `STRIPE_SECRET_KEY` name mismatch between
   `config/initializers/stripe.rb:1` and `.env.example:34`; document
   `STRIPE_PUBLIC_KEY`.
2. Add the ownership check to `stripe_client_secret`
   (`tickets_controller.rb:196`).
3. `update` → `update!` at `tickets_controller.rb:201`; add
   `metadata: {ticket_item_id: …}` and an idempotency key.
4. Remove or fix the dead `payment_intent.canceled` branch
   (`tickets_controller.rb:188`).
5. Enforce `coupons.removed` in `Coupon#available?` and `applicable_ticket_ids`
   in `build_paid_ticket_item`; allow a null `expires_at`.
6. Revisit or remove the `STRIPE_MIN_CENTS` free-ticket waiver
   (`tickets_controller.rb:473`).
7. Give `TicketItem#timeout` a caller — even a crude 30-minute sweeper beats
   the current permanent inventory leak.
8. Pin `Stripe.api_version` and set `Stripe.max_network_retries = 2` in
   `config/initializers/stripe.rb`.
9. Make `set_payment_status` reject `chain == "stripe"`
   (`tickets_controller.rb:166`).
