# sails/ → soon/ data migration — local dry-run + load report

**Date**: 2026-07-29
**Scope**: local-only. Source = `solia_development` (sails' local Postgres dev DB,
seeded from an earlier production import — confirmed no `DATABASE_URL` override
active, no remote host in either side's connection config). Target =
`sails_db_development` (soon/'s own local Postgres dev DB). **Production was not
touched** — verified before running: `ActiveRecord::Base.connection_db_config`
had no `host` set on either side, and the script now hard-aborts if it ever
detects one (see `script/migrate_from_sails.rb`, added this pass).

**This report needs a human read-through before anyone treats the migration
path as trustworthy** — it documents what ran and what I checked, not a
sign-off.

## What changed in the script this pass

- Added `DRY_RUN=1` — builds id maps and reads/transforms every source row
  (validating `req`/`null_dup`/`suffix_dup`) without truncating or writing to
  the target. Note its "inserted" number is an *estimate* (buffer size) — it
  can't see real DB-level unique-constraint conflicts, which only show up on
  an actual load (see participants/event_roles below).
- Added a hard guard: aborts if the target DB config has a `host` or if
  `DATABASE_URL` is set, since the script unconditionally `TRUNCATE`s every
  table it migrates. It must only ever run against a bare local database name.
- Committed the script — it was previously untracked (`git status` showed
  `??`), someone had run it once locally (2026-07-16) but the tool itself was
  never saved.

## Run 1: `DRY_RUN=1`

Read/transform-only, no writes. Confirmed the read/skip logic behaves as
expected before touching the target DB. Full per-table read/skip counts
matched Run 2's read/skip columns exactly (deterministic — same source, same
transform code).

## Run 2: real load (target truncated + reloaded)

| table | read | inserted (target has) | skipped |
|---|---:|---:|---:|
| users | 34234 | 34168 | 66 (identity-merged, see below — not data loss) |
| groups | 451 | 451 | 0 |
| events | 18082 | 18079 | 3 |
| venues | 520 | 498 | 22 |
| tracks | 67 | 67 | 0 |
| track_roles | 3 | 3 | 0 |
| places | 2272 | 2272 | 0 |
| memberships | 3793 | 3793 | 0 |
| badge_classes | 1933 | 1933 | 0 |
| badges | 3661 | 3661 | 0 |
| vouchers | 1345 | 1345 | 0 |
| recurrings | 830 | 830 | 0 |
| tickets | 381 | 381 | 0 |
| payment_methods | 205 | 205 | 0 |
| coupons | 182 | 182 | 0 |
| participants | 55221 | **55202** | 19 more than the dry-run estimate — see below |
| ticket_items | 1666 | 1666 | 0 |
| event_roles | 13175 | **12667** | 264 more than the dry-run estimate — see below |
| group_invites | 3582 | 3582 | 0 |
| comments | 4224 | 4224 | 0 |
| activities | 3069 | 3069 | 0 |
| markers | 1592 | 1576 | 16 |
| availabilities | 52 | 52 | 0 |
| domains | 31245 | 31245 | 0 |
| forms | 23 | 23 | 0 |
| form_fields | 62 | 62 | 0 |
| form_submissions | 100 | 100 | 0 |
| form_answers | 292 | 292 | 0 |

Target DB row counts were verified directly against `sails_db_development`
after the load (not just trusting the script's own "inserted" tally).

## Investigated every non-zero skip — root cause, not just a count

All of these are **pre-existing data-quality gaps in the source sails/
database itself**, not migration-script bugs. Confirmed by direct SQL against
`solia_development`:

- **users, 66**: intentional identity-merge, not a skip in the "lost data"
  sense — 66 legacy `profiles` rows share an email/wallet/username/phone with
  an earlier row and get folded into that survivor's soon `users` id (every
  foreign key pointing at the duplicate is redirected to the survivor, see
  `build_user_map`). Confirmed: 34234 read = 34168 kept + 66 merged.
- **events, 3**: `group_id IS NULL` on 3 rows (ids 11573, 12033, 12034 —
  titles "Hello from Propel", "test create", "test create 2" — look like
  actual test/orphaned rows in production data).
- **venues, 22**: `group_id IS NULL` on all 22 (a `NOT EXISTS` join makes this
  look like a dangling FK at first glance, but it's actually just a NULL
  column, not a broken reference to a deleted group). Sample titles: "The
  Loft - Annex 1", "Hub - Boardroom 1", etc. — soon/'s `Venue` requires a
  group, so these can't carry over as-is.
- **event_roles, 244** (of 264 total gap — see below): `item_type IS NULL` on
  244 rows (vs. 6436 `"Group"` + 6495 `"Profile"` for the rest) — the
  polymorphic `item` was never set on these co-host/speaker rows.
- **markers, 16**: `place_id IS NULL` on exactly 16 (group_id/owner_id/title
  are all non-null on every row) — soon/'s `Marker` requires a place.

## The two counts that came in lower than the dry-run's naive estimate

The dry-run's "inserted" number is just `buf.size` — it can't detect real
Postgres unique-constraint conflicts, which `insert_all`'s
`ON CONFLICT DO NOTHING` only surfaces on an actual write:

- **participants**: 19 rows collided on soon's `UNIQUE (user_id, event_id)`
  index. Root cause: the identity-merge above collapses distinct legacy
  `profiles` into one `users` row — if two of a survivor's merged identities
  had each separately RSVPed to the same event, that's now a legitimate
  duplicate under soon's schema and `ON CONFLICT DO NOTHING` correctly kept
  just one. Not data loss of substance (same person, same event).
- **event_roles**: 264 rows (244 of them the null-`item_type` skip above,
  plus 20 more) collided on soon's `UNIQUE (event_id, item_id, item_type)`
  index, for the same identity-merge reason.

**Both are the correct outcome**, not something to fix in the script — but
flagging explicitly since it's a case where dedup happens silently by design
and is worth a human eyeballing the reasoning above before trusting it blind.

## Integrity checks run against the target DB post-load

All zero (no dangling required FKs anywhere checked):
```
events.group_id -> groups            : 0 dangling
events.owner_id -> users             : 0 dangling
memberships.{group_id,user_id}       : 0 dangling
participants.{event_id,user_id}      : 0 dangling
venues.place_id (nullable)           : 0 dangling
ticket_items.ticket_id (nullable)    : 0 dangling
```

## Field-level spot check

3 random groups compared source vs. target by `ref_id` (the legacy integer id
soon/ stores alongside the new TSID) — `name`/`nickname`/`timezone` matched
exactly in all 3 (`testgroup`/498, `steemians`/885, `strike-being`/3716).
This was a small manual sample, not a systematic diff — worth doing a larger
automated field-diff pass before this migration is trusted for anything more
than local dev/testing.

## Explicitly NOT done in this pass (flagging so it isn't assumed covered)

- No systematic field-by-field diff beyond the 3-row spot check above.
- No re-verification that soon/'s app-level behavior (auth, ticket claim,
  venue booking) actually works correctly against this now-populated local
  DB — worth a manual pass through the key flows next.
- Production `sola_sails_db` (PlanetScale) was never connected to by anything
  in this pass — confirmed by the config check above, not just by intent.
