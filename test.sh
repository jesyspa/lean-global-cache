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
for f in "$CLI" "$REPO_DIR/deploy.sh" "$REPO_DIR/test.sh" \
         "$REPO_DIR/lib/config.sh" "$REPO_DIR"/admin/*.sh \
         "$REPO_DIR/lean-cache.conf.example"; do
  [[ -e "$f" ]] || continue
  bash -n "$f" && note "ok: $f"
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  shellcheck -S warning "$CLI" "$REPO_DIR/deploy.sh" "$REPO_DIR/test.sh" \
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

echo "== build seeding & push gate (hermetic) =="
# No real Lean here: a stub `lake` stands in for the build so publish/seed and
# the push gate can be exercised without the toolchain or the network. The store
# is redirected to a throwaway dir via LEAN_CACHE_BUILDS.
export LEAN_CACHE_BUILDS="$TMP/builds"
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

# Idempotent: re-seeding a worktree that already has a build changes nothing.
before="$(inode "$Q/.lake/build/lib/lean/Proj/A.olean")"
"$CLI" seed-build "$Q" >/dev/null 2>&1
check "seed-build no-ops when a build exists"  "$before" "$(inode "$Q/.lake/build/lib/lean/Proj/A.olean")"

# Safety: on a commit mismatch, seed NOTHING (never approximate a stale build).
R="$TMP/r"; mkdir -p "$R/Proj"; gitc "$R" init -q
pin v4.30.0 "$R"; printf 'name="p"\n' > "$R/lakefile.toml"
printf 'def a := 2\n' > "$R/Proj/A.lean"     # different content -> different commit
gitc "$R" add -A; gitc "$R" commit -qm other
"$CLI" seed-build "$R" >/dev/null 2>&1
check "seed-build no-ops on commit mismatch"   "0" \
  "$(find "$R/.lake/build" -name '*.olean' 2>/dev/null | wc -l)"

# Push gate: stub lake decides pass/fail; a bare remote receives the push.
"$CLI" use "$P" >/dev/null 2>&1                   # installs hooks (+ re-seeds, a no-op)
check "pre-push hook installed"               "yes" \
  "$(grep -ql lean-cache-managed-hook "$P/.git/hooks/pre-push" && echo yes || echo no)"
check "pre-push hook delegates to pre-push-gate" "yes" \
  "$(grep -ql 'pre-push-gate' "$P/.git/hooks/pre-push" && echo yes || echo no)"
git init -q --bare "$TMP/remote.git"
gitc "$P" remote add origin "$TMP/remote.git"

# Establish the baseline on the remote (the first push carries A.lean, so the
# gate runs the build once here).
: > "$TMP/g.log"
PATH="$STUB:$PATH" LAKE_LOG="$TMP/g.log" gitc "$P" push -q origin HEAD:main >/dev/null 2>&1 || true
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

echo
if [[ "$fail" -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$fail"
