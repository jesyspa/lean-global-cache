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

echo
if [[ "$fail" -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$fail"
