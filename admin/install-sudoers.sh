#!/usr/bin/env bash
# admin/install-sudoers.sh — ONE-TIME root setup. Lets any GROUP-member user
# run the mutating lean-cache subcommands as OWNER, so installs/uninstalls
# always produce OWNER-owned files. Read-only subcommands need no privilege.
#
# OWNER, GROUP, and BIN are read from the config (env vars or the config file);
# they must match the values used by the CLI.
# See lean-cache.conf.example for the settings.
#
#   sudo ./admin/install-sudoers.sh
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"

DST="/etc/sudoers.d/lean-cache"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# The command path is pinned; lean-cache validates its version argument
# strictly (rejecting anything that is not vX.Y.Z[-suffix]) before acting, so
# the trailing wildcard cannot smuggle in extra behaviour — sudo execs the
# binary directly with the given argv, no shell is involved.
cat > "$TMP" <<EOF
# Managed by lean-global-cache (admin/install-sudoers.sh).
# Allow $GROUP-group users to manage the shared Lean cache as its owner, $OWNER.
%$GROUP ALL=($OWNER) NOPASSWD: $BIN install *, \\
$(printf '%*s' ${#GROUP} '')            $BIN uninstall *, \\
$(printf '%*s' ${#GROUP} '')            $BIN set-default-toolchain *, \\
$(printf '%*s' ${#GROUP} '')            $BIN fix-filemode, \\
$(printf '%*s' ${#GROUP} '')            $BIN fix-perms, \\
$(printf '%*s' ${#GROUP} '')            $BIN fix-perms *
EOF

visudo -cf "$TMP" >/dev/null || { echo "sudoers syntax check failed" >&2; exit 1; }
install -m 0440 -o root -g root "$TMP" "$DST"
echo "installed $DST"
visudo -cf "$DST" >/dev/null && echo "verified."
