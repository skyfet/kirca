# Working in this repo

## Always run tests locally before pushing

Don't push anything unverified. Before `git push` on any branch that
touches code, run the relevant suite locally and confirm it's green.

### Backend (`backend/`)

```bash
cd backend
npx tsc --noEmit       # type-check
npm test               # vitest-pool-workers unit tests
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
```

## Config files: no Cyrillic

`*.yaml` / `*.yml` / `*.toml` / `*.json` config files must be
ASCII-only (English comments). Russian belongs in `*.md` docs and
prose, not in CI / wrangler / codemagic configs — some linters and
editors with strict encoding settings choke on UTF-8 there.
