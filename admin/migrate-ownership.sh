#!/usr/bin/env bash
# admin/migrate-ownership.sh — ONE-TIME root migration of the existing shared
# Lean cache to the single-writer model. Run by a human with sudo, once, at
# adoption time. NOT run by deploy.sh (deploy never needs root).
#
# ROOT, OWNER, and GROUP are read from the config (env vars or
# /etc/lean-cache.conf). See lean-cache.conf.example for the fleet's settings.
#
#   sudo ./admin/migrate-ownership.sh
#
# Effect: OWNER owns everything under ROOT; GROUP can read but not write; the
# per-file ACLs that caused the v4-30-0 "unreadable cache" incident are
# stripped. Best run when no bot is mid-build, since anything that was
# (incorrectly) writing into the cache will start failing afterwards.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"

[[ "$(id -u)" -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ -d "$ROOT" ]] || { echo "$ROOT does not exist" >&2; exit 1; }

# Versions to drop on adoption: everything before 4.28, plus orphan RC
# toolchains that have no corresponding lake cache. Edit before running if the
# policy changes; safe to empty the list if nothing should be dropped.
DROP=(
  "$ROOT/lakes/v4-22-0"
  "$ROOT/elan/toolchains/leanprover--lean4---v4.22.0"
  "$ROOT/elan/toolchains/leanprover--lean4---v4.29.0-rc7"
  "$ROOT/elan/toolchains/leanprover--lean4---v4.30.0-rc2"
)

echo "==> dropping pre-4.28 versions and orphan RC toolchains"
for p in "${DROP[@]}"; do
  [[ -e "$p" ]] && { echo "    rm -rf $p"; rm -rf "$p"; }
done

echo "==> chown -R $OWNER:$GROUP $ROOT  (this walks ~millions of files; be patient)"
chown -R "$OWNER:$GROUP" "$ROOT"

echo "==> stripping per-file ACLs (revert to plain mode bits)"
setfacl -R -b "$ROOT"

echo "==> owner-write, group/other read+traverse only"
chmod -R u=rwX,go=rX "$ROOT"

echo "==> setgid on directories (new files inherit group $GROUP)"
find "$ROOT" -type d -exec chmod g+s {} +

echo "==> done. Verification:"
ls -ld "$ROOT" "$ROOT/lakes" "$ROOT/elan"
getfacl -p "$ROOT" 2>/dev/null | sed 's/^/    /'
