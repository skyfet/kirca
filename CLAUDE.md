# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo layout

Two independent projects, each with its own toolchain:

- `backend/` — Cloudflare Worker (`kirca-api`), TypeScript + Hono, deployed
  via `wrangler`. State lives in D1 (`DB` binding), R2 (`ATTACHMENTS`), and
  two Durable Object classes (`ROOM`, `USER_HUB`).
- `flutter_app/` — Flutter client (Riverpod, `flutter_secure_storage`,
  `sqflite`). Bundle id `ai.kirca.app`. Backend URL is a `--dart-define`
  (`KIRCA_API_BASE`), defaulted in `lib/config.dart`; `wsBase` is derived
  from it (`http(s)://` → `ws(s)://`).

Top-level docs: `README.md` (overview, Russian), `DEPLOY.md` (CI/CD +
APNs/Codemagic setup), `LAUNCH.md`, `ROADMAP.md`.

## Architecture (big picture)

The backend is a single Worker that does HTTP + WebSocket. Two DO classes:

- **`Room`** (`src/room.ts`, `idFromName(roomId)`) — one DO per chat room.
  Holds active WS connections via Hibernation API (`acceptWebSocket` +
  `serializeAttachment`), persists messages to D1, dedups on
  `UNIQUE(room_id, client_id)` (clients generate `client_id` UUIDv4 for
  at-least-once send). Per-user rate limit in DO memory (10 msgs / 5 s).
  Internal HTTP endpoints `/online` and `/broadcast` are called by the
  worker after edit/delete/read.
- **`UserHub`** (`src/user_hub.ts`, `idFromName(userId)`) — one DO per
  user, holds that user's WS connections across devices (the `/v1/ws`
  channel). Pure server→client fan-out for cross-room events (new room,
  membership changes, push echoes). Receives `POST /notify` from the
  worker and from `Room` after a broadcast (`src/lib/notify.ts`).

Worker entry is `src/index.ts`: CORS, request-id middleware, structured
`logInfo`/`logError`, then mounts route modules from `src/routes/` (auth,
devices, rooms, messages, profile, uploads, ws). Cross-cutting helpers
live in `src/lib/` (`auth`, `apns`, `rate_limit`, `notify`, `cron`,
`openapi`, `schemas`, …).

OpenAPI is the source of truth: routes are declared with
`@hono/zod-openapi` via the wrappers in `src/lib/openapi.ts`, served at
`/openapi.json`, rendered at `/docs` (Scalar UI, `src/docs.ts`). Landing
HTML is `src/home.ts`. Don't hand-edit a spec file — change the route
definitions and the spec regenerates.

Auth: passwords are scrypt-hashed (`s1:<salt>:<hash>`), sessions are rows
in D1 with `expires_at = now + 30d`; legacy SHA-256 hashes are silently
upgraded on next successful login. Rate-limit on register/login is
per-IP (`CF-Connecting-IP`), fixed-window 1 h, persisted in D1
(`rate_limits` table swept daily by the cron at `0 3 * * *` —
`runDailySweep` in `src/lib/cron.ts`).

Push is APNs-direct via Web Crypto (`src/lib/apns.ts`). Configuration is
the `APNS_*` vars in `wrangler.toml` plus the `APNS_KEY` secret. If any
of those is missing, push is silently disabled — handy for local dev.

Flutter client mirrors the backend's reliability story: an on-disk
`outbox` (sqflite, `lib/storage/outbox.dart`) survives crashes,
`lib/ws/user_ws.dart` reconnects with exponential backoff
(1→2→4→8→16→30 s), and the per-room WS replays pending messages on
reconnect. `lib/api.dart` has a global 401 hook
(`registerUnauthorizedHandler`) that triggers a forced logout from
anywhere.

## Always run tests locally before pushing

Don't push anything unverified. Before `git push` on any branch that
touches code, run the relevant suite locally and confirm it's green.

### Backend (`backend/`)

```bash
cd backend
npx tsc --noEmit       # type-check
npm test               # vitest-pool-workers unit tests (miniflare-backed)
```

Run a single vitest file or test:

```bash
npx vitest run test/unit/auth.test.ts
npx vitest run -t "dedup"
```

For the Postman/Newman e2e suite — it must run against a **local**
worker, not prod (prod has rate limits and a public URL that may be
blocked by sandboxed networks, producing misleading 503s):

```bash
cd backend
npx wrangler d1 migrations apply kirca-api --local
npx wrangler dev --local --port 8787 &
# wait for /healthz to return 200
npx newman run test/kirca-api.postman_collection.json \
  -e test/kirca-api.postman_environment.json \
  --env-var baseUrl=http://127.0.0.1:8787 \
  --reporters cli
```

All assertions must pass. If any fail, fix and re-run — do not push.

### Flutter (`flutter_app/`)

```bash
cd flutter_app
flutter analyze
flutter test
flutter test test/rooms_tile_golden_test.dart   # single file
```

Golden tests live under `test/goldens/`. If you change UI intentionally,
regenerate with `flutter test --update-goldens`.

## Common backend commands

`backend/package.json` scripts:

- `npm run dev` — `wrangler dev` on `:8787`.
- `npm run db:migrate:local` / `:remote` / `:staging` — apply
  `migrations/*.sql` to the corresponding D1.
- `npm run deploy` / `npm run deploy:staging` — wrangler deploy (prod /
  the `kirca-api-staging` worker). CI does this on push to `main` / `dev`
  via `.github/workflows/backend.yml` and `backend-staging.yml`; only run
  manually when bootstrapping a new account.

## Config files: no Cyrillic

`*.yaml` / `*.yml` / `*.toml` / `*.json` config files must be
ASCII-only (English comments). Russian belongs in `*.md` docs and
prose, not in CI / wrangler / codemagic configs — some linters and
editors with strict encoding settings choke on UTF-8 there.

## Wrangler / D1 / DO gotchas

- `wrangler.toml` ships with the prod `database_id` baked in. Staging
  needs a one-time `wrangler d1 create kirca-api-staging` and the new id
  pasted into `[[env.staging.d1_databases]]` (see `DEPLOY.md`).
- Any change that adds/renames a Durable Object class requires a new
  `[[migrations]]` block with `new_sqlite_classes` / `renamed_classes`
  in `wrangler.toml` — otherwise deploy will refuse.
- DO instances are addressed by **name**: rooms use
  `ROOM.idFromName(roomId)`, user hubs use `USER_HUB.idFromName(userId)`.
  Don't introduce a second addressing scheme — the dedup and routing
  assumptions depend on this.
