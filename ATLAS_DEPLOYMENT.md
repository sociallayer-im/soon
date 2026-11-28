# Atlas deployment

The frontend and API use separate services. The current backend directory is `surf-backend`; its public API is https://soon.generic.dev/api/v1. `/up` is the health endpoint; `/` may return404. The current `atlas.json` uses the original Dockerfile with context `.`, port8080.

Run the existing Atlas CLI from this directory:

```sh
~/zurich/atlas/atlas/dist/atlas status
~/zurich/atlas/atlas/dist/atlas up --config atlas.json
```

Inspect the returned operation/deployment IDs and verify `/up` and `/.well-known/atlas/version` after deployment. See frontend `docs/event-fields.md` and `docs/profile-settings.md` for recent feature validation.

Private runtime values belong in ignored `.atlas/env.json`. Importing variables replaces the complete map: retain database, authentication and mail settings. Never commit credentials or point this service at the production database.

Do not run local Docker or QEMU. Atlas builds on the configured remote Linux target and uses existing Nomad/Traefik infrastructure. No Web deployment is needed when the user uploads the mini program.

`Dockerfile.Atlas` and `ginger.surf.yml` are ignored local legacy files, not the active deployment configuration. The optional `SERVE_WEB_APP` routes and WebController only run if explicitly enabled; normal deployments do not set that variable.
