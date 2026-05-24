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
npm run test:e2e:local
```

All assertions must pass. If any fail, fix and re-run — do not push.

`test:e2e:local` bakes in `baseUrl=http://127.0.0.1:8787`. The sibling
script `test:e2e:prod` uses `baseUrl` from `kirca-api.postman_environment.json`
and is reserved for the post-deploy smoke that CI runs against the
deployed worker — don't use it pre-push.

### Flutter (`flutter_app/`)

```bash
cd flutter_app
flutter analyze
flutter test
# To regenerate golden PNGs after an intentional UI change:
flutter test --update-goldens
```

## Config files: no Cyrillic

`*.yaml` / `*.yml` / `*.toml` / `*.json` config files must be
ASCII-only (English comments). Russian belongs in `*.md` docs and
prose, not in CI / wrangler / codemagic configs — some linters and
editors with strict encoding settings choke on UTF-8 there.
