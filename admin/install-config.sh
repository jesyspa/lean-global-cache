#!/usr/bin/env bash
# admin/install-config.sh — ONE-TIME root setup. Installs the host config to
# /etc/lean-cache.conf from lean-cache.conf.example, so the CLI and the
# deploy/admin scripts all resolve the same OWNER / GROUP / ROOT / BIN.
#
# Run this BEFORE deploying the CLI on a shared-writer (fleet) host: without it
# the CLI falls back to single-user defaults (the calling user and
# $HOME/.local/share), which is wrong for the shared cache.
#
# Single-user hosts do not need this — leave /etc/lean-cache.conf absent and the
# defaults apply.
#
#   sudo ./admin/install-config.sh
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/lean-cache.conf.example"
DST="/etc/lean-cache.conf"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }
if [[ -e "$DST" ]]; then
  echo "$DST already exists — leaving it untouched (edit by hand if needed)"
  exit 0
fi

install -m 0644 -o root -g root "$SRC" "$DST"
echo "installed $DST — review and edit its values to match this host:"
sed 's/^/    /' "$DST"
