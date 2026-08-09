# Changelog

All notable changes to `soon/` are recorded here.

## 2026-08-08 (later) — orders remember what happened to them

`ticketing_activities` / `Ticketing::Activity`: an append-only record of the
ticketing domain, written from `TicketItem#transition!` — the one place a
status change is guaranteed to pass through, so recording cannot be forgotten
at a call site. Design and rationale in `design/PAYMENTS_PLAN.md` §8.

The short version of why: an order kept only a current status, so its past was
being derived from timestamps, and the derivation was wrong in ways nobody
would notice. `updated_at` is the last write of any kind rather than the moment
of a transition. A dispute lost at the provider runs `transition!(:refunded)`
with no Refund row, making it identical to a voluntary refund afterwards —
opposite facts, same evidence. Retries changed no status and so left nothing.

The action vocabulary is deliberately wider than the status machine, because
the events most needing explanation later are not transitions at all
(`payment_retried`, `callback_rejected`, `prepay_created`).

**Fixed while designing it**: `add_group_ticket_item` wrote
`update(status: "succeeded")` directly — the only bypass of `transition!` in
the codebase. Re-granting to an email whose order had expired silently
reopened a closed order whose seat and coupon were already handed back.

**Also fixed, found by a real refund**: `WechatPayGateway` asked for gzip
(Net::HTTP's default) and the refund endpoint answered with something it could
not inflate, raising `Zlib::DataError` *after* WeChat had accepted the refund —
a 500 for an operation that succeeded.

The dangerous part was the near-miss in the fix: catching it as a plain
`Error` would have recorded a successful refund as `failed`, and the organizer
retrying would refund a partial amount twice (only a duplicate *full* refund is
caught by the unique index). So an unreadable answer is now
`WechatPayGateway::Unreachable`, distinct from a refusal: it leaves the refund
pending and waits for the callback. Same principle `query_order` already used
for "could not ask" vs "not paid".

The gateway moved to `httpx`, which was already a dependency and unused. Two
Net::HTTP defaults had cost something here: the gzip one above, and
`Net::HTTP.start` defaulting its proxy argument to `:ENV`, which silently
routes payment traffic through `http_proxy` — set on the dev machine.

**Organizer-facing**: `GET /tickets/list` gains an `:order_detail` view for
managers (refunds, timestamps, ticket title, activities), and refunds accept an
`amount` so a partial refund no longer needs curl. The manager who ordered a
refund is named in the payload, not left as an id.

## 2026-08-08 — WeChat Pay, and the currency that should always have been there

CN's second payment rail, built on branch `wechat-pay` and not yet deployed.
Full write-up in `design/WECHAT_INTEGRATION.md` §5; what follows is what
changed for everything that is *not* WeChat.

**Payment methods now carry a currency.** `payment_methods.currency` had been a
column nobody wrote or read: orders were stamped `currency: "usd"` from a
literal. It is now assigned from the rail, validated against it, and
**snapshotted onto the order as charged** — a refund has to go out in the
currency that came in, and an order taken before a rail's default moved must
keep its own.

**Three places stopped asking `chain == "stripe"`.** Each was correct with one
fiat rail and wrong with two:

- `Coupon#get_discounted_price` multiplied a fixed-amount discount by 10000
  for anything that was not literally `"stripe"`. A ¥1 coupon on a WeChat order
  would have become ¥10,000, clamped to the price — **the order goes free**.
  Now keyed off `PaymentMethod::FIAT_CHAINS`, and the test asserts the property
  over the whole set so the next rail is covered without anyone remembering.
- `set_payment_status` refused to confirm stripe orders by name. It is
  authenticated by a shared secret and verifies no payment, so any rail left
  open there mints paid tickets for whoever holds `NEXT_TOKEN`. It now refuses
  every fiat rail.
- `payment_proof_ok?` split stripe from crypto, so a third rail fell through to
  the crypto branch and was asked for a txhash it can never have.

**The $4 card floor became `MIN_PRICE`, a per-rail map.** It exists to cover
Stripe's fixed $0.30 per charge; a rail without a fixed fee has no reason for
it, and one global constant imposes it anyway.

**`AuthController#bind_wechat`** attaches a WeChat identity to an existing
account — JSAPI cannot place an order without the payer's openid and
email-registered buyers have none. It requires *both* a session and
`NEXT_TOKEN`: the JWT says which account, the shared secret says the openid
came from the server that just redeemed the code. On user auth alone anyone
could claim a stranger's openid and receive their next WeChat sign-in. Unlike
`bind_email` it refuses rather than merges when the identity already has an
account — that direction would delete an account with real data on it.

`ginger.cn.yml` gains `API_URL`. `WechatPayGateway.notify_url` is one default
away from `localhost`, and a localhost notify_url is invisible: WeChat reports
nothing, and payments would confirm solely through the 5-minute sweeper.

## 2026-08-08 — a second sign-in channel no longer means a second account

WeChat sign-in creates an account with no email. Binding one that already
belonged to an email account failed with `email is already in use`, which left
the person holding two accounts and no way to reconcile them — the exact
duplicate the WeChat work was supposed to avoid.

**`bind_email` now merges** instead of failing: the WeChat identity moves onto
the account that owns the address and the throwaway one is deleted, so the next
WeChat login lands on the merged account rather than minting another. Order
matters inside the transaction — both identity columns are uniquely indexed, so
`from` has to be destroyed before `into` can take them.

Merging deletes an account, so it is allowed only in a narrow window, guarded
three ways (`AuthController#mergeable?`):

- **The account must be WeChat-first.** A blank `name` is the window marker,
  but nothing server-side requires a name before writing — `EventPolicy#create?`
  never looks at it — so a long-lived *wallet* account whose owner simply never
  registered one would otherwise qualify and be deleted along with its data.
- **`name` must still be blank**, i.e. registration never finished. This is why
  `seastar-app` now asks for the email *before* the username: picking a name
  closes the window. That reordering is not cosmetic — without it this path is
  unreachable.
- **The target must carry no WeChat identity of its own.** Overwriting one
  would aim a different person's next login at this account; refusing to move
  ours would recreate the duplicate.

The bind-context code is unchanged and still required — it is what proves the
caller owns the address. Without it any WeChat user could type someone else's
address and swallow their account.

A merge changes *who the caller is*, so the response is a fresh token marked
`merged: true` rather than a profile; the token that was sent authenticates a
row that no longer exists. Frontend detail is in
`seastar-app/design/AUTH_INTEGRATION.md`.

**Confirmed on CN production the same day** — the first exercise of this path
against real data rather than tests. An email account and a WeChat account
merged into one: `User.count` went 2 → 1, the survivor kept the email account's
`created_at` and username (so the direction was right) and gained the WeChat
account's `openid`. Signing in with that WeChat identity now lands on the merged
account instead of minting another.

That same check surfaced an unrelated finding worth acting on: the account's
`wechat_unionid` is nil, i.e. **the 服务号 is not bound to a 微信开放平台
account**. Harmless today with a single appid, but it removes the only automatic
way to recognise the same person across a future mini program or desktop QR
login. See `WECHAT_INTEGRATION.md` §1.3.1 for why binding early is much cheaper
than binding later, and for the steps.

## 2026-08-07 — removed venues stayed in every list

Removing a venue is a soft delete (`archived: true`), but `GroupBlueprint`'s
`:detail` view rendered the unfiltered `venues` association. Every venue LIST in
the product reads `groupDetail.venues` — the venues page, the event editor's
venue picker, the schedule venue view, the settings count — so a removed venue
stayed on screen after Remove + reload and was still bookable. `VenuesController#index`
had the `archived: false` filter all along, but nothing calls `index`.

`Group` gained an `active_venues` association and the blueprint sources from it
while keeping the `venues` key, so no frontend change was needed;
`with_detail_associations` preloads it instead, keeping the N+1 guard intact.

Booking an event or a recurring series *into* an archived venue is now refused
too — the API allowed it directly. Both guards distinguish a new booking from an
untouched one, because the client resubmits the whole form and `venue_id` comes
back on every edit: `EventsController` checks `venue_id_changed?`, and
`RecurringController#resolve_venue` compares against the series' current venue.
Treating a resubmitted value as a booking would have made an event — or a whole
series — permanently uneditable once its venue was removed.

**Venue names are no longer unique** (`index_venues_on_name` dropped, no
replacement). The constraint was global, so a soft-deleted venue kept blocking
its own name and recreating it failed with "Name has already been taken"
against a row invisible in the UI. Names are labels, not identifiers — every
lookup goes through the TSID and the schedule filter matches on `venue.id`.

## 2026-07-30 — public reads that 401'd, cancelled events, SIWE domains

Four fixes, all surfaced while moving sign-in into `seastar-app` (the full
record of that work is in `seastar-app/design/AUTH_INTEGRATION.md`).

**`recurring#show` and `forms#get_event_form` 401'd without a token**, and the
event detail page fetches both server-side for signed-out visitors. The SDK's
`requestOrNull` only swallows 404, so a 401 threw and took the whole page down
with a 500 — reported as a broken event URL. Both are public reads now, with
visibility enforced explicitly rather than by demanding a session:
`recurring#show` filters occurrences through `Event.visible_to(current_user)`
(via a new `visible_events` option on the blueprint, since the association would
otherwise render every occurrence), and `get_event_form` authorizes the event
itself — `set_event` uses a bare `Event.find`, so a draft or private event's
form had been readable by anyone holding the event id.

**Cancelled events left every listing.** `Event.visible_to` excluded them from
the public branch but re-admitted them via `OR owner_id / OR group_id IN
(managed)`, which put cancelled occurrences back on the group schedule grid —
where, unlike CardEvent, there is no "Cancelled" badge to disambiguate them. The
exclusion is NULL-safe on purpose: `events.status` has a default but no NOT NULL
constraint, and a plain `where.not(status: [...])` is NULL for a NULL status in
Postgres, which would have dropped every legacy row that has none. Direct links
still render — `EventPolicy#show?` does not gate cancelled.

**The single-event ICS export leaked cancelled and pending events.**
`calendar_visible?` hand-copied `Event.visible_to`'s status list and had drifted
out of sync with it. It now delegates to the scope, so the two cannot diverge
again. The group feed was never affected — it filters on `status: "published"`.

**`ALLOWED_SIWE_DOMAINS`** now accepts `app.sola.day` and `id.sola.day` (plus
the juluo equivalents), since the SIWE message's `domain` is
`window.location.host` and sign-in moved hosts. Note this variable was **not**
injected by `ginger.yml`, so SG had been running on the hardcoded default in
`AuthController` all along and the value in `.env.production` had no effect;
both are now correct and the variable is injected.

Not fixed, recorded here because it is load-bearing elsewhere:
`ParticipantsController#create` never checks the group's `can_join_event`. The
frontend hides the RSVP button accordingly, but that is a UI hint, not a
permission — a direct POST still joins.

## 2026-07-29 — GoodJob as the Active Job backend; all mail moved onto it

Background work had no durable backend: `config.active_job.queue_adapter` was
never set, so every `deliver_later` in the app ran on Rails' built-in `:async`
adapter — an in-memory thread pool whose queue dies with the process. A deploy
or a crash silently dropped whatever mail was in flight: group invites, event
cancellation notices, ticket confirmations.

Adopted **GoodJob** (`~> 4.19`), running with `execution_mode :async` — i.e.
inside the Puma process, no separate worker to deploy (the Dockerfile `CMD` is
a bare `rails server` and stays that way). The win over the built-in `:async`
adapter isn't *where* jobs run, it's that they're rows in `good_jobs`, so a
restart re-picks them up. Verified end to end: a job enqueued while the server
was down was executed on the next boot.

This supersedes ARCHITECTURE §9's earlier note that Solid Queue was the
intended backend. Solid Queue wants a supervisor process (or a Puma plugin)
and a second database; GoodJob's `:async` mode is exactly the one-container,
one-Postgres shape this app deploys in, and sails already ran GoodJob so its
behaviour is familiar. Note this is the gem only — none of sails' `good_job_*`
rows are migrated; the tables are created fresh.

- **`MailDeliveryJob`** is now `config.action_mailer.delivery_job`, so every
  `deliver_later` inherits a real failure policy instead of ActionMailer's
  bare default: polynomial backoff on `Resend::Error` (with a longer leash for
  `RateLimitExceededError`) and on socket-level failures, and `discard_on
  ActiveRecord::RecordNotFound` — the mailers resolve their subject with
  `Model.find(id)`, so a record deleted between enqueue and execution has
  nothing left to send and must not retry forever.
- **Two fan-out jobs** move per-recipient loops off the request. `events#destroy`
  and `#update` used to walk every attending participant inline and enqueue one
  delivery each (`each_attendee_email`), and `groups#send_email` did the same
  over the membership list — so cancelling a 2,000-attendee event meant 2,000
  job inserts before the request could respond. Now each costs one enqueue:
  `EventAttendeeMailJob` and `GroupBroadcastMailJob` do the walk, and each
  recipient still gets its own `MailDeliveryJob` so one bad address retries
  alone instead of stalling the batch. `EventAttendeeMailJob` allowlists the
  mailer action (`cancelled`/`updated`) since the name reaches `public_send`.
- **`Group#member_emails`** extracted so `groups#send_email` (which reports
  `sent_count`) and `GroupBroadcastMailJob` (which actually sends) can't
  disagree about the audience. Also replaces a `.includes(:user).filter_map`
  that loaded every membership row with a single distinct pluck.
- **`AuthMailer#login_code` deliberately stays `deliver_now`.** It is the only
  mail whose failure the user can act on — if the code can't be sent, the
  request that asked for it should fail rather than return 200 and leave
  someone waiting for a code that will never arrive.
- **`config/database.yml` pool fix (latent bug, unrelated to jobs but exposed
  by them)**: the pool key was spelled `max_connections`, which Active Record
  does not recognise, so the pool had silently been the default 5 regardless of
  `RAILS_MAX_THREADS`. Corrected to `pool:` and sized
  `RAILS_MAX_THREADS + GOOD_JOB_MAX_THREADS + 2` — job threads draw from the
  same pool as web threads, plus one held open by GoodJob's `LISTEN` notifier.
  Left undersized, concurrent job execution would have starved web requests
  with `ConnectionTimeoutError`.
- `config/environments/test.rb` keeps the `:test` adapter (it loads after
  `application.rb`), so the suite still asserts on enqueues without executing.
  Three existing tests were updated for the new indirection — they now run the
  fan-out job inline via `perform_enqueued_jobs(only:)` before asserting on the
  mail it produces. New `test/jobs/mail_jobs_test.rb` covers recipient
  selection, the action allowlist, and both discard paths. 615 runs, 0 failures.

## 2026-07-29 — audit pass over every remaining list endpoint (markers, venues, ...)

Swept all 17 `index` actions under `api/v1/` for the same class of bug found
in the events/badges/groups passes above (missing status filter, missing
group scoping). Two real bugs found and fixed; the rest were compared and
found equivalent to sails or currently unused by the frontend (see below).

- **`markers#index` leaked soft-deleted markers**: no filter on `status` at
  all, despite `status: "removed"` existing as a soft-delete left over from
  migrated legacy data (soon's own `#destroy` hard-deletes, so `"removed"`
  only ever comes from migrated rows — 103 of them locally). sails'
  equivalent `marker#list` excludes `status != "active"`. Fixed with
  `where(status: [nil, "active"])` — not a plain `where.not(status:
  "removed")`, since `status` has no DB default and a plain `!=` would also
  drop `nil`-status rows (SQL's 3-valued NULL logic) — a marker created
  through soon's own `#create` without an explicit status is `nil`, not
  `"active"`.
- **`venues#index` had no `group_id` filter at all** — always returned every
  venue across every group, unlike `tracks#index` (its closest sibling),
  which already supported one. Not currently called by the frontend (venues
  are read out of the embedded group-detail payload instead), so no visible
  regression today, but a real gap — fixed to match `tracks#index`'s
  `Group.resolve!` pattern.
- Everything else checked (`groups#index`, `group_invites#index`,
  `participants#index`, `tickets#index`, `event_roles#index`,
  `activities#index`, `comments#index`, `places#index`, `tracks#index`) is
  either already-equivalent to sails or currently unused/orphaned by the
  frontend (embedded-in-parent payloads instead) — noted but left as-is to
  avoid touching dead code paths speculatively. `activities#index` returns
  more activity `action` types than sails' hardcoded whitelist
  (`voucher/send_badge`, `group_invite/send`) — a real behavior difference,
  but not necessarily a bug (unclear whether sails' whitelist was
  intentional curation or just never updated), left for a follow-up if it
  turns out to be user-visible noise.

## 2026-07-29 — co-hosting/starred event lists: missing filter, N+1 star lookup

`/my-events/co-hosting` and `/my-events/stared` (and the profile page's
matching tabs) diverged from production:

- **Co-hosting was permanently empty**: `events_controller#apply_filters`
  had no filter for "events where this user is an `EventRole` item" at
  all — the sola-sdk stubbed `coHosting: []` with a `TODO`. sails supported
  this via `Event.joins(:event_roles).where(event_roles: {item_id: ...,
  item_type: 'Profile'})`, no role restriction. Added a matching
  `co_host_id` filter (same shape as `owner_id`/`attendee_id`), also with
  no role restriction — a co-host is any `EventRole` row with
  `item_type: "User"`, regardless of `role` (`member`/`manager`).
- **Starred was a 3-round-trip N+1**: `getStaredEvent` resolved the viewer
  via `/users/me`, listed up to 30 star `Comment`s, then fetched each
  referenced event individually via `/events/:id` — silently dropping any
  that 404'd (deleted/inaccessible), with a hard 30-item cap and no
  pagination. Added a `starred_id` filter (`Comment.where(...).visible`
  scoped to the event id) so the whole thing is one `GET /events?starred_id=`
  query, matching `owner_id`/`attendee_id`/`co_host_id`. `getProfileEventByName`
  now fetches `coHosting`/`starred` for real instead of stubbing them, so a
  profile's tabs work for *any* handle, not just the logged-in viewer
  (previously starred was viewer-only; sails' `by_profile` was never
  restricted like that either).
- Also wired `is_starred`/`is_attending`/`is_owner` into `events#show`
  (previously only `#index` set them) so the event-detail page can read
  `eventDetail.is_starred` directly instead of doing its own separate
  "fetch my whole starred list and check if this id is in it" lookup.

## 2026-07-29 — profile page's groups/badges tabs diverged from production

Diffed `app.sola.day/profile/jiang?tab=groups`/`?tab=badges` against the
local equivalent.

- **Groups tab**: `UsersController#groups` filtered `Membership#active`
  but never checked `Group#active`, so a group frozen/deactivated by an
  admin (sails: `status == 'freezed'`) kept appearing in a user's Groups
  tab locally, though sails' `profile#groups` explicitly excludes it. The
  `groups.active` column was already populated correctly by
  `migrate_from_sails.rb` — the controller just never read it. Fixed by
  joining and filtering on `groups: { active: true }`.
- **Badges tab (count)**: `BadgesController#index`/`BadgeClassesController#index`
  go through `render_collection`, which paginates at 20/page (Pagy) by
  default. sails' `badge#list` has no limit at all (returns every minted
  badge); `badge_class#list` hard-caps at 20 with no offset/paging. Since
  the sola-sdk badge calls never requested extra pages, profiles with more
  than 20 badges/badge-classes silently showed fewer locally than on
  production. Fixed by switching `getBadgesByOwnerName`/
  `getBadgeClassesByCreatorName` (sola-sdk) to `requestAllPages` instead of
  reading only page 1.
- **Groups tab (order)**: sails' `Group.where(id: role_by_group.keys)` happens
  to return rows in the *group's own* primary-key order (creation order) —
  an artifact of that query shape, not a deliberate choice — rather than
  when the viewed user joined each one. soon orders by `memberships.created_at`
  (join time) already, which is the more sensible sort for "this person's
  communities"; kept intentionally rather than matching sails' incidental
  behavior.
- **Badges tab (order)**: neither `badges_controller#index` nor
  `badge_classes_controller#index` had an explicit `ORDER BY` — both relied
  on implicit DB row order, which is not guaranteed and legitimately
  differs between two separately-populated databases (sails' original data
  vs soon's freshly-migrated copy). Added `.order(created_at: :desc)` to
  both, matching the pattern already used by `vouchers_controller`/
  `comments_controller`/`activities_controller`.

## 2026-07-29 — `Place#name` had a bogus global-uniqueness constraint

Diffed `app.sola.day/event/edgeesmeralda/schedule/compact` against local:
the same real-world venue showed as "Hotel Trio - Patio" on production but
"Hotel Trio - Patio (2)" locally. Root cause: `places.name` had a DB unique
index + model `uniqueness: true`, which don't exist in sails — two
genuinely different real-world locations can share a name (a hotel chain's
"Patio" in different cities), and `migrate_from_sails.rb`'s dup-suffixing
(`"... (2)"`) was fabricating a distinguishing name that never existed in
production. `PlacesController#create`'s find-by-exact-name-then-create is a
sufficient soft convenience on the write path; a hard DB constraint isn't
needed and actively corrupts migrated data. Removed the index and
validation (`20260729113156_remove_unique_index_on_places_name.rb`); the
migration now imports all 2280 places 1:1 with no merging/suffixing.

## 2026-07-29 — homepage popup-city list wasn't curated, and its card image was wrong

Third round of local-vs-production diffing (`localhost:4001/` vs
`app.sola.day/`): the homepage popup-city carousel showed 50 uncurated
groups locally (any active group with start_date+location) vs 21 curated
ones on production. Root cause, per sails' `event/discover`: popup cities
are curated by `group_tags` containing `top` (excluding `hidden`) — a
deploy-side decision — not "has dates". Fixed `DiscoverController#index` to
match (same 21 groups, same order as production after the fix).

Also cancelled events (initially assumed intentional per the entry below)
now also drop out of browse listings per an explicit product decision —
`Event.visible_to`'s public branch excludes `cancelled` alongside
`draft`/`pending`/`archived`; the owner/manager branches are untouched so an
organizer still sees their own cancelled event.

Second, compounding gap: sails renders `group.featured_image_url ||
group.image_url` for the popup-city card — a dedicated wide/banner image,
distinct from the small avatar `image_url`. soon's `groups` table never had
this column (added: `20260729111650_add_featured_image_url_to_groups.rb`),
`migrate_from_sails.rb` never copied it, and the frontend's `toPopupCity()`
only ever read `image_url`. Fixed all three. Also normalized `group_tags`
during migration — sails stores them colon-prefixed (`:top`), but
soon's own code (`GroupsController::PRIVILEGED_TAGS`, this fix) always
compares colon-less strings, so every tag check on migrated data was
silently failing before this.

## 2026-07-29 — pending events were publicly listed before manager approval

Follow-up to the event_union investigation below: checked a second reported
list-mismatch (`/event/mushanghai?collection=past`, local showed 266 vs
production's 204). Root-caused by diffing sails' `event/list` filter against
soon's `Event.visible_to`:
- sails whitelists `status IN ('open','published','closed')` AND
  `display IN ('normal','pinned','public')` for public listing.
- soon's `visible_to` only blacklisted `status IN ('draft','archived')`, and
  `display`'s hidden/private states were already correctly absorbed into
  `visibility != 'public'` during the schema redesign — but `status: pending`
  was not excluded.

Two different findings, not one:
- **Real bug, fixed**: a `pending` event (awaiting `EventsController#approve`
  via the manager review-inbox flow — see `#pending_approval`) was publicly
  listed to anyone before a manager ever approved it, defeating the point of
  the pending-review workflow. `Event.visible_to` now excludes `pending`
  alongside `draft`/`archived`. Low volume in this dataset (1 of 279 events)
  but a real content-moderation gap regardless of count.
- **Cancelled events**: initially assumed intentional (frontend has a
  "Cancelled" badge in `CardEvent`, unlike sails' hard exclude), but per
  explicit product decision this was wrong — cancelled events must also drop
  out of browse listings, matching sails. `visible_to`'s public branch now
  excludes `cancelled` too. The badge still fires where it's actually useful:
  the `owner_id`/`managed` OR-clauses are untouched, so an organizer still
  sees their own cancelled event (with the badge) instead of it silently
  vanishing for them — only random public viewers lose visibility.

## 2026-07-29 — event_union/venue_union cross-group federation was silently dropped in migration

Refreshed local dev data (fresh prod dump → local sails → local soon, see
below) to debug a report that `localhost:4001/event/ethchiangmai2025` and
`app.sola.day/event/ethchiangmai2025` showed completely different event
lists. Root cause, confirmed against production directly: sails' `groups`
table has `group_union`/`venue_union` (integer[] columns) — a cross-group
event-listing/venue-sharing federation feature (e.g. a popup-city cluster of
partner communities cross-listing each other's events; 8 groups use it in
production, including `ethchiangmai2025` ∪ `4seas`). soon's schema already
had the equivalent columns (`event_union`/`venue_union`, renamed for its TSID
ids) but:
- `migrate_from_sails.rb` hardcoded both to `[]` on every group — never
  actually copied `group_union`/`venue_union`, even after remapping ids.
- `EventsController#apply_filters`'s `group_id` filter only matched the
  literal group, never expanding through `event_union`.
- `EventsController#reference_error` and `RecurringController#resolve_venue`
  only accepted a venue owned by the event's own group, never one owned by a
  `venue_union` partner.

Fixed all three: `Group#event_group_ids`/`#venue_group_ids` (new model
methods, self + union, deduped), migration now remaps `group_union` →
`event_union` and `venue_union` → `venue_union` via the existing groups id
map, and both controllers now check against the expanded set. Local re-migration
confirmed exact parity with production for `ethchiangmai2025` (211 upcoming
events, matching `api.sola.day`'s live response, vs 0 before the fix).

**Local data refresh tooling** (`sails/`, unrelated to soon/'s own code but
needed to get here): `bin/dump_tables_advanced.rb` and
`bin/load_tables_advanced.rb` both had a real bug — a helper method (
`dump_table_raw_sql`/`process_batch`) was `def`'d *after* the loop that calls
it, so Ruby's top-to-bottom top-level execution meant every default-mode
invocation failed with `undefined method`. Fixed by moving the definitions
above their call sites. Also added `TABLE_ORDER` support to the load script —
`CLEAR_TABLES=true` was clearing tables in alphabetical order, ignoring FK
dependencies, so parent tables' `delete_all` aborted on FK violations from
still-populated children and silently kept 100% stale data. A full prod dump
→ local sails reload now needs: `TRUNCATE ... CASCADE` up front (sidesteps
ordering entirely), then load with `TABLE_ORDER=profiles,groups,badge_classes,
recurrings,vote_proposals,vote_options,vouchers,events,group_invites,
memberships,venues,tracks,tickets,forms` (parents before children; the
remaining independent tables fall back to alphabetical). ~0.2% of rows
(mostly duplicate emails predating a unique index, and a handful of legacy
NULL enum values predating a NOT NULL constraint) are unrecoverable
legacy-data artifacts, not a tooling bug — expected and acceptable.

## 2026-07-29 — adversarial seastar-app audit + fixes

An adversarial ("find bugs like a competitor would") pass over seastar-app/
seastar-auth against soon/'s current backend contract, run across three
parallel reviews (sola-sdk contract, SIWE/auth flow, group/membership/venue
UI). 17 findings; all fixed except the two wallet-extension e2e specs (need
real wallet-automation tooling, out of scope). soon/ suite green at 573 runs;
seastar-app `tsc --noEmit` clean. The Cypress rewrite below could not be
executed against a live server in this pass — un-skipped and repointed at the
correct contract, but not run end-to-end; treat as needing one real run
before being trusted as a regression gate.

**Backend (`soon/`):**
- **Badge/BadgeClass/Voucher browsing 401'd on every read** — none of the
  three controllers skipped `authenticate!` for index/show, but the SDK's
  corresponding read functions never sent a token (by design — these are
  public pages). Added `skip_before_action :authenticate!` for the
  genuinely-public read actions.
- **`badge_classes#invites` had no authorization check at all** — any
  authenticated user could view any group's pending invites, including
  `receiver_address` (an email, for email-type invites). Added a
  `GroupPolicy#update?` check; deliberately did NOT make this action public
  when fixing the badges/vouchers 401s above, for exactly this reason.
- **Declining a group invite always 403'd the one user it's for** —
  `GroupInvitePolicy#cancel?` only allowed the sender or a group admin; the
  *recipient* (matched by `receiver_id` or, for email invites, by email) is
  neither. Added recipient-cancel to the policy.
- **`send_with_code`'s `message` param was accepted but silently discarded** —
  unlike the direct-invite path, which persists it.

**SDK (`packages/sola-sdk`):**
- **Ticket payment-method edits duplicated instead of updating; deletes were
  no-ops** — `ticketBody()` omitted `id`/`_destroy` on
  `payment_methods_attributes`, even though the backend supports
  `accepts_nested_attributes_for allow_destroy: true`.
- **`updateGroup` silently dropped most editable fields** — banner
  image/link/text, social_links, group_tags, event/requirement/venue tag
  lists, can_publish/join/view_event all round-tripped as no-ops.
- **Ticket `status`/`start_date`/`end_date`/`days_allowed` were unreachable**
  from the frontend despite the backend accepting all four (scheduled on-sale
  dates, hiding a ticket, day-restricted tickets).
- **`getBadgeClassAndInviteByGroupName` hardcoded `groupInvites: []`** with a
  stale comment claiming the backend didn't expose it — it does
  (`badge_classes#invites`, now authorized — see above). Wired it up for real
  (manager-only; falls back to `[]` for anonymous/non-manager callers).
- Smaller SDK fixes: `updateMarker` had no location-required guard (unlike
  `createMarker`); `transferBadge`'s docstring promised eth-address/email
  target resolution the backend doesn't support (badges resolve by username
  only, unlike vouchers); `getPopupCityById`'s "is this a popup city" check
  used OR (`start_date` or `location`) while `/discover`'s listing uses AND —
  a group with only one set was reachable by ID but never listed, or vice
  versa; `getRememberMetadata` crashed on `data.types[0]` when the array was
  empty instead of returning null (the caller already handled null — the bug
  was the crash, not missing caller code); `Venue`/`VenueDetail` TS types were
  missing `archived`, which the blueprint always returns.

**Frontend (`seastar-app`):**
- **Dead "Issuer" invite-role option** — `InviteForm.tsx` still offered it;
  the backend rejects any role outside `member|manager|owner` (422), so
  picking it made the invite flow fail 100% of the time. Removed (issuer was
  already retired everywhere else, per `src/utils/index.ts`'s `isIssuer = false`).
- **The parent-group-manager capability had no UI entry point** —
  `GroupPolicy#can_assign_manager?` (2026-07-16 design decision: a parent
  group's admin/owner may toggle a child-group member's role to/from
  "manager", nothing else) was reachable from no page: `TabMembers.tsx`'s
  management-dropdown gate never considered `group.parent`, and even a
  hand-crafted request would have hit the wrong endpoint (`addManager` POSTed
  to the member-create action, which requires full `manage?` and 403s for a
  parent manager). Fixed `addManager` to PATCH an existing membership's role
  instead (correct for both direct and parent managers — its one caller only
  ever offers existing members anyway), and threaded a new
  `currUserIsParentManager` flag through `GroupPageData` → `TabMembers` to
  show a scoped "Manager Management" entry.
- **Venue `start_date`/`end_date` had no edit UI** — the backend read/wrote
  them and the SDK already passed them through, but the booking-window fields
  were simply unreachable from `VenueForm.tsx`. Added date inputs.
- `seastar-auth/.env` (git-tracked) points `NEXT_PUBLIC_API_URL` at the
  legacy sails backend — correct for production today (sails is still the
  live backend), but a fresh checkout running `bun run dev` with no
  hand-made `.env.local` silently targets it too, so the hardened SIWE nonce
  flow (server-persisted `AuthCode`) can never be exercised locally by
  default. Added a git-tracked `.env.development` (loaded by `next dev`
  before `.env`, never affects `next build`) pointing dev at
  `localhost:3000`; production behavior is untouched.
- `seastar-auth/cypress/e2e/Auth.cy.ts` was entirely `describe.skip` and
  targeted sails-only routes end to end. Rewritten against soon's actual
  `/api/v1/auth/*` contract and current component selectors/redirects; wallet
  sign-in specs stay skipped (need real wallet-extension automation, not an
  endpoint fix) with that reasoning now stated instead of silently skipped.

## 2026-07-29 — behavioral parity pass vs sails/, SIWE hardening, migration tooling

Suite green at 567 runs. Prompted by `soon/design/BEHAVIOR_COMPARISON.md` (new
this pass — a functional/behavioral audit vs sails/, deeper than the existing
`SAILS_COMPARISON.md` schema/scope audit) and a matching API-contract audit of
seastar-app's `soon` git branch. Full findings/citations live in those two
docs; this entry is the fix summary.

**Functional bugs fixed (real divergences from sails/, not intentional):**

- **Join-time capacity enforcement** — `ParticipantsController#create` had no
  `max_participant`/venue-capacity check at all (overbooking risk); the
  ticketed `rsvp` path already tracked `event.participant_count` for exactly
  this, the free/direct-join path just never used it. Extended that same
  counter to create/update/destroy/approve.
- **Venue `start_date`/`end_date` booking window restored** — soon/'s schema
  had dropped these entirely; a venue meant only for a fixed popup-city date
  range could be booked outside it. Migration + `Venue#check_availability`
  enforcement + validation.
- **EventRole co-host rights restored** — `EventPolicy#update?` (also gates
  approve/reject/check_in) never consulted EventRole; a co-host lost edit/
  approve/check-in rights they'd have in sails/. Scoped to `role: "manager"`
  specifically (soon/'s EventRole already distinguishes co-host from
  merely-listed speaker; sails/ granted this to any assigned role, looser).
- **Buyer confirmation email on ticket purchase** — `TicketItem#confirm_payment!`
  only ever notified the group owner; the buyer got nothing. Added
  `EventMailer#ticket_purchased`, fired once per purchase.
- **Self-service join requests now expire** (30 days, matching sails/) —
  `request_invite` never set `expires_at`, `accept_request` never checked it.
- **One canonical, persisted timezone source for venue availability checks** —
  four call sites (event create/update, recurring create/update) resolved the
  zone three different ways, converging correctly today only by coincidence
  (parallel fallback chains landing on the same group timezone). `event.timezone`
  is now always persisted at save time instead of frequently left nil, so
  every check site can just read it directly — immune to a group's timezone
  setting changing after the fact. Surfaced two related gaps while making
  recurring time/venue editing fully usable (per explicit request — sails/
  under-supported this): `RecurringController#update` only re-checked
  availability when `venue_id` was re-sent (a pure time-shift on a series
  that already has a venue skipped the check entirely); and the check used
  the stale pre-update timezone even when the same request also changed it.
- **SIWE hardening**: `verify_wallet` passed the message's own domain/nonce
  back into the gem's verify call as the "expected" values — a self-matching
  no-op. Added an explicit `ALLOWED_SIWE_DOMAINS` allowlist checked before the
  nonce lookup (so a rejected domain never burns the nonce).
- **Replaced the unmaintained `siwe` gem with `siwe-rb`** (spruceid/siwe-ruby
  hadn't had a real commit since 2023-07). Reviewed the replacement's full
  `lib/` before adopting (anchored non-backtracking regexes, no eval/dynamic-
  send on untrusted input, same underlying `eth` gem for signature recovery,
  smart-contract-wallet RPC path unreachable since never configured). Note:
  `signinwithethereum` (the new gem's org) is not spruceid — new org, 0 stars
  at review time — a deliberate call to adopt via normal rubygems versioning
  anyway; worth re-reviewing the diff on any future version bump.
- **`EventBlueprint`/`TicketsController#index` were missing `payment_methods`**
  on nested tickets (no `view: :extended` passed to the association/render) —
  every ticket showed as "paid" in the event editor regardless of actual
  price, and editing a paid ticket lost its payment methods on load.
- **`VenueBlueprint` was missing `require_approval`/`group_id`/`image_urls`/
  `track_ids`/`archived`** — all writable via `venue_params`, never exposed on
  read. Worse than a display gap: seastar-app's venue edit form hydrates its
  draft straight from the GET response and saves the whole draft back on
  update, so every edit of an existing venue silently wiped these fields to
  blank/false/[] even when the user never touched them.
- **Frontend**: `admin` → `manager` Membership-role rename (landed backend-side
  earlier) wasn't finished on the seastar-app `soon` branch — `addManager`
  sent the dead role string (422 every time), two group-picker filters
  silently dropped managers, and three permission checks never recognized a
  real manager. Also fixed `createEvent` to send `event_roles`/`tickets`
  inline (matching the backend's atomic-create contract) instead of two
  follow-up requests that could leave a bare event behind on failure.

**Deliberate design decision (not a bug fix — recorded for a later product
call):** a parent-group manager's only capability over a child group is now
promoting/demoting a member to/from that child group's manager role.
Previously (matching sails/'s documented "Parent-Child Groups" contract in
the monorepo `CLAUDE.md`) a parent manager could fully manage a child group —
update its settings, destroy it, manage its venues/tracks/badge classes/
invites. That full-manage path is narrowed to direct admins only;
`GroupPolicy#can_assign_manager?` is the one surviving parent-inclusive
check. Whether to restore broader parent-manager access is explicitly left
open, not resolved here — see `GroupPolicy`'s comment.

**Migration tooling**: `script/migrate_from_sails.rb` (a real one-shot ETL
from sails/'s DB into soon/'s, previously written but never committed) is now
tracked, with a `DRY_RUN` mode and a hard abort if ever pointed at a
non-local target (it unconditionally `TRUNCATE`s every table it touches).
Ran a dry-run + real load against local-only databases (sails/'s local dev
DB, seeded from a prior production import — production itself was never
touched) — see `soon/design/migration_report_2026-07-29.md` for the full
read/skip/error breakdown and root-caused every non-zero skip count back to
pre-existing sails/-side data-quality gaps, not script bugs. Also added a
`GroupInvite`-based redesign of the group-ticket claim-on-signup flow
(`ticket_id` on `GroupInvite`, previously an unused column) replacing the
ported-verbatim sails/ mechanism that never actually bound a ticket back to
an account on signup.

**Test-environment safety**: added `.env.test` (dotenv-rails loads it before
the plain `.env`) plus a boot-time guard in `config/environments/test.rb`
that aborts if the resolved database host isn't local — defends against the
exact failure mode that hit sails/ (see sails/'s own `.env.test` + guard,
committed the same day): `DATABASE_URL` overrides `config/database.yml` for
every Rails environment including test.

## 2026-07-16 — wallet & third-party auth (seastar-auth migration H)

Suite green at 528 runs.

- **SIWE wallet login**: `GET /auth/nonce` mints a single-use nonce (stored as
  an AuthCode, context `siwe_nonce`); `POST /auth/verify_wallet` verifies the
  EIP-4361 message + signature (new `siwe` gem) against that nonce — replay of
  a signed message is rejected — and signs in `find_or_create_by(eth:)`
  (addresses normalized to lowercase). sails never stored its nonces, so any
  self-consistent message verified; soon requires a server-minted nonce.
- **Trusted signin**: `POST /auth/trusted_signin` for the auth service's
  server-verified flows (Google OAuth → `email`, Solana signature →
  `sol_address`), gated by the `NEXT_TOKEN` shared secret (secure_compare;
  endpoint disabled when the env var is unset). New `users.sol` column
  (unique).
- **Email signup**: `request_code`/`verify_code` now serve unknown emails too —
  first login creates the account (`find_or_create_by(email:)`), matching
  sails' signin_with_email. Malformed emails get a 422 instead of the old
  silent uniform no-op.
- **Bind email**: `POST /auth/request_code` with `context=bind_email` +
  `POST /auth/bind_email` (authed) attach a code-verified email to a
  wallet-first account. Bind codes and login codes are separate contexts and
  can't be replayed across flows; email is set-once and must be unused.
- **User model**: email/name are now optional (wallet-first accounts have
  neither until bind/register); a user must have at least one of email/eth/sol;
  email+eth normalized to lowercase; users#update rejects blanking-out an
  existing name.

## 2026-07-16 — platform-admin curation + polish (frontend migration G)

Suite green at 508 runs.

- **Platform admins**: `User#platform_admin?` (`users.permissions` includes
  `"admin"`). They manage/freeze/delete any group and may set the privileged
  `featured`/`top` group_tags (stripped for everyone else); `/users/me`
  exposes `permissions` so the UI can gate admin actions. Restores sails'
  popup-city curation (tags are clean names now — no `:` prefix).
- groups#create/update render the `:detail` view (writes return the full
  group payload).
- Group calendar feed resolves by slug (subscription URLs use the name).
- tickets#update/destroy for event editing (sold tickets retire to
  `inactive`); tickets#list supports event-wide manager listing
  (`:with_profile`); VenueBlueprint emits `place`; EventBlueprint emits
  `requirement_tags`/`notes`; PaymentMethodBlueprint emits `token_address`/
  `chain_token_addresses`; invite activities carry `group_name` payload.

## 2026-07-16 — public map/comments, profile tabs, member email, marker authz (frontend migration F)

Gaps surfaced while rewriting the SDK. Suite green at 503 runs.

- **Markers**: index is public with `group_id` (TSID or slug) + `category`
  filters (anonymous callers must filter by group); **security fix** — the
  existing `MarkerPolicy` was never invoked: any authenticated user could
  create markers in any group and update/destroy anyone's. Now enforced
  (create: group member; update/destroy: owner or group manager).
- **Comments**: `GET /comments` is public (threads render on public pages).
- **Events**: `owner_id` / `attendee_id` filters (TSID or username) on the
  public list — profile-page "hosting"/"attended" tabs. These filters bypass
  the authenticated caller's own-groups default scope.
- **Groups**: `POST /groups/:id/send_email` (manager-only) — broadcast to all
  active members via `GroupMailer#member_broadcast`; `test_recipient` sends a
  single preview email. Returns `{sent_count, test}`.
- Blueprinter timestamps are ISO 8601 (`...T...Z` / plain dates) — JS `Date`
  can't reliably parse Ruby's default `to_s`.

## 2026-07-16 — remember feature (frontend migration E)

Ports sails' "remember" (shared commemorative badge for people physically
together) onto soon's voucher/badge primitives. Suite green at 498 runs.

- `POST /remember` — creates a `strategy: "remember"` voucher from a
  `badge_type: "remember"` badge class and auto-joins the creator.
- `POST /remember/:voucher_id/join|cancel` — join roster is
  `remember/join` activities on the voucher (idempotent join).
- `POST /remember/:voucher_id/mint` — creator-only, ≥2 joiners; one identical
  badge per joiner via `Voucher#build_badge_for` with the same badge_class
  index locking as vouchers#use; voucher consumed (counter → 0).
- `GET /remember/meta` (public) — badge_class id + joiner threshold; resolved
  by `badge_type: "remember"` instead of sails' hardcoded id.
- `GET /remember/:voucher_id` (public) — the QR-poll payload
  (voucher/badge_class/join roster).
- `GET /remember/related_groups?user_ids=` (public) — popup-city groups each
  user attended (replaces sails' hardcoded 14-group allowlist with the
  dated+located group rule).

## 2026-07-16 — places/tracks/discover/search (frontend migration C+D)

Third and fourth backend chunks of the seastar-app → soon migration. Suite
green at 493 runs.

### Places (C)
- `POST /places` is **find-or-create by name** — the frontend resolves every
  location-bearing write (events, venues, markers) to a `place_id` first, so an
  existing name returns the existing record (200) instead of erroring.
- `GET /places/search?query=` — typeahead over name/address.
- `places.data` jsonb added (carries the Google place id, as sails did).
- **Fix:** longitude validation was bounded to ±90 (latitude's range), rejecting
  any place east of 90°E (Tokyo at 139°E). Now ±180.

### Tracks (C)
- Full CRUD (group-manager only). `name` slug generated from title on collision
  (`edge-city-workshops-2`). `manager_ids` syncs `TrackRole` rows (role admin).
  `:with_roles` view; public index filterable by group slug.

### Discovery (D)
- `GET /discover` (public) — featured groups (`group_tags && {featured,top}`),
  popup cities (groups with `start_date` + `location`, `:detail` view), next
  20 public events.
- `GET /search?keyword=` (public, ≥2 chars) — events (public+published only),
  groups, users, badge_classes; ILIKE, 10 each.
- `GET /users/:id/groups?role=` (public) — a user's active memberships with
  their groups (profile page "communities"), role-filterable.

## 2026-07-16 — public event browsing + event ops (frontend migration B)

Second backend chunk of the seastar-app → soon migration. Suite green at 482 runs.

### Public filtered event list
- `GET /events` is now public: anonymous callers see public/published events;
  `visible_to` keeps hiding drafts/private. Filters: `group_id` (TSID or slug),
  `collection` (upcoming|past|ongoing), `start_date`/`end_date` interpreted in
  the request `timezone`, `search_title` (ILIKE, sanitized), `tags` (array
  overlap), `venue_id`, `track_id`, `kind`, `category`, `pinned`,
  `skip_recurring`. Authenticated callers with no group filter keep the old
  "my groups" scope.
- With a token the listing carries `is_attending`/`is_starred`/`is_owner`
  viewer flags — two plucks total, blueprint checks set membership (no N+1).

### Event ops
- `GET /events/pending_approval` — review inbox for groups the caller manages.
- `POST /events/:id/approve` — pending → published; **manager-only**
  (`EventPolicy#approve?` — owning the event does not let you self-approve).
- `POST /events/:event_id/participants/check_in` — manager stamps
  `register_time` on an attendee's participant (door scan); idempotent.
- `GET /venues/:id/conflict?start_time&end_time[&exclude_event_id]` — first
  clashing event for the window (event editor pre-submit warning).

## 2026-07-16 — public reads, by-name lookups, richer blueprints (frontend migration A)

First backend chunk of the seastar-app → soon migration. Suite green at 474 runs.

### Identifiers
- `User.resolve!` / `Group.resolve!`: API paths accept a TSID **or** the unique
  name slug (`/users/alice`, `/groups/edge-city`) — powers `/profile/[name]` and
  `/group/[name]` frontend routes.
- Group `name` is now a validated unique slug (`/\A[a-z0-9_-]{3,30}\z/`, unique
  index added) — same handle concept as `User#name`, hyphens additionally allowed.

### Public reads (anonymous, server-rendered pages)
- `authenticate_optional!` in `Api::BaseController`: sets `current_user` from a
  valid Bearer token, stays anonymous otherwise — public endpoints can personalize.
- Public now: `users#show` (email only for self/"me"), `groups#show`,
  `memberships#index` (roster), `events#show` (EventPolicy still hides
  drafts/private from anonymous viewers).

### Blueprints
- `GroupBlueprint` default gains `nickname/image_url/logo_url`; new `:detail` view
  emits the full group page payload (bio, banners, social_links, tags, timezone,
  dates, can_*_event, counts, parent/children, tracks, venues, memberships).
- `UserBlueprint` new `:profile` view (bio, eth, social_links); `:self` includes it.
- `EventBlueprint` gains `image_url/recurring_id/form_id` + `owner`/`track`
  associations; `:extended` adds `tickets`; `events#show` now renders `:extended`.

### Group freeze
- `POST /groups/:id/freeze` deactivates (`active: false`) without destroying —
  **owner-only** (`GroupPolicy#freeze?`); admins cannot take a group offline.

## 2026-07-16 — iCalendar redesign + timezone correctness

Redesigned event calendar generation and fixed the timezone bugs it depended on.
Suite green at 459 runs.

### The core bug (matches a sails user report)
The old `Event#to_ics` passed a datetime to `Icalendar::Values::DateTime.new` with
**no `tzid`**, producing a *floating* DATE-TIME (`DTSTART:20260716T140000` — no `Z`,
no `TZID`). Calendar clients render floating times in the **viewer's** zone, so a
14:00 Shanghai event showed as 14:00 for a New York subscriber instead of the real
02:00. (sails had the same class of bug via `in_time_zone(tz)` without `tzid`.)

### EventCalendar service (new)
- One place builds all `.ics` output (`app/services/event_calendar.rb`), used by both
  emails and feeds. Emits the event in its **own zone with a TZID + full VTIMEZONE**
  (DST rules included) via `icalendar/tzinfo`, so every viewer sees the correct instant.
  UTC events use canonical `...Z` times (no redundant VTIMEZONE).
- Stable per-event **UID**, monotonic **SEQUENCE** (from `updated_at`, bumps on edit),
  UTC **DTSTAMP**, **ORGANIZER**/optional **ATTENDEE**, and iTIP **METHOD**
  (REQUEST invite / CANCEL / PUBLISH feed) set on both the VCALENDAR and the MIME part.

### Lifecycle + delivery
- Approval → `REQUEST` invite; cancellation → `CANCEL`; **new**: editing a calendar-relevant
  field (time/place/title/status…) emails attendees an `updated` invite with a bumped
  SEQUENCE so their calendar updates in place. Emails now render the **event-local** time
  with its zone abbreviation (was raw UTC).

### Apple Calendar subscription feeds (new, public)
- `GET /api/v1/events/:id/calendar.ics` (single) and `GET /api/v1/groups/:id/calendar.ics`
  (group feed, `METHOD:PUBLISH` + `X-WR-CALNAME` + refresh hints) — subscribable via
  `webcal://`. Public but only expose published, public events.

### Timezone fixes
- **Recurring across DST**: `RecurringController` now parses `start_time` in the series'
  zone (a naive `"2026-03-01 10:00"` means 10:00 *local*, not UTC) and advances occurrences
  in that zone, so a weekly 10:00 stays 10:00 across the spring-forward boundary (was
  drifting an hour). `Event#event_timezone`/`#local_start`/`#local_end` centralize safe
  zone resolution (invalid free-text → UTC, never raises).
- **Events inherit the group's timezone** when none is given (`before_validation`, fixed at
  creation) — a group-scoped event no longer needs a redundant `timezone`.
- **`events#create`/`update` interpret naive time strings in the event's zone** (the
  request's timezone, else the current one on update, else the group's) — `"2026-07-16 14:00"`
  for a Shanghai event is stored as 06:00 UTC, not 14:00 UTC. An explicit offset in the string
  still wins. Consistent with the recurring path; recurring's `resolve_zone` also falls back to
  the group zone.

## 2026-07-16 — email notifications + Cloudflare image upload

Ported the two remaining sails subsystems the API needed — transactional email
and image upload — as clean, self-contained features. Suite green at 445 runs.

### Email notifications (Resend + ActionMailer)
- **Delivery**: production sends via Resend (`config.action_mailer.delivery_method = :resend`,
  `config/initializers/resend.rb` reads `RESEND_API_KEY`). Test uses `:test`; the test env now
  pins `:test` ActiveJob adapter so `deliver_later` is deterministic.
- **Coherent branding** (improves on sails' per-template inlining): from-address, product name,
  logo, and web host live once in `ApplicationMailer` + `MailerHelper`; a single branded
  `layouts/mailer.{html,text}.erb` shell wraps every message, so templates carry only content.
  Every mail is multipart HTML **and** text.
- **Mailers**: `AuthMailer#login_code`, `GroupMailer#{invite,ticket_purchased}`,
  `CommentMailer#feedback`, `EventMailer#{participant_approved,participant_rejected,cancelled}`.
  Event approval/cancellation carry an `.ics` calendar invite via the new `Event#to_ics`
  (icalendar gem); cancellation emits `STATUS:CANCELLED`/`METHOD:CANCEL`.
- **Wired the standing TODO hooks + more**: login code (auth `request_code`, `deliver_now` so
  failures surface), feedback comment, group-ticket purchase, email group invite, participant
  approve. Added a `participants#reject` action (sibling of `approve`) and event-cancellation
  fan-out to attending participants (`deliver_later`).

### Image upload (Cloudflare Images)
- `POST /api/v1/upload/image` — **authenticated** (sails' equivalent was an open endpoint),
  validates content-type + 10 MB size, forwards the file to Cloudflare Images via the existing
  `httpx` (no new dependency), returns the delivery URL. Logic is isolated in a
  `CloudflareImages` service (sails used a bare global `$client`).
- Config (ENV): `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_IMAGES_TOKEN`. New `.env.example` documents
  all feature env vars.

### Tests (+24)
- Mailer unit tests (subjects/recipients/bodies + `.ics` attachments), `CloudflareImages` service
  tests (variant selection, not-configured guard), uploads controller tests (auth, success with
  stubbed Cloudflare, validation, 502 on failure), and an `email_notifications` integration suite
  asserting the right mail fires on each domain event.

## 2026-07-16 — auth/group/membership: fix review findings + drop `handle`

A code review of login, group creation/management, and membership fixed 8 findings, and — per the
product decision that `handle` is legacy `sails/` design — dropped the `handle` column entirely so
both users and groups are identified by `name`. Suite green at 390 runs.

### Fixed — auth
- **Login-code brute force / stacking.** `AuthCode` gained `MAX_ATTEMPTS = 5` and an `attempts`
  counter (migration `20260316000005`); `verify_code` burns the code after 5 wrong tries and compares
  with `ActiveSupport::SecurityUtils.secure_compare`. `request_code` invalidates any prior active
  login codes so an attacker can't hold several concurrently-guessable codes.
- **Account enumeration.** `request_code` now returns a uniform `{message: "Code sent"}` whether or
  not the email exists (previously 404 leaked which emails had accounts).
- Codes are scoped by `context` ("login") so a code minted for one flow can't verify another;
  `last_signin_at` is stamped on success.

### Fixed — group / membership
- **Authorization centralized in `GroupPolicy`.** `update?/destroy?/manage?` require `manages?`
  (own admins/owners, or a *parent*-group manager per the Parent-Child contract); `members?`
  requires membership-or-manage. Hand-rolled `authorize_group_admin!`/`group_admin?` helpers removed.
- **Owner-role protection.** A non-owner admin can no longer grant the owner role, self-promote to
  owner, or demote the owner (membership create/update guards), and the **last owner** of a group
  can't be removed.
- **`memberships#index` no longer leaks email** — it renders `UserBlueprint`'s default view (email
  lives only in the `:self` view).
- **`memberships_count` via `counter_cache`** on `Membership belongs_to :group` — `Group#add_member`
  no longer hand-increments, so create/destroy keep the count exact.
- **Group create is transactional** and routes the owner through `add_member`; nesting under a parent
  you don't manage is rejected (`parent_ok?`).

### Changed — `handle` → `name`
- Dropped `users.handle` (migration `20260316000006`); users are identified by `name`, which now
  carries the slug rule (`/\A[a-z0-9_]{3,30}\z/`, unique). `name` is not user-clearable (presence)
  but the format check is `allow_blank` so presence owns the empty case.
- Groups are looked up by `name` too (was `handle`/`nickname` in filters). All controller lookups
  (vouchers, badges, badge_classes, tickets, group_invites) migrated `handle:` → `name:`.
- **Email is PII:** `UserBlueprint` default view excludes it; only the `:self` view (own record)
  includes it. `users#update` permits neither `handle` nor `email`.

### Tests
- 14 regressions added: owner-role guards, last-owner protection, index membership-gate + no email
  leak, counter_cache correctness, parent-manager-manages-child, unmanaged-parent create 403, group
  timezone update, own-vs-other email visibility, name slug/uniqueness 422.

## 2026-07-16 — badge/voucher: fix review findings + drop redundant columns

A code review of the badge/voucher features fixed 8 findings and removed redundant schema fields.
Suite green at 373 runs.

### Fixed
- **Non-atomic batch sends.** `send_badge` / `send_badge_by_address` / `send_badge_by_email` used
  `return` inside `.map` with no transaction, so a mid-batch invalid receiver left earlier vouchers
  committed while returning an error (retry → duplicates). Extracted one `issue_vouchers` helper that
  wraps the batch in a transaction (bad receiver → whole batch rolls back) and applies the
  unweighted-value guard consistently (it previously existed only on `send_badge`).
- **swap ignored the caller's own badge.** A burned or non-transferable badge you own could be
  swapped away (only the target was checked). `swap` now guards `@badge` too. Added `Badge#held?`
  to dedup the `minted|accepted` check across transfer/swap_code/swap.
- **swap token type not verified.** `Badge.decode_swap_code` now requires `auth_type == "swap"`, so a
  generic JWT carrying a badge_id is no longer accepted as a swap token.
- **`remember` strategy fell through `Voucher#use` with no eligibility check.** The case now
  default-denies any strategy without an explicit rule.
- **Dead features made reachable.** `can_send_badge` and `permissions` are now permitted on
  badge_class create (with a `can_send_badge` inclusion validation), so `group_member_send`
  authorization and `group_member_pass` auto-join actually work.
- **Invalid `display` on badge update** returned 500 (enum ArgumentError); now validated → 422.
- **Badge `index` race.** `index` is allocated under the badge_class row lock (was only the voucher
  lock), so concurrent redemptions of different vouchers of the same class can't collide.
- **Repeated RecordNotFound rescues** replaced by one `rescue_from` in `Api::BaseController`
  (~10 hand-written rescues removed; `badges#swap` keeps its local "invalid swap token" mapping).
- Extracted `Voucher#build_badge_for(user)` to centralize the voucher-override precedence.

### Removed redundant columns (migration `20260316000004`)
- `badges`: `last_value_used_at`, `domain`, `hashtags` (never populated), `metadata` (verbatim copy
  of `badge_classes.metadata` — read it through the association).
- `badge_classes`: `domain`, `hashtags` (never settable), `status` (`freezed` was never enforced).
- `vouchers`: `receiver_address_type` (fully derivable from `strategy`). *(The identically-named
  `group_invites.receiver_address_type` is a different column and was kept.)*

## 2026-07-16 — event/recurring/venue: build missing features + fix review findings

A code review of the event / recurring / venue / visibility area found two named features
entirely unbuilt and several authorization/integrity bugs in what existed. This change builds the
missing pieces and fixes the bugs. Suite green at 362 runs.

### New: recurring event series (`Api::V1::RecurringController`)
- `POST /recurring` creates a `Recurring` + one `Event` per occurrence (`interval` day|week|month,
  `event_count`). If a `venue_id` is given, **every** occurrence must pass the venue
  overlap/availability check before anything is created — the whole series is created in one
  transaction or not at all.
- `PATCH /recurring/:recurring_id` updates the series' events; `selector: "after"` (+ `after_event_id`)
  limits the change to that occurrence onward, otherwise the whole series. Optional
  `start_time_diff`/`end_time_diff` (seconds) shift each occurrence and re-run the venue check.
- `POST /recurring/:recurring_id/cancel` soft-cancels the selected occurrences (`status → cancelled`),
  never destroys. `Recurring has_many :events` is now `dependent: :nullify` so deleting a series row
  can never cascade away events + attendees.

### New: venue booking & availability
- `Venue#check_availability(start, end, timezone, event_id = nil)` — the canonical check
  (overlap against other non-cancelled events, date-override priority over weekly slots,
  empty-intervals = closed, no-records = open 7×24), mirroring the sails/ design.
- Wired into `EventsController` create/update and the recurring flow: an event with a `venue_id`
  is now rejected if it double-books the venue, falls outside configured hours, or its
  `max_participant` exceeds the venue capacity.
- `VenuesController` gained `create`/`update`/`destroy` (group-admin) and
  `POST /venues/:id/availability` to configure `Availability` records (previously a dead model).
- `Availability` now allows empty intervals (a valid "closed" marker) and validates day_of_week.

### Fixed review findings
- **Visibility was unenforced.** `EventPolicy#show?` was hardcoded `true` and `show` never called
  `authorize`, so any authenticated user could read any private/draft event by ID. `show` now
  authorizes, and `index` filters via a new `Event.visible_to(user)` scope (public+published to all;
  draft/private only to owner/group-manager).
- **Cancelling destroyed data.** `EventsController#destroy` did a hard `@event.destroy`, cascading
  away participants/tickets/coupons. It now soft-cancels (`status: "cancelled"`, row preserved).
  **Venue `destroy` is likewise a soft delete** — new `venues.archived` flag (migration
  `20260316000003`), archived venues drop out of `index`, events keep referencing them.
- **Event could be moved into another group.** `update` no longer accepts `group_id` changes
  (authorization was checked against the old group).
- **Cross-group resource attachment.** `venue_id`/`track_id` are validated to belong to the event's
  group before save.
- **Missing enum validations.** `Event#status` and `#visibility` now have inclusion validations;
  `Recurring#interval` is constrained to day|week|month.

Migrations: `20260316000003` (venues.archived).

## 2026-07-16 — fixes from a focused code review of the ticket/payment/coupon/badge flow

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
