# lean-global-cache

A shared, read-only Lean/mathlib package cache and the `lean-cache` CLI that
manages it. Projects on the host symlink mathlib's prebuilt oleans out of the
cache instead of each worktree building or downloading its own copy.

One configured user owns every file in the cache and nothing is
group-writable, so consumers cannot clobber it; all mutation goes through the
CLI. [DESIGN.md](DESIGN.md) has the rationale, internals, and known
limitations.

## Install

**Single-user host** — get `elan` on your PATH first; the CLI drives it but does
not install it (`elan-init.sh` from elan.lean-lang.org). Then put
`bin/lean-cache` on your PATH. The cache lands in
`~/.local/share/lean-global-cache`, you own it, and no config file or sudo is
involved. The cache and the shared toolchain dir stay empty until the first
`lean-cache use` in a project, which creates them and installs that project's
pinned toolchain. `lean-cache check-env` reports the wiring after that; on a
bare install it correctly reports both as missing.

**Multi-user host** — copy [`lean-cache.conf.example`](lean-cache.conf.example)
to `/etc/lean-cache/lean-cache.conf` and edit it, do the one-time root setup in
[admin/README.md](admin/README.md), then run `deploy.sh`. That installs the CLI
to `BIN` and the `lake` shim beside it. It provisions no versions — `use`
installs a project's pinned toolchain the first time it is needed.

## Use it in a project

```bash
cd ~/dev/my-lean-project   # has a lean-toolchain file
lean-cache use             # overlay .lake/packages onto the shared cache
lake build                 # your code builds into project-local .lake/build
```

`use` installs the pinned version if the cache lacks it, symlinks mathlib and
its dependency closure into `.lake/packages`, seeds `.lake/build` from a stored
warm build when one matches HEAD, and installs the git hooks below. Re-run it
after a version bump; `--clean` rebuilds the overlay from scratch.

After that, use bare `lake` and the LSP as on stock Lean. Only mathlib's oleans
come from the shared cache — your build artifacts stay in the project.
`.lake/packages` is a real directory, so a project needing packages outside
mathlib's closure can let `lake` clone them in alongside the symlinks.

Point `use` at a directory that is not itself a Lake project and it overlays
every Lake project beneath it, so a repo holding several independent projects
needs no per-project wiring. `refresh`, `seed-build`, `publish-build`, and
`clean` do the same.

### Git hooks

`use` installs three hooks:

- `post-checkout` and `reference-transaction` run `lean-cache refresh`, which
  repoints the overlay when HEAD moves to a commit pinning a different
  toolchain and is a cheap no-op otherwise.
- `pre-push` runs `lake build` before any push touching a `*.lean` file and
  aborts the push if it fails. It is skipped when the warm-build store already
  holds this commit as green, and on success it publishes the build for reuse.
  `SKIP_LEAN_PUSH_GATE=1` bypasses it. It only fires when the repo root itself
  is a Lake project.

### Sharing a warm build between worktrees

`.lake/build` is per-worktree, so a fresh worktree cold-builds the whole project
even when an identical build sits next door. `lean-cache` keeps a per-user
store of warm builds keyed by repo, exact commit, and toolchain:

```bash
lean-cache publish-build   # store this worktree's warm build
# … later, in a fresh worktree at the same commit …
lean-cache use             # overlays packages AND seeds .lake/build
```

Seeding requires an exact commit and toolchain match, so a stale build can
never replay as a false green. The store lives under
`~/.cache/lean-global-cache/builds` (`LEAN_CACHE_BUILDS`) and rotates itself;
`lean-cache prune-builds` prunes it on demand.

### Builds

Where the `lake` shim is installed, bare `lake build` runs under a shared
policy. Warm and incremental builds start immediately. A cold full build first
takes one of `LEAN_CACHE_BUILD_SLOTS` host-wide slots (default 2) so concurrent
sessions don't stack several thrashing builds onto the same cores;
`lean-cache slots` shows which are held. `LEAN_CACHE_BUILD_SLOTS=0` turns
serialization off.

A cold build cannot finish inside a bounded foreground Claude Code call, so
there the policy prints the command to re-run and exits 75 — re-run it
backgrounded or with a long timeout. `lean-cache build --wait` blocks to
completion regardless.

## Commands

`lean-cache --help` prints the full list. The ones you will type:

| Command | What it does |
|---|---|
| `use [version] [path]` | overlay a project onto the cache; installs hooks |
| `publish-build [path]` | store this worktree's warm build for reuse |
| `build [--wait] [path]` | `lake build` under the shared build policy |
| `clean [path]` | wipe `.lake/build` back to cold |
| `install <version>` | build and install a mathlib version |
| `uninstall <version>` | remove a version's cache and toolchain |
| `list` | installed versions and sizes |
| `check-env` | check this user's wiring to the cache |
| `verify` | read-only invariant sweep; exits 1 on failure, fits cron |
| `stats [--since DAYS]` | summarize the event log (default 7 days) |

`<version>` accepts `4.30`, `4.30.0`, `v4.30.0`, `leanprover/lean4:v4.30.0`, or
an RC like `4.30.0-rc2`. Bare `major.minor` expands to `major.minor.0`;
otherwise the version is exact — there is no "latest patch" resolution.

`install`, `uninstall`, and `set-default-toolchain` re-exec as the cache owner
via sudo on a multi-user host. Everything else needs no privilege.

`stats` reads the event log the CLI appends to at
`$LOG_DIR/events.<user>.log`, one line per mutating or build-policy operation.

## Configuration

Env var beats config file beats built-in default.

| Setting | Env var | Default (single-user) |
|---|---|---|
| OWNER | `LEAN_CACHE_OWNER` | current user (`id -un`) |
| GROUP | `LEAN_CACHE_GROUP` | current group (`id -gn`) |
| ROOT | `LEAN_CACHE_ROOT` | `$HOME/.local/share/lean-global-cache` |
| BIN | `LEAN_CACHE_BIN` | realpath of the running `lean-cache` |
| INSTALL_LAKE_SHIM | `LEAN_CACHE_INSTALL_LAKE_SHIM` | `0` (no `lake` shim) |
| LOG_DIR | `LEAN_CACHE_LOG_DIR` | `$ROOT/log` |

If `LEAN_CACHE_CONF` is set it is the only config file read. Otherwise the
first existing of `~/.config/lean-cache/lean-cache.conf`,
`/etc/lean-cache/lean-cache.conf`, `/etc/lean-cache.conf` wins. It may set any
subset of the settings as shell assignments. `lean-cache config` prints what
resolved.

Under `ROOT`, `elan/` is the shared `ELAN_HOME` and `lakes/<slug>/packages/`
is the package cache for one version, where `<slug>` is the toolchain version
with dots replaced by dashes (`v4-30-0`).
