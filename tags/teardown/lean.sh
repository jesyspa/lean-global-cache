#!/usr/bin/env bash
# Teardown for `lean`-tagged repos — run when a worktree is recycled for a new
# tenant, before the checkout that hands the slot off (the mirror of
# tags/setup/lean.sh).
#
# Cold-resets the worktree's `.lake/build` via `lean-cache clean`. That build is
# gitignored, so `git clean`/`git reset` in the recycle path leave it in place,
# and the next tenant would otherwise inherit the previous tenant's stale build
# and force wrong/slow incremental builds. `clean` removes `.lake/build` only
# (leaving the `.lake/packages` overlay), so after the recycle checkout the
# post-checkout hook re-seeds `.lake/build` from the warm store when HEAD
# matches a stored build, and otherwise the slot starts cold — never warm-wrong.
#
# `lean-cache clean` is a no-op off a Lake project and when there's no build to
# remove, so this is safe to run unconditionally; the `lean` tag already gates
# it to repos where it's relevant. Runs as the bot/tenant user on its own
# worktree — no sudo.
set -euo pipefail

exec /opt/bots/bin/lean-cache clean
