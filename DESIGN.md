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

## Model: single writer

Exactly one user — `hostbot`, the deploy user — owns and mutates the cache.
Every file is `hostbot`-owned, group `bots`, and **not group-writable**. Other
bots can only read. This is enforced two ways:

- One-time root migration (`admin/migrate-ownership.sh`) takes ownership,
  strips the per-file ACLs, and removes group/other write.
- All mutation flows through the `lean-cache` CLI, which forces `umask 022` and
  runs a deterministic permission-normalization pass (`u=rwX,go=rX`, setgid on
  dirs) on everything it writes — so readability no longer depends on the
  caller's environment.

Mutating subcommands (`install`/`uninstall`) re-exec as `hostbot` via a
tightly-scoped sudoers rule (`admin/install-sudoers.sh`), so a bot can still
*invoke* them, but the resulting files are always hostbot-owned. Read-only
subcommands run unprivileged.

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

Two stock hooks are installed:

- **post-checkout** — `git checkout` / `switch` / `worktree add`.
- **reference-transaction** — the only stock hook that also fires on
  `git reset --hard` and `git cherry-pick`, which post-checkout never sees. It
  fires on nearly every ref update (and several times per operation), so the
  hook itself filters to the `committed` phase of a HEAD-or-local-branch update
  and otherwise exits immediately; `refresh`'s staleness check is the second
  cheap gate. Because it also covers rebase and `commit --amend` (both move a
  local branch), no separate `post-rewrite` hook is installed.

Both hooks no-op outside a Lean project and while the CLI is mid-overlay
(`LEAN_CACHE_NO_HOOK`), so they can never recurse through their own ref updates.

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

Standard hostbot deploy-handler repo. `deploy.sh` (as hostbot):

1. installs `bin/lean-cache` to `/opt/bots/bin/lean-cache`,
2. ensures `/opt/bots/lean/{lakes,elan}` exist `2755`,
3. reconciles the `versions` manifest — each listed version is `install`ed
   (idempotent). The manifest is a **floor**: ad-hoc installs are never
   auto-removed, and pruning is manual via `uninstall`.

`test.sh` runs first in an isolated worktree: bash syntax + shellcheck, version
resolution unit tests, and validation-rejects-junk tests. It does not touch the
cache or the network.

## Known limitations / open points

- **Shared cache is the mathlib closure.** `install` provisions mathlib and its
  transitive dependencies. Packages beyond that closure are handled per-project
  by the consumer overlay (above), not added to the shared cache — so they
  cost a few project-local symlinks and a local clone, never a shared-tree
  conflict.
- **Orphan RC toolchains.** `v4.29.0-rc7` and `v4.30.0-rc2` are dropped by
  `admin/migrate-ownership.sh` (no corresponding lake cache).
- **Disk.** Each version is ~7–9 GB. No automatic GC; `uninstall` is manual.
- **Toolchain reuse.** `uninstall` removes a version's packages but leaves its
  elan toolchain (cheap, possibly shared). A `--purge-toolchain` flag could be
  added if needed.
