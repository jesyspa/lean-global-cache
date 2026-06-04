#!/usr/bin/env bash
# admin/install-sudoers.sh — ONE-TIME root setup. Lets any bots-group user run
# the mutating lean-cache subcommands as hostbot, so installs/uninstalls always
# produce hostbot-owned files. Read-only subcommands need no privilege.
#
#   sudo ./admin/install-sudoers.sh
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

DST="/etc/sudoers.d/lean-cache"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# The command path is pinned; lean-cache validates its version argument
# strictly (rejecting anything that is not vX.Y.Z[-suffix]) before acting, so
# the trailing wildcard cannot smuggle in extra behaviour — sudo execs the
# binary directly with the given argv, no shell is involved.
cat > "$TMP" <<'EOF'
# Managed by lean-global-cache (admin/install-sudoers.sh).
# Allow bots-group users to manage the shared Lean cache as its owner, hostbot.
%bots ALL=(hostbot) NOPASSWD: /opt/bots/bin/lean-cache install *, \
                              /opt/bots/bin/lean-cache uninstall *
EOF

visudo -cf "$TMP" >/dev/null || { echo "sudoers syntax check failed" >&2; exit 1; }
install -m 0440 -o root -g root "$TMP" "$DST"
echo "installed $DST"
visudo -cf "$DST" >/dev/null && echo "verified."
