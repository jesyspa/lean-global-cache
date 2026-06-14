# Design

## Problem

`/opt/bots/lean` holds the shared Lean toolchains (`elan/`) and a per-version
mathlib package cache (`lakes/<slug>/packages/`). Historically it was
`bots`-group-writable with a permissive default ACL, and every bot wrote into
it directly. Two failure modes followed:

1. **Clobbering.** A bot doing `lake update`, `git checkout`, or `lake exe cache
   get` inside the *shared* package checkouts mutated them for everyone — e.g.
   checking out the wrong mathlib rev corrupted the cache other bots were using.
2. **Permission lottery.** Each version was owned by whoever published it
   (`v4-28-0` by devbot, `v4-30-0` by brainbot) under whatever umask that
   session happened to have. One publish ran under umask 077, leaving ~8200
   oleans mode 600 and the whole version unreadable to the rest of the group
   until it was hand-repaired with `setfacl`.

## Portability / configuration

The single-writer model is opt-in via configuration. Four settings — `OWNER`,
`GROUP`, `ROOT`, `BIN` — are resolved at runtime with the precedence env var >
`/etc/lean-cache.conf` > built-in default.

The built-in defaults target a **single-user host**: `OWNER` is the current
user, `ROOT` is `~/.local/share/lean-global-cache`. Because `require_owner`
no-ops when the caller already IS `OWNER`, a single-user host never invokes
sudo and needs no sudoers rule or admin scripts.

The fleet sets `OWNER=hostbot GROUP=bots ROOT=/opt/bots/lean
BIN=/opt/bots/bin/lean-cache` via `/etc/lean-cache.conf`. The admin scripts
read the same config file so the sudoers rule always matches the CLI.

## Model: single writer

Exactly one user — the configured `OWNER` — owns and mutates the cache.
Every file is `OWNER`-owned and **not group-writable**. Other group members can
only read. This is enforced two ways:

- One-time root migration (`admin/migrate-ownership.sh`) takes ownership,
  strips the per-file ACLs, and removes group/other write.
- All mutation flows through the `lean-cache` CLI, which forces `umask 022` and
  runs a deterministic permission-normalization pass (`u=rwX,go=rX`, setgid on
  dirs) on everything it writes — so readability no longer depends on the
  caller's environment.

Mutating subcommands (`install`/`uninstall`) re-exec as `OWNER` via a
tightly-scoped sudoers rule (`admin/install-sudoers.sh`), so any group member
can still *invoke* them, but the resulting files are always OWNER-owned.
Read-only subcommands run unprivileged. On a single-user host where the caller
IS already `OWNER`, the re-exec is skipped entirely.

### Why read-only is enough for consumers

A consuming project overlays its `.lake/packages` onto the shared
`lakes/<slug>/packages` (see "Consumer overlay" below). Lake reads mathlib's
prebuilt oleans from the shared tree but writes the project's *own* build
artifacts into the project-local `.lake/build`. Nothing in a normal consumer
build needs to write into the shared `packages/`. The cases that used to write
there — `lake update`, `cache get`, dependency rebuilds — are exactly the
clobbering we are removing; under this model they happen once, at install time,
performed by the owner.

A direct consequence worth stating: a project pinned to a mathlib rev/toolchain
that is **not installed** will no longer silently rebuild into the shared tree.
It fails loudly instead. Version discipline becomes mandatory rather than
best-effort — which is the intended outcome.

## `install` internals

`lean-cache install <version>`:

1. Re-exec as `hostbot` if needed; `umask 022`; take a per-version `flock`.
2. `elan toolchain install leanprover/lean4:<version>` into `ELAN_HOME`.
3. Build in a temp project **on the same filesystem** as the destination (so
   the final move is atomic): a `lean-toolchain` pinned to the version and a
   `lakefile.toml` requiring `mathlib` at `rev = v<version>`.
4. `lake update mathlib` — resolves mathlib + its dependency closure (batteries,
   aesop, Qq, proofwidgets, importGraph, plausible, LeanSearchClient) into a
   flat `.lake/packages`.
5. `lake exe cache get` — downloads mathlib's prebuilt oleans (covers the whole
   dependency closure).
6. Integrity check: abort unless mathlib oleans are actually present.
7. Atomically move `.lake/packages` into `lakes/<slug>/packages`, then normalize
   permissions.

Idempotent: a version that already exists is a no-op.

## Consumer overlay

`lean-cache use` does **not** make `.lake/packages` a single symlink to the
shared tree. Instead it builds an *overlay*: `.lake/packages` is a real
directory holding one symlink per shared package
(`.lake/packages/mathlib -> .../lakes/<slug>/packages/mathlib`, etc.). The
directory itself is project-owned and writable, so a project that requires
packages beyond mathlib's closure lets `lake` clone those in alongside the
symlinks; they live in the project, not the shared cache, so they never collide
with another project's revs. This was chosen over installing extras into the
shared cache precisely to avoid cross-project conflicts.

`use` is idempotent and version-aware:

- A legacy whole-directory symlink (or `--clean`) is replaced with a fresh
  overlay.
- Symlinks pointing into *any* shared cache are dropped and recreated from the
  current version's tree, so a toolchain bump repoints cleanly and removed
  packages disappear.
- A package name the project provides as its own *real* directory is treated as
  an intentional override/extra and left untouched.

### Keeping the overlay fresh across git operations

The overlay is toolchain-specific: it points at `lakes/<slug>/packages`, and a
commit that changes `lean-toolchain` needs the overlay repointed at the new
slug, or lake sees the deps as missing and tries (and fails) to fetch them.
`use` installs git hooks that repoint automatically. They all funnel through
`lean-cache refresh`, which compares the slug embedded in the live overlay
(`readlink .lake/packages/mathlib`) against the slug the current `lean-toolchain`
normalizes to and re-overlays only on a mismatch. The check reads a single
symlink — no fetch, no guess — so it is cheap enough to run on every ref update.

Three hooks are installed:

- **post-checkout** — `git checkout` / `switch` / `worktree add`.
- **reference-transaction** — the only stock hook that also fires on
  `git reset --hard` and `git cherry-pick`, which post-checkout never sees. It
  fires on nearly every ref update (and several times per operation), so the
  hook itself filters to the `committed` phase of a HEAD-or-local-branch update
  and otherwise exits immediately; `refresh`'s staleness check is the second
  cheap gate. Because it also covers rebase and `commit --amend` (both move a
  local branch), no separate `post-rewrite` hook is installed.
- **pre-push** — the project build gate (see "Pre-push build gate" below).

The two overlay hooks no-op outside a Lean project and while the CLI is
mid-overlay (`LEAN_CACHE_NO_HOOK`), so they can never recurse through their own
ref updates.

## Project build seeding

`.lake/packages` (mathlib) is shared, but `.lake/build` — the project's own
oleans — is per-worktree. Every fresh worktree of a repo therefore cold-builds
the entire project cone from scratch, even when a byte-identical warm build
already exists in a sibling worktree at the same commit. On a large project that
is many minutes per worktree, and under multi-instance load (several worktrees
cold-building the same cone at once) it caused repeated long single-file
compiles and memory pressure. Seeding eliminates the redundant work.

### Store

A per-user store under `BUILDS` (default `~/.cache/lean-global-cache/builds`)
holds warm `.lake/build` trees keyed by **(repo identity, exact commit,
toolchain slug)**:

```
<BUILDS>/<repo>-<hash>/<full-commit-sha>/<slug>/{lib,ir,.seed-manifest}
```

`<repo>-<hash>` is the basename of the repo's shared git dir plus a short hash of
its realpath, so all worktrees of one repo share a key while distinct repos
never collide. The store is **single-writer, owner-owned, read-only**: dirs
`755`, files `444`, owned by the publishing user.

Unlike the mathlib package cache, this store is **per-user**, not owned by a
fleet-wide cache owner. A project's `.lake/build` is reproducible and the
worktrees that share it belong to one user; the clobbering hazards that made the
package cache single-owner (`lake update` / `cache get` mutating shared
checkouts) do not apply to immutable content-addressed build snapshots. Keeping
it per-user also sidesteps a cross-user wrinkle: the publishing user's worktrees
are not readable by a different cache owner, so an owner-builds-it path would
have to rebuild from scratch. (`BUILDS` is configurable, so a shared
owner-owned store with an owner-path publish remains possible if ever needed.)

### `publish-build`

`lean-cache publish-build [path]` runs `lake build` to completion first — so a
partial or stale tree is never stored (which would later replay as a false
green) — then snapshots `.lake/build/{lib,ir}` into the store under a per-build
`flock`, normalizes permissions, and atomically swaps it into place (an existing
entry is replaced, so it doubles as "refresh after main advances").

### `seed-build`

`lean-cache seed-build [path]` is called automatically at the end of `use` (and
thus by the post-checkout hook). It seeds a worktree's `.lake/build` from the
store **only** when the worktree's HEAD exactly matches a stored build's commit
**and** the toolchain slug matches **and** the worktree has no project build
yet. On any mismatch — or no stored build — it seeds nothing and lets the normal
cold/incremental build run. It never approximates, so it can never make Lake
replay a stale olean as a false green. The exact-(commit, slug) gate is the
whole safety argument: identical commit ⇒ byte-identical sources ⇒ every module
legitimately replays.

Two artifact classes are handled differently:

- **`*.olean`** — hardlinked from the read-only store. They are large (the bulk
  of the disk), and `lean` always writes a rebuilt olean via unlink+create (a
  fresh inode), never in place — so a read-only hardlink to the shared store is
  safe: an in-worktree edit can't mutate the shared inode, and a rebuild simply
  replaces the link. The seed first verifies the store is owned by the caller
  and has no group/other-writable file, refusing to link out of a store it
  cannot vouch for.
- **everything else** (`.trace`, `.hash`, `.setup.json`, `.ilean`, `.c`, …) —
  copied as writable, worktree-owned files. Lake rewrites this bookkeeping *in
  place* when it rebuilds a module, so these must never be links back to the
  shared store.

The net effect: a fresh worktree at a stored commit replays the whole project in
seconds instead of cold-building it; editing one `.lean` file rebuilds exactly
that file's cone (its olean replaced with a fresh worktree-owned inode) and
nothing stale slips through.

## Pre-push build gate

A targeted check (`lake build <submodule>`, `lake env lean <file>`) can report
green on non-compiling code via stale-olean replay, which once let a
non-compiling commit reach `main`. The `pre-push` hook closes that gap: for any
project with a lakefile, before allowing a push that changes `*.lean`, it

1. computes the changed `*.lean` across the pushed range,
2. `touch`es them (bumping mtime invalidates their traces — defeating replay),
3. runs the bare default `lake build`,
4. aborts the push if the build fails.

A bare `lake build` can take minutes; that latency is the intended cost of the
gate. It is generic (no project-specific paths), no-ops when the push changes no
`*.lean`, and is bypassable with `SKIP_LEAN_PUSH_GATE=1` for when the user has
just run a clean build themselves.

Each hook carries a sentinel comment line. Re-running `use` regenerates the
hooks it owns — and upgrades a pre-sentinel legacy `post-checkout` hook in
place — but never overwrites a hook some other tool installed.

## Version normalization

A version string is reduced to four canonical forms:

| form        | example                      | used for                |
|-------------|------------------------------|-------------------------|
| `TCVER`     | `v4.30.0`                    | display                 |
| `TOOLCHAIN` | `leanprover/lean4:v4.30.0`   | elan / `lean-toolchain` |
| `REV`       | `v4.30.0`                    | mathlib git rev         |
| `SLUG`      | `v4-30-0`                    | cache directory name    |

Bare `major.minor` is expanded to `major.minor.0`; everything else is taken
verbatim, including `-rcN` suffixes. Inputs that are not `vX.Y.Z[-suffix]` are
rejected — this is also what keeps the sudoers wildcard safe.

## Deployment

Standard hostbot deploy-handler repo. `deploy.sh` (as `OWNER`):

1. installs `bin/lean-cache` to `BIN`,
2. ensures `ROOT/{lakes,elan}` exist `2755`,
3. reconciles the `versions` manifest — each listed version is `install`ed
   (idempotent). The manifest is a **floor**: ad-hoc installs are never
   auto-removed, and pruning is manual via `uninstall`.

`test.sh` runs first in an isolated worktree: bash syntax + shellcheck, version
resolution unit tests, validation-rejects-junk tests, the overlay/hooks
scenarios, and the build-seeding + push-gate scenarios (with a stub `lake`). It
does not touch the real cache or the network.

`publish-build` / `seed-build` are not part of `deploy.sh`: they are per-user,
per-project operations a bot runs in its own worktrees, not a host-level deploy
step.

## Known limitations / open points

- **Shared cache is the mathlib closure.** `install` provisions mathlib and its
  transitive dependencies. Packages beyond that closure are handled per-project
  by the consumer overlay (above), not added to the shared cache — so they
  cost a few project-local symlinks and a local clone, never a shared-tree
  conflict.
- **Orphan RC toolchains.** `v4.29.0-rc7` and `v4.30.0-rc2` are dropped by
  `admin/migrate-ownership.sh` (no corresponding lake cache).
- **Disk.** Each version is ~7–9 GB. No automatic GC; `uninstall` is manual.
- **Build store GC.** The warm-build store is keyed by exact commit, so entries
  for superseded commits accumulate and are never auto-removed. Each entry is
  modest (the project build, oleans hardlinked across worktrees), but pruning
  old commits is currently manual (`rm -rf` under `BUILDS`).
- **Toolchain reuse.** `uninstall` removes a version's packages but leaves its
  elan toolchain (cheap, possibly shared). A `--purge-toolchain` flag could be
  added if needed.
