#!/usr/bin/env bash
# test.sh — runs in an isolated worktree before deploy. Self-contained, fast,
# no network, no cache mutation. Exit non-zero to abort the deploy.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$REPO_DIR/bin/lean-cache"
fail=0
note() { echo "  $*"; }
check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then note "ok: $1"
  else note "FAIL: $1 — expected '$2', got '$3'"; fail=1; fi
}

echo "== bash syntax =="
for f in "$CLI" "$REPO_DIR/bin/lake-shim" "$REPO_DIR/deploy.sh" "$REPO_DIR/test.sh" \
         "$REPO_DIR/lib/config.sh" "$REPO_DIR"/admin/*.sh \
         "$REPO_DIR/lean-cache.conf.example"; do
  [[ -e "$f" ]] || continue
  bash -n "$f" && note "ok: $f"
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  shellcheck -S warning "$CLI" "$REPO_DIR/bin/lake-shim" "$REPO_DIR/deploy.sh" "$REPO_DIR/test.sh" \
    "$REPO_DIR/lib/config.sh" "$REPO_DIR"/admin/*.sh && note "ok: shellcheck clean"
else
  echo "== shellcheck (skipped, not installed) =="
fi

echo "== version resolution =="
slug_of() { "$CLI" resolve "$1" | awk '/^slug:/ {print $2}'; }
tc_of()   { "$CLI" resolve "$1" | awk '/^toolchain:/ {print $2}'; }
check "4.30 -> v4-30-0"            "v4-30-0"      "$(slug_of 4.30)"
check "4.30.0 -> v4-30-0"          "v4-30-0"      "$(slug_of 4.30.0)"
check "v4.28.0 -> v4-28-0"         "v4-28-0"      "$(slug_of v4.28.0)"
check "prefix form -> v4-30-0"     "v4-30-0"      "$(slug_of leanprover/lean4:v4.30.0)"
check "rc -> v4-30-0-rc2"          "v4-30-0-rc2"  "$(slug_of 4.30.0-rc2)"
check "toolchain string"  "leanprover/lean4:v4.30.0" "$(tc_of 4.30)"

echo "== version validation rejects junk =="
for bad in "" "4" "foo" "4.x" "../etc" "4.30.0; rm -rf /"; do
  if "$CLI" resolve "$bad" >/dev/null 2>&1; then
    note "FAIL: accepted bad version '$bad'"; fail=1
  else
    note "ok: rejected '$bad'"
  fi
done

echo "== config resolution =="
cfg_field() { # cfg_field <env...> <field>
  local field="${@: -1}"
  local env_args=("${@:1:$#-1}")
  env "${env_args[@]}" LEAN_CACHE_CONF=/nonexistent "$CLI" config \
    | awk -v f="$field:" '$1==f{print $2}'
}
check "default owner = current user" \
  "$(id -un)" \
  "$(cfg_field owner)"
check "LEAN_CACHE_OWNER override" \
  "somebody" \
  "$(cfg_field LEAN_CACHE_OWNER=somebody owner)"
check "LEAN_CACHE_ROOT override" \
  "/tmp/x" \
  "$(cfg_field LEAN_CACHE_ROOT=/tmp/x root)"
# The per-user config file (XDG) is read when LEAN_CACHE_CONF is unset.
_xdg="$(mktemp -d)"; mkdir -p "$_xdg/lean-cache"
echo 'ROOT=/tmp/from-xdg-conf' > "$_xdg/lean-cache/lean-cache.conf"
check "XDG config file is read" \
  "/tmp/from-xdg-conf" \
  "$(env -u LEAN_CACHE_CONF -u LEAN_CACHE_ROOT XDG_CONFIG_HOME="$_xdg" "$CLI" config | awk '$1=="root:"{print $2}')"
rm -rf "$_xdg"

echo "== config block parity (bin/lean-cache vs lib/config.sh) =="
# The config-resolution block at the top of bin/lean-cache is inlined from
# lib/config.sh (the CLI stays a single self-contained file); nothing at runtime
# keeps them in sync. Fail the moment they drift on the parts they genuinely
# share: the config-file discovery block and the OWNER/GROUP/ROOT resolution
# lines. They are NOT byte-identical by design — the CLI adds CONFIG_FILE
# bookkeeping and a different BIN default — so compare only the shared regions.
config_discovery() { # the _conf discovery block, from `_conf=""` to the source line
  awk '/^_conf=""/{f=1} f{print} index($0, ". \"$_conf\""){if(f)exit}' "$1"
}
config_resolution() { grep -E '^(OWNER|GROUP|ROOT)=' "$1"; }
check "config discovery block matches" \
  "$(config_discovery "$CLI")" "$(config_discovery "$REPO_DIR/lib/config.sh")"
check "OWNER/GROUP/ROOT resolution matches" \
  "$(config_resolution "$CLI")" "$(config_resolution "$REPO_DIR/lib/config.sh")"

echo "== overlay staleness & hooks (hermetic) =="
# Everything here runs against a throwaway cache and throwaway git repos, so it
# touches neither the real /opt/bots/lean tree nor the network. LEAN_CACHE_ROOT
# redirects the layout; LEAN_CACHE_BIN makes the installed hooks call this CLI.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LEAN_CACHE_ROOT="$TMP/cache"
export LEAN_CACHE_BIN="$CLI"
for slug in v4-30-0 v4-31-0; do
  mkdir -p "$TMP/cache/lakes/$slug/packages/mathlib" \
           "$TMP/cache/lakes/$slug/packages/batteries"
done

gitc()      { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
live_slug() { # slug the project's overlay currently points its mathlib at
  local t; t="$(readlink "$1/.lake/packages/mathlib" 2>/dev/null || true)"
  t="${t%/packages/mathlib}"; basename "$t"
}
pin() { printf 'leanprover/lean4:%s\n' "$1" > "$2/lean-toolchain"; }

# Scenario: `git reset --hard` to a commit pinning a different toolchain. This
# is the case post-checkout never sees; the reference-transaction hook must.
A="$TMP/reset"; mkdir -p "$A"; gitc "$A" init -q
pin v4.30.0 "$A"; gitc "$A" add -A; gitc "$A" commit -qm a30
pin v4.31.0 "$A"; gitc "$A" add -A; gitc "$A" commit -qm b31
b31="$(gitc "$A" rev-parse HEAD)"
gitc "$A" checkout -q HEAD~1
"$CLI" use "$A" >/dev/null 2>&1
check "use overlays current toolchain"        "v4-30-0" "$(live_slug "$A")"
gitc "$A" reset --hard -q "$b31"
check "reset --hard repoints overlay"         "v4-31-0" "$(live_slug "$A")"

# Scenario: `git cherry-pick` of a commit that bumps the toolchain.
B="$TMP/pick"; mkdir -p "$B"; gitc "$B" init -q
pin v4.30.0 "$B"; gitc "$B" add -A; gitc "$B" commit -qm base
base="$(gitc "$B" rev-parse HEAD)"
gitc "$B" checkout -q -b other
pin v4.31.0 "$B"; gitc "$B" commit -qam bump
pick="$(gitc "$B" rev-parse HEAD)"
gitc "$B" checkout -q "$base"
"$CLI" use "$B" >/dev/null 2>&1
check "use overlays base toolchain"           "v4-30-0" "$(live_slug "$B")"
gitc "$B" cherry-pick "$pick" >/dev/null 2>&1
check "cherry-pick repoints overlay"          "v4-31-0" "$(live_slug "$B")"

# Scenario: hooks are installed, sentinel-marked, and idempotent.
C="$TMP/hooks"; mkdir -p "$C"; gitc "$C" init -q
pin v4.30.0 "$C"; gitc "$C" add -A; gitc "$C" commit -qm a
"$CLI" use "$C" >/dev/null 2>&1
H="$C/.git/hooks"
has_sentinel() { grep -qF lean-cache-managed-hook "$1" && echo yes || echo no; }
check "post-checkout hook marked"             "yes" "$(has_sentinel "$H/post-checkout")"
check "reference-transaction hook marked"     "yes" "$(has_sentinel "$H/reference-transaction")"
before="$(md5sum "$H/post-checkout" "$H/reference-transaction")"
"$CLI" use "$C" >/dev/null 2>&1
check "re-running use leaves hooks identical"  "$before" "$(md5sum "$H/post-checkout" "$H/reference-transaction")"

# Scenario: a pre-sentinel legacy hook is upgraded; a foreign hook is preserved.
cat > "$H/post-checkout" <<'LEGACY'
#!/usr/bin/env bash
# Re-establish the .lake/packages overlay onto the shared Lean cache after
# checkout. Installed by `lean-cache use`.
root="$(git rev-parse --show-toplevel)"
LEGACY
printf '#!/bin/sh\necho FOREIGN\n' > "$H/reference-transaction"
foreign="$(cat "$H/reference-transaction")"
"$CLI" use "$C" >/dev/null 2>&1
check "legacy hook upgraded in place"         "yes" "$(has_sentinel "$H/post-checkout")"
check "foreign hook left untouched"           "$foreign" "$(cat "$H/reference-transaction")"

# Scenario: refresh is a safe no-op off a Lean project and when already fresh.
rc=0; "$CLI" refresh "$TMP" >/dev/null 2>&1 || rc=$?
check "refresh on non-Lean dir exits 0"       "0" "$rc"
rc=0; "$CLI" refresh "$B" >/dev/null 2>&1 || rc=$?
check "refresh when fresh exits 0"            "0" "$rc"
check "refresh when fresh changes nothing"    "v4-31-0" "$(live_slug "$B")"

# Scenario: a project pinning an UN-installed version. `use` auto-installs by
# default, but with auto-install off it must hard-fail; `refresh` (the hook
# path) must stay a silent no-op rather than kick off an install on checkout.
U="$TMP/uninstalled"; mkdir -p "$U"; gitc "$U" init -q
pin v4.99.0 "$U"; gitc "$U" add -A; gitc "$U" commit -qm u
rc=0; LEAN_CACHE_AUTO_INSTALL=0 "$CLI" use "$U" >/dev/null 2>&1 || rc=$?
check "use of uninstalled ver hard-fails (opt-out)" "1" "$rc"
check "failed use created no overlay"         "" "$(live_slug "$U")"
rc=0; "$CLI" refresh "$U" >/dev/null 2>&1 || rc=$?
check "refresh of uninstalled ver exits 0"    "0" "$rc"
check "refresh of uninstalled ver no overlay" "" "$(live_slug "$U")"

# A bounded foreground call must NOT launch the multi-minute auto-install (the
# harness would kill it mid-build). It bails with the distinct code and names
# the install command to run instead — but still installs nothing.
rc=0; out="$(CLAUDE_BASH_MODE=foreground "$CLI" use "$U" 2>&1)" && rc=0 || rc=$?
check "foreground use of uninstalled ver bails, code 75" "75" "$rc"
check "foreground use bail names the install command"    "yes" \
  "$(printf '%s' "$out" | grep -q "install v4.99.0" && echo yes || echo no)"
check "foreground use bail installed nothing"            "" "$(live_slug "$U")"
# (force-wait and slot-held override the bail — exercised with stubs in the
# install section, where the auto-install can run offline.)

echo "== elan wiring (hermetic) =="
# `use` points ~/.elan at the shared ELAN_HOME ($LEAN_CACHE_ROOT/elan) so bare
# lean/lake and the editor resolve the shared toolchain, unless a real personal
# elan is present (then it warns and leaves it). HOME is redirected per case, so
# this never touches the developer's real ~/.elan.
mkdir -p "$TMP/cache/elan/bin"; : > "$TMP/cache/elan/bin/lean"
EP="$TMP/elanwire"; mkdir -p "$EP"; gitc "$EP" init -q
pin v4.30.0 "$EP"; gitc "$EP" add -A; gitc "$EP" commit -qm e
elink()    { readlink "$1/.elan" 2>/dev/null || true; }
realdir()  { [[ -d "$1" && ! -L "$1" ]] && echo yes || echo no; }

# (a) absent ~/.elan -> symlinked to the shared elan.
EA="$TMP/eh-fresh"; mkdir -p "$EA"
HOME="$EA" "$CLI" use "$EP" >/dev/null 2>&1
check "use wires an absent ~/.elan"           "$TMP/cache/elan" "$(elink "$EA")"
# (b) a correct link is idempotent.
HOME="$EA" "$CLI" use "$EP" >/dev/null 2>&1
check "use leaves a correct ~/.elan link"     "$TMP/cache/elan" "$(elink "$EA")"
# (c) a wrong/broken link is repointed.
EW="$TMP/eh-wrong"; mkdir -p "$EW"; ln -sfn /nonexistent "$EW/.elan"
HOME="$EW" "$CLI" use "$EP" >/dev/null 2>&1
check "use repoints a wrong ~/.elan link"     "$TMP/cache/elan" "$(elink "$EW")"
# (d) a real personal elan is preserved, never clobbered.
ER="$TMP/eh-real"; mkdir -p "$ER/.elan/bin"; : > "$ER/.elan/bin/lean"
HOME="$ER" "$CLI" use "$EP" >/dev/null 2>&1
check "use preserves a real ~/.elan"          "yes" "$(realdir "$ER/.elan")"

echo "== fix-filemode (hermetic) =="
# The cache normalizes permissions, which flips the exec bit on tracked files;
# fix-filemode must set core.fileMode=false on each package repo so `git status`
# stops reporting that as a change. OWNER defaults to the current user here, so
# require_owner passes without sudo (OWNER pinned to the current user).
FM="$TMP/cache/lakes/v4-30-0/packages"
for p in mathlib batteries; do
  gitc "$FM/$p" init -q
  printf 'x\n' > "$FM/$p/f.txt"; gitc "$FM/$p" add -A; gitc "$FM/$p" commit -qm seed
  chmod +x "$FM/$p/f.txt"   # mimic the cache's normalized exec bit
done
check "exec bit shows as dirty before fix" " M f.txt" "$(gitc "$FM/mathlib" status --short)"
LEAN_CACHE_OWNER="$(id -un)" "$CLI" fix-filemode >/dev/null 2>&1
check "fix-filemode silences mathlib mode diff"   "" "$(gitc "$FM/mathlib" status --short)"
check "fix-filemode silences batteries mode diff" "" "$(gitc "$FM/batteries" status --short)"
check "core.fileMode set to false" "false" "$(gitc "$FM/mathlib" config --get core.fileMode)"

echo "== uninstall (hermetic) =="
# No real elan here: a stub `elan` backed by a flat "installed toolchains" file
# stands in for `elan toolchain list`/`uninstall`, mirroring how the `lake`
# stub below stands in for builds. ELAN_STATE_FILE points the stub at that file.
ELANSTUB="$TMP/elanstub"; mkdir -p "$ELANSTUB"
cat > "$ELANSTUB/elan" <<'EL'
#!/usr/bin/env bash
state="${ELAN_STATE_FILE:?ELAN_STATE_FILE not set}"
case "$1 $2" in
  "toolchain list")
    [[ -f "$state" ]] && cat "$state"
    exit 0 ;;
  "toolchain uninstall")
    tc="$3"
    grep -qxF "$tc" "$state" 2>/dev/null || { echo "elan-stub: no such toolchain: $tc" >&2; exit 1; }
    grep -vxF "$tc" "$state" > "$state.new"    # grep exits 1 when this empties the file; that's fine
    mv "$state.new" "$state"
    exit 0 ;;
  "default "*)                                 # elan default <toolchain>
    tc="$2"
    # Real elan would DOWNLOAD an uninstalled toolchain here; the stub refuses,
    # matching the cache invariant cmd_set_default guards before ever calling us.
    grep -qxF "$tc" "$state" 2>/dev/null || { echo "elan-stub: toolchain not installed: $tc" >&2; exit 1; }
    exit 0 ;;
  *) echo "elan-stub: unsupported: $*" >&2; exit 1 ;;
esac
EL
chmod +x "$ELANSTUB/elan"
ELAN_STATE="$TMP/elan-toolchains.txt"
has_dir() { [[ -d "$1" ]] && echo yes || echo no; }
export LEAN_CACHE_OWNER="$(id -un)"   # so require_owner passes without sudo

# (a) A full-state uninstall removes both the lake cache and the toolchain, and
# warns that project pins will stop building.
UTC="leanprover/lean4:v4.77.0"; USLUG="v4-77-0"
mkdir -p "$TMP/cache/lakes/$USLUG/packages/mathlib"
printf '%s\n' "$UTC" > "$ELAN_STATE"
out="$(PATH="$ELANSTUB:$PATH" ELAN_STATE_FILE="$ELAN_STATE" "$CLI" uninstall 4.77.0 2>&1)"
check "uninstall removes the lake cache"      "no"  "$(has_dir "$TMP/cache/lakes/$USLUG")"
check "uninstall removes the toolchain"       "no"  "$(grep -qxF "$UTC" "$ELAN_STATE" && echo yes || echo no)"
check "uninstall warns pinning projects break" "yes" \
  "$(printf '%s' "$out" | grep -qi 'no longer build' && echo yes || echo no)"

# (b) Idempotent re-run on a half-removed version (lake cache already gone,
# toolchain still lingering — the current real state of 4.28.0) finishes the job.
printf '%s\n' "$UTC" > "$ELAN_STATE"     # lake cache stays absent from (a)
PATH="$ELANSTUB:$PATH" ELAN_STATE_FILE="$ELAN_STATE" "$CLI" uninstall 4.77.0 >/dev/null 2>&1
check "half-state re-run removes the lingering toolchain" "no" \
  "$(grep -qxF "$UTC" "$ELAN_STATE" && echo yes || echo no)"

# (c) A further re-run, with nothing left to remove, is a clean no-op.
out="$(PATH="$ELANSTUB:$PATH" ELAN_STATE_FILE="$ELAN_STATE" "$CLI" uninstall 4.77.0 2>&1)"
check "no-op re-run reports nothing to do" "yes" \
  "$(printf '%s' "$out" | grep -qi 'nothing to do' && echo yes || echo no)"

# (d) uninstall skips elan's default toolchain (removing it would break elan),
# with a clear note, but still removes the lake cache.
DTC="leanprover/lean4:v4.78.0"; DSLUG="v4-78-0"
mkdir -p "$TMP/cache/lakes/$DSLUG/packages/mathlib"
printf '%s (default)\n' "$DTC" > "$ELAN_STATE"
out="$(PATH="$ELANSTUB:$PATH" ELAN_STATE_FILE="$ELAN_STATE" "$CLI" uninstall 4.78.0 2>&1)"
check "uninstall skips the elan default toolchain" "yes" \
  "$(grep -qxF "$DTC (default)" "$ELAN_STATE" && echo yes || echo no)"
check "uninstall still removes the lake cache for the default" "no" "$(has_dir "$TMP/cache/lakes/$DSLUG")"
check "uninstall notes the default-toolchain skip" "yes" \
  "$(printf '%s' "$out" | grep -qi 'default' && echo yes || echo no)"

echo "== set-default-toolchain (hermetic) =="
# Sets the shared elan default, but only for an already-installed toolchain —
# defaulting to an uncached one would download it into the shared tree behind
# `install`'s back. Reuses the elan stub (its `default` arm refuses uninstalled).
STC="leanprover/lean4:v4.79.0"
# (a) installed -> succeeds and confirms the new default.
printf '%s\n' "$STC" > "$ELAN_STATE"
rc=0; out="$(PATH="$ELANSTUB:$PATH" ELAN_STATE_FILE="$ELAN_STATE" "$CLI" set-default-toolchain 4.79.0 2>&1)" || rc=$?
check "set-default of installed ver exits 0"   "0" "$rc"
check "set-default confirms the new default"   "yes" \
  "$(printf '%s' "$out" | grep -qi 'default toolchain set to' && echo yes || echo no)"
# (b) not installed -> hard-fails, tells the user to install first, calls no elan.
printf '%s\n' "$STC" > "$ELAN_STATE"    # 4.80.0 absent from state
rc=0; out="$(PATH="$ELANSTUB:$PATH" ELAN_STATE_FILE="$ELAN_STATE" "$CLI" set-default-toolchain 4.80.0 2>&1)" || rc=$?
check "set-default of uninstalled ver fails"   "1" "$rc"
check "set-default names the install remedy"   "yes" \
  "$(printf '%s' "$out" | grep -qi 'not installed' && echo yes || echo no)"

echo "== install: build slot (hermetic) =="
# cmd_install's replay build (lake build Mathlib …) is a cold build and must take
# a host build slot like any policied cold build, so a cache install can't thrash
# alongside them. Stub elan + lake so install runs fully offline; OWNER is the
# current user (exported above) so require_owner passes without sudo.
ISTUB="$TMP/istub"; mkdir -p "$ISTUB"
cat > "$ISTUB/elan" <<'EL'
#!/usr/bin/env bash
# Minimal elan: `toolchain list` is empty (so install takes the install path);
# every call is a no-op success.
exit 0
EL
chmod +x "$ISTUB/elan"
cat > "$ISTUB/lake" <<'LK'
#!/usr/bin/env bash
echo "lake $*" >> "${LAKE_LOG:-/dev/null}"
if [[ "$1 $2" == "update mathlib" ]]; then
  # Fabricate the flat packages tree with a mathlib olean, as real lake would,
  # so install's integrity check passes. OLEAN_CONTENT lets a --force rebuild be
  # told apart from the original tree.
  mkdir -p .lake/packages/mathlib/.lake/build/lib
  printf '%s' "${OLEAN_CONTENT:-OLE}" > .lake/packages/mathlib/.lake/build/lib/M.olean
fi
exit "${LAKE_RC:-0}"
LK
chmod +x "$ISTUB/lake"

# (a) Contend the only slot with zero wait: install must still complete AND
# announce it degraded to unserialized — proving it tried to take a slot.
flock "$TMP/lean-cache-build-slot.0.lock" sleep 60 &
ilocker=$!
until ! flock -n "$TMP/lean-cache-build-slot.0.lock" true 2>/dev/null; do sleep 0.1; done
: > "$TMP/i.log"
out="$(PATH="$ISTUB:$PATH" LEAN_CACHE_BUILD_LOCK_DIR="$TMP" \
       LEAN_CACHE_BUILD_SLOTS=1 LEAN_CACHE_BUILD_WAIT=0 \
       LAKE_LOG="$TMP/i.log" "$CLI" install 4.55.0 2>&1)"; rc=$?
check "install completes despite a contended slot" "0" "$rc"
check "install ran the replay build"               "1" "$(grep -c '^lake build Mathlib' "$TMP/i.log" 2>/dev/null)"
check "install acquires a build slot (degrades under contention)" "yes" \
  "$(printf '%s' "$out" | grep -q 'proceeding unserialized' && echo yes || echo no)"
check "install published the version"              "yes" "$(has_dir "$TMP/cache/lakes/v4-55-0/packages")"

# (b) A nested install riding a parent's slot (LEAN_CACHE_BUILD_SLOT_HELD) takes
# no new slot, so a `use`-triggered auto-install inside a slotted build never
# deadlocks — even with the slot contended it proceeds without waiting.
: > "$TMP/i.log"
out="$(PATH="$ISTUB:$PATH" LEAN_CACHE_BUILD_LOCK_DIR="$TMP" LEAN_CACHE_BUILD_SLOT_HELD=1 \
       LEAN_CACHE_BUILD_SLOTS=1 LEAN_CACHE_BUILD_WAIT=0 \
       LAKE_LOG="$TMP/i.log" "$CLI" install 4.56.0 2>&1)"; rc=$?
check "slot-held install completes"                "0" "$rc"
check "slot-held install acquires no new slot"     "no" \
  "$(printf '%s' "$out" | grep -q 'build slot' && echo yes || echo no)"
# flock(1) forks: kill the child holding the lock, then the wrapper.
kill $(ps -o pid= --ppid "$ilocker" 2>/dev/null) 2>/dev/null || true
kill "$ilocker" 2>/dev/null || true; wait "$ilocker" 2>/dev/null || true

# (c) A --force rebuild swaps the freshly built tree into an already-populated
# $pkgs and leaves no scratch dirs behind — via mv --exchange (coreutils >=9.5)
# or the two-mv fallback, whichever this host has. OLEAN_CONTENT marks the new
# tree so the swap is observable; v4-55-0 exists from (a).
: > "$TMP/i.log"
PATH="$ISTUB:$PATH" LEAN_CACHE_BUILD_LOCK_DIR="$TMP" OLEAN_CONTENT=NEW \
  LAKE_LOG="$TMP/i.log" "$CLI" install --force 4.55.0 >/dev/null 2>&1
check "force rebuild replaced the packages tree"  "NEW" \
  "$(cat "$TMP/cache/lakes/v4-55-0/packages/mathlib/.lake/build/lib/M.olean" 2>/dev/null)"
check "force rebuild left no scratch dirs"        "0" \
  "$(find "$TMP/cache/lakes/v4-55-0" -maxdepth 1 -name '.packages.*' 2>/dev/null | wc -l)"

# (d) `use`'s foreground auto-install bail (fix in cmd_use) and its overrides,
# exercised offline via the stubs: a plain foreground call bails (75) and
# provisions nothing; force-wait overrides the bail and installs to completion.
# HOME/BUILDS are redirected so wire_elan and seeding never touch the real home.
mkdir -p "$TMP/ihome"
UFG="$TMP/usefg"; mkdir -p "$UFG"; gitc "$UFG" init -q
pin v4.57.0 "$UFG"; printf 'name="p"\n' > "$UFG/lakefile.toml"
gitc "$UFG" add -A; gitc "$UFG" commit -qm init
rc=0; PATH="$ISTUB:$PATH" LEAN_CACHE_BUILD_LOCK_DIR="$TMP" LEAN_CACHE_BUILDS="$TMP/ibuilds" \
  HOME="$TMP/ihome" CLAUDE_BASH_MODE=foreground "$CLI" use "$UFG" >/dev/null 2>&1 && rc=0 || rc=$?
check "foreground use bails before an offline install too" "75" "$rc"
check "bailed foreground use provisioned nothing"          "no" \
  "$(has_dir "$TMP/cache/lakes/v4-57-0/packages")"
rc=0; PATH="$ISTUB:$PATH" LEAN_CACHE_BUILD_LOCK_DIR="$TMP" LEAN_CACHE_BUILDS="$TMP/ibuilds" \
  HOME="$TMP/ihome" CLAUDE_BASH_MODE=foreground LEAN_CACHE_FORCE_WAIT=1 \
  "$CLI" use "$UFG" >/dev/null 2>&1 || rc=$?
check "force-wait overrides the foreground use bail"       "0" "$rc"
check "force-wait foreground use provisioned the version"  "yes" \
  "$(has_dir "$TMP/cache/lakes/v4-57-0/packages")"

echo "== slots (hermetic) =="
# `slots` is read-only: probe each lock file with a non-blocking flock and
# report free/held (holder identification is best-effort and not asserted
# here). Uses its own lock dir so it never collides with a concurrent test's
# slot locks.
SLOTS_DIR="$TMP/slotsdir"; mkdir -p "$SLOTS_DIR"
slots_cli() { LEAN_CACHE_BUILD_LOCK_DIR="$SLOTS_DIR" LEAN_CACHE_BUILD_SLOTS=2 "$CLI" slots 2>&1; }

out="$(slots_cli)"; rc=$?
check "slots exits 0 with no locks yet"      "0" "$rc"
check "slots reports the configured count"   "yes" \
  "$(printf '%s' "$out" | grep -q '^build slots: 2 configured' && echo yes || echo no)"
check "slots reports slot 0 free"            "yes" \
  "$(printf '%s' "$out" | grep -qE '^  slot 0: free' && echo yes || echo no)"
check "slots reports slot 1 free"            "yes" \
  "$(printf '%s' "$out" | grep -qE '^  slot 1: free' && echo yes || echo no)"

# Hold slot 0 from a background subshell, then assert the probe sees it held.
flock "$SLOTS_DIR/lean-cache-build-slot.0.lock" sleep 20 &
slocker=$!
until ! flock -n "$SLOTS_DIR/lean-cache-build-slot.0.lock" true 2>/dev/null; do sleep 0.1; done
out="$(slots_cli)"; rc=$?
check "slots exits 0 even with a held slot"  "0" "$rc"
check "slots sees the held slot"             "yes" \
  "$(printf '%s' "$out" | grep -qE '^  slot 0: held' && echo yes || echo no)"
check "slots leaves the other slot free"     "yes" \
  "$(printf '%s' "$out" | grep -qE '^  slot 1: free' && echo yes || echo no)"
# The probe must release immediately (never leave the fd held past the
# command): a second run sees the same real holder still holding it, not a
# lock our own probe accidentally released or left held.
out2="$(slots_cli)"
check "slots probe doesn't disturb the real holder's lock" "yes" \
  "$(printf '%s' "$out2" | grep -qE '^  slot 0: held' && echo yes || echo no)"
# flock(1) forks: kill the child actually holding the lock (killing only the
# wrapper leaves an orphaned sleep pinning the slot), then the wrapper itself.
# Plain kill by pid — pkill is unreliable here (shimmed on some hosts).
kill $(ps -o pid= --ppid "$slocker" 2>/dev/null) 2>/dev/null || true
kill "$slocker" 2>/dev/null || true; wait "$slocker" 2>/dev/null || true

out="$(slots_cli)"
check "slots sees the slot free again after release" "yes" \
  "$(printf '%s' "$out" | grep -qE '^  slot 0: free' && echo yes || echo no)"

out="$(LEAN_CACHE_BUILD_LOCK_DIR="$SLOTS_DIR" LEAN_CACHE_BUILD_SLOTS=0 "$CLI" slots 2>&1)"; rc=$?
check "SLOTS=0 reports serialization disabled" "yes" \
  "$(printf '%s' "$out" | grep -q 'disabled' && echo yes || echo no)"
check "SLOTS=0 slots exits 0"                   "0" "$rc"

echo "== build seeding & push gate (hermetic) =="
# No real Lean here: a stub `lake` stands in for the build so publish/seed and
# the push gate can be exercised without the toolchain or the network. The store
# is redirected to a throwaway dir via LEAN_CACHE_BUILDS.
export LEAN_CACHE_BUILDS="$TMP/builds"
export LEAN_CACHE_BUILD_LOCK_DIR="$TMP"   # never contend with real host builds
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/lake" <<'LK'
#!/usr/bin/env bash
# Stub: record the call and the git-relevant env; succeed unless LAKE_RC says so.
echo "lake $*" >> "${LAKE_LOG:-/dev/null}"
echo "GIT_DIR=${GIT_DIR-<unset>} GIT_WORK_TREE=${GIT_WORK_TREE-<unset>}" >> "${LAKE_ENV_LOG:-/dev/null}"
exit "${LAKE_RC:-0}"
LK
chmod +x "$STUB/lake"
inode() { stat -c '%i' "$1" 2>/dev/null; }
mode()  { stat -c '%a' "$1" 2>/dev/null; }

# A fake project with a pre-staged "warm build" tree.
P="$TMP/proj"; mkdir -p "$P/Proj"; gitc "$P" init -q
pin v4.30.0 "$P"; printf 'name="p"\n' > "$P/lakefile.toml"
printf '.lake/\n' > "$P/.gitignore"          # as any real Lake project has
printf 'def a := 1\n' > "$P/Proj/A.lean"
gitc "$P" add -A; gitc "$P" commit -qm init
pcommit="$(gitc "$P" rev-parse HEAD)"
mkdir -p "$P/.lake/build/lib/lean/Proj" "$P/.lake/build/ir/Proj"
printf 'OLEAN-A'  > "$P/.lake/build/lib/lean/Proj/A.olean"
printf 'TRACE-A'  > "$P/.lake/build/lib/lean/Proj/A.trace"
printf 'IR-A'     > "$P/.lake/build/ir/Proj/A.c"

# publish-build snapshots that tree into the store (lake build is the stub).
PATH="$STUB:$PATH" LAKE_LOG="$TMP/pub.log" "$CLI" publish-build "$P" >/dev/null 2>&1
store="$(find "$LEAN_CACHE_BUILDS" -name .seed-manifest -printf '%h\n' 2>/dev/null | head -1)"
check "publish-build ran lake build first"    "1" "$(grep -c '^lake' "$TMP/pub.log" 2>/dev/null)"
check "publish-build stored the olean"        "OLEAN-A" "$(cat "$store/lib/lean/Proj/A.olean" 2>/dev/null)"
check "stored manifest records the commit"    "commit=$pcommit" "$(grep '^commit=' "$store/.seed-manifest" 2>/dev/null)"
check "store has no group/other-writable file" "0" \
  "$(find "$store" -type f \( -perm -0020 -o -perm -0002 \) 2>/dev/null | wc -l)"
check "stored olean is read-only"             "444" "$(mode "$store/lib/lean/Proj/A.olean")"

# Seed a cold sibling worktree at the SAME commit.
Q="$TMP/q"; gitc "$P" worktree add -q "$Q" HEAD 2>/dev/null
"$CLI" seed-build "$Q" >/dev/null 2>&1
check "seed-build populated the olean"        "OLEAN-A" "$(cat "$Q/.lake/build/lib/lean/Proj/A.olean" 2>/dev/null)"
check "seeded olean is a hardlink to store"   "$(inode "$store/lib/lean/Proj/A.olean")" \
                                              "$(inode "$Q/.lake/build/lib/lean/Proj/A.olean")"
check "seeded olean is read-only"             "444" "$(mode "$Q/.lake/build/lib/lean/Proj/A.olean")"
qti="$(inode "$Q/.lake/build/lib/lean/Proj/A.trace")"
check "seeded trace is a writable copy (not the store inode)" "yes" \
  "$([[ -n "$qti" && "$qti" != "$(inode "$store/lib/lean/Proj/A.trace")" ]] && echo yes || echo no)"

# Replace, not preserve: a stale leftover build (wrong content + an orphan olean
# absent from the store) is fully overwritten by the stored build at this commit.
rm -rf "$Q/.lake/build/lib" "$Q/.lake/build/ir"
mkdir -p "$Q/.lake/build/lib/lean/Proj"
printf 'STALE-A' > "$Q/.lake/build/lib/lean/Proj/A.olean"
printf 'ORPHAN'  > "$Q/.lake/build/lib/lean/Proj/Z.olean"
"$CLI" seed-build "$Q" >/dev/null 2>&1
check "re-seed overwrote the stale olean"      "OLEAN-A" \
  "$(cat "$Q/.lake/build/lib/lean/Proj/A.olean" 2>/dev/null)"
check "re-seed hardlinked the fresh olean to store" "$(inode "$store/lib/lean/Proj/A.olean")" \
                                              "$(inode "$Q/.lake/build/lib/lean/Proj/A.olean")"
check "re-seed dropped the orphan olean"       "no" \
  "$([[ -e "$Q/.lake/build/lib/lean/Proj/Z.olean" ]] && echo yes || echo no)"

# Safety: on a commit mismatch, seed NOTHING (never approximate a stale build).
R="$TMP/r"; mkdir -p "$R/Proj"; gitc "$R" init -q
pin v4.30.0 "$R"; printf 'name="p"\n' > "$R/lakefile.toml"
printf 'def a := 2\n' > "$R/Proj/A.lean"     # different content -> different commit
gitc "$R" add -A; gitc "$R" commit -qm other
"$CLI" seed-build "$R" >/dev/null 2>&1
check "seed-build no-ops on commit mismatch"   "0" \
  "$(find "$R/.lake/build" -name '*.olean' 2>/dev/null | wc -l)"

# refresh seeds the new HEAD even when the overlay slug is already current: a
# checkout can land on a published commit without changing the overlay, yet must
# still pull in the warm build for that commit.
"$CLI" use "$P" >/dev/null 2>&1                   # overlay current for v4-30-0
rm -rf "$P/.lake/build/lib" "$P/.lake/build/ir"
mkdir -p "$P/.lake/build/lib/lean/Proj"
printf 'STALE-A' > "$P/.lake/build/lib/lean/Proj/A.olean"
"$CLI" refresh "$P" >/dev/null 2>&1
check "refresh seeds when overlay already current" "OLEAN-A" \
  "$(cat "$P/.lake/build/lib/lean/Proj/A.olean" 2>/dev/null)"

# clean wipes .lake/build (cold reset) but leaves the package overlay in place.
check "clean: build present before"            "yes" \
  "$([[ -d "$P/.lake/build" ]] && echo yes || echo no)"
ovl_before="$(live_slug "$P")"
"$CLI" clean "$P" >/dev/null 2>&1
check "clean removed .lake/build"              "no" \
  "$([[ -e "$P/.lake/build" ]] && echo yes || echo no)"
check "clean left the package overlay"         "$ovl_before" "$(live_slug "$P")"
rc=0; "$CLI" clean "$TMP" >/dev/null 2>&1 || rc=$?   # non-Lake dir
check "clean on non-Lake dir exits 0"          "0" "$rc"

# Push gate: stub lake decides pass/fail; a bare remote receives the push. These
# cases isolate the gate itself, so suppress the on-push warm-build publish (a
# second lake invocation) — it is exercised in its own section below.
export LEAN_CACHE_NO_PUBLISH_ON_PUSH=1
"$CLI" use "$P" >/dev/null 2>&1                   # installs hooks (+ re-seeds)
check "pre-push hook installed"               "yes" \
  "$(grep -ql lean-cache-managed-hook "$P/.git/hooks/pre-push" && echo yes || echo no)"
check "pre-push hook delegates to pre-push-gate" "yes" \
  "$(grep -ql 'pre-push-gate' "$P/.git/hooks/pre-push" && echo yes || echo no)"
git init -q --bare -b main "$TMP/remote.git"
gitc "$P" remote add origin "$TMP/remote.git"

# Establish the baseline on the remote (the first push carries A.lean, so the
# gate runs the build once here). NO_GATE_SKIP: the publish-build test above
# stored a green build for this very commit, which would legitimately skip the
# gate — the skip has its own section below; here we exercise the build path.
: > "$TMP/g.log"
PATH="$STUB:$PATH" LEAN_CACHE_NO_GATE_SKIP=1 LAKE_LOG="$TMP/g.log" gitc "$P" push -q origin HEAD:main >/dev/null 2>&1 || true
check "gate: initial push (new .lean) runs lake" "1" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"

# (a) An incremental push whose diff has no *.lean must not invoke lake.
printf 'hi\n' > "$P/README.md"; gitc "$P" add -A; gitc "$P" commit -qm doc
: > "$TMP/g.log"
PATH="$STUB:$PATH" LAKE_LOG="$TMP/g.log" gitc "$P" push -q origin HEAD:main >/dev/null 2>&1 || true
check "gate: doc-only push skips lake"         "0" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"

# (b) A push that changes *.lean and fails to build is rejected.
printf 'def a := 3\n' > "$P/Proj/A.lean"; gitc "$P" add -A; gitc "$P" commit -qm edit
remote_before="$(gitc "$P" ls-remote origin refs/heads/main | cut -f1)"
: > "$TMP/g.log"
PATH="$STUB:$PATH" LAKE_RC=1 LAKE_LOG="$TMP/g.log" gitc "$P" push -q origin HEAD:main >/dev/null 2>&1 || true
check "gate: failing build invokes lake"       "1" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "gate: failing build blocks the push"    "$remote_before" \
  "$(gitc "$P" ls-remote origin refs/heads/main | cut -f1)"

# (c) SKIP_LEAN_PUSH_GATE bypasses the gate entirely.
: > "$TMP/g.log"
PATH="$STUB:$PATH" SKIP_LEAN_PUSH_GATE=1 LAKE_LOG="$TMP/g.log" gitc "$P" push -q origin HEAD:main >/dev/null 2>&1 || true
check "gate: SKIP_LEAN_PUSH_GATE skips lake"    "0" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "gate: SKIP_LEAN_PUSH_GATE lets push through" \
  "$(gitc "$P" rev-parse HEAD)" "$(gitc "$P" ls-remote origin refs/heads/main | cut -f1)"

# (d) Linked-worktree regression. `git push` from a linked worktree exports
# GIT_DIR (and friends) into the hook; if the gate lets `lake build` inherit
# them, every `git remote get-url` Lake runs to validate a dependency resolves
# against the superproject instead of the package's own checkout — a bogus URL
# mismatch that makes Lake re-clone a read-only cache-symlinked package. The gate
# must scrub those vars so its build matches a plain interactive `lake build`.
W="$TMP/wt"; gitc "$P" worktree add -q -b wt-branch "$W" main 2>/dev/null
printf 'def b := 1\n' > "$W/Proj/B.lean"; gitc "$W" add -A; gitc "$W" commit -qm wt
: > "$TMP/g.log"; : > "$TMP/genv.log"
PATH="$STUB:$PATH" LAKE_LOG="$TMP/g.log" LAKE_ENV_LOG="$TMP/genv.log" \
  gitc "$W" push -q origin HEAD:refs/heads/wt-branch >/dev/null 2>&1 || true
check "gate (linked worktree): lake ran"          "1" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "gate scrubs GIT_DIR for lake build"        "0" "$(grep -c 'GIT_DIR=[^<]' "$TMP/genv.log" 2>/dev/null)"
check "gate scrubs GIT_WORK_TREE for lake build"  "0" "$(grep -c 'GIT_WORK_TREE=[^<]' "$TMP/genv.log" 2>/dev/null)"

# (e) First push of a multi-commit new branch gates on the WHOLE new history,
# not just the tip commit: commit 1 adds a .lean, the tip is doc-only, and the
# gate must still build (the .lean is new to the remote).
E="$TMP/newrepo"; mkdir -p "$E"; gitc "$E" init -q
pin v4.30.0 "$E"; printf 'name="p"\n' > "$E/lakefile.toml"
printf 'def e := 1\n' > "$E/E.lean"
gitc "$E" add -A; gitc "$E" commit -qm lean-change
printf 'doc\n' > "$E/README.md"; gitc "$E" add -A; gitc "$E" commit -qm doc-tip
git init -q --bare -b main "$TMP/eremote.git"; gitc "$E" remote add origin "$TMP/eremote.git"
"$CLI" use "$E" >/dev/null 2>&1
: > "$TMP/g.log"
PATH="$STUB:$PATH" LAKE_LOG="$TMP/g.log" gitc "$E" push -q origin HEAD:main >/dev/null 2>&1 || true
check "gate: new-branch push gates non-tip .lean commits" "1" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"

# (f) Force-push when the remote moved and was never fetched: the remote tip's
# object is absent locally, so the roid..loid diff cannot run. The gate must
# fall back to the remote-tracking range (not die silently) and still build.
git init -q --bare -b main "$TMP/fremote.git"
F="$TMP/fpush"; mkdir -p "$F"; gitc "$F" init -q
pin v4.30.0 "$F"; printf 'name="p"\n' > "$F/lakefile.toml"
printf 'def f := 1\n' > "$F/F.lean"; gitc "$F" add -A; gitc "$F" commit -qm init
gitc "$F" remote add origin "$TMP/fremote.git"
"$CLI" use "$F" >/dev/null 2>&1
PATH="$STUB:$PATH" gitc "$F" push -q origin HEAD:main >/dev/null 2>&1
F2="$TMP/fpush2"; git clone -q "$TMP/fremote.git" "$F2"
printf 'def g := 2\n' > "$F2/G.lean"; gitc "$F2" add -A; gitc "$F2" commit -qm other
gitc "$F2" push -q origin HEAD:main >/dev/null 2>&1     # remote advances
printf 'def f := 3\n' > "$F/F.lean"; gitc "$F" add -A; gitc "$F" commit -qm mine
: > "$TMP/g.log"
out="$(PATH="$STUB:$PATH" LAKE_LOG="$TMP/g.log" gitc "$F" push --force origin HEAD:main 2>&1)"; rc=$?
check "gate: unfetched force-push still builds"   "1" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "gate: unfetched force-push goes through"   "0" "$rc"
check "gate: unfetched force-push announces the gate" "yes" \
  "$(printf '%s' "$out" | grep -q 'lean push gate' && echo yes || echo no)"

# (f2) Force-push rollback to a commit the remote-tracking refs already have:
# the changed set is undecidable locally, so the gate builds conservatively.
gitc "$F" fetch -q origin
gitc "$F" reset --hard -q "HEAD~1" >/dev/null 2>&1
# advance the remote once more so its tip is again unknown to F (F's own
# force-push moved the remote, so this one must force too)
printf 'def g := 3\n' > "$F2/G.lean"; gitc "$F2" add -A; gitc "$F2" commit -qm more
gitc "$F2" push -q --force origin HEAD:main >/dev/null 2>&1
: > "$TMP/g.log"
out="$(PATH="$STUB:$PATH" LAKE_LOG="$TMP/g.log" gitc "$F" push --force origin HEAD:main 2>&1)"; rc=$?
check "gate: undecidable rollback push builds conservatively" "1" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "gate: undecidable rollback push goes through" "0" "$rc"

# (g) Pushing a ref whose tip is NOT the checked-out HEAD: the gate can only
# build the current worktree, so it must warn and pass the ref ungated instead
# of green-lighting it on the strength of the wrong tree.
G="$TMP/gpush"; mkdir -p "$G"; gitc "$G" init -q
pin v4.30.0 "$G"; printf 'name="p"\n' > "$G/lakefile.toml"
printf 'def h := 1\n' > "$G/H.lean"; gitc "$G" add -A; gitc "$G" commit -qm init
git init -q --bare -b main "$TMP/gremote.git"; gitc "$G" remote add origin "$TMP/gremote.git"
"$CLI" use "$G" >/dev/null 2>&1
PATH="$STUB:$PATH" gitc "$G" push -q origin HEAD:main >/dev/null 2>&1
gitc "$G" switch -qc feature 2>/dev/null || gitc "$G" checkout -qb feature
printf 'def broken :=\n' > "$G/H.lean"; gitc "$G" add -A; gitc "$G" commit -qm feat
gitc "$G" switch -q - 2>/dev/null || gitc "$G" checkout -q "@{-1}"
: > "$TMP/g.log"
out="$(PATH="$STUB:$PATH" LAKE_LOG="$TMP/g.log" gitc "$G" push origin feature:feature 2>&1)"; rc=$?
check "gate: non-HEAD ref push does not run lake"  "0" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "gate: non-HEAD ref push warns it is ungated" "yes" \
  "$(printf '%s' "$out" | grep -q 'NOT gated' && echo yes || echo no)"
check "gate: non-HEAD ref push goes through"        "0" "$rc"

echo "== publish-on-push & commit reminder (hermetic) =="
unset LEAN_CACHE_NO_PUBLISH_ON_PUSH   # re-enable the on-push publish under test
# True if the warm-build store holds a build published for commit $1.
haspub() { grep -Rls "^commit=$1$" "$LEAN_CACHE_BUILDS" 2>/dev/null | grep -q . && echo yes || echo no; }

# commit-hint: reminds on a *.lean commit, silent when no *.lean changed.
printf 'def a := 4\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm edit2
check "commit-hint reminds on .lean commit"       "yes" \
  "$("$CLI" commit-hint "$P" 2>&1 | grep -q 'publish-build' && echo yes || echo no)"
printf 'y\n' >> "$P/README.md"; gitc "$P" add README.md; gitc "$P" commit -qm doc3
check "commit-hint silent on non-.lean commit"    "" "$("$CLI" commit-hint "$P" 2>&1)"
rc=0; "$CLI" commit-hint "$P" >/dev/null 2>&1 || rc=$?
check "commit-hint exits 0 on non-.lean commit"   "0" "$rc"

# The post-commit hook is installed and delegates to commit-hint.
check "post-commit hook installed"                "yes" \
  "$(grep -ql lean-cache-managed-hook "$P/.git/hooks/post-commit" && echo yes || echo no)"
check "post-commit hook delegates to commit-hint" "yes" \
  "$(grep -ql 'commit-hint' "$P/.git/hooks/post-commit" && echo yes || echo no)"

# (a) A clean *.lean push captures the warm build for the pushed HEAD. The stub
# lake does not produce artifacts, so stage a build tree the gate can publish.
printf 'def a := 5\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm edit3
c_ok="$(gitc "$P" rev-parse HEAD)"
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'OLE5' > "$P/.lake/build/lib/lean/Proj/A.olean"
: > "$TMP/g.log"
PATH="$STUB:$PATH" LAKE_LOG="$TMP/g.log" gitc "$P" push -q origin HEAD:main >/dev/null 2>&1 || true
check "clean push publishes the warm build"       "yes" "$(haspub "$c_ok")"

# (b) LEAN_CACHE_NO_PUBLISH_ON_PUSH suppresses the capture.
printf 'def a := 6\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm edit4
c_skip="$(gitc "$P" rev-parse HEAD)"
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'OLE6' > "$P/.lake/build/lib/lean/Proj/A.olean"
: > "$TMP/g.log"
PATH="$STUB:$PATH" LEAN_CACHE_NO_PUBLISH_ON_PUSH=1 LAKE_LOG="$TMP/g.log" \
  gitc "$P" push -q origin HEAD:main >/dev/null 2>&1 || true
check "NO_PUBLISH_ON_PUSH skips the capture"      "no" "$(haspub "$c_skip")"

# (c) A failing gate build aborts the push before any publish.
printf 'def a := 7\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm bad
c_bad="$(gitc "$P" rev-parse HEAD)"
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'OLE7' > "$P/.lake/build/lib/lean/Proj/A.olean"
: > "$TMP/g.log"
PATH="$STUB:$PATH" LAKE_RC=1 LAKE_LOG="$TMP/g.log" gitc "$P" push -q origin HEAD:main >/dev/null 2>&1 || true
check "failed gate build publishes nothing"       "no" "$(haspub "$c_bad")"

echo "== gate skip on stored green build (hermetic) =="
# A green publish attests the commit: the gate must skip its rebuild when the
# store already holds that (commit, toolchain) with tree_clean=1.
printf 'def a := 8\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm edit5
c5="$(gitc "$P" rev-parse HEAD)"
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'OLE8' > "$P/.lake/build/lib/lean/Proj/A.olean"
PATH="$STUB:$PATH" "$CLI" publish-build "$P" >/dev/null 2>&1
m5="$(grep -Rl "^commit=$c5$" "$LEAN_CACHE_BUILDS" 2>/dev/null | head -1)"
check "green publish stamps tree_clean=1"       "tree_clean=1" "$(grep '^tree_clean=' "$m5" 2>/dev/null)"
: > "$TMP/g.log"
out="$(PATH="$STUB:$PATH" LAKE_LOG="$TMP/g.log" gitc "$P" push origin HEAD:main 2>&1)"; rc=$?
check "gate skips build for stored green HEAD"  "0" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "gate announces the skip"                 "yes" \
  "$(printf '%s' "$out" | grep -q 'skipping the gate build' && echo yes || echo no)"
check "skipped-gate push goes through"          "$c5" \
  "$(gitc "$P" ls-remote origin refs/heads/main | cut -f1)"

# LEAN_CACHE_NO_GATE_SKIP forces the rebuild even with a stored green build.
printf 'def a := 9\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm edit6
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'OLE9' > "$P/.lake/build/lib/lean/Proj/A.olean"
PATH="$STUB:$PATH" "$CLI" publish-build "$P" >/dev/null 2>&1
: > "$TMP/g.log"
PATH="$STUB:$PATH" LEAN_CACHE_NO_GATE_SKIP=1 LEAN_CACHE_NO_PUBLISH_ON_PUSH=1 \
  LAKE_LOG="$TMP/g.log" gitc "$P" push -q origin HEAD:main >/dev/null 2>&1 || true
check "NO_GATE_SKIP forces the gate build"      "1" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"

# A dirty-tree publish is refused outright: every stored build must be an honest
# snapshot of committed sources.
printf 'def a := 10\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm edit7
c7="$(gitc "$P" rev-parse HEAD)"
printf 'def stray := 0\n' > "$P/Stray.lean"                 # untracked source -> dirty tree
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'OLE10' > "$P/.lake/build/lib/lean/Proj/A.olean"
rc=0; out="$(PATH="$STUB:$PATH" "$CLI" publish-build "$P" 2>&1)" || rc=$?
check "dirty-tree publish is refused"           "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "dirty-tree publish says why"             "yes" \
  "$(printf '%s' "$out" | grep -q 'dirty tree' && echo yes || echo no)"
check "dirty-tree publish stores nothing"       "no" "$(haspub "$c7")"
rm -f "$P/Stray.lean"

# A failed build on a clean tree still publishes, stamped tree_clean=0 (non-green):
# it seeds future incremental builds but attests nothing.
PATH="$STUB:$PATH" LAKE_RC=1 "$CLI" publish-build "$P" >/dev/null 2>&1
m7="$(grep -Rl "^commit=$c7$" "$LEAN_CACHE_BUILDS" 2>/dev/null | head -1)"
check "failed build publishes a store entry"    "yes" "$(haspub "$c7")"
check "failed build stamps tree_clean=0"        "tree_clean=0" "$(grep '^tree_clean=' "$m7" 2>/dev/null)"

# seed-build seeds a non-green entry like any other (honest olean/trace pairs).
NG="$TMP/ng"; gitc "$P" worktree add -q "$NG" "$c7" 2>/dev/null
"$CLI" seed-build "$NG" >/dev/null 2>&1
check "seed-build seeds a non-green entry"      "OLE10" \
  "$(cat "$NG/.lake/build/lib/lean/Proj/A.olean" 2>/dev/null)"

# The gate must NOT skip on a non-green (tree_clean=0) store entry.
: > "$TMP/g.log"
out="$(PATH="$STUB:$PATH" LEAN_CACHE_NO_PUBLISH_ON_PUSH=1 LAKE_LOG="$TMP/g.log" \
       gitc "$P" push origin HEAD:main 2>&1)"; rc=$?
check "gate does not skip on a non-green store" "1" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "no skip message on a non-green store"    "no" \
  "$(printf '%s' "$out" | grep -q 'skipping the gate build' && echo yes || echo no)"

# A stored green build is never overwritten by a later non-green publish at the
# same commit: an interrupted/OOM'd rebuild must not stale the entry or switch
# off the gate skip.
printf 'def a := 20\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm green-guard
c8="$(gitc "$P" rev-parse HEAD)"
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'GREEN8' > "$P/.lake/build/lib/lean/Proj/A.olean"
PATH="$STUB:$PATH" "$CLI" publish-build "$P" >/dev/null 2>&1          # green publish
m8="$(grep -Rl "^commit=$c8$" "$LEAN_CACHE_BUILDS" 2>/dev/null | head -1)"
check "green build stamps tree_clean=1"         "tree_clean=1" "$(grep '^tree_clean=' "$m8" 2>/dev/null)"
printf 'NONGREEN8' > "$P/.lake/build/lib/lean/Proj/A.olean"          # different olean content
rc=0; PATH="$STUB:$PATH" LAKE_RC=1 "$CLI" publish-build "$P" >/dev/null 2>&1 || rc=$?
check "failed publish over green entry succeeds" "0" "$rc"
check "green entry survives a failed re-publish" "tree_clean=1" "$(grep '^tree_clean=' "$m8" 2>/dev/null)"
check "green entry keeps its green olean"       "GREEN8" \
  "$(cat "$(dirname "$m8")/lib/lean/Proj/A.olean" 2>/dev/null)"

echo "== store retention protects green attestations (hermetic) =="
# Retention keeps the newest build per slug (warmth) AND the newest green build
# per slug (attestation), so a stream of non-green WIP publishes cannot evict a
# green entry the gate skips on. Craft entries with explicit published_at so the
# ordering is deterministic.
RB="$LEAN_CACHE_BUILDS/retain-repo"
mkentry() { # dir published_at tree_clean
  mkdir -p "$1/lib"; printf 'OLE' > "$1/lib/x.olean"
  printf 'slug=s\npublished_at=%s\ntree_clean=%s\n' "$2" "$3" > "$1/.seed-manifest"
}
mkentry "$RB/cX/s" 1000 1     # green, oldest
mkentry "$RB/cY/s" 2000 0     # non-green WIP
mkentry "$RB/cZ/s" 3000 0     # non-green WIP, newest
"$CLI" prune-builds --keep-days 0 >/dev/null 2>&1
check "retention keeps the newest green entry"   "yes" "$([[ -d "$RB/cX/s" ]] && echo yes || echo no)"
check "retention keeps the newest entry"         "yes" "$([[ -d "$RB/cZ/s" ]] && echo yes || echo no)"
check "retention drops middle non-green WIP"     "no"  "$([[ -d "$RB/cY/s" ]] && echo yes || echo no)"

echo "== host build slots & lean-cache build (hermetic) =="
# The wrapper runs lake build (with passthrough args) in the project.
: > "$TMP/b.log"
PATH="$STUB:$PATH" LAKE_LOG="$TMP/b.log" "$CLI" build "$P" >/dev/null 2>&1
check "build wrapper runs lake build"           "lake build" "$(cat "$TMP/b.log" 2>/dev/null)"
: > "$TMP/b.log"
PATH="$STUB:$PATH" LAKE_LOG="$TMP/b.log" "$CLI" build "$P" Proj.A >/dev/null 2>&1
check "build wrapper passes extra args to lake" "lake build Proj.A" "$(cat "$TMP/b.log" 2>/dev/null)"
rc=0; PATH="$STUB:$PATH" LAKE_RC=1 "$CLI" build "$P" >/dev/null 2>&1 || rc=$?
check "build wrapper propagates build failure"  "1" "$rc"
# A bare-word target that shares its name with a directory is a lake target,
# never a project path (paths must be "." or contain a slash).
mkdir -p "$P/Aliasing"
: > "$TMP/b.log"
( cd "$P" && PATH="$STUB:$PATH" LAKE_LOG="$TMP/b.log" "$CLI" build Aliasing >/dev/null 2>&1 )
check "build wrapper: bare word is a target, not a path" "lake build Aliasing" "$(cat "$TMP/b.log" 2>/dev/null)"
rm -rf "$P/Aliasing"

# Only cold/full builds take a slot, so the slot machinery is exercised with a
# cold project (no .lake/build, no stored warm build) forced to build to
# completion (force-wait) instead of bailing.
CB="$TMP/coldslot"; mkdir -p "$CB/Proj"; gitc "$CB" init -q
pin v4.30.0 "$CB"; printf 'name="p"\n' > "$CB/lakefile.toml"
printf '.lake/\n' > "$CB/.gitignore"; printf 'def cb := 1\n' > "$CB/Proj/CB.lean"
gitc "$CB" add -A; gitc "$CB" commit -qm init

# All slots busy + zero wait: degrade to an unserialized build with a note.
flock "$TMP/lean-cache-build-slot.0.lock" sleep 20 &
locker=$!
until ! flock -n "$TMP/lean-cache-build-slot.0.lock" true 2>/dev/null; do sleep 0.1; done
out="$(PATH="$STUB:$PATH" LEAN_CACHE_FORCE_WAIT=1 LEAN_CACHE_BUILD_SLOTS=1 LEAN_CACHE_BUILD_WAIT=0 "$CLI" build "$CB" 2>&1)"; rc=$?
check "contended slot degrades, build still runs" "0" "$rc"
check "contended slot says so"                  "yes" \
  "$(printf '%s' "$out" | grep -q 'proceeding unserialized' && echo yes || echo no)"
# flock(1) forks: kill the child actually holding the lock (killing only the
# wrapper leaves an orphaned sleep pinning the slot), then the wrapper itself.
# Plain kill by pid — pkill is unreliable here (shimmed on some hosts).
kill $(ps -o pid= --ppid "$locker" 2>/dev/null) 2>/dev/null || true
kill "$locker" 2>/dev/null || true; wait "$locker" 2>/dev/null || true

# LEAN_CACHE_BUILD_SLOTS=0 disables serialization entirely (no slot chatter).
out="$(PATH="$STUB:$PATH" LEAN_CACHE_FORCE_WAIT=1 LEAN_CACHE_BUILD_SLOTS=0 "$CLI" build "$CB" 2>&1)"; rc=$?
check "SLOTS=0 disables serialization"          "0" "$rc"
check "SLOTS=0 emits no slot messages"          "no" \
  "$(printf '%s' "$out" | grep -q 'build slot' && echo yes || echo no)"

# The gate's publish re-exec rides the gate's own slot (no self-deadlock, no
# waiting): with a single slot and publish-on-push enabled, the push completes
# with two lake runs (gate + publish's no-op) and never waits for a slot.
printf 'def a := 11\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm edit8
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'OLE11' > "$P/.lake/build/lib/lean/Proj/A.olean"
: > "$TMP/g.log"
out="$(PATH="$STUB:$PATH" LEAN_CACHE_BUILD_SLOTS=1 LEAN_CACHE_BUILD_WAIT=45 \
       LAKE_LOG="$TMP/g.log" gitc "$P" push origin HEAD:main 2>&1)"; rc=$?
check "gate+publish share one slot: push succeeds" "0" "$rc"
check "gate+publish share one slot: both builds ran" "2" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "gate+publish share one slot: no slot wait"  "no" \
  "$(printf '%s' "$out" | grep -q 'waiting for a host build slot' && echo yes || echo no)"

echo "== transparent build policy (hermetic) =="
# The shared warm/cold policy behind both `lake build` (via the shim) and
# `lean-cache build`. A warm/incremental build runs immediately; a cold/full one
# serializes and, in a bounded foreground call, bails instead of being killed.

# Cold project: committed, no .lake/build, no stored warm build.
CP="$TMP/cold"; mkdir -p "$CP/Proj"; gitc "$CP" init -q
pin v4.30.0 "$CP"; printf 'name="p"\n' > "$CP/lakefile.toml"
printf '.lake/\n' > "$CP/.gitignore"; printf 'def c := 1\n' > "$CP/Proj/C.lean"
gitc "$CP" add -A; gitc "$CP" commit -qm init

# Warm project: same, but carrying a prior build (an olean under .lake/build).
WP="$TMP/warm"; mkdir -p "$WP/Proj"; gitc "$WP" init -q
pin v4.30.0 "$WP"; printf 'name="p"\n' > "$WP/lakefile.toml"
printf '.lake/\n' > "$WP/.gitignore"; printf 'def w := 1\n' > "$WP/Proj/W.lean"
gitc "$WP" add -A; gitc "$WP" commit -qm init
mkdir -p "$WP/.lake/build/lib/lean/Proj"; printf 'OLE' > "$WP/.lake/build/lib/lean/Proj/W.olean"

# (a) Warm build runs immediately with no slot, even in a foreground call.
: > "$TMP/pol.log"
out="$(PATH="$STUB:$PATH" CLAUDE_BASH_MODE=foreground LAKE_LOG="$TMP/pol.log" "$CLI" build "$WP" 2>&1)"; rc=$?
check "warm build runs (foreground)"            "1" "$(grep -c '^lake build' "$TMP/pol.log" 2>/dev/null)"
check "warm build exits 0"                      "0" "$rc"
check "warm build takes no slot"                "no" \
  "$(printf '%s' "$out" | grep -q 'build slot' && echo yes || echo no)"

# (b) Cold build in a bounded foreground call bails: it does NOT build, exits the
# distinct bail code, and prints actionable re-run instructions.
: > "$TMP/pol.log"
out="$(PATH="$STUB:$PATH" CLAUDE_BASH_MODE=foreground LAKE_LOG="$TMP/pol.log" "$CLI" build "$CP" 2>&1)" && rc=0 || rc=$?
check "cold foreground build runs no lake"       "0" "$(grep -c '^lake build' "$TMP/pol.log" 2>/dev/null)"
check "cold foreground build bails, code 75"     "75" "$rc"
check "cold foreground bail explains re-run"     "yes" \
  "$(printf '%s' "$out" | grep -q 'backgrounded' && echo yes || echo no)"

# (c) Cold build with an explicit background mode queues and builds to completion.
: > "$TMP/pol.log"; rc=0
PATH="$STUB:$PATH" CLAUDE_BASH_MODE=background LAKE_LOG="$TMP/pol.log" "$CLI" build "$CP" >/dev/null 2>&1 || rc=$?
check "cold background build runs lake"          "1" "$(grep -c '^lake build' "$TMP/pol.log" 2>/dev/null)"
check "cold background build exits 0"            "0" "$rc"

# (d) Absent CLAUDE_BASH_MODE defaults to background (queue-and-build, not bail).
: > "$TMP/pol.log"; rc=0
env -u CLAUDE_BASH_MODE PATH="$STUB:$PATH" LAKE_LOG="$TMP/pol.log" "$CLI" build "$CP" >/dev/null 2>&1 || rc=$?
check "absent mode builds (not bail)"            "1" "$(grep -c '^lake build' "$TMP/pol.log" 2>/dev/null)"
check "absent mode exits 0"                      "0" "$rc"

# (e) Force-wait (--wait or LEAN_CACHE_FORCE_WAIT=1) builds a cold project to
# completion even in a foreground call — no bail.
: > "$TMP/pol.log"; rc=0
PATH="$STUB:$PATH" CLAUDE_BASH_MODE=foreground LAKE_LOG="$TMP/pol.log" "$CLI" build --wait "$CP" >/dev/null 2>&1 || rc=$?
check "--wait forces cold build (foreground)"    "1" "$(grep -c '^lake build' "$TMP/pol.log" 2>/dev/null)"
check "--wait cold build exits 0"                "0" "$rc"
: > "$TMP/pol.log"; rc=0
PATH="$STUB:$PATH" CLAUDE_BASH_MODE=foreground LEAN_CACHE_FORCE_WAIT=1 LAKE_LOG="$TMP/pol.log" \
  "$CLI" build "$CP" >/dev/null 2>&1 || rc=$?
check "FORCE_WAIT forces cold build (foreground)" "1" "$(grep -c '^lake build' "$TMP/pol.log" 2>/dev/null)"

# (f) A build riding a parent's slot (LEAN_CACHE_BUILD_SLOT_HELD) completes now:
# no re-acquire, and no foreground bail even when cold.
: > "$TMP/pol.log"
out="$(PATH="$STUB:$PATH" CLAUDE_BASH_MODE=foreground LEAN_CACHE_BUILD_SLOT_HELD=1 \
       LAKE_LOG="$TMP/pol.log" "$CLI" build "$CP" 2>&1)"; rc=$?
check "slot-held cold build runs (no bail)"      "1" "$(grep -c '^lake build' "$TMP/pol.log" 2>/dev/null)"
check "slot-held cold build exits 0"             "0" "$rc"
check "slot-held build acquires no new slot"     "no" \
  "$(printf '%s' "$out" | grep -q 'build slot' && echo yes || echo no)"

# (g) A stored warm build matching HEAD classifies as warm even with an empty
# .lake/build on disk (a freshly seedable worktree), so it does not bail.
SP="$TMP/stored"; mkdir -p "$SP/Proj"; gitc "$SP" init -q
pin v4.30.0 "$SP"; printf 'name="p"\n' > "$SP/lakefile.toml"
printf '.lake/\n' > "$SP/.gitignore"; printf 'def s := 1\n' > "$SP/Proj/S.lean"
gitc "$SP" add -A; gitc "$SP" commit -qm init
mkdir -p "$SP/.lake/build/lib/lean/Proj"; printf 'OLE' > "$SP/.lake/build/lib/lean/Proj/S.olean"
PATH="$STUB:$PATH" "$CLI" publish-build "$SP" >/dev/null 2>&1
rm -rf "$SP/.lake/build"                 # cold on disk, but a stored build matches HEAD
: > "$TMP/pol.log"; rc=0
PATH="$STUB:$PATH" CLAUDE_BASH_MODE=foreground LAKE_LOG="$TMP/pol.log" "$CLI" build "$SP" >/dev/null 2>&1 || rc=$?
check "stored-warm build classifies as warm (fg)" "1" "$(grep -c '^lake build' "$TMP/pol.log" 2>/dev/null)"
check "stored-warm build does not bail"          "0" "$rc"

echo "== lake shim (hermetic) =="
# The shim, installed alongside lean-cache, must pass non-build subcommands
# straight through to the real lake and route `lake build` through the policy —
# without recursing into itself.
SHIMDIR="$TMP/shimbin"; mkdir -p "$SHIMDIR"
install -m 0755 "$REPO_DIR/bin/lake-shim" "$SHIMDIR/lake"
install -m 0755 "$CLI" "$SHIMDIR/lean-cache"

# (a) A non-build subcommand execs the real lake untouched.
: > "$TMP/shim.log"
( cd "$WP" && PATH="$SHIMDIR:$STUB:$PATH" LAKE_LOG="$TMP/shim.log" lake env >/dev/null 2>&1 ) || true
check "shim passes non-build to the real lake"   "yes" \
  "$(grep -q '^lake env' "$TMP/shim.log" && echo yes || echo no)"

# (b) `lake build` routes through the policy — a warm project builds now.
: > "$TMP/shim.log"
( cd "$WP" && PATH="$SHIMDIR:$STUB:$PATH" LAKE_LOG="$TMP/shim.log" lake build >/dev/null 2>&1 ) || true
check "shim routes build through the policy (warm runs)" "1" \
  "$(grep -c '^lake build' "$TMP/shim.log" 2>/dev/null)"

# (c) The shim resolves the real lake (not itself), so a cold foreground `lake
# build` reaches the policy's bail rather than looping through the shim.
: > "$TMP/shim.log"
out="$( cd "$CP" && PATH="$SHIMDIR:$STUB:$PATH" CLAUDE_BASH_MODE=foreground \
        LAKE_LOG="$TMP/shim.log" lake build 2>&1 )" && rc=0 || rc=$?
check "shim cold foreground build bails, code 75" "75" "$rc"
check "shim cold bail ran no real build"          "0" "$(grep -c '^lake build' "$TMP/shim.log" 2>/dev/null)"
check "shim cold bail names 'lake build' to re-run" "yes" \
  "$(printf '%s' "$out" | grep -q 'lake build' && echo yes || echo no)"

echo "== overlay self-heal on build (hermetic) =="
# A project whose shared-cache overlay has gone dangling (e.g. its version was
# uninstalled from underneath it) must be silently repaired by `build` before
# it runs lake — no manual `lean-cache use` required.
mkdir -p "$TMP/cache/lakes/v9-2-0/packages/mathlib" "$TMP/cache/lakes/v9-2-0/packages/batteries"
OV="$TMP/selfheal"; mkdir -p "$OV/Proj"; gitc "$OV" init -q
pin v9.2.0 "$OV"; printf 'name="p"\n' > "$OV/lakefile.toml"
printf '.lake/\n' > "$OV/.gitignore"; printf 'def o := 1\n' > "$OV/Proj/O.lean"
gitc "$OV" add -A; gitc "$OV" commit -qm init
"$CLI" use "$OV" >/dev/null 2>&1
mkdir -p "$OV/.lake/build/lib/lean/Proj" "$OV/.lake/build/ir/Proj"
printf 'OLEAN-O' > "$OV/.lake/build/lib/lean/Proj/O.olean"
printf 'IR-O'    > "$OV/.lake/build/ir/Proj/O.c"
mathlib_target="$(readlink "$OV/.lake/packages/mathlib")"

# (a) overlay present: build runs directly, no repair, and the existing
# incremental .lake/build is left untouched (not wiped by a needless reseed).
: > "$TMP/b.log"
out="$(PATH="$STUB:$PATH" LAKE_LOG="$TMP/b.log" "$CLI" build "$OV" 2>&1)"; rc=$?
check "healthy overlay: build ran lake"           "1" "$(grep -c '^lake build' "$TMP/b.log" 2>/dev/null)"
check "healthy overlay: build exits 0"            "0" "$rc"
check "healthy overlay: no repair message"        "no" \
  "$(printf '%s' "$out" | grep -qi 'repairing' && echo yes || echo no)"
check "healthy overlay: mathlib link unchanged"   "$mathlib_target" "$(readlink "$OV/.lake/packages/mathlib")"
check "healthy overlay: build/lib olean intact"   "OLEAN-O" "$(cat "$OV/.lake/build/lib/lean/Proj/O.olean" 2>/dev/null)"
check "healthy overlay: build/ir intact"          "IR-O" "$(cat "$OV/.lake/build/ir/Proj/O.c" 2>/dev/null)"

# (b) overlay dangling: repair runs (re-links to the real shared package), then
# the build proceeds. No stored warm build matches this commit, so the repair's
# own seed-build stays a no-op and .lake/build is left alone too.
ln -sfn "$TMP/cache/lakes/v9-2-0/packages/nonexistent" "$OV/.lake/packages/mathlib"
: > "$TMP/b.log"
out="$(PATH="$STUB:$PATH" LAKE_LOG="$TMP/b.log" "$CLI" build "$OV" 2>&1)"; rc=$?
check "dangling overlay: repair message shown"    "yes" \
  "$(printf '%s' "$out" | grep -qi 'repairing' && echo yes || echo no)"
check "dangling overlay: mathlib re-linked"        "$mathlib_target" "$(readlink "$OV/.lake/packages/mathlib")"
check "dangling overlay: mathlib resolves"         "yes" "$([[ -e "$OV/.lake/packages/mathlib" ]] && echo yes || echo no)"
check "dangling overlay: build still ran lake"     "1" "$(grep -c '^lake build' "$TMP/b.log" 2>/dev/null)"
check "dangling overlay: build exits 0"            "0" "$rc"
check "dangling overlay: build/lib olean intact"   "OLEAN-O" "$(cat "$OV/.lake/build/lib/lean/Proj/O.olean" 2>/dev/null)"

# (c) A project with no shared-cache overlay at all (never `use`d) is left
# alone: build must not force one into existence off a bare mathlib-missing
# check — the hooks are what provision a fresh checkout.
NV="$TMP/nooverlay"; mkdir -p "$NV/Proj"; gitc "$NV" init -q
pin v9.2.0 "$NV"; printf 'name="p"\n' > "$NV/lakefile.toml"
printf '.lake/\n' > "$NV/.gitignore"; printf 'def n := 1\n' > "$NV/Proj/N.lean"
gitc "$NV" add -A; gitc "$NV" commit -qm init
: > "$TMP/b.log"
out="$(PATH="$STUB:$PATH" CLAUDE_BASH_MODE=background LAKE_LOG="$TMP/b.log" "$CLI" build "$NV" 2>&1)"; rc=$?
check "no overlay yet: build does not force one"  "no" \
  "$([[ -e "$NV/.lake/packages" ]] && echo yes || echo no)"
check "no overlay yet: build still ran lake"      "1" "$(grep -c '^lake build' "$TMP/b.log" 2>/dev/null)"
check "no overlay yet: build exits 0"             "0" "$rc"

echo "== build-store rotation (hermetic) =="
# Fabricate builds with controlled publish times and check the keep/drop policy.
mkbuild() { # mkbuild <repodir> <commit> <slug> <age_days>
  local d="$1/$2/$3"; mkdir -p "$d/lib"
  printf 'OLE' > "$d/lib/x.olean"
  printf 'commit=%s\nslug=%s\npublished_at=%s\n' "$2" "$3" "$(( $(date +%s) - $4 * 86400 ))" \
    > "$d/.seed-manifest"
}
RB="$LEAN_CACHE_BUILDS/rot-repo"
mkbuild "$RB" newcommit v9-9-9 0    # newest for v9-9-9      -> keep
mkbuild "$RB" midcommit v9-9-9 3    # non-latest, within 7d  -> keep
mkbuild "$RB" oldcommit v9-9-9 10   # non-latest, older 7d   -> prune
mkbuild "$RB" loneold   v8-8-8 30   # only build for v8-8-8  -> newest -> keep
exists() { [[ -d "$1" ]] && echo yes || echo no; }
"$CLI" prune-builds --keep-days 7 >/dev/null 2>&1
check "rotation keeps newest per toolchain"      "yes" "$(exists "$RB/newcommit/v9-9-9")"
check "rotation keeps non-latest within window"  "yes" "$(exists "$RB/midcommit/v9-9-9")"
check "rotation drops non-latest past window"    "no"  "$(exists "$RB/oldcommit/v9-9-9")"
check "rotation keeps lone latest even if old"   "yes" "$(exists "$RB/loneold/v8-8-8")"
check "rotation removes emptied commit dir"      "no"  "$(exists "$RB/oldcommit")"

echo "== opportunistic prune on use (hermetic) =="
# `use` rotates the whole build store at most once a day, guarded by a stamp
# file, so a store that stops being published to doesn't accumulate stale
# builds forever without a cron'd prune-builds. Reuses mkbuild/exists from the
# rotation section above; $B (pinned v4.31.0, already `use`d earlier) is a
# project `use` can run against without any stub lake.
UP="$LEAN_CACHE_BUILDS/use-prune-repo"
mkbuild "$UP" upnew v9-9-9 0     # newest -> keep
mkbuild "$UP" upold v9-9-9 10    # non-latest, past the 7-day window -> prune
prune_stamp="$LEAN_CACHE_BUILDS/.last-prune"
rm -f "$prune_stamp"

"$CLI" use "$B" >/dev/null 2>&1
check "use with no stamp prunes the store"         "no"  "$(exists "$UP/upold/v9-9-9")"
check "use with no stamp creates the stamp"        "yes" "$([[ -f "$prune_stamp" ]] && echo yes || echo no)"

# A fresh stamp (just written above): a newly-eligible stale build is left alone.
mkbuild "$UP" upnew2 v8-8-8 0
mkbuild "$UP" upold2 v8-8-8 10
"$CLI" use "$B" >/dev/null 2>&1
check "use with a fresh stamp skips pruning"       "yes" "$(exists "$UP/upold2/v8-8-8")"

# An old stamp (>1 day) triggers another prune, and refreshes the stamp.
touch -d "@$(( $(date +%s) - 90000 ))" "$prune_stamp"
"$CLI" use "$B" >/dev/null 2>&1
check "use with a stale stamp prunes again"        "no"  "$(exists "$UP/upold2/v8-8-8")"
check "use with a stale stamp refreshes the stamp" "yes" \
  "$([[ -n "$(find "$prune_stamp" -mtime -1 2>/dev/null)" ]] && echo yes || echo no)"

echo "== event log & stats (hermetic) =="
# Redirect the event log to a throwaway dir and drive a use/seed/publish/gate
# flow (stub lake), asserting each event lands with the right fields. Then check
# that an unusable log dir never breaks a command, and that `stats` summarizes a
# synthetic log deterministically.
export LEAN_CACHE_LOG_DIR="$TMP/eventlog"
export LEAN_CACHE_NO_PUBLISH_ON_PUSH=1     # keep the gate's own event isolated
evlog="$LEAN_CACHE_LOG_DIR/events.$(id -un).log"
# Value of <key> from the LAST line of event <ev> (empty if none).
ev_field() { awk -F'\t' -v ev="$2" -v key="$3" \
  '$3==ev{for(i=4;i<=NF;i++){p=index($i,"=");if(substr($i,1,p-1)==key)val=substr($i,p+1)}} END{print val}' "$1"; }

EV="$TMP/evproj"; mkdir -p "$EV/Proj"; gitc "$EV" init -q
pin v4.30.0 "$EV"; printf 'name="e"\n' > "$EV/lakefile.toml"
printf '.lake/\n' > "$EV/.gitignore"
printf 'def a := 1\n' > "$EV/Proj/A.lean"
gitc "$EV" add -A; gitc "$EV" commit -qm init
evcommit="$(gitc "$EV" rev-parse HEAD)"

# use: logs a use event (auto_install=0; v4-30-0 exists in the throwaway cache)
# and, via its trailing seed-build, a seed MISS (nothing stored for this commit).
"$CLI" use "$EV" >/dev/null 2>&1
check "use created this user's log file"       "yes" "$([[ -f "$evlog" ]] && echo yes || echo no)"
check "use event records the slug"             "v4-30-0" "$(ev_field "$evlog" use slug)"
check "use event auto_install=0"               "0" "$(ev_field "$evlog" use auto_install)"
check "seed miss logged on first use"          "0" "$(ev_field "$evlog" seed hit)"

# publish: build (stub) to completion and store, logging a publish event.
mkdir -p "$EV/.lake/build/lib/lean/Proj"
printf 'OLEAN-A' > "$EV/.lake/build/lib/lean/Proj/A.olean"
PATH="$STUB:$PATH" "$CLI" publish-build "$EV" >/dev/null 2>&1
check "publish event green=1"                  "1" "$(ev_field "$evlog" publish green)"
check "publish event records the short commit" "${evcommit:0:12}" "$(ev_field "$evlog" publish commit)"

# seed: now a build is stored for this exact commit, so seeding HITS.
"$CLI" seed-build "$EV" >/dev/null 2>&1
check "seed hit logged after a matching publish" "1" "$(ev_field "$evlog" seed hit)"

# gate: a green build is stored for HEAD, so the push gate SKIPs and logs it.
git init -q --bare -b main "$TMP/evremote.git"
gitc "$EV" remote add origin "$TMP/evremote.git"
PATH="$STUB:$PATH" gitc "$EV" push -q origin HEAD:main >/dev/null 2>&1 || true
check "gate skip logged (stored green build)"  "skip" "$(ev_field "$evlog" gate outcome)"
check "gate skip records secs=0"               "0" "$(ev_field "$evlog" gate secs)"

# gate build: a new commit with no stored build, gate skip forced off -> ok.
printf 'def b := 2\n' > "$EV/Proj/B.lean"; gitc "$EV" add -A; gitc "$EV" commit -qm addb
PATH="$STUB:$PATH" LEAN_CACHE_NO_GATE_SKIP=1 gitc "$EV" push -q origin HEAD:main >/dev/null 2>&1 || true
check "gate ok logged on a built push"         "ok" "$(ev_field "$evlog" gate outcome)"

# An unusable log dir must never break a command. Point LOG_DIR below a regular
# file: mkdir -p fails (ENOTDIR) even for root, so log_event silently no-ops.
printf 'x' > "$TMP/notadir"
evrc=0; LEAN_CACHE_LOG_DIR="$TMP/notadir/sub" "$CLI" use "$EV" >/dev/null 2>&1 || evrc=$?
check "command survives an unusable log dir"   "0" "$evrc"
check "nothing written under the bogus path"   "no" "$([[ -e "$TMP/notadir/sub" ]] && echo yes || echo no)"

# stats: summarize a synthetic multi-field log; an out-of-window event is dropped.
SL="$TMP/statslog"; mkdir -p "$SL"; snow="$(date +%s)"
{
  printf '%s\tu1\tseed\thit=1\trepo=r\tcommit=c\tslug=s\n'          "$snow"
  printf '%s\tu1\tseed\thit=0\trepo=r\tcommit=c\tslug=s\n'          "$snow"
  printf '%s\tu1\tinstall\tslug=s\tsecs=100\tok=1\tforced=0\n'      "$snow"
  printf '%s\tu1\tinstall\tslug=s\tsecs=300\tok=0\tforced=0\n'      "$snow"
  printf '%s\tu1\tgate\toutcome=ok\trepo=r\tcommit=c\tsecs=50\n'    "$snow"
  printf '%s\tu1\tgate\toutcome=skip\trepo=r\tcommit=c\tsecs=0\n'   "$snow"
  printf '%s\tu1\tinstall\tslug=s\tsecs=999\tok=1\tforced=0\n' "$(( snow - 30*86400 ))"  # out of window
} > "$SL/events.u1.log"
sout="$(LEAN_CACHE_LOG_DIR="$SL" "$CLI" stats --since 7 2>/dev/null)"
seen() { grep -qE "$2" <<<"$1" && echo yes || echo no; }
check "stats: seed hit rate"       "yes" "$(seen "$sout" 'seed +2 applicable, 1 hit, 1 miss \(50% hit rate\)')"
check "stats: install durations exclude out-of-window" "yes" \
  "$(seen "$sout" 'install +2 run: 1 ok, 1 fail.*median 200, max 300')"
check "stats: gate outcomes"       "yes" "$(seen "$sout" 'gate +2 engaged: 1 ok, 1 skip, 0 fail')"

echo "== verify (hermetic) =="
# A fresh cache tree with one installed version, planted with one violation per
# check at a time. LEAN_CACHE_LOG_DIR is still $TMP/eventlog from the event-log
# section above, so verify's own event lands in the same log we already probe.
VROOT="$TMP/vcache"
mkdir -p "$VROOT/lakes/v9-1-0/packages/mathlib/.lake/build" \
         "$VROOT/lakes/v9-1-0/packages/batteries" "$VROOT/elan/bin"
: > "$VROOT/lakes/v9-1-0/packages/mathlib/.lake/build/M.olean"
: > "$VROOT/elan/bin/lean"
gitc "$VROOT/lakes/v9-1-0/packages/batteries" init -q
gitc "$VROOT/lakes/v9-1-0/packages/batteries" config core.fileMode false
chmod -R u=rwX,go=rX "$VROOT"  # normalize_perms' own baseline, so a loose umask can't fake a violation

VELANSTUB="$TMP/velanstub"; mkdir -p "$VELANSTUB"
cat > "$VELANSTUB/elan" <<'EL'
#!/usr/bin/env bash
# Matches VROOT exactly: one toolchain, one cache dir, nothing orphaned.
case "$1 $2" in
  "toolchain list") printf 'leanprover/lean4:v9.1.0 (default)\n' ;;
  *) exit 0 ;;
esac
EL
chmod +x "$VELANSTUB/elan"
run_verify() { PATH="$VELANSTUB:$PATH" LEAN_CACHE_ROOT="$VROOT" "$CLI" verify "$@"; }

rc=0; out="$(run_verify 2>&1)" || rc=$?
check "clean cache verifies ok (exit 0)"    "0" "$rc"
check "clean cache: no FAIL lines"          "no" "$(grep -q FAIL <<<"$out" && echo yes || echo no)"
check "clean cache: no warn lines"          "no" "$(grep -q '  warn  ' <<<"$out" && echo yes || echo no)"
check "clean cache: oleans check passes"    "yes" "$(grep -q 'mathlib oleans present' <<<"$out" && echo yes || echo no)"

# Violation 1: a group-writable file trips the single-writer invariant itself.
chmod g+w "$VROOT/lakes/v9-1-0/packages/mathlib/.lake/build/M.olean"
rc=0; out="$(run_verify 2>&1)" || rc=$?
check "group-writable file -> FAIL, exit 1" "1" "$rc"
check "group-writable file flagged"         "yes" "$(grep -qi 'group/other-writable path' <<<"$out" && echo yes || echo no)"
chmod g-w "$VROOT/lakes/v9-1-0/packages/mathlib/.lake/build/M.olean"

# Violation 2: an installed version with no mathlib oleans.
mkdir -p "$VROOT/lakes/v9-2-0/packages/mathlib/.lake/build"
rc=0; out="$(run_verify 2>&1)" || rc=$?
check "missing oleans -> FAIL, exit 1"      "1" "$rc"
check "missing oleans names the slug"       "yes" \
  "$(grep -q 'v9-2-0: no mathlib oleans' <<<"$out" && echo yes || echo no)"
rm -rf "$VROOT/lakes/v9-2-0"

# Violation 3: ownership. Hermetic without root — declare a bogus numeric
# OWNER so every real file (owned by us) reads as "not owned by $OWNER".
rc=0; out="$(PATH="$VELANSTUB:$PATH" LEAN_CACHE_ROOT="$VROOT" LEAN_CACHE_OWNER=999999 "$CLI" verify 2>&1)" || rc=$?
check "ownership mismatch -> FAIL, exit 1"  "1" "$rc"
check "ownership mismatch flagged"          "yes" "$(grep -qi 'not owned by 999999' <<<"$out" && echo yes || echo no)"

# Violation 4: fileMode untracked on a package repo -> warn, not FAIL.
gitc "$VROOT/lakes/v9-1-0/packages/batteries" config --unset core.fileMode
rc=0; out="$(run_verify 2>&1)" || rc=$?
check "unset fileMode -> exit 0 (warn only)" "0" "$rc"
check "unset fileMode names the remedy"      "yes" "$(grep -qi 'fix-filemode' <<<"$out" && echo yes || echo no)"
gitc "$VROOT/lakes/v9-1-0/packages/batteries" config core.fileMode false

# Violation 5: an elan toolchain with no matching cache dir -> warn.
OELANSTUB="$TMP/oelanstub"; mkdir -p "$OELANSTUB"
cat > "$OELANSTUB/elan" <<'EL'
#!/usr/bin/env bash
case "$1 $2" in
  "toolchain list") printf 'leanprover/lean4:v9.1.0 (default)\nleanprover/lean4:v9.9.9\n' ;;
  *) exit 0 ;;
esac
EL
chmod +x "$OELANSTUB/elan"
rc=0; out="$(PATH="$OELANSTUB:$PATH" LEAN_CACHE_ROOT="$VROOT" "$CLI" verify 2>&1)" || rc=$?
check "orphan elan toolchain -> exit 0 (warn only)" "0" "$rc"
check "orphan elan toolchain flagged"               "yes" \
  "$(grep -qi 'orphan elan toolchain leanprover/lean4:v9.9.9' <<<"$out" && echo yes || echo no)"

# Violation 6: a cache dir with no matching elan toolchain -> warn.
NELANSTUB="$TMP/nelanstub"; mkdir -p "$NELANSTUB"
cat > "$NELANSTUB/elan" <<'EL'
#!/usr/bin/env bash
case "$1 $2" in
  "toolchain list") printf '' ;;
  *) exit 0 ;;
esac
EL
chmod +x "$NELANSTUB/elan"
rc=0; out="$(PATH="$NELANSTUB:$PATH" LEAN_CACHE_ROOT="$VROOT" "$CLI" verify 2>&1)" || rc=$?
check "orphan cache dir -> exit 0 (warn only)" "0" "$rc"
check "orphan cache dir flagged"               "yes" \
  "$(grep -qi 'orphan cache dir .*v9-1-0' <<<"$out" && echo yes || echo no)"

# Violation 7: install scratch older than a day -> warn; a fresh one is skipped
# (it may be an in-flight install). chmod go-w: mkdir honors the ambient umask
# (e.g. group-writable under umask 002), which would otherwise trip check 2
# (permissions) and mask the scratch check this scenario targets.
mkdir -p "$VROOT/lakes/.build.v9-1-0.stale"; chmod go-w "$VROOT/lakes/.build.v9-1-0.stale"
touch -d '2 days ago' "$VROOT/lakes/.build.v9-1-0.stale"
rc=0; out="$(run_verify 2>&1)" || rc=$?
check "stale install scratch -> exit 0 (warn only)" "0" "$rc"
check "stale install scratch flagged"               "yes" \
  "$(grep -qi 'stale install scratch' <<<"$out" && echo yes || echo no)"
rm -rf "$VROOT/lakes/.build.v9-1-0.stale"

mkdir -p "$VROOT/lakes/.build.v9-1-0.fresh"; chmod go-w "$VROOT/lakes/.build.v9-1-0.fresh"
rc=0; out="$(run_verify 2>&1)" || rc=$?
check "fresh install scratch not flagged"    "0" "$rc"
check "fresh install scratch not flagged (2)" "no" \
  "$(grep -qi 'stale install scratch' <<<"$out" && echo yes || echo no)"
rm -rf "$VROOT/lakes/.build.v9-1-0.fresh"

check "verify logs a verify event"       "yes" "$(grep -q $'\tverify\t' "$evlog" 2>/dev/null && echo yes || echo no)"
check "verify event records the clean run" "1" "$(ev_field "$evlog" verify ok)"

echo
if [[ "$fail" -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$fail"
