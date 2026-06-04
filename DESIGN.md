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

A consuming project symlinks its `.lake/packages` at the shared
`lakes/<slug>/packages`. Lake reads mathlib's prebuilt oleans from there but
writes the project's *own* build artifacts into the project-local `.lake/build`.
Nothing in a normal consumer build needs to write into `packages/`. The cases
that used to write there — `lake update`, `cache get`, dependency rebuilds —
are exactly the clobbering we are removing; under this model they happen once,
at install time, performed by the owner.

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

- **Mathlib closure only.** `install` provisions mathlib and its transitive
  dependencies. A project that requires *extra* packages not in that closure
  (e.g. a standalone `Cli`) cannot add them to the read-only shared cache the
  way it used to. Such projects need those deps provided another way. If this
  becomes common, the manifest could grow per-version "extra package" lists.
- **Orphan RC toolchains.** `v4.29.0-rc7` and `v4.30.0-rc2` exist under
  `elan/toolchains` with no corresponding lake cache. Left in place for now;
  drop if confirmed unused.
- **Disk.** Each version is ~7–9 GB. No automatic GC; `uninstall` is manual.
- **Toolchain reuse.** `uninstall` removes a version's packages but leaves its
  elan toolchain (cheap, possibly shared). A `--purge-toolchain` flag could be
  added if needed.
