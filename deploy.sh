#!/usr/bin/env bash
# deploy.sh — install the lean-cache CLI and provision the shared cache tree.
#
# Installs the CLI to BIN (default: $HOME/.local/bin/lean-cache on a single-user
# host; a shared path on a multi-user host via the config file). Versions are
# not provisioned here: `lean-cache use` installs the toolchain a project pins
# the first time it is needed, and `lean-cache list` reports what a host holds.
# All cache files end up OWNER-owned and not group-writable.
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

# Publish executables with a same-directory rename. Copying directly over a
# running shell script can leave a concurrent invocation reading half old and
# half new content; a rename makes each invocation see one complete version.
DEPLOY_TMP=""
cleanup() { [[ -z "$DEPLOY_TMP" ]] || rm -f "$DEPLOY_TMP"; }
trap cleanup EXIT
install_atomic() { # install_atomic <source> <destination>
  local src="$1" dst="$2"
  DEPLOY_TMP="$(mktemp "${dst}.new.XXXXXX")"
  install -m 0755 "$src" "$DEPLOY_TMP"
  mv -f "$DEPLOY_TMP" "$dst"
  DEPLOY_TMP=""
}

# --- 1. Install the CLI -------------------------------------------------------

log "installing $BIN_DST"
mkdir -p "$(dirname "$BIN_DST")"
install_atomic "$REPO_DIR/bin/lean-cache" "$BIN_DST"

# The transparent `lake` shim (opt-in via INSTALL_LAKE_SHIM). Placed ahead of the
# real lake on PATH, it makes bare `lake build` route through the shared build
# policy while every other subcommand (and the LSP) passes straight through. Off
# by default; only remove a shim this tool installed (carries its marker), never
# a real lake that happens to sit there.
LAKE_SHIM_DST="$(dirname "$BIN_DST")/lake"
if [[ "$INSTALL_LAKE_SHIM" == 1 ]]; then
  log "installing $LAKE_SHIM_DST"
  install_atomic "$REPO_DIR/bin/lake-shim" "$LAKE_SHIM_DST"
elif grep -q 'LEAN_CACHE_LAKE_SHIM' "$LAKE_SHIM_DST" 2>/dev/null; then
  log "removing $LAKE_SHIM_DST (INSTALL_LAKE_SHIM off)"
  rm -f "$LAKE_SHIM_DST"
fi

# --- 2. Ensure the cache root exists, OWNER-owned, not group-writable --------
# (Ownership of any pre-existing tree is fixed once by admin/migrate-ownership.sh;
#  here we only create-if-missing and set modes on what we own.)

mkdir -p "$ROOT/lakes" "$ROOT/elan"
chgrp "$GROUP" "$ROOT" "$ROOT/lakes" "$ROOT/elan"
chmod 2755 "$ROOT" "$ROOT/lakes" "$ROOT/elan"

# --- 2b. Event log dir --------------------------------------------------------
# Shared, but every user writes only its own events.<user>.log — the same
# single-writer model as the cache, one writer per file. 3775 = setgid (files
# inherit $GROUP) + sticky (a group member can create its file but not remove
# another's), so the dir is safely group-writable. On a single-user host it sits
# under the owner's own ROOT and just works.
log "ensuring event log dir $LOG_DIR"
mkdir -p "$LOG_DIR"
chgrp "$GROUP" "$LOG_DIR"
chmod 3775 "$LOG_DIR"

log "deploy complete"
