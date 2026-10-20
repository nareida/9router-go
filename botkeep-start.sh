#!/usr/bin/env bash
#
# 9router-go — Botkeep.cloud runner
# Adapted from nareida/keirouter-mod + nareida/OmniRoute botkeep-start.sh patterns.
#
# Why this exists (do NOT simplify without reading):
#   1. Botkeep's panel has NO env setter — every setting is self-contained here.
#   2. Botkeep's repo/ZIP import limit is ~20 MB. The 9router-go source tree
#      is ~7 MB, but its .git is ~33 MB — a full clone risks exceeding the
#      limit. This branch (botkeep) contains ONLY this script (~4 KB).
#   3. The 9router-go release binary is ~44 MB — far above any import limit.
#      => Solution: download the prebuilt single binary from GitHub Releases
#         at container start. No git clone of upstream, no Go compile.
#         9router-go ships the Svelte dashboard EMBEDDED in the binary, so
#         unlike keirouter/OmniRoute there is no separate frontend-dist fetch
#         and no npm install — one curl, one chmod, one exec.
#   4. Botkeep assigns the port at runtime: read $SERVER_PORT (fallback $PORT),
#      bind 0.0.0.0 — loopback-only answers "This application is not responding".
#   5. DATA_DIR lives OUTSIDE the app tree ($HOME/data) so restarts/redeploys
#      never wipe the SQLite DB.
#   6. The binary lives OUTSIDE the repo tree ($HOME/app) so a redeploy
#      (which replaces the repo checkout) does not force a re-download.
#
# Start command in the Botkeep panel:  bash botkeep-start.sh
# Runtime profile: Go (any version — the binary is statically linked, CGO-free).
#
set -euo pipefail

APP_PORT="${SERVER_PORT:-${PORT:-20130}}"
echo "==> 9router-go on port $APP_PORT"

# Pinned version — bump when a new release is tested. Falls back to "latest".
NINEROUTER_VERSION="${NINEROUTER_VERSION:-latest}"

# Pinned homes so credentials + SQLite survive restarts and reinstalls.
# $HOME is persistent across restarts within the same Botkeep workload.
DATA_DIR="${NINEROUTER_DATA_DIR:-$HOME/data}"
APP_DIR="${NINEROUTER_APP_DIR:-$HOME/app}"
mkdir -p "$DATA_DIR" "$APP_DIR"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl not found"

# ---------------------------------------------------------------------------
# 1. Prebuilt binary (idempotent: skipped when the version stamp matches).
#    9router-go is a single CGO-free Go binary with the Svelte dashboard
#    embedded — no node_modules, no frontend-dist, no compile step.
# ---------------------------------------------------------------------------
BIN="$APP_DIR/9router-go"
STAMP="$APP_DIR/.9router-version"

# Resolve "latest" to a concrete tag for the stamp (so we don't re-download
# every restart when the version hasn't changed).
if [ "$NINEROUTER_VERSION" = "latest" ]; then
  RESOLVED_VERSION="$(curl -fsSL --retry 3 \
    https://api.github.com/repos/luqman-v1/9router-go/releases/latest \
    | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
  [ -n "$RESOLVED_VERSION" ] || die "could not resolve latest 9router-go version"
else
  RESOLVED_VERSION="$NINEROUTER_VERSION"
fi

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$RESOLVED_VERSION" ] && [ -x "$BIN" ]; then
  info "9router-go $RESOLVED_VERSION already present — skipping download"
else
  info "Downloading 9router-go $RESOLVED_VERSION (~44 MB)..."
  DL_DIR="$(mktemp -d)"
  TMP_BIN="$DL_DIR/9router-go"
  # -f: a proxy error page must fail loudly instead of writing HTML as the binary.
  URL="https://github.com/luqman-v1/9router-go/releases/download/${RESOLVED_VERSION}/9router-go-linux-amd64"
  curl -fsSL --retry 3 --retry-delay 2 "$URL" -o "$TMP_BIN" \
    || die "download failed: $URL"
  [ -s "$TMP_BIN" ] || die "download produced an empty file"

  mv "$TMP_BIN" "$BIN"
  chmod +x "$BIN"
  rm -rf "$DL_DIR"

  printf '%s' "$RESOLVED_VERSION" > "$STAMP"
  ok "9router-go $RESOLVED_VERSION installed to $BIN"
fi

# ---------------------------------------------------------------------------
# 2. Environment. No external env setter — everything is self-contained here.
#    Botkeep's endpoint is a public hostname; an anonymous /v1 proxy on the
#    internet is an unlimited bill against your provider quotas, so auth stays ON.
# ---------------------------------------------------------------------------

# Port + bind: Botkeep injects the port; bind all interfaces.
export PORT="$APP_PORT"
export HOST="${HOST:-0.0.0.0}"

# Data dir: outside the repo tree so redeploys never wipe the SQLite DB.
export DATA_DIR="$DATA_DIR"

# JWT secret: needed for session tokens. Generate a STABLE random secret per
# workload (persisted to $DATA_DIR) so sessions survive restarts. Botkeep has
# no env panel to set a fixed secret, so we mint and persist one ourselves.
JWT_SECRET_FILE="$DATA_DIR/.jwt-secret"
if [ -z "${JWT_SECRET:-}" ]; then
  if [ -f "$JWT_SECRET_FILE" ]; then
    export JWT_SECRET="$(cat "$JWT_SECRET_FILE")"
  else
    JWT_SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
    export JWT_SECRET
    chmod 600 "$JWT_SECRET_FILE" 2>/dev/null || true
    printf '%s' "$JWT_SECRET" > "$JWT_SECRET_FILE"
    info "Generated JWT_SECRET (persisted to $JWT_SECRET_FILE)"
  fi
fi

# Dashboard password: INITIAL_PASSWORD is only honored on FIRST run (when the
# SQLite DB is empty). After that it's stored hashed in the DB and changed via
# the dashboard. Since Botkeep has no env panel, generate a random password on
# first boot and print it to stdout (the Botkeep console log) — look for BOOTSTRAP.
DB_FILE="$DATA_DIR/db/data.sqlite"
if [ ! -f "$DB_FILE" ] && [ -z "${INITIAL_PASSWORD:-}" ]; then
  INITIAL_PASSWORD="$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
  export INITIAL_PASSWORD
  echo ""
  echo "========================================================"
  echo " BOOTSTRAP: First-run dashboard password: $INITIAL_PASSWORD"
  echo " Save this now — it will NOT be shown again."
  echo " Change it in the dashboard after first login."
  echo "========================================================"
  echo ""
fi

# ---------------------------------------------------------------------------
# 3. Launch.
# ---------------------------------------------------------------------------
ok "Starting 9router-go $RESOLVED_VERSION on 0.0.0.0:$APP_PORT"
ok "Data dir: $DATA_DIR"
ok "Binary:   $BIN"

exec "$BIN"
