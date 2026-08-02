# Upstream federation fixtures

Real payloads copied verbatim from the reference implementations. They are the
contract: our inbound path has to handle exactly what these peers actually
send, not what we imagine they send. When a reference checkout is upgraded,
re-copy and diff — a changed fixture is protocol drift, and the tests that read
them will say what broke.

| File | Source | Upstream commit |
|---|---|---|
| `mobilizon-*.json` | `mobilizon/test/fixtures/` | `e4e3d70747e1214415540eceb2bafeefabf0695c` (2026-06-29, v5.2.4) |
| `mastodon-*.json` | `mobilizon/test/fixtures/` — Mobilizon keeps captured Mastodon payloads for its own interop tests | same |
| `gancio-event-activity.json` | same | same |

`gancio-event-activity.json` earns its place by being *sloppy*: its `location`
has no `type` and no `address`. Mobilizon tolerates that, so we must too —
a strict parser turns a cosmetic difference into a dropped event.

Payloads are unmodified, including their original hostnames. Tests rewrite the
`actor`/`id` hosts where they need the object to appear to originate from the
signing actor.
