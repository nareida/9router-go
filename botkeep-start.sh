#!/bin/bash
# botkeep-start.sh — 9router-go runner for Botkeep.cloud
#
# Adapted from nareida/keirouter-mod/botkeep-start.sh, retargeted to 9router-go.
# Reads the port Botkeep injects, binds 0.0.0.0, downloads the latest release
# binary at container start (binary is gitignored — never ship 30MB+ in repo),
# and writes data into the workspace so it survives restarts within the same
# deploy but stays out of git.
set -euo pipefail

# ── Port ────────────────────────────────────────────────────────────────────
# Botkeep's container-port env var is SERVER_PORT first (per the keirouter-
# patching skill: "Botkeep env: Botkeep container port env var is SERVER_PORT,
# not PORT"). Fall back to PORT, then 9router-go's default.
APP_PORT="${SERVER_PORT:-${PORT:-20130}}"
echo "==> 9router-go on port $APP_PORT"

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/9router-go"
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"

mkdir -p "$DATA_DIR"

# ── Binary: download at container start, never commit ──────────────────────
# 9router-go ships as a single CGO-free binary with the Svelte dashboard
# embedded — no separate frontend-dist fetch needed (unlike keirouter).
# Binary is gitignored in this repo; the source of truth is GitHub Releases.
if [ ! -x "$BIN" ]; then
  echo "==> Downloading 9router-go release binary (linux-amd64)..."
  # Try the pinned version first, then fall back to latest.
  PINNED="${NINEROUTER_VERSION:-}"
  if [ -n "$PINNED" ]; then
    URL="https://github.com/luqman-v1/9router-go/releases/download/${PINNED}/9router-go-linux-amd64"
  else
    URL="https://github.com/luqman-v1/9router-go/releases/latest/download/9router-go-linux-amd64"
  fi
  curl -fsSL --retry 3 -o "$BIN" "$URL"
  chmod +x "$BIN"
  echo "==> Downloaded $( "$BIN" version 2>/dev/null || echo 'version unavailable' )"
fi

# ── Environment for Botkeep ─────────────────────────────────────────────────
# 9router-go binds all interfaces by default when PORT is set; we still make
# the bind explicit. DATA_DIR points the SQLite DB + run files into the
# workspace so they persist across restarts inside the same deploy.
export PORT="$APP_PORT"
export DATA_DIR="$DATA_DIR"
export HOST="${HOST:-0.0.0.0}"

# SECURITY: never keep the default dashboard password (123456) on a public host.
# INITIAL_PASSWORD is only honored on first run (when the DB is empty); after
# that the password is stored hashed in SQLite and changed via the dashboard.
# If you want a specific first-run password, set INITIAL_PASSWORD in the
# Botkeep env panel before the first start. A random fallback is generated
# here only when neither the panel nor .env supplied one — and printed once.
if [ -z "${INITIAL_PASSWORD:-}" ] && [ ! -f "$DATA_DIR/db/data.sqlite" ]; then
  INITIAL_PASSWORD="$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
  export INITIAL_PASSWORD
  echo "==> First run: generated dashboard password (INITIAL_PASSWORD): $INITIAL_PASSWORD"
  echo "==> Save this now — it will not be shown again. Change it in the dashboard after login."
fi

# JWT secret: 9router-go needs one for session tokens. Generate a stable random
# secret per-deploy if the panel didn't supply JWT_SECRET. NOTE: regenerating
# this on every container restart invalidates existing sessions (not data) —
# set a fixed JWT_SECRET in the Botkeep panel for stable sessions.
if [ -z "${JWT_SECRET:-}" ]; then
  JWT_SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
  export JWT_SECRET
  echo "==> WARNING: JWT_SECRET not set in panel — generated a random one."
  echo "==> Sessions will reset on restart. Set JWT_SECRET in the Botkeep env panel for stability."
fi

# ── Launch ───────────────────────────────────────────────────────────────────
echo "==> Running $BIN on 0.0.0.0:$APP_PORT (DATA_DIR=$DATA_DIR)"
exec "$BIN"
