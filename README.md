# lean-global-cache

A shared Lean/mathlib package cache plus a CLI (`lean-cache`) that installs
mathlib versions into it and overlays them onto your projects. Projects read
mathlib's prebuilt oleans from the cache instead of building or downloading
them per worktree.

The cache is single-writer: everything in it is owned by one configured user
and is not group-writable, so consumers can only read it. All mutation goes
through the CLI. See [DESIGN.md](DESIGN.md) for the rationale and internals.

## Install

**Single-user host** — put `bin/lean-cache` on your PATH. No config file, no
sudo. The cache lands in `~/.local/share/lean-global-cache` and you own it.

```bash
lean-cache config      # show the resolved OWNER/GROUP/ROOT/BIN
lean-cache check-env   # verify this user's wiring to the cache
```

**Multi-user host** — copy [`lean-cache.conf.example`](lean-cache.conf.example)
to `/etc/lean-cache/lean-cache.conf` and edit it, then do the one-time root
setup in [admin/README.md](admin/README.md). After that, deploy with
`deploy.sh`: it installs the CLI to `BIN`, installs the transparent `lake` shim
beside it, and reconciles the [`versions`](versions) manifest.

## Usage

### In a project

```bash
cd ~/dev/my-lean-project   # has a lean-toolchain file
lean-cache use             # overlay .lake/packages onto the shared cache
lake build                 # builds your code into project-local .lake/build
```

`use` installs the version if the cache doesn't have it yet, symlinks each
shared package into `.lake/packages`, seeds `.lake/build` from a stored warm
build if one matches HEAD, and installs the git hooks described below. Re-run
it after a version bump; `lean-cache use --clean` rebuilds the overlay from
scratch.

Then use bare `lake` and the LSP exactly as on stock Lean. Your own build
artifacts stay in the project's `.lake/build`; only mathlib's oleans come from
the shared cache.

`.lake/packages` is a real directory, so a project needing packages beyond
mathlib's closure can let `lake` clone them in alongside the symlinks.

If the path you give `use` is not itself a Lake project and you name no
version, the command applies to every Lake project found beneath it — a repo
root holding several independent projects works without per-project wiring.
The same fallback applies to `refresh`, `seed-build`, `publish-build`, and
`clean`.

### Sharing a warm build between worktrees

`.lake/build` is per-worktree, so a fresh worktree cold-builds the whole
project even when an identical build exists next door. `lean-cache` keeps a
per-user store of warm builds keyed by (repo, exact commit, toolchain).

```bash
lean-cache publish-build   # store this worktree's warm build
# … later, in a fresh worktree at the same commit …
lean-cache use             # overlays packages AND seeds .lake/build
lake build                 # re-elaborates only what you edit
```

Seeding happens only on an exact commit+toolchain match, so a stale build can
never replay as a false green. The store lives under
`~/.cache/lean-global-cache/builds` (`LEAN_CACHE_BUILDS`) and rotates itself;
`lean-cache prune-builds [--keep-days N]` prunes it on demand.

### Git hooks `use` installs

- `post-checkout` / `reference-transaction` — run `lean-cache refresh`, which
  repoints the overlay when HEAD moves to a commit pinning a different
  toolchain, and is a cheap no-op otherwise.
- `pre-push` — runs `lake build` before a push that changes any `*.lean` and
  aborts on failure. Skipped when the warm-build store already holds this
  commit as green; on success it publishes the build for reuse. Bypass with
  `SKIP_LEAN_PUSH_GATE=1`. The gate only fires when the repo root itself is a
  Lake project.

### Builds

Where the `lake` shim is installed, bare `lake build` routes through a shared
policy (also reachable as `lean-cache build`). Warm and incremental builds run
immediately. Cold full builds first take one of `LEAN_CACHE_BUILD_SLOTS`
(default 2) host-wide slots, so concurrent sessions don't stack several
thrashing builds onto the same cores. `lean-cache slots` shows which slots are
free or held.

A cold build cannot finish inside a bounded foreground Claude Code call, so
there the policy prints the command to re-run and exits 75 — re-run it
backgrounded or with a long timeout. `--wait` (or `LEAN_CACHE_FORCE_WAIT=1`)
blocks to completion regardless. `LEAN_CACHE_BUILD_SLOTS=0` disables
serialization.

### Monitoring

```bash
lean-cache stats [--since DAYS]   # summarize the event log, default 7 days
lean-cache verify                 # read-only invariant sweep, cron-friendly
```

Mutating and build-policy paths append tab-separated lines to
`$LOG_DIR/events.<user>.log`; `stats` summarizes seed hit rate, gate outcomes,
build durations, and slot waits. `verify` checks the cache's invariants and
exits 1 on any FAIL, so it fits a cron job that pages on the exit code. Both
are read-only and need no privilege.

## Commands

```
lean-cache install [--force] <version>      build & install a mathlib version
lean-cache uninstall <version>              remove a version's cache and toolchain
lean-cache set-default-toolchain <version>  default for bare lean/lake outside a project
lean-cache link <version>                   print the packages path to symlink against
lean-cache use [version] [path]             set up .lake/packages in a project
lean-cache refresh [path]                   re-overlay only if the toolchain changed
lean-cache seed-build [path]                seed .lake/build from a stored warm build
lean-cache publish-build [path]             store this project's warm build for reuse
lean-cache build [--wait] [path] [args]     lake build under the shared build policy
lean-cache clean [path]                     wipe .lake/build
lean-cache prune-builds [--keep-days N]     rotate the warm-build store
lean-cache slots                            report host build-slot state
lean-cache list                             installed versions + sizes
lean-cache resolve <version>                show normalized toolchain/rev/slug
lean-cache config                           show resolved owner/group/root/builds/bin
lean-cache check-env                        check this user's wiring to the cache
lean-cache verify                           read-only cache invariant sweep
lean-cache stats [--since DAYS]             summarize the event log
lean-cache fix-perms [version]              re-normalize cache permissions
```

`<version>` accepts `4.30`, `4.30.0`, `v4.30.0`, `leanprover/lean4:v4.30.0`, or
an RC like `4.30.0-rc2`. Bare `major.minor` expands to `major.minor.0`;
otherwise the version is exact — there is no "latest patch" resolution.

`install`, `uninstall`, and `set-default-toolchain` re-exec as the cache owner
via sudo on a multi-user host. Everything else only reads the shared cache and
needs no privilege.

## Configuration

Precedence: env var > config file > built-in default.

| Setting           | Env var                      | Default (single-user)                              |
|-------------------|------------------------------|----------------------------------------------------|
| OWNER             | LEAN_CACHE_OWNER             | current user (`id -un`)                            |
| GROUP             | LEAN_CACHE_GROUP             | current group (`id -gn`)                           |
| ROOT              | LEAN_CACHE_ROOT              | `$HOME/.local/share/lean-global-cache`             |
| BIN               | LEAN_CACHE_BIN               | realpath of the running `lean-cache` script        |
| INSTALL_LAKE_SHIM | LEAN_CACHE_INSTALL_LAKE_SHIM | `0` (no `lake` shim)                               |
| LOG_DIR           | LEAN_CACHE_LOG_DIR           | `$ROOT/log`                                        |

`LEAN_CACHE_CONF`, if set, is the config file and nothing else is read.
Otherwise the first existing of `~/.config/lean-cache/lean-cache.conf`,
`/etc/lean-cache/lean-cache.conf`, `/etc/lean-cache.conf` is used. It may set
any subset of the settings as plain shell assignments.

The cache layout under `ROOT`:

```
<root>/elan/                    ELAN_HOME — lean toolchains
<root>/lakes/<slug>/packages/   per-version package cache (mathlib + deps)
```

`<slug>` is the toolchain version with dots replaced by dashes, e.g. `v4-30-0`.
