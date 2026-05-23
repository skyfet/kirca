#!/usr/bin/env bash
# Flutter env bootstrap for kirca (headless Linux desktop + wrangler backend).
# Idempotent: safe to re-run.
set -euo pipefail

FLUTTER_VERSION="${FLUTTER_VERSION:-3.44.0}"
FLUTTER_DIR="${FLUTTER_DIR:-/opt/flutter}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

# ── 1. system deps ───────────────────────────────────────────────────────────
need_apt=(
  # Linux desktop build (flutter drive -d linux)
  clang cmake ninja-build pkg-config
  libgtk-3-dev liblzma-dev libstdc++-12-dev
  # sqflite_common_ffi + flutter_secure_storage backends
  libsqlite3-dev libsecret-1-dev
  # headless display + dbus + keyring (for integration_test on headless CI)
  xvfb x11-utils dbus-x11 gnome-keyring
  # download
  curl ca-certificates tar xz-utils git
)

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  missing=()
  for pkg in "${need_apt[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    apt-get update -qq
    apt-get install -y --no-install-recommends "${missing[@]}"
  fi
fi

# ── 2. Flutter SDK ───────────────────────────────────────────────────────────
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  echo ">>> downloading Flutter $FLUTTER_VERSION → $FLUTTER_DIR"
  mkdir -p "$(dirname "$FLUTTER_DIR")"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/flutter.tar.xz" \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  tar -xf "$tmp/flutter.tar.xz" -C "$(dirname "$FLUTTER_DIR")"
  rm -rf "$tmp"
fi
git config --global --add safe.directory "$FLUTTER_DIR" || true
export PATH="$FLUTTER_DIR/bin:$PATH"
flutter --version >/dev/null 2>&1 || true

# ── 3. Flutter app: pub get + Linux desktop target ───────────────────────────
APP_DIR="$PROJECT_DIR/flutter_app"
if [ -f "$APP_DIR/pubspec.yaml" ]; then
  cd "$APP_DIR"
  if [ ! -d linux ]; then
    flutter create . --platforms=linux --project-name=kirca >/dev/null
  fi
  flutter pub get
fi

# ── 4. Backend: npm install + D1 local migrations ────────────────────────────
BE_DIR="$PROJECT_DIR/backend"
if [ -f "$BE_DIR/package.json" ]; then
  cd "$BE_DIR"
  npm install --no-audit --no-fund --silent
  npx wrangler d1 migrations apply kirca-api --local >/dev/null 2>&1 || true
fi

# ── 5. Persist PATH for the session (Claude Code on the web) ─────────────────
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$FLUTTER_DIR/bin:\$PATH\""
    echo 'export DISPLAY="${DISPLAY:-:99}"'
  } >> "$CLAUDE_ENV_FILE"
fi

echo "✓ Flutter $($FLUTTER_DIR/bin/flutter --version 2>/dev/null | head -1) ready"
