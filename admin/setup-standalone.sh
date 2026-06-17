#!/usr/bin/env bash
# admin/setup-standalone.sh — ONE-SHOT root setup for a standalone (non-fleet)
# shared lean-global-cache, with autoupdate. Stands the whole thing up by
# itself: no bots-host, no hostbot, no /opt/bots, no deploy-handler.
#
# What it does (all idempotent — safe to re-run):
#   1. Creates a dedicated owner system user (the single writer).
#   2. Creates the prefix skeleton, owner-owned.
#   3. Clones the repo (or fast-forwards an existing clone) to $SRC.
#   4. Writes /etc/lean-cache.conf so the CLI/admin scripts share OWNER/GROUP/ROOT/BIN.
#   5. Bootstraps elan (the Lean toolchain manager) into the shared ELAN_HOME —
#      the CLI uses elan but does not install it.
#   6. Installs the lean-cache CLI and creates the cache tree (versions are
#      installed on demand via `lean-cache install`, NOT provisioned here).
#   7. Symlinks the CLI onto PATH.
#   8. Installs a sudoers rule letting ANY local user run install/uninstall as
#      the owner (so the cache stays single-writer / correctly-permissioned no
#      matter who triggers it).
#   9. Installs a systemd timer that fast-forwards + redeploys on a schedule.
#
# Run:  sudo ./admin/setup-standalone.sh
#
# It deliberately does NOT run admin/migrate-ownership.sh: that adopts a
# pre-existing badly-ACL'd cache tree, which a fresh standalone host has none of.
#
# Access model: the cache is world-readable (the CLI normalizes everything to
# go=rX), so any user can `use`/`link`/build against it with no setup. Mutations
# (install/uninstall) re-exec as $OWNER via the sudoers rule below — that
# re-exec is what guarantees owner-owned, lottery-free permissions; it is NOT an
# access gate. Hence no group and no per-user enrolment is needed.

set -euo pipefail

# ---- configuration (edit to taste) ----------------------------------------
OWNER=leancache                              # single writer; owns the cache
PREFIX=/opt/lean-global-cache
SRC="$PREFIX/src"                            # deployment clone (tracks origin/$BRANCH)
ROOT="$PREFIX/data"                          # cache tree: lakes/, elan/
BINDIR="$PREFIX/bin"
BIN="$BINDIR/lean-cache"                     # pinned binary (sudoers + re-exec target)
PATH_LINK=/usr/local/bin/lean-cache          # on-PATH symlink -> $BIN
REPO_URL="https://github.com/jesyspa/lean-global-cache.git"
BRANCH=main
UPDATE_ON_CALENDAR="hourly"                  # systemd OnCalendar= for autoupdate
CONF=/etc/lean-cache.conf
# ---------------------------------------------------------------------------

[[ "$(id -u)" -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }
log() { echo "==> $*"; }
run_owner() { runuser -u "$OWNER" -- "$@"; }

# --- 1. owner user (its primary group is auto-created by useradd) ------------
if ! getent passwd "$OWNER" >/dev/null; then
  log "creating system user $OWNER (home=$PREFIX, no login)"
  useradd --system --user-group --home-dir "$PREFIX" --shell /usr/sbin/nologin "$OWNER"
fi
GROUP="$(id -gn "$OWNER")"                    # the owner's own group; cosmetic only

# --- 2. prefix skeleton, owner-owned ----------------------------------------
log "ensuring $PREFIX skeleton"
install -d -o "$OWNER" -g "$GROUP" -m 2755 "$PREFIX" "$BINDIR"

# --- 3. deployment clone (clone if absent, else fast-forward) ---------------
if [[ ! -d "$SRC/.git" ]]; then
  log "cloning $REPO_URL -> $SRC"
  run_owner git clone --branch "$BRANCH" "$REPO_URL" "$SRC"
else
  log "fast-forwarding existing clone $SRC"
  run_owner git -C "$SRC" fetch --quiet origin "$BRANCH"
  run_owner git -C "$SRC" merge --ff-only "origin/$BRANCH"
fi

# --- 4. /etc/lean-cache.conf (deterministic, root-owned) --------------------
log "writing $CONF"
cat > "$CONF" <<EOF
# lean-cache.conf — standalone shared host. Managed by admin/setup-standalone.sh.
# The CLI, deploy.sh, and the admin scripts all resolve these four settings.
OWNER=$OWNER
GROUP=$GROUP
ROOT=$ROOT
BIN=$BIN
EOF
chown root:root "$CONF"
chmod 0644 "$CONF"

# --- 5. elan (Lean toolchain manager) into the shared ELAN_HOME -------------
# The CLI runs `elan`/`lake` with ELAN_HOME=$ROOT/elan and $ROOT/elan/bin on
# PATH, but never installs elan itself. Bootstrap it here, as the owner, so
# `lean-cache install` can provision toolchains. --no-modify-path: the CLI
# prepends $ELAN_HOME/bin itself, so no profile editing is needed.
ELAN_BIN="$ROOT/elan/bin/elan"
if [[ ! -x "$ELAN_BIN" ]]; then
  command -v curl >/dev/null || { echo "need curl to bootstrap elan" >&2; exit 1; }
  log "bootstrapping elan into $ROOT/elan"
  install -d -o "$OWNER" -g "$GROUP" -m 2755 "$ROOT"
  run_owner env ELAN_HOME="$ROOT/elan" sh -c \
    'umask 022; curl --proto "=https" --tlsv1.2 -sSf https://elan.lean-lang.org/elan-init.sh | sh -s -- -y --no-modify-path --default-toolchain none'
else
  log "elan already present at $ELAN_BIN"
fi

# --- 6. install the CLI + cache tree (no version provisioning) ---------------
# Versions are installed on demand by users (`lean-cache install <ver>`), so we
# deliberately skip deploy.sh's `versions` reconcile and just lay down the CLI
# and the cache dirs. The CLI reads /etc/lean-cache.conf at runtime.
log "installing the lean-cache CLI to $BIN"
run_owner install -m 0755 "$SRC/bin/lean-cache" "$BIN"
run_owner install -d -m 2755 "$ROOT/lakes" "$ROOT/elan"

# --- 7. on-PATH symlink -----------------------------------------------------
if [[ "$(readlink -f "$PATH_LINK" 2>/dev/null || true)" != "$BIN" ]]; then
  log "linking $PATH_LINK -> $BIN"
  ln -sfn "$BIN" "$PATH_LINK"
fi

# --- 8. sudoers (any local user may install/uninstall as the owner) ---------
# The re-exec produces owner-owned, correctly-permissioned files regardless of
# caller. lean-cache strictly validates the version arg (vX.Y.Z[-suffix]) before
# acting, so the trailing wildcard cannot smuggle in extra behaviour.
log "installing sudoers rule (any user may install/uninstall as $OWNER)"
SUDO_TMP="$(mktemp)"
trap 'rm -f "$SUDO_TMP"' EXIT
cat > "$SUDO_TMP" <<EOF
# Managed by lean-global-cache (admin/setup-standalone.sh).
# Any local user may manage the shared Lean cache as its owner, $OWNER.
ALL ALL=($OWNER) NOPASSWD: $BIN install *, $BIN uninstall *
EOF
visudo -cf "$SUDO_TMP" >/dev/null || { echo "sudoers syntax check failed" >&2; exit 1; }
install -m 0440 -o root -g root "$SUDO_TMP" /etc/sudoers.d/lean-cache
log "installed /etc/sudoers.d/lean-cache"

# --- 9. autoupdate: updater script + systemd service + timer ----------------
log "installing autoupdate units"
cat > "$PREFIX/autoupdate.sh" <<EOF
#!/usr/bin/env bash
# autoupdate.sh — fast-forward $SRC to origin/$BRANCH and reinstall the CLI.
# A failing test.sh rolls HEAD back to the prior sha. No-op when origin has not
# advanced. Versions are NOT provisioned here (on-demand only). Generated by
# setup-standalone.sh.
set -euo pipefail
cd "$SRC"
OLD=\$(git rev-parse HEAD)
git fetch --quiet origin "$BRANCH"
NEW=\$(git rev-parse "origin/$BRANCH")
[[ "\$OLD" == "\$NEW" ]] && exit 0
echo "updating \$OLD -> \$NEW"
git merge --ff-only "origin/$BRANCH"
if [[ -x ./test.sh ]] && ! ./test.sh; then
  echo "tests failed; rolling back to \$OLD" >&2
  git reset --hard "\$OLD"
  exit 1
fi
install -m 0755 ./bin/lean-cache "$BIN"
EOF
chown "$OWNER:$GROUP" "$PREFIX/autoupdate.sh"
chmod 0755 "$PREFIX/autoupdate.sh"

cat > /etc/systemd/system/lean-cache-update.service <<EOF
[Unit]
Description=lean-global-cache autoupdate (fast-forward + redeploy)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$OWNER
Group=$GROUP
ExecStart=$PREFIX/autoupdate.sh
TimeoutStartSec=0
EOF

cat > /etc/systemd/system/lean-cache-update.timer <<EOF
[Unit]
Description=Run lean-global-cache autoupdate ($UPDATE_ON_CALENDAR)

[Timer]
OnCalendar=$UPDATE_ON_CALENDAR
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now lean-cache-update.timer

# --- summary ----------------------------------------------------------------
cat <<EOF

==> done.

  owner       : $OWNER   (single writer; any user installs via sudo)
  clone       : $SRC   (tracks origin/$BRANCH)
  cache       : $ROOT
  CLI         : $BIN   (on PATH via $PATH_LINK)
  autoupdate  : systemd timer 'lean-cache-update.timer' ($UPDATE_ON_CALENDAR)

Anyone can immediately: lean-cache use / link / publish-build (world-readable
cache, no enrolment). install/uninstall re-exec as $OWNER via sudo, NOPASSWD.

Notes:
  * No Lean versions are pre-provisioned. Install on demand, e.g.:
        lean-cache install v4.30.0
  * To run lean/lake interactively (outside 'lean-cache'), users add the shared
    toolchain to their shell rc:
        export ELAN_HOME=$ROOT/elan
        export PATH="\$ELAN_HOME/bin:\$PATH"
  * Run an update now:   sudo systemctl start lean-cache-update.service
  * Inspect the timer:   systemctl list-timers lean-cache-update.timer
EOF
