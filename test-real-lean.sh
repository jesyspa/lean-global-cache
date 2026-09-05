#!/usr/bin/env bash
# Optional offline integration test. Pass an installed Lean toolchain directory.
# Runs real Lake/Lean with isolated HOME, cache and projects; downloads nothing.
set -euo pipefail
CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/lean-cache"
TC="$(cd "${1:?usage: bash test-real-lean.sh /path/to/toolchain}" && pwd)"
[[ -x "$TC/bin/lake" && -x "$TC/bin/lean" ]] || exit 2
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" LEAN_CACHE_CONF="$T/no-config" LEAN_CACHE_ROOT="$T/cache" \
  LEAN_CACHE_BUILDS="$T/builds" LEAN_CACHE_BUILD_SLOTS=0 \
  LEAN_CACHE_REAL_LAKE="$TC/bin/lake" PATH="$TC/bin:$PATH"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
mkdir -p "$HOME" "$T/project/Proj"
P="$T/project"; Q="$T/sibling"
version="$(lean --version)"; version="${version#Lean (version }"; version="${version%%,*}"
printf 'leanprover/lean4:v%s\n' "$version" > "$P/lean-toolchain"
printf '.lake/\n' > "$P/.gitignore"
printf 'name = "p"\ndefaultTargets = ["Proj"]\n[[lean_lib]]\nname = "Proj"\n' > "$P/lakefile.toml"
printf 'def value : Nat := 1\n' > "$P/Proj/A.lean"
printf 'import Proj.A\nexample : value = 1 := rfl\n' > "$P/Proj.lean"
git -C "$P" init -q
git -C "$P" add .
git -C "$P" -c user.name=test -c user.email=test@example.com commit -qm init
# Lake generates its manifest on first build. Commit it before publishing.
(cd "$P" && "$TC/bin/lake" build)
git -C "$P" add lake-manifest.json
git -C "$P" -c user.name=test -c user.email=test@example.com commit -qm manifest
"$CLI" publish-build "$P"
store_olean="$(find "$LEAN_CACHE_BUILDS" -path '*/lib/lean/Proj/A.olean' -print)"
[[ -f "$store_olean" ]]
cp "$store_olean" "$T/original.olean"
git -C "$P" -c core.hooksPath=/dev/null worktree add -q "$Q" HEAD
"$CLI" seed-build "$Q"
[[ "$store_olean" -ef "$Q/.lake/build/lib/lean/Proj/A.olean" ]]
"$CLI" build --wait "$Q"
# Rebuilding a seeded olean must replace its inode, not modify the store.
printf 'def value : Nat := 2\n' > "$Q/Proj/A.lean"
printf 'import Proj.A\nexample : value = 2 := rfl\n' > "$Q/Proj.lean"
"$CLI" build --wait "$Q"
[[ ! "$store_olean" -ef "$Q/.lake/build/lib/lean/Proj/A.olean" ]]
cmp "$store_olean" "$T/original.olean"
# A source error after seeding must not replay as a successful build.
printf 'import Proj.A\nexample : value = 3 := rfl\n' > "$Q/Proj.lean"
if "$CLI" build --wait "$Q"; then
  echo 'FAIL: invalid proof passed after seeding' >&2; exit 1
fi
echo 'REAL LEAN TEST PASSED'
