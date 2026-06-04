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
         "$REPO_DIR"/admin/*.sh; do
  [[ -e "$f" ]] || continue
  bash -n "$f" && note "ok: $f"
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  shellcheck -S warning "$CLI" "$REPO_DIR/deploy.sh" "$REPO_DIR/test.sh" \
    "$REPO_DIR"/admin/*.sh && note "ok: shellcheck clean"
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

echo
if [[ "$fail" -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$fail"
