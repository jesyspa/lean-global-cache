#!/usr/bin/env bash
# deploy.sh — runs as hostbot from ~hostbot/deployments/lean-global-cache/.
#
# Installs the `lean-cache` CLI to /opt/bots/bin and reconciles the versions
# listed in ./versions against the shared cache (idempotent). All cache files
# end up hostbot-owned and not group-writable.
#
# One-time root setup (ownership migration + sudoers) lives in admin/ and is
# NOT run here — see admin/README.md. deploy.sh never needs root.
set -euo pipefail

if [[ "$(id -un)" != "hostbot" ]]; then
  echo "deploy.sh: must run as hostbot (got $(id -un))" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="/opt/bots/bin/lean-cache"
ROOT="/opt/bots/lean"

umask 022
log() { echo "==> $*"; }

# --- 1. Install the CLI -------------------------------------------------------

log "installing $BIN_DST"
install -m 0755 "$REPO_DIR/bin/lean-cache" "$BIN_DST"

# --- 2. Ensure the cache root exists, hostbot-owned, not group-writable --------
# (Ownership of any pre-existing tree is fixed once by admin/migrate-ownership.sh;
#  here we only create-if-missing and set modes on what we own.)

mkdir -p "$ROOT/lakes" "$ROOT/elan"
chmod 2755 "$ROOT" "$ROOT/lakes" "$ROOT/elan" 2>/dev/null || true

# --- 3. Reconcile versions ----------------------------------------------------

if [[ -f "$REPO_DIR/versions" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    log "ensuring version $line"
    "$BIN_DST" install "$line"
  done < "$REPO_DIR/versions"
fi

log "deploy complete"
