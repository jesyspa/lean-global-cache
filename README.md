# lean-global-cache

Owns a shared Lean/mathlib package cache and exposes a CLI (`lean-cache`) that
bots use to install, remove, and link mathlib versions.

## Why

The cache used to be group-writable and owned by whichever bot happened to
publish each version. Bots wrote into it directly — stray `lake update`/
`git checkout`/`cache get` in the shared checkouts clobbered it for everyone,
and a publish under the wrong umask once left an entire version unreadable to
the rest of the group.

This repo makes the cache **single-writer**: every file is owned by the
configured owner and is not group-writable. Consumers can only read it, so
they cannot clobber it. All mutation goes through one CLI that applies a
deterministic umask and permission pass every time.

## CLI

```
lean-cache install <version>     # build & install a mathlib version
lean-cache uninstall <version>   # remove a version's lake cache and elan toolchain
lean-cache link <version>        # print the packages path to symlink against
lean-cache use [version] [path]  # set up .lake/packages in a project
lean-cache refresh [path]        # re-overlay only if the toolchain changed
lean-cache seed-build [path]     # seed .lake/build from a stored warm build
lean-cache publish-build [path]  # store this project's warm build for reuse
lean-cache build [--wait] [path] [args]  # lake build under the shared build policy
lean-cache clean [path]          # wipe .lake/build (cold-reset a reused worktree)
lean-cache prune-builds [--keep-days N]  # rotate the warm-build store
lean-cache list                  # installed versions + sizes
lean-cache resolve <version>     # show normalized toolchain/rev/slug
lean-cache config                # show resolved owner/group/root/builds/bin
```

`<version>` accepts `4.30`, `4.30.0`, `v4.30.0`, `leanprover/lean4:v4.30.0`, or
an RC like `4.30.0-rc2`. Bare `major.minor` expands to `major.minor.0`;
otherwise the version is exact (no "latest patch" resolution).

`install` and `uninstall` re-exec themselves as the cache owner via sudo on a
multi-user host, so they work from any group member while always producing
owner-owned files. On a single-user host the current user IS the owner, so no
sudo is needed. `link`, `use`, `refresh`, `list`, `config`, and `resolve` only
read the shared cache (writing at most into the consuming project) and need no
privilege.

### Consuming the cache from a project

```bash
cd ~/dev/my-lean-project          # has a lean-toolchain file
lean-cache use                    # overlays .lake/packages onto the shared cache
lake exe cache get                # near-instant; oleans already present
lake build                        # builds your code into project-local .lake/build
```

Use bare `lake` (and the LSP) exactly as on stock Lean. On the fleet a
transparent `lake` shim sits ahead of the real `lake` on PATH: every subcommand
except `build` passes straight through, and `lake build` routes through the
[shared build policy](#transparent-builds-cold-only-serialization) so cold/full
builds serialize host-wide — you never invoke `lean-cache build` or manage a
build timeout yourself.

`use` makes `.lake/packages` a real directory containing one symlink per shared
package (mathlib + its closure). Because the directory itself is writable, a
project that requires extra packages beyond mathlib's closure can let `lake`
clone them in alongside the symlinks — those live in the project, so they never
conflict with other projects in the read-only shared tree. Re-running `use`
repoints the shared symlinks (e.g. after a version bump) and leaves the
project's own package dirs untouched; `lean-cache use --clean` rebuilds the
overlay from scratch.

`use` also installs git hooks (`post-checkout` and `reference-transaction`) that
repoint the overlay automatically whenever HEAD moves to a commit pinning a
different toolchain — including via `git reset --hard` and `git cherry-pick`.
They call `lean-cache refresh`, which re-overlays only on an actual toolchain
mismatch and is otherwise a cheap no-op. See [DESIGN.md](DESIGN.md) for details.

Your project's own build artifacts live in `.lake/build`; only mathlib's
prebuilt oleans are read from the shared cache, so read-only access is enough.

### Seeding a worktree's project build

`.lake/build` is per-worktree, so every fresh worktree of a repo cold-builds the
entire project from scratch — even when a byte-identical warm build already
exists in a sibling worktree at the same commit. To avoid that, `lean-cache`
keeps a per-user store of warm project builds keyed by **(repo, exact commit,
toolchain slug)**:

```bash
lean-cache publish-build           # build to completion, then store the warm
                                   # .lake/build for the current commit+toolchain
# … later, in any fresh worktree at that same commit …
lean-cache use                     # overlays packages AND seeds .lake/build
lake build                         # re-elaborates only the files you edit
```

`use` and `refresh` call `seed-build` automatically, so both overlay hooks
(post-checkout and reference-transaction) reach it. Seeding happens **only** when
the worktree's HEAD exactly matches a stored build's commit and the toolchain
matches; on any mismatch it seeds nothing and the normal cold/incremental build
runs, so a stale build can never replay as a false green. When HEAD does match,
seeding replaces any `.lake/build` already present (a reused worktree's stale
leftover is exactly what otherwise forces a needless full rebuild); Lake still
re-elaborates any module you have since edited. Oleans are hardlinked from the read-only store (so they cost no disk and
can't be mutated through the worktree — a rebuild replaces the link with a fresh
file); the small bookkeeping files Lake rewrites in place are copied. The store
lives under `~/.cache/lean-global-cache/builds` by default (`LEAN_CACHE_BUILDS`
to override); it is per-user because a project's build is reproducible and the
worktrees that share it belong to one user — unlike the cross-bot mathlib cache.

The store is rotated automatically: `publish-build` keeps the newest build per
`(repo, toolchain)` indefinitely (that is "latest main") and drops any older one
past a window (`LEAN_CACHE_BUILD_KEEP_DAYS`, default 7). `lean-cache prune-builds
[--keep-days N]` applies the same policy across the whole store on demand (cron-
friendly).

### Pre-push build gate

`use` also installs a `pre-push` hook. Before allowing a push that changes any
`*.lean`, it bumps the mtime of the changed files (defeating stale-olean replay)
and runs a bare `lake build`, aborting the push if the build fails. This catches
the "pushed non-compiling code that targeted checks falsely reported green" case.
A full `lake build` can take minutes — that latency is the intended cost. Set
`SKIP_LEAN_PUSH_GATE=1` to bypass it (e.g. right after a known-clean build).

The gate skips the rebuild when the warm-build store already holds this exact
commit+toolchain published from a clean tree — that build already attests the
commit compiles, so re-pushing an already-green branch (or pushing right after
a `publish-build`) is near-instant. `LEAN_CACHE_NO_GATE_SKIP=1` forces the
rebuild. The gate only vouches for the checked-out HEAD: pushing a ref whose
tip is some other commit passes with a warning instead of being validated
against the wrong tree.

### Transparent builds & cold-only serialization

Instances run bare `lake build`; the serialization is transparent and engages
only for builds that actually thrash the host. The installed `lake` shim routes
`lake build` through a shared policy (also reachable explicitly as `lean-cache
build`):

- **warm/incremental** (a stored warm build matches HEAD, or `.lake/build`
  already holds oleans) → runs immediately, foreground, with no slot. This is
  the common case and feels exactly like a plain `lake build`.
- **cold/full** (no stored build matches HEAD *and* `.lake/build` has no oleans)
  → takes one of `LEAN_CACHE_BUILD_SLOTS` (default 2) host-wide lock slots first,
  so concurrent sessions don't stack five thrashing cold builds onto six cores.
  Waiting is capped (`LEAN_CACHE_BUILD_WAIT`, default 3600s) and degrades to an
  unserialized build rather than blocking; progress lines print while waiting and
  every 30s during the build.

A cold/full build cannot finish inside a bounded foreground tool call. The
harness exports `CLAUDE_BASH_MODE=foreground|background` per Bash call
(absent → treat as `background`). When a cold build is requested with
`CLAUDE_BASH_MODE=foreground`, the policy does **not** build: it prints the exact
command to re-run and exits code 75, so you re-run it backgrounded (woken on
completion) or with a 10-minute timeout instead of having it killed mid-build.
In `background` mode (or absent) a cold build queues on a slot and runs to
completion. Set `LEAN_CACHE_FORCE_WAIT=1` (or pass `--wait` to `lean-cache
build`) to block to completion regardless of mode; the pre-push gate and
`publish-build` force-wait internally, since they must complete synchronously. A
build riding a parent's slot (`LEAN_CACHE_BUILD_SLOT_HELD`) completes in place —
no second slot, no bail. `LEAN_CACHE_BUILD_SLOTS=0` disables serialization.

Before either path runs, the build policy also checks the project's package
overlay: if a shared-cache symlink under `.lake/packages` has gone dangling
(e.g. its version was `uninstall`ed out from under a worktree that still
points at it), it re-overlays once to repair it, then proceeds. A healthy
overlay costs one stat and changes nothing, so this never touches an
already-fine `.lake/build`; you no longer need to run `lean-cache use` by hand
to recover from a broken overlay.

Because the gate already builds the pushed commit to completion, it then
**publishes that warm build** (`publish-build`) so future worktrees at the same
commit seed instead of cold-building — capturing the build for reuse at exactly
the moment a branch advances, at no extra build cost. Skip this with
`LEAN_CACHE_NO_PUBLISH_ON_PUSH=1`. A commit touching any `*.lean` also prints a
one-line reminder that `lean-cache publish-build` is available (silence with
`LEAN_CACHE_NO_COMMIT_HINT=1`); it's just a nudge, since a clean push publishes
automatically.

## Layout it manages

```
<root>/elan/                    ELAN_HOME — lean toolchains
<root>/lakes/<slug>/packages/   per-version package cache (mathlib + deps)
```

`<slug>` is the toolchain version with dots replaced by dashes, e.g. `v4-30-0`.
Consumers symlink `.lake/packages` at `<root>/lakes/<slug>/packages`.

On the fleet these paths are under `/opt/bots/lean` (see [Configuration](#configuration)).

## Configuration

These settings control the host layout:

| Setting           | Env var                       | Default (single-user)                              |
|-------------------|-------------------------------|----------------------------------------------------|
| OWNER             | LEAN_CACHE_OWNER              | current user (`id -un`)                            |
| GROUP             | LEAN_CACHE_GROUP              | current group (`id -gn`)                           |
| ROOT              | LEAN_CACHE_ROOT              | `$HOME/.local/share/lean-global-cache`             |
| BIN               | LEAN_CACHE_BIN               | realpath of the running `lean-cache` script itself |
| INSTALL_LAKE_SHIM | LEAN_CACHE_INSTALL_LAKE_SHIM | `0` (no `lake` shim)                               |

**Precedence:** env var > config file > built-in default.

**Config file:** `LEAN_CACHE_CONF`, if set, is used exclusively; otherwise the
first that exists is read — `~/.config/lean-cache/lean-cache.conf` (per-user)
then `/etc/lean-cache/lean-cache.conf` (multi-user), plus the legacy
`/etc/lean-cache.conf`. It may set any subset of the settings as plain shell
assignments. See [`lean-cache.conf.example`](lean-cache.conf.example).

**Single-user host:** no config file needed. Just put `bin/lean-cache` on your
PATH (or install it anywhere). The cache lands in
`~/.local/share/lean-global-cache`, you already own it, and no sudo or admin
scripts are required.

```bash
lean-cache config      # show the resolved OWNER/GROUP/ROOT/BIN
lean-cache check-env   # verify this user's wiring to the cache
```

**Multi-user host:** copy `lean-cache.conf.example` to
`/etc/lean-cache/lean-cache.conf` and edit to taste (the fleet values are
`OWNER=hostbot GROUP=bots ROOT=/opt/bots/lean BIN=/opt/bots/bin/lean-cache`,
`INSTALL_LAKE_SHIM=1`), then follow [admin/README.md](admin/README.md) for the
one-time root setup.

## Setup & deployment

**Single-user:** no setup — just use the CLI.

**Multi-user:** one-time root setup (ownership migration + sudoers) — see
[admin/README.md](admin/README.md). After that, deploy through the hostbot
deploy-handler: `deploy.sh` installs the CLI to `BIN`, installs the transparent
`lake` shim next to it (`$(dirname BIN)/lake`), and reconciles the
[`versions`](versions) manifest (a floor of versions to keep present — it never
auto-removes).

See [DESIGN.md](DESIGN.md) for the full rationale, install internals, and known
limitations.
