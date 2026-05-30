#!/usr/bin/env bash
# Run the Postman/Newman e2e suite against a LOCAL wrangler worker.
#
# The suite must never run against prod: prod has rate limits and a public
# URL that may be blocked by sandboxed networks, both of which surface as
# misleading 503s (and cascading 401s once an auth step fails to return a
# token). A local worker is deterministic and credential-free.
#
# Usage: bash scripts/e2e-local.sh   (run from the backend/ directory)
set -euo pipefail

PORT="${PORT:-8787}"
BASE_URL="http://127.0.0.1:${PORT}"
LOG="$(mktemp -t wrangler-dev.XXXXXX.log)"
WORKER_PID=""

cleanup() {
  # wrangler dev spawns a workerd child; kill the whole process group so the
  # listener doesn't outlive this script (setsid below makes WORKER_PID the
  # group leader, so its pgid == pid).
  if [ -n "${WORKER_PID}" ] && kill -0 "${WORKER_PID}" 2>/dev/null; then
    kill -- "-${WORKER_PID}" 2>/dev/null || kill "${WORKER_PID}" 2>/dev/null || true
    wait "${WORKER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Fresh local D1 schema (idempotent — wrangler tracks applied migrations).
npx wrangler d1 migrations apply kirca-api --local

# Boot the worker in the background, in its own process group (setsid) so
# cleanup can reap workerd along with it.
setsid npx wrangler dev --local --port "${PORT}" >"${LOG}" 2>&1 &
WORKER_PID=$!

# Wait for /healthz to return 200 (up to 60s).
ready=""
for _ in $(seq 1 60); do
  if curl -fsS "${BASE_URL}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "${WORKER_PID}" 2>/dev/null; then
    echo "wrangler dev exited before becoming ready; log follows:" >&2
    cat "${LOG}" >&2
    exit 1
  fi
  sleep 1
done

if [ -z "${ready}" ]; then
  echo "worker did not become ready within 60s; log follows:" >&2
  cat "${LOG}" >&2
  exit 1
fi

npx newman run test/kirca-api.postman_collection.json \
  -e test/kirca-api.postman_environment.json \
  --env-var "baseUrl=${BASE_URL}" \
  --reporters cli
