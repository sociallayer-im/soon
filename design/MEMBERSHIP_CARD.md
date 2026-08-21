# 会员卡 (Membership Card) — Design

Status: v1 (fixed 30-day) implemented on branch `feature/membership-card`.
v2 (configurable duration + multiple tiers) approved 2026-08-22, extending
the same branch.

## v2 addendum: multiple durations and tiers

Requirement: durations besides 30 days (7 / 30 / 365, or any custom day
count), and multiple card "tiers" at different prices (e.g. Silver/Gold/
Platinum).

**Tiers need no new modeling.** A `Ticket` is already "one buyable item, one
price (via `payment_methods`), one event" and an event already supports
several `Ticket` rows — that's exactly what "多种卡等级，不同的价格" is. A
tier is just another `membership_card` ticket on the group's ticket event
with its own title/price/duration. No schema change for tiers themselves.

**Duration becomes a per-ticket field**, not a global constant:
- Migration: `add_column :tickets, :membership_duration_days, :integer,
  default: 30, null: false`. Only meaningful when `ticket_type ==
  "membership_card"`; ignored otherwise (mirrors how `days_allowed`/
  `tracks_allowed` are only meaningful for `"group"`).
- `TicketItem#confirm_payment!`'s membership_card branch now calls
  `group.grant_or_extend_membership(user_id, ticket.membership_duration_days.days)`
  instead of the old hardcoded `MEMBERSHIP_CARD_DURATION` constant (removed).
  `Group#grant_or_extend_membership` already took `duration` as a parameter,
  so no change needed there — the stacking-onto-existing-expiry semantics
  from v1 apply unchanged, just with whatever duration *this* ticket carries.
  A user who buys a 7-day card then a 365-day card gets `now + 7d + 365d`, in
  that purchase order — durations from different tiers stack just like same-
  tier renewals do, since the grant only ever reads "this ticket's duration"
  and "the membership's current expiry," never which ticket funded either.
- Frontend `TicketForm.tsx`: the "Monthly membership card" toggle becomes a
  "Membership card" toggle plus a duration control (preset chips: 7/30/365
  days, falling back to a plain number input for a custom day count).
  Renamed lang keys accordingly (`"Monthly membership card"` →
  `"Membership card"`).
- `TabMembers.tsx`'s "Member until" display needs no change — it already
  renders whatever `expires_at` ended up being, regardless of which
  duration(s) produced it.

## Problem

`Ticket`/`TicketItem`/`Membership` already exist. Buying a `ticket_type:
"group"` ticket auto-grants a permanent `Membership` row
(`TicketItem#confirm_payment!` → `group.add_member`). This is fine for
one-time "become a member" tickets, but there's no way to sell a
**time-limited, repeatably-purchasable** membership — `memberships` has no
expiry, and `confirm_payment!`'s `unless group.memberships.exists?` guard
makes a second purchase a no-op.

## Decisions (confirmed with user)

1. **Renewal stacks on the existing expiry**, not from "now": buying while
   still active extends the current `expires_at` by 30 days (does not waste
   remaining time). Buying while lapsed/never-a-member starts fresh from now.
2. **Refunds do not shorten/revoke membership.** MVP explicitly skips this —
   stacked purchases make "which 30-day slice do we claw back" ambiguous.
   Revisit if abuse shows up.
3. **New `ticket_type: "membership_card"`**, fully separate from the existing
   `"group"` ticket_type. Existing group-ticket permanent-membership behavior
   is untouched.
4. **Not in scope for MVP**: no cron/sweeper job. Expiry is enforced live via
   `Membership#active?` at read time (`expires_at.nil? || expires_at.future?`),
   so a lapsed membership just stops passing the check — nothing needs to
   proactively "close" the row.

## Backend changes (`soon`)

- Migration: `add_column :memberships, :expires_at, :datetime` (nullable).
  `NULL` = permanent (existing manager/owner/group-ticket rows keep current
  behavior unchanged).
- `Membership#active?`: `role.present? && (expires_at.nil? || expires_at.future?)`.
  Replaces raw `memberships.exists?` at every permission-gate call site,
  notably `TicketsController#member_of_required_group?` and
  `TicketItem#confirm_payment!`'s idempotency guard — so an expired member
  loses gated access automatically, and a lapsed member can re-trigger a
  fresh grant.
- `Ticket`: `ticket_type` gains `"membership_card"` alongside existing
  `"event"`/`"group"`.
- `TicketItem#confirm_payment!`: new branch for `ticket_type ==
  "membership_card"` → `group.grant_or_extend_membership(user_id, 30.days)`,
  computing `expires_at = [Time.current, existing_membership&.expires_at]
  .compact.max + 30.days`. Existing `"group"` branch untouched.
- `rsvp`'s pending-order dedupe is already per-ticket and already compatible
  with repeat *completed* purchases — no change needed.
- Refund path (`revoke_purchase_membership!` etc.) — no change per decision 2.

## Frontend changes (`seastar-app`)

- Ticket-type picker (group ticket settings form) — add "Membership Card"
  option; duration fixed at 30 days for MVP (not user-configurable yet).
- SDK: extend `ticket_type` union in `packages/sola-sdk/src/event/types.ts`
  (and wherever `TicketDraft`/`Ticket` types live) with `"membership_card"`.
- Purchase flow: reuses existing `rsvp`/`DialogTicket` as-is — same payment
  rails (Stripe/WeChat/on-chain), no new purchase UI needed.
- Membership display: group page or "my tickets" — show "Member until
  `<expires_at>`" plus a renew/buy-again CTA when the group has an active
  `membership_card` ticket.

## Explicitly out of scope for this pass

- Configurable duration (fixed 30 days only).
- Refund-driven expiry adjustment.
- Any background job to lapse/notify on expiry.
- Migrating existing permanent group-ticket memberships to the expiring model.
