# Behavioral comparison: `sails/` vs `soon/`

This is a **functional/behavioral** audit, not a schema/scope audit — see `SAILS_COMPARISON.md`
for table inventory and porting decisions, and `CHANGELOG.md` for what's already been found and
fixed during earlier code-review passes on `soon/`. This document does not repeat anything already
documented there; it goes one layer deeper, comparing actual business logic between
`sails/app/**` and `soon/app/**` line-by-line for the domains that are genuinely ported in both
systems.

Last generated: 2026-07-29.

## How to read this

- **Match** — same real-world outcome for the same input, confirmed by reading both implementations.
- **Improved** — soon/ changed the behavior, but the change closes a real bug/gap in sails/ and is
  clearly intentional/beneficial (or already effectively required by the schema/design change).
- **DIVERGENT** — the two systems produce different real-world outcomes for the same input, and it
  does **not** appear to be an intentional, already-documented fix. These are the rows that matter
  for the migration — anyone relying on the old behavior in production will notice.
- **Confidence** — "checked both directly" means an agent read the actual current source in both
  repos for that behavior; "inferred" means partially reasoned from adjacent code/grep rather than
  full step-through.

## Executive summary — the divergences that matter most

Ranked by real-world consequence if `soon/` ships as-is:

1. **No join-time capacity enforcement in soon/ (overbooking).** sails/ hard-blocks a join once
   `event.max_participant` or `venue.capacity` is reached
   (`sails/app/controllers/api/event_controller.rb:355-361`). soon/'s
   `Api::V1::ParticipantsController#create` (`soon/app/controllers/api/v1/participants_controller.rb:10-49`)
   never checks either value, and there is no `participants_count`-equivalent counter anywhere in
   soon/'s app. Confirmed independently by two separate agents (Event/Venue pass and
   Participant pass). This is a straightforward overselling bug for any capacity-limited event.
2. **Dropped venue `start_date`/`end_date` booking window.** sails/'s `Venue` model and schema
   carry an overall availability window (`sails/app/models/venue.rb:22,38,44-53`); soon/'s `Venue`
   has no such columns (`soon/db/schema.rb`). A venue only usable during a fixed popup-city date
   range can be booked outside that range in soon/ with no rejection.
3. **Inverted parent-group authorization coverage between Event and Venue.** sails/ never grants a
   parent-group manager rights over a child group's events *or* venues
   (`sails/app/policies/event_policy.rb:5-11`, `sails/app/policies/group_policy.rb:22-24` —
   both direct-manager-only). soon/ grants parent-manager rights over **venues**
   (`soon/app/controllers/api/v1/venues_controller.rb:16` via `GroupPolicy#manage?`, which does
   include the parent) but **not** over events (`soon/app/policies/event_policy.rb:13,18` use
   `group_admin?`, which is direct-only). The result is not a straight "soon/ is more permissive"
   or "soon/ matches CLAUDE.md's contract" story — it's inconsistent in opposite directions across
   two adjacent resources in the same request path.
4. **`EventRole` (co-host/speaker) no longer grants event-edit rights.** sails/'s
   `EventPolicy#update?` consults `EventRole` for co-hosts/speakers in addition to owner/group-manager
   (`sails/app/policies/event_policy.rb:9-16`); soon/'s equivalent
   (`soon/app/policies/event_policy.rb:13`) does not, and this same policy method gates
   `approve`/`reject`/`check_in`. `EventRole` still exists as a model/controller in soon/ but is
   never consulted for authorization — co-hosts assigned via the (still-functioning) EventRole
   endpoints silently lose edit/approve/check-in rights they'd have in production sails/.
5. **`register_time` now double-duty (join-time vs. check-in-time) and `checked` status dropped.**
   sails/ has two fields: `register_time` (stamped at join) and `check_time` (stamped by the
   separate `check` action, alongside a `checked` participant status). soon/ has no `check_time`
   column; `ParticipantsController#check_in`
   (`soon/app/controllers/api/v1/participants_controller.rb:112-118`) overwrites `register_time`
   instead. Any consumer reading "when did this person RSVP" loses that value the moment the
   person is checked in, and there is no way to query "checked in" participants by status anymore.
6. **No buyer confirmation email on ticket purchase.** sails/'s `mark_ticket_item_paid!` emails the
   purchaser (`sails/app/controllers/api/ticket_controller.rb:425`,
   `profile.send_mail_new_event`). soon/'s `TicketItem#confirm_payment!`
   (`soon/app/models/ticket_item.rb:49-64`) only notifies the group owner for group tickets — the
   actual buyer gets no email at all on a successful paid purchase.
7. **New destructive capability: parent-manager can hard-delete a child group.** sails/ has no
   group-destroy endpoint at all (only owner-only freeze). soon/'s
   `GroupsController#destroy` (`soon/app/controllers/api/v1/groups_controller.rb:72-76`) is gated
   on `manages?`, which includes parent-group managers, and cascades `dependent: :destroy` across
   events/markers/tracks/venues/domains/group_invites/badge_classes. A parent-group manager who in
   sails/ could never even touch a child group's core settings can now permanently delete it and
   everything in it.
8. **Self-service join requests never expire in soon/.** sails/'s `request_invite` sets
   `expires_at: DateTime.now + 30.days` and `accept_request` checks it
   (`sails/app/controllers/api/group_invite_controller.rb:36,49`); soon/'s `request_invite`
   (`soon/app/controllers/api/v1/group_invites_controller.rb:85`) never sets `expires_at`, and
   `accept_request` never checks `.expired?` — a months-old join request can still be approved.
9. **Inconsistent timezone source for venue availability checks.** sails/ always resolves venue
   hours in `group.timezone` for both direct event create/update and recurring series
   (`sails/app/controllers/api/event_controller.rb:55,215,221`;
   `recurring_controller.rb:57,148`). soon/ uses the event's own timezone on update
   (`soon/app/controllers/api/v1/events_controller.rb:221`) but the request's `params[:timezone]`
   on recurring create (`soon/app/controllers/api/v1/recurring_controller.rb:41`) and the
   individual event's own timezone on recurring update (`:86`) — three different zone sources for
   what should be one canonical check, and none of them consistently matches sails/'s
   always-group-zone behavior.
10. **`Recurring#update selector: "after"` selects a different subset of occurrences.** sails/
    selects "after" by primary-key id ordering (`Event.where('id >= ?', after_event_id)`,
    `sails/app/controllers/api/recurring_controller.rb:114-115,197-199`); soon/ selects by
    `start_time` (`soon/app/controllers/api/v1/recurring_controller.rb:130-136`). Under normal
    chronological creation these agree, but the selection *rule* itself differs — any occurrence
    reordering or bulk-rebuild would make the two systems pick different events for a bulk
    time-shift or cancellation.

A few notable **Improved** fixes surfaced along the way that are *not* in `CHANGELOG.md` and are
worth crediting explicitly rather than re-discovering later: soon/'s `Voucher#invalid?` no longer
crashes on a nil `expires_at` (sails/ raises `NoMethodError` — `sails/app/models/voucher.rb:14`
vs `soon/app/models/voucher.rb:11`), and soon/'s voucher-batch `Activity.create` no longer corrupts
the recipient address/email into an integer column the way sails/ silently does
(`sails/app/controllers/api/voucher_controller.rb:261,311`, writing a string into `receiver_id:integer`).

## Full comparison table

| Domain | Behavior | sails/ (file:line) | soon/ (file:line) | Verdict | Confidence |
|---|---|---|---|---|---|
| **Group** | Parent-group manager manages child group (core content ops: update, general manage) | `app/policies/group_policy.rb:13-17` (`manage?` walks `@group.parent.is_manager`) | `app/policies/group_policy.rb:22-26` (`manages?` walks parent) | Match — confirmed genuinely implemented in both, not just documented in CLAUDE.md | checked both |
| **Group** | Hard-delete endpoint | No `destroy` endpoint exists; only owner-only `freeze_group` (`app/controllers/api/group_controller.rb:168-175`, `group_policy.rb:9-11`) | `groups_controller.rb#destroy` authorized via `manages?` (parent-inclusive); cascades `dependent: :destroy` to events/markers/tracks/venues/domains/group_invites/badge_classes (`app/models/group.rb:7-13`) | **DIVERGENT** — new destructive capability granted to parent-group managers, unmatched by any sails/ equivalent (see summary #7) | checked both |
| **Group** | Freeze/deactivate | Owner-only, no parent fallback (`group_policy.rb:9-11`) | Owner or platform_admin, no parent fallback (`group_policy.rb:11`) | Match | checked both |
| **Membership** | Role vocabulary | `enum :role` = `member/operator/manager/owner` (4 values) (`app/models/membership.rb:7`) | `validates :role, inclusion:` `member/manager/owner` (3 values) (`app/models/membership.rb:9`) | DIVERGENT (data-model only) — `"operator"` is a real persisted sails/ enum value with no live controller code path setting/reading it as a group role today; likely vestigial but would fail soon/'s validation on data migration if any row has it | checked both, usage inferred dead |
| **Membership** | Destroy cascade to tickets/badges held via that membership | Plain `membership.destroy`, no ticket/badge cleanup (`group_controller.rb:193-244`) | Plain `membership.destroy`, no cleanup (`memberships_controller.rb:47-57`) | Match — neither revokes tickets/badges on membership removal | checked both |
| **GroupInvite** | Ticket grant on invite acceptance | `create_ticket_item_for_invite` in `accept_invite`/`accept_invite_with_code` (`group_invite_controller.rb:139,183,234-252`) | `GroupInvite#accept!` → `grant_ticket!`, idempotent `find_or_create_by!` (`group_invite.rb:30-36,51-58`), plus new auto-accept-on-email-verify hook (`:44-47`) | Improved — behavior preserved and made idempotent, not silently dropped as `SAILS_COMPARISON.md` had worried; the auto-accept-on-verify hook is a genuinely new side effect worth confirming intentional | checked both |
| **GroupInvite** | Self-service join-request expiry | `expires_at: DateTime.now + 30.days` set at request; checked at accept (`group_invite_controller.rb:36,49`) | `expires_at` never set at request (`group_invites_controller.rb:85`); `accept_request` never checks `.expired?` | **DIVERGENT** — join requests never expire in soon/ (see summary #8) | checked both |
| **GroupInvite** | Requestable role on self-join request | `role: params[:role]` (attacker-controlled), gated at accept — only an owner may approve a `"manager"` request, `"owner"` always rejected | `request_invite` hardcodes `role: "member"` always | Improved (stricter) — closes the sails/ edge case entirely, at the cost of no longer supporting self-requesting a manager role | checked both |
| **GroupInvite** | `GroupInvitePolicy#accept?` semantics | Invite belongs to this recipient (by `receiver_id` or matching email) (`group_invite_policy.rb:9-12`) | `accept? = group_admin?(record.group)` — inverted meaning (admin-of-group, not recipient) (`group_invite_policy.rb:2`) | DIVERGENT in definition but currently **inert** — `GroupInvitesController#accept` never calls `authorize`, it manually checks `receiver_address == current_user.email` instead. Latent trap for any future caller that wires this policy in. | checked both |
| **GroupInvite** | Revoke/cancel authorization | Group manager only (`group_invite_policy.rb:14-16`) | Original sender OR group admin (`group_invite_policy.rb:3-4`) | Improved (slightly broader, no security regression) | checked both |
| **Event** | Edit rights for co-hosts/speakers (EventRole) | `EventPolicy#update?` also grants access via `EventRole.find_by(event_id:, item_id:/email:)` (`event_policy.rb:9-16`) | `update? = owner?(record) \|\| group_admin?(record.group)` — `EventRole` never consulted (`event_policy.rb:13`); same method gates `approve`/`reject`/`check_in` | **DIVERGENT** — real, live sails/ capability dropped (see summary #4) | checked both |
| **Event** | Parent-group manager edit/approve rights | `update?` has no parent fallback; only `approve_event` explicitly checks `GroupPolicy#manage?` (which does include parent) — inconsistent even within sails/ itself (`event_policy.rb:5-11`, `event_controller.rb:100`) | `update?`/`approve?` both use direct-only `group_admin?` (`event_policy.rb:13,18`) — no parent fallback anywhere for events | **DIVERGENT** — soon/ is uniformly narrower than sails/ for events (sails/ at least let a parent-manager approve); combined with the Venue row below, this inverts relative to Venue (see summary #3) | checked both |
| **Event** | Capacity check at join time | `event_controller.rb:355-361` blocks join once `max_participant` or `venue.capacity` reached | No check anywhere in `ParticipantsController#create`; no `participants_count`-equivalent counter in soon/'s codebase | **DIVERGENT — overbooking risk** (see summary #1) | checked both, confirmed independently by 2 agents |
| **Event** | Capacity check at create/update time | No creation-time comparison of `max_participant` vs venue capacity | `events_controller.rb:218-220` checks `max_participant > venue.capacity` once, at create/update only | Partial improvement, but doesn't compensate for the missing join-time check above | checked both |
| **Event** | Manager email when event lands in `pending` (venue requires approval) | `EventMailer` `venue_review` sent to admin-notification managers on create (`event_controller.rb:85-90`) | No equivalent — pending events only visible via `pending_approval` polling endpoint | **DIVERGENT** — no push notice to managers in soon/ | checked both |
| **Event** | Join/self-cancel email to the attendee | `profile.send_mail_new_event`/`send_mail_cancel_event` (`event_controller.rb:429`, self-cancel path) | `ParticipantsController#create`/`#destroy` send no email at all | **DIVERGENT** — no join-confirmation or self-cancel email in soon/ | checked both |
| **Event → to_ics** | Floating-datetime bug (no tzid) | Confirmed still present in sails/ today (`in_time_zone(tz)` with no `tzid`) | Already fixed via `EventCalendar` service with real TZID/VTIMEZONE — documented in `CHANGELOG.md`, not a new finding | Improved (documented) | confirmed fresh, terse |
| **Venue** | Overall booking window (`start_date`/`end_date`) | Present, enforced (`venue.rb:22,38,44-53`) | Columns don't exist in soon/'s schema at all | **DIVERGENT — dropped feature** (see summary #2) | checked both |
| **Venue** | Overlap query (non-cancelled events, strict bounds) | `venue.rb:54-56` | `venue.rb:24-26` | Match | checked both |
| **Venue** | Date-override priority over weekly slots; empty intervals = closed; no records = open 7×24 | `venue.rb:61-85` | `venue.rb:29-40` | Match | checked both |
| **Venue** | Overnight/past-midnight interval edge case | No explicit guard — `end_secs < start_secs` fails all intervals silently, same net effect | Explicit guard rejects (`venue.rb:50`) | Match in net outcome (cosmetic-only difference) | checked both |
| **Venue** | Timezone source for `check_availability` | Always `group.timezone`, ignoring event's own zone (`event_controller.rb:55,215,221`; `recurring_controller.rb:57,148`) | Event's own timezone on update; request `params[:timezone]` on recurring create; inconsistent between soon/'s own create vs update paths | **DIVERGENT** — three-way inconsistency (see summary #9) | checked both |
| **Venue** | Create authorization | No `authorize` call at all — any authenticated profile can create a venue under any `group_id` (`venue_controller.rb:2-9`) | Requires `authorize group, :manage?` (`venues_controller.rb:16`) | Improved — closes a real sails/ gap | checked both |
| **Venue** | Parent-group manager rights (create/update/destroy/availability) | Direct-manager-only, no parent fallback (`group_policy.rb:22-24`) | Uses `GroupPolicy#manage?`, which does include parent (`venues_controller.rb:16,24,29,55`) | **DIVERGENT (Improved but inconsistent)** — more permissive than sails/, and inverted relative to Event above (see summary #3) | checked both |
| **Recurring** | Naive local-time parsing for series base occurrence | `DateTime.parse(params[:start_time])`, no explicit zone — offset-less string treated as UTC; `DateTime#advance` has no IANA-zone DST awareness (`recurring_controller.rb:43,68`) | `zone.parse(...)` in the resolved series zone, `TimeWithZone#advance` (DST-aware) (`recurring_controller.rb:29-30,163-168`) | Improved (documented in CHANGELOG.md as the DST-drift fix) — confirmed sails/'s bug is real and still present today | checked both |
| **Recurring** | `selector: "after"` occurrence selection rule | Selects by primary-key `id >=` ordering (`recurring_controller.rb:114-115,197-199`) | Selects by `start_time >=` (`recurring_controller.rb:130-136`) | **DIVERGENT** — different selection rule, same result only under normal chronological-id creation order (see summary #10) | checked both |
| **Recurring** | Destroy cascade to member events | No `dependent:` option — events survive with a dangling `recurring_id` pointing at a deleted row (`recurring.rb:2`) | Explicit `dependent: :nullify` (`recurring.rb:6`) | Improved (minor) — same net survival, cleaner FK state | checked both |
| **Ticket** | `has_many :participants` destroy cascade | `dependent: :delete_all` — participants hard-deleted when a ticket type is destroyed (`ticket.rb:4`) | `dependent: :nullify` — participant rows kept, `ticket_id` nulled (`ticket.rb:4`) | **DIVERGENT** — orphaned participant history survives in soon/ instead of being deleted | checked both |
| **TicketItem** | Purchaser confirmation email on payment success | `mark_ticket_item_paid!` → `profile.send_mail_new_event(event)` whenever `profile.email.present?` (`ticket_controller.rb:425`) | `confirm_payment!` only calls `notify_group_owner` (different recipient); buyer gets nothing (`ticket_item.rb:49-64`) | **DIVERGENT — dropped notification** (see summary #6) | checked both |
| **TicketItem** | Group-owner notification delivery mode | `mailer.deliver_now!` (sync, failure surfaces inline) (`ticket_item.rb:61`) | `.deliver_later` (async, silent if queue misconfigured) (`ticket_item.rb:72`) | DIVERGENT (minor) — acceptable design choice but changes failure-mode visibility | checked both |
| **TicketItem** | Coupon ratio/amount discount math, all branches (ratio, amount+stripe, amount+non-stripe chain, amount+nil paymethod) | `coupon.rb:21-32` | `coupon.rb:31-40` | Match — identical arithmetic in every branch, confirmed line-by-line | checked both |
| **Ticket** | Unknown-email group-ticket grant mechanism | Creates an `unbounded`-status `TicketItem` up front with no profile link; flips to `succeeded` later only if a matching Profile appears; unmatched emails sit permanently unlinked (`ticket_controller.rb:375-397`) | Known emails get an immediate `TicketItem`; unknown emails get a `GroupInvite` (`ticket_id` set) that auto-accepts on signup/bind/trusted_signin via `GroupInvite.auto_accept_ticket_invites_for` (`tickets_controller.rb:219-244`) | DIVERGENT (redesign, plausible but undocumented) — different mechanism entirely; soon/'s `unbounded` `TicketItem` status is now vestigial on this path. Worth confirming this fully replaces old semantics (e.g. any coupon/discount_data linkage the old unbounded record carried). | inferred, not in CHANGELOG.md |
| **Voucher** | `invalid?` with nil `expires_at` | `expires_at < DateTime.now()` raises `NoMethodError` — a voucher with no expiry can never be validly used (`voucher.rb:14`) | `expires_at.present? && expires_at < Time.current` (`voucher.rb:11`) | **Improved** (new finding, not in CHANGELOG.md) — real sails/ crash-on-use bug fixed | checked both |
| **Voucher** | Batch issuance atomicity (`send_badge*`) | No transaction; a later individual `save` failure leaves earlier vouchers persisted | `issue_vouchers` wraps the whole batch in one transaction (`vouchers_controller.rb:159-178`) | Already documented in CHANGELOG.md — not re-flagged as new | checked both |
| **Voucher/Activity** | `receiver_id` on address/email voucher-send Activity records | Writes a hex-address/email **string** into an **integer** `receiver_id` column — silently coerced/lost, real value never persisted (`voucher_controller.rb:261,311`; schema confirms `receiver_id:integer`) | Writes to the correctly-typed string `receiver_address` column (`vouchers_controller.rb:125-137`) | **Improved** (new finding, not in CHANGELOG.md) — fixes real data corruption, byproduct of the string-PK migration rather than a documented deliberate fix | checked both |
| **PaymentMethod** | Chain/token resolution logic | `payment_method.rb` | `payment_method.rb` | Match — byte-for-byte identical logic; only `item_type` allowed values renamed `Profile`→`User` | checked both |
| **Badge** | `swap_code` action Activity logging | `Activity.create(action: "badge/swap_code")` on every code generation (`badge_controller.rb:61`) | No Activity call on `swap_code` at all (`badges_controller.rb:58-66`) | **DIVERGENT** — activity feed loses the "generated a swap code" event (distinct from the already-fixed `swap`-completion logging bug) | checked both |
| **Badge** | Swap/transfer eligibility (burned, non-transferable, held-by-caller checks) | Only checks the *target* badge | `Badge#held?` guards both caller's and target's badge; `decode_swap_code` requires `auth_type == "swap"` | Already documented in CHANGELOG.md as fixed — not re-flagged | checked both |
| **Badge** | `update` (`display`) authorization | No `authorize` call at all (pre-existing gap) | `BadgePolicy#update? = creator_id == user.id \|\| own?` | Not a divergence (sails/ had nothing to compare) — design note only: soon/'s rule (creator-or-owner) is broader than "creator only," appears intentional and reasonable | checked both |
| **Participant** | Capacity enforcement at join | Hard-blocks (see Event row above) | None (see Event row above) | **DIVERGENT** — duplicate of the Event-domain finding, listed here for domain completeness | checked both, confirmed independently by 2 agents |
| **Participant** | `register_time` vs `check_time` semantics | Two fields: `register_time` (join), `check_time` (attendance, via separate `check` action + `checked` status) | One field: `register_time`, overwritten by `check_in` action; no `check_time` column, no `checked` status | **DIVERGENT** (see summary #5) | checked both |
| **Participant** | `status` enum dead values (`waiting`, `disapproved`) | Present in validation list, never referenced by any controller | Dropped | Match/Improved — correctly not carried over, confirmed dead in sails/ | checked both |
| **Participant** | Approval authorization (who can approve/reject a pending participant) | `ParticipantPolicy#approve? = ` event owner or direct group manager — no parent walk (`participant_policy.rb:14-16`) | `approve`/`reject` reuse `EventPolicy#update?` = owner or direct `group_admin?` — no parent walk | Match — neither system extends approval rights to a parent-group manager (though both are further narrowed relative to sails/ by the EventRole finding above, which also blocks co-hosts from approving in soon/) | checked both |
| **Participant** | Email on approve/reject | `profile.send_mail_participant_approved/rejected` (sync) | `EventMailer...deliver_later` | Match (mechanism differs, same trigger) | checked both |
| **Form** | Required-field validation depth | Inline string-based `field_id` presence check only, no per-FormField-type value validation (`event_controller.rb:373-379`) | Same string-based presence check only (`participants_controller.rb:12-20`) | Match — neither validates answer format against declared field type; no new divergence beyond the already-documented boolean-cast fix | checked both |
| **Comment** | Author-only create, feedback→mailer trigger, star/unstar, visibility filtering | `comment_controller.rb:1-51` | `comments_controller.rb:1-59`, adds a cleaner `Comment.visible` scope | Match/Improved — same trigger set; no new divergence beyond the already-documented `title` type fix and author-only `remove` fix | checked both |
| **Activity** | Trigger points for `voucher/*`, `group_invite/*`, `remember/*` | `voucher_controller.rb:113,165,212,261,311` | `vouchers_controller.rb:89,107,170`, `remember_controller.rb:89`, `group_invites_controller.rb:114,140,147` | Match — same trigger points ported under the documented typed-payload redesign; no dropped/added trigger found other than the `badge/swap_code` gap above | checked both |
| **Track** | Track-management rights via parent-group manager | Walks one level of parent (`group_policy.rb:13-17`) | Walks one level of parent (`group_policy.rb:22-26`) | Match | checked both |
| **Track** | `manager_ids[]` → Event edit rights | Column exists on `Track` but is **dead code** — never written by any controller (`track_params` doesn't permit it), so the `EventPolicy#update?` branch reading it never actually grants anyone access (`event_policy.rb:14`) | Replaced with real `TrackRole` sync, but that only grants Track management, not Event edit rights | Match/Improved — since the old path was inert in sails/, no real users lose access by soon/ not reproducing it | checked both |

## Domains audited with no material findings beyond `CHANGELOG.md`

- **BadgeClass** creation/authorization, **Coupon** availability/expiry gating, **PaymentMethod**
  chain resolution, **Voucher** per-strategy eligibility (code/account/address/email/event), and
  **Form** boolean-casting were all read directly and found to match the already-documented,
  already-fixed behavior with no further real-world-consequential drift.

## Notes on methodology

Four parallel research passes each read the actual current source in both `sails/app/**` and
`soon/app/**` (models, controllers, policies, and — where relevant — `db/schema.rb`) rather than
relying on `SAILS_COMPARISON.md`/`CHANGELOG.md`'s own paraphrases of sails/'s behavior. Every row
above cites the specific file:line checked in at least one repo; rows marked "checked both" were
independently confirmed in both codebases. Two independent passes (Event/Venue domain and
Participant domain) separately arrived at the same overbooking finding (#1), which is a useful
cross-check on its validity.
