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
# A clean-tree publish attests the commit: the gate must skip its rebuild when
# the store already holds that (commit, toolchain) with tree_clean=1.
printf 'def a := 8\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm edit5
c5="$(gitc "$P" rev-parse HEAD)"
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'OLE8' > "$P/.lake/build/lib/lean/Proj/A.olean"
PATH="$STUB:$PATH" "$CLI" publish-build "$P" >/dev/null 2>&1
m5="$(grep -Rl "^commit=$c5$" "$LEAN_CACHE_BUILDS" 2>/dev/null | head -1)"
check "clean-tree publish stamps tree_clean=1"  "tree_clean=1" "$(grep '^tree_clean=' "$m5" 2>/dev/null)"
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

# A dirty-tree publish (untracked .lean present) attests nothing: tree_clean=0
# and the gate must NOT skip.
printf 'def stray := 0\n' > "$P/Stray.lean"                 # untracked source
printf 'def a := 10\n' > "$P/Proj/A.lean"; gitc "$P" add Proj/A.lean; gitc "$P" commit -qm edit7
c7="$(gitc "$P" rev-parse HEAD)"
rm -rf "$P/.lake/build"; mkdir -p "$P/.lake/build/lib/lean/Proj"; printf 'OLE10' > "$P/.lake/build/lib/lean/Proj/A.olean"
PATH="$STUB:$PATH" "$CLI" publish-build "$P" >/dev/null 2>&1
m7="$(grep -Rl "^commit=$c7$" "$LEAN_CACHE_BUILDS" 2>/dev/null | head -1)"
check "dirty-tree publish stamps tree_clean=0"  "tree_clean=0" "$(grep '^tree_clean=' "$m7" 2>/dev/null)"
rm -f "$P/Stray.lean"
: > "$TMP/g.log"
out="$(PATH="$STUB:$PATH" LEAN_CACHE_NO_PUBLISH_ON_PUSH=1 LAKE_LOG="$TMP/g.log" \
       gitc "$P" push origin HEAD:main 2>&1)"; rc=$?
check "gate does not skip on a dirty-tree store" "1" "$(grep -c '^lake' "$TMP/g.log" 2>/dev/null)"
check "no skip message on a dirty-tree store"    "no" \
  "$(printf '%s' "$out" | grep -q 'skipping the gate build' && echo yes || echo no)"

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
