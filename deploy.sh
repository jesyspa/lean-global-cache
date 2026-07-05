#!/usr/bin/env bash
# deploy.sh — install the lean-cache CLI and reconcile the versions manifest.
#
# Installs the CLI to BIN (default: $HOME/.local/bin/lean-cache on a
# single-user host; /opt/bots/bin/lean-cache on the fleet via
# /etc/lean-cache.conf) and reconciles ./versions against the shared cache
# (idempotent). All cache files end up OWNER-owned and not group-writable.
#
# One-time root setup (ownership migration + sudoers) lives in admin/ and is
# NOT run here — see admin/README.md. deploy.sh never needs root.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$REPO_DIR/lib/config.sh"

if [[ "$(id -un)" != "$OWNER" ]]; then
  echo "deploy.sh: must run as $OWNER (got $(id -un))" >&2
  exit 1
fi

BIN_DST="$BIN"

umask 022
log() { echo "==> $*"; }

# --- 1. Install the CLI -------------------------------------------------------

log "installing $BIN_DST"
mkdir -p "$(dirname "$BIN_DST")"
install -m 0755 "$REPO_DIR/bin/lean-cache" "$BIN_DST"

# The transparent `lake` shim (opt-in via INSTALL_LAKE_SHIM). Placed ahead of the
# real lake on PATH, it makes bare `lake build` route through the shared build
# policy while every other subcommand (and the LSP) passes straight through. Off
# by default; only remove a shim this tool installed (carries its marker), never
# a real lake that happens to sit there.
LAKE_SHIM_DST="$(dirname "$BIN_DST")/lake"
if [[ "$INSTALL_LAKE_SHIM" == 1 ]]; then
  log "installing $LAKE_SHIM_DST"
  install -m 0755 "$REPO_DIR/bin/lake-shim" "$LAKE_SHIM_DST"
elif grep -q 'LEAN_CACHE_LAKE_SHIM' "$LAKE_SHIM_DST" 2>/dev/null; then
  log "removing $LAKE_SHIM_DST (INSTALL_LAKE_SHIM off)"
  rm -f "$LAKE_SHIM_DST"
fi

# --- 2. Ensure the cache root exists, OWNER-owned, not group-writable --------
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
