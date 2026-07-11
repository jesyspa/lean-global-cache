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

The single-writer model is opt-in via configuration. `OWNER`, `GROUP`, `ROOT`,
`BIN`, and `INSTALL_LAKE_SHIM` are resolved at runtime with the precedence env
var > config file > built-in default. The config file is `LEAN_CACHE_CONF` if
set (used exclusively), else the first of `~/.config/lean-cache/lean-cache.conf`,
`/etc/lean-cache/lean-cache.conf`, or the legacy `/etc/lean-cache.conf`.

The built-in defaults target a **single-user host**: `OWNER` is the current
user, `ROOT` is `~/.local/share/lean-global-cache`, no config file is needed.
Because `require_owner` no-ops when the caller already IS `OWNER`, a single-user
host never invokes sudo and needs no sudoers rule or admin scripts.

A shared host sets e.g. `OWNER=hostbot GROUP=bots ROOT=/opt/bots/lean
BIN=/opt/bots/bin/lean-cache` in the config file. The admin scripts read the
same file so the sudoers rule always matches the CLI.

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

1. Re-exec as `hostbot` if needed; `umask 022`; take a per-version `flock` and a
   host build slot (`acquire_build_slot`), so the replay build in step 7
   serializes with policied cold builds instead of thrashing alongside them. A
   nested install riding a parent's slot (`LEAN_CACHE_BUILD_SLOT_HELD`) skips
   re-acquiring, so a `use`-triggered auto-install inside a slotted build never
   deadlocks; the slot degrades to unserialized rather than blocking.
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
   permissions. A `--force` rebuild finds the destination already populated and
   swaps the new tree in with `mv --exchange` (renameat2 `RENAME_EXCHANGE`,
   coreutils ≥9.5) — a single atomic swap, so a concurrent consumer never sees
   the destination missing or a dangling overlay through it — falling back to a
   two-mv sequence (with a brief absent window) where `--exchange` is
   unsupported.

Idempotent: a version that already exists is a no-op.

## `uninstall` internals

`lean-cache uninstall <version>`:

1. Re-exec as `hostbot` if needed.
2. Remove `lakes/<slug>/packages` if present (refusing if it's not
   owner-owned, same as `install`).
3. Remove the elan toolchain if present — unless it's elan's *default*
   toolchain, in which case it's left alone (with a note): removing the
   default breaks `elan` for every other toolchain too. A project pinning the
   removed toolchain via `lean-toolchain` prints a warning, since `lean-cache`
   has no way to enumerate which projects pin it.

Each artifact (lake cache, toolchain) is removed independently and reported
separately, so a re-run on a half-removed version (e.g. lake cache already
gone, toolchain still lingering) finishes the job rather than early-returning.
It's a no-op only when neither artifact exists.

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

### Wiring elan to the shared toolchain

`lean-cache` runs its own `lean`/`lake` against the shared `ELAN_HOME`
(`ROOT/elan`), but bare `lean`/`lake` and the editor's Lean server resolve elan
the usual way — via `$HOME/.elan/bin` on `PATH`, or by looking straight at
`~/.elan` — and would otherwise miss the shared toolchain (or be shadowed by a
stale personal elan). So `use` makes `~/.elan` a **symlink to `ROOT/elan`**: no
shell-rc edits, and it also catches tools that hardcode `~/.elan` and ignore
`PATH`. The shared tree stays owner-only (`2755`), so a consumer runs its
toolchains read-only and cannot pollute it — the same read-only-is-enough
argument as the package overlay. In steady state (toolchain already cached and
pinned via `lean-toolchain`) elan never needs to write, so the read-only home is
transparent; an uncached toolchain or `self update` fails loudly, which is the
owner's job to resolve. Linking is idempotent and repoints a wrong/broken link,
but a **real** (non-symlink) `~/.elan` is never clobbered — `use` warns and
leaves it, since replacing a user's own install needs their consent. `check-env`
compares by `realpath`, so a symlinked `~/.elan` reads as correctly wired and a
genuine shadow is flagged. A single-user cache the caller owns (`ELAN_HOME ==
~/.elan`) needs no wiring and is skipped.

Inside a project the `lean-toolchain` file selects the toolchain, so wiring is
all a consumer needs. *Outside* any project, bare `lean`/`lake` fall back to
elan's default toolchain, which a fresh shared `ELAN_HOME` does not set — so they
error with "no default toolchain configured". `set-default-toolchain <version>`
sets it (owner-only, re-execs as `OWNER`, and requires the version already
installed so `elan default` cannot download an uncached toolchain into the shared
tree behind `install`'s back). It is optional: the cache is fully usable for
project work without a default.

### Keeping the overlay fresh across git operations

The overlay is toolchain-specific: it points at `lakes/<slug>/packages`, and a
commit that changes `lean-toolchain` needs the overlay repointed at the new
slug, or lake sees the deps as missing and tries (and fails) to fetch them.
`use` installs git hooks that repoint automatically. They all funnel through
`lean-cache refresh`, which compares the slug embedded in the live overlay
(`readlink .lake/packages/mathlib`) against the slug the current `lean-toolchain`
normalizes to and re-overlays only on a mismatch. The check reads a single
symlink — no fetch, no guess — so it is cheap enough to run on every ref update.

Four hooks are installed:

- **post-checkout** — `git checkout` / `switch` / `worktree add`.
- **reference-transaction** — the only stock hook that also fires on
  `git reset --hard` and `git cherry-pick`, which post-checkout never sees. It
  fires on nearly every ref update (and several times per operation), so the
  hook itself filters to the `committed` phase of a HEAD-or-local-branch update
  and otherwise exits immediately; `refresh`'s staleness check is the second
  cheap gate. Because it also covers rebase and `commit --amend` (both move a
  local branch), no separate `post-rewrite` hook is installed.
- **pre-push** — the project build gate, which also publishes the resulting warm
  build for reuse (see "Pre-push build gate" and "Publishing on push" below).
- **post-commit** — prints a reminder when a commit touches `*.lean` that the
  warm build can be published (see "Publishing on push"). Cheap: it exits after a
  single `diff-tree` when no `*.lean` changed, and honours
  `LEAN_CACHE_NO_COMMIT_HINT`.

The two overlay hooks no-op outside a Lean project and while the CLI is
mid-overlay (`LEAN_CACHE_NO_HOOK`), so they can never recurse through their own
ref updates.

### Self-healing a dangling overlay on build

`refresh`'s staleness check only reads the slug encoded in the live overlay's
`readlink` text — it never checks whether that target still resolves. That's
fine for the toolchain-bump case it exists for, but it means a version
`uninstall`ed out from under a worktree that still points at it (or an overlay
otherwise mangled by hand) would look "current" to `refresh` forever, so the
hooks alone would never repair it. `lean-cache build` (and, via the shim, bare
`lake build`) covers that gap: before it calls the shared build policy, it
checks whether `.lake/packages` already holds an overlay and, if so, whether
any of its shared-cache symlinks has gone dangling (`overlay_broken`). Only
then does it re-run `use` to repair it; a healthy overlay costs one directory
scan and changes nothing. This makes a manual `lean-cache use` unnecessary to
recover from a broken overlay.

The check deliberately does **not** fire on a project with no overlay yet
(`.lake/packages` absent) — that's not "broken", it's "never provisioned",
and forcing one into existence on every cold build would both mis-provision a
project with no shared-cache dependency and, worse, risk masking the fact that
the hooks never ran. It also must never be unconditional: `use`'s own
`seed-build` replaces `.lake/build/{lib,ir}` when the worktree's HEAD matches
a stored build, which is exactly the incremental build state a plain `lake
build` must never disturb — so the repair is gated strictly on an actual
dangling symlink, never run on the common warm/incremental path.

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
entry is replaced, so it doubles as "refresh after main advances"). It records a
`published_at` epoch in the manifest and then rotates the store (below).

### Rotation

The store would otherwise grow unbounded as `main` advances. The policy: keep
the **newest build per (repo, toolchain) indefinitely** — that is "latest main",
the build fresh worktrees will actually seed from — and drop any *other* build
published more than `BUILD_KEEP_DAYS` (default 7) ago. "Latest" is defined by
publish time rather than git topology, which needs no repo access and matches the
workflow (you publish exactly when main advances, so the newest publish is latest
main). `publish-build` rotates the repo it just wrote; `lean-cache prune-builds
[--keep-days N]` applies the policy across the whole store and is safe to cron.

### `seed-build`

`lean-cache seed-build [path]` is called automatically at the end of `use` and
by `refresh` — so both overlay hooks (post-checkout and reference-transaction)
reach it, and a checkout that lands on a published commit seeds even when the
overlay slug is unchanged. It seeds a worktree's `.lake/build` from the store
**only** when the worktree's HEAD exactly matches a stored build's commit **and**
the toolchain slug matches. On any mismatch — or no stored build — it seeds
nothing and lets the normal cold/incremental build run. It never approximates, so
it can never make Lake replay a stale olean as a false green. The exact-(commit,
slug) gate is the whole safety argument: identical commit ⇒ byte-identical
sources ⇒ every module legitimately replays.

When HEAD does match, seeding **replaces** whatever `.lake/build` already holds
(clearing `lib`/`ir` first, so a stale leftover leaves no orphan oleans). It does
not preserve an existing build: the worktrees this targets are long-lived and
reused across tenants, so they typically carry a `.lake/build` from an earlier
commit, and preserving it is exactly what forces the full rebuild seeding exists
to avoid. Replacing is safe because the stored tree *is* the true full build of
this exact commit — and if the worktree's sources have since been edited, Lake's
own mtime/hash staleness check re-elaborates the changed modules regardless of
the seeded oleans, so the replacement cannot manufacture a false green.

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

### `clean`

`lean-cache clean [path]` removes a worktree's `.lake/build`, resetting it to a
cold state. It exists for long-lived worktrees that are recycled across tenants:
such a worktree carries a `.lake/build` from a previous tenant's commit, and the
recycler should `clean` it on handoff so the next tenant starts cold and seeds
cleanly. Seeding already *replaces* a stale build when HEAD lands on a stored
commit, so `clean` is belt-and-suspenders — it also covers the case where the
next checkout is a commit with no stored build, where there is nothing to seed
and the stale leftover would otherwise linger. It leaves `.lake/packages` (the
overlay) alone, since that is just symlinks the hooks refresh, and is a no-op off
a Lake project so a recycler can call it unconditionally.

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

The changed set for a pushed ref is computed against the best base available,
degrading conservatively:

- remote ref exists and its tip is in the local odb — plain `roid..loid` diff;
- ref is new on the remote, or the remote tip is absent locally (a force-push
  after the remote moved, without fetching) — diff from just below the oldest
  pushed commit no remote-tracking ref already has, or from the **empty tree**
  when the entire history is new to the remote (a first push gates every commit,
  not just the tip);
- remote tip absent *and* every pushed commit is already on a remote-tracking
  ref (a force-pushed rollback) — the changed set is undecidable locally, so the
  gate builds anyway rather than waving the push through.

The gate can only build the tree it has: the checked-out worktree. A pushed ref
whose tip is not the worktree's HEAD (`git push origin other` while on `main`)
is **not gated** — a build of `main` says nothing about `other`, so the gate
prints a warning and lets the ref pass rather than green-lighting it on the
strength of the wrong tree. To gate such a ref, check it out and push from that
worktree.

### Skipping the gate for a stored green build

The gate skips its rebuild when the warm-build store already holds this exact
(commit, toolchain) **published from a clean tree** (`tree_clean=1` in the
manifest — no tracked changes, no untracked `.lean`/lakefile/toolchain files):
such a build attests that the commit itself compiles, so rebuilding it only
repeats minutes of work. This kills the observed triple-build pattern (a worker
builds green and publishes, a coordinator re-verifies, and the gate built a
third time) and the re-push of an already-green branch. A store entry published
from a dirty tree records `tree_clean=0` and never skips — the artifacts may
not correspond to the commit (they are still fine to *seed* from: Lake
re-elaborates anything whose sources differ). `LEAN_CACHE_NO_GATE_SKIP=1`
forces the rebuild.

## Transparent `lake` shim

Instances should run bare `lake build` and the LSP as on stock Lean and never
touch `lean-cache` commands or manage build timeouts. A transparent shim makes
that so. `deploy.sh` installs `bin/lake-shim` as `$(dirname BIN)/lake` — on the
fleet `/opt/bots/bin/lake`, which sits at PATH position 2, ahead of the real
`lake` (an ELF at `~/bin/lake`), so it wins.

The shim carries a `LEAN_CACHE_LAKE_SHIM` marker and resolves the real `lake` as
the first `lake` on PATH without that marker (falling back to the active elan
toolchain's `lake`), so it never execs itself. Any subcommand other than `build`
— and the LSP's `lake setup-file`/`serve`/… — `exec`s the real lake untouched,
so only full builds are ever policied. `lake build` delegates to `lean-cache
build`, handing down the resolved real-lake path (`LEAN_CACHE_REAL_LAKE`) so the
build underneath never re-enters the shim and recurses. Keeping the policy in the
CLI — the shim is a thin stub, like the git hooks — means one home for it and one
place a fix lands. `lean-cache`'s own `run_lake_build` resolves the real lake the
same way, so a `lake build` it spawns (the gate, `publish-build`) also skips the
shim.

## Host-wide build serialization

Concurrent full `lake build`s from several sessions oversubscribe the host
(observed: four cold builds stacked on six cores, load ~20, a 10-line check
taking 24 minutes), and every build crawls instead of a few finishing fast. But
most builds are *warm* — a fresh worktree seeded from the store, or an
incremental rebuild after an edit — and serializing those would add pointless
queueing to the common, cheap case. So the policy serializes **only cold/full
builds** (the ones that actually thrash), classified cheaply (milliseconds): a
build is cold when no stored warm build matches HEAD **and** `.lake/build` holds
no oleans; anything else is warm. Warm builds run immediately, foreground, with
no slot — indistinguishable from a plain `lake build`. The classification reuses
the exact-(commit, slug) match `seed-build` already computes.

A cold/full build takes a **host build slot** first: one of
`LEAN_CACHE_BUILD_SLOTS` (default 2) world-openable lock files under `/tmp`
(`flock` on `lean-cache-build-slot.N.lock`), so at most that many heavy builds
run at once, each with real parallelism. Serialization degrades, it never blocks
work: a process that cannot get a slot within `LEAN_CACHE_BUILD_WAIT` seconds
(default 3600) — or cannot use the lock files at all — proceeds unserialized with
a note. Waiting and building both emit periodic progress lines, so a session
watching a silent pipe can tell a minutes-long build from a hang. The slot is
held (fd 8) until the process exits; a child build inherits
`LEAN_CACHE_BUILD_SLOT_HELD` and rides the parent's slot rather than deadlocking
on it. `LEAN_CACHE_BUILD_SLOTS=0` disables serialization.

### Foreground bail on a cold build

A cold/full build takes minutes and cannot finish inside a bounded foreground
tool call — the harness terminates a foreground Bash call that exceeds its
timeout (default ~2 min, max 10) rather than letting it run on or flipping it to
the background. The harness signals which regime a call is in by exporting
`CLAUDE_BASH_MODE=foreground|background` per Bash call; **absent means
background** (a human terminal, cron, or nested script has no 2-minute guillotine
and should just wait).

The policy reads that signal for a cold build:

- **force-wait** (`LEAN_CACHE_FORCE_WAIT=1`, or `--wait` on `lean-cache build`) —
  acquire a slot and build to completion regardless of mode. This is what the
  pre-push gate and `publish-build` set internally, since they must complete
  synchronously (the gate blocks the push).
- **`CLAUDE_BASH_MODE=foreground`** — do **not** build: print the exact command
  to re-run (backgrounded, so the model is woken on completion, or with a
  10-minute timeout) and exit a distinct code (75, so a caller can tell
  "re-run me backgrounded" from a build failure). Bailing fast beats being killed
  mid-build with a half-written `.lake/build`.
- **`background` or absent** — acquire a slot and build to completion (the
  wake-on-completion path).

A build already riding a parent's slot (`LEAN_CACHE_BUILD_SLOT_HELD`) short-
circuits all of this and completes in place — the parent already committed to
building, so a nested build must finish, never bail. `lean-cache build` is an
explicit alias for the same policy; instances no longer need it, but it stays
useful (and `--wait` maps to force-wait).

`use`'s auto-install applies the same foreground bail. `lean-cache use` on a
not-yet-installed version otherwise launches a multi-minute cold install, which
a bounded foreground call would kill mid-build; so in `foreground` mode (and
without `LEAN_CACHE_FORCE_WAIT` or a held parent slot) `use` does not start the
install — it prints the `lean-cache install <version>` command to run
backgrounded / with a long timeout and exits `BUILD_BAIL_CODE`. Background or
absent mode, force-wait, a held slot, and an explicit `lean-cache install` all
proceed to install. The git-hook path (`refresh`) never reaches this — it no-ops
on an uninstalled version rather than provisioning — so a checkout can't trip
the bail either.

Like the two overlay hooks (which delegate to `refresh`), the installed
`pre-push` hook is a thin stub: it does the cheap guards (`SKIP_LEAN_PUSH_GATE`,
lakefile present) and then `exec`s `lean-cache pre-push-gate`, where the actual
gate lives. Keeping the logic in the CLI rather than inlined in the hook means a
fix to the gate reaches every already-installed worktree the moment the CLI is
upgraded — no hook regeneration. (Existing inline hooks still need one `use`/
`refresh` to switch over to the stub; after that they track the CLI.)

The gate runs `lake build` with git's hook-injected environment scrubbed
(`env -u GIT_DIR -u GIT_WORK_TREE …`). `git push` from a *linked worktree*
exports `GIT_DIR`/`GIT_WORK_TREE` into the hook; without scrubbing, the `git`
processes Lake spawns to validate each dependency inherit them and resolve
against the superproject's git dir instead of the package's own checkout. Lake
reads back the superproject's remote URL, decides the package URL "has changed",
and tries to re-clone it — which fails hard against a read-only cache symlink and
would silently re-clone every dependency otherwise. The gate's own git plumbing
(diffing the pushed range) is left on the superproject deliberately; only the
`lake build` is run in the scrubbed environment, matching a plain interactive
`lake build`.

Each hook carries a sentinel comment line. Re-running `use` regenerates the
hooks it owns — and upgrades a pre-sentinel legacy `post-checkout` hook in
place — but never overwrites a hook some other tool installed.

## Publishing on push

Publishing the warm build is bound to **push, not commit**, and specifically to
the moment the pre-push gate's `lake build` succeeds. That is the ideal capture
point for two reasons: the tree is known to compile (a failed gate build aborts
the push, so a broken build is never stored), and the gate has *already* built it
to completion — so `cmd_pre_push_gate` re-invoking `publish-build` costs only an
up-to-date-no-op `lake build` plus the artifact copy. It captures the warm build
for reuse exactly when a branch advances, which is also when a sibling worktree
is most likely to want to seed from that commit.

The publish runs as a re-exec of `lean-cache publish-build` in the same scrubbed
environment as the gate build (same linked-worktree reason — see below), inside
`( … ) || …` so a publish failure is logged but never fails the already-allowed
push. `LEAN_CACHE_NO_PUBLISH_ON_PUSH=1` skips it.

Commit only *reminds*. The `post-commit` hook delegates to `lean-cache
commit-hint`, which prints a one-line note when the commit touched `*.lean`.
Keeping the reminder on commit and the action on push mirrors the workflow: you
commit repeatedly, but the warm build is worth storing when you push. As with the
gate, the hint/publish logic lives in the CLI (the hooks are thin stubs), so a
fix reaches every worktree the moment the CLI is upgraded.

Why not auto-publish on every commit: commit is not build-gated and fires on
intermediate/WIP states, so it would store partial or non-compiling builds (which
`seed-build` would then have to reject) and rebuild repeatedly for commits no one
seeds from. Publishing off the push's completed, gated build avoids both.

## Event log

The warm-build machinery makes strong performance claims — seeding replays a
build in seconds, the gate skips an already-green rebuild, slots keep cold
builds from thrashing the host — with no way to see whether any of it fires in
practice. An append-only event log closes that gap: `stats` turns it into a
seed hit rate, a gate skip/build/fail split, build durations, and slot-wait
counts.

### What is logged

Each event is one tab-separated line —
`epoch<TAB>user<TAB>event<TAB>key=value<TAB>…` — appended to the acting user's
file. The whole set:

- `install` — `slug secs ok forced`. Emitted from an EXIT trap, so a failed
  install (any `die` on the path) still records `ok=0`.
- `use` — `slug auto_install`. `auto_install=1` marks a `use` that provisioned
  the version on first touch.
- `seed` — `hit repo commit slug`. `hit=1` when a stored build matched the
  worktree's exact (commit, slug) and was seeded; `hit=0` when seeding was
  applicable (valid commit+toolchain) but the store held no match. The two
  together are the seed hit rate.
- `publish` — `repo commit slug green secs`.
- `gate` — `outcome=skip|ok|fail`, `repo commit secs` (`secs=0` for a skip).
  Logged only when the gate actually engaged (the push changed `*.lean` at the
  checked-out HEAD).
- `bail` — `where=build|use`, the foreground exit-75 paths that decline to start
  a multi-minute build inside a bounded foreground call.
- `slot` — `wait outcome=acquired|unserialized`, logged only when a cold build
  actually waited for a slot or degraded to unserialized; the instant-acquire
  common case logs nothing.

Attribution follows who acts. `install` re-execs as OWNER, so its event lands in
OWNER's file — correct, OWNER did the build. `use`'s auto-install *trigger* is
logged as the calling user (its own file), while the install it spawns logs
separately as OWNER: the two events attribute the two distinct actors.

### One writer per file

The log dir is shared like the cache, but the file name embeds the writer
(`events.<user>.log`), so every file has exactly one writer. This preserves the
single-writer model that governs the rest of the tree — no file is ever written
by two users — without a lock: concurrent writers touch disjoint files.
`deploy.sh` provisions the dir mode `3775` (setgid so files inherit `$GROUP`,
sticky so a group member cannot remove another's file), the first real consumer
of the `GROUP` setting. On a single-user host the dir sits under the user's own
`$ROOT` and the modes are moot. `stats` only reads, and reads every file it can,
so it needs no privilege and no coordination.

### Never break work

Logging is telemetry, not function: it must never fail or slow a build, a hook,
or a push. `log_event` builds the whole line first, then writes it with a single
`>>`; every step is guarded and the helper always returns 0, so a missing or
unwritable log dir, a full disk, or a `date`/`id` that somehow fails just drops
the event silently. Nothing downstream branches on a log write, and no caller
checks its result — the event log can degrade to writing nothing and every other
guarantee in this document still holds.

## `verify`

The event log measures whether the warm-build machinery fires; `verify`
measures whether the cache's own invariants still hold. It re-checks, over the
whole configured cache, everything `install` establishes at write time but
nothing enforces afterward: mathlib oleans present per version, no group- or
other-writable path (the single-writer invariant itself), everything owned by
`OWNER`, `core.fileMode=false` on every package repo, elan toolchains and
`lakes/<slug>` dirs in sync in both directions, and no `.build.*`/
`.packages.incoming.*`/`.packages.old.*` scratch left over from an install
interrupted mid-flight (a fresh one is skipped — it may be a live install).

It is deliberately report-only: unprivileged, takes no lock, and never writes
under the cache, so it can run from cron on any group member's account without
a sudoers rule and without racing a concurrent `install`. Output mirrors
`check-env`'s `ok`/`warn`/`FAIL` lines — a FAIL is a broken invariant a
consumer's build will hit (missing oleans, a writable path); a warn is drift
that degrades ergonomics or signals a half-finished operation (fileMode noise,
an orphaned toolchain/cache-dir pair, stale scratch) without breaking a build
outright. Exit code follows: 0 clean or warnings-only, 1 on any FAIL, so a cron
wrapper can page on the exit code alone. It ends with a `verify` event
(`fails=N warns=N ok=0/1`) in the same log `stats` reads, so a FAIL streak is
visible there too.

The group/other-writable FAIL has a single-writer remedy: `lean-cache fix-perms
[version]` re-runs the install-time `normalize_perms` pass over the lake cache
(one version or all) as OWNER, putting a stray writable file that drifted in
back to owner-writable/group-read without a hand `chmod`; verify's FAIL line
names it. It covers `$LAKES` only — elan owns `$ELAN_HOME` and normalizing that
tree wholesale is riskier than the drift is worth. Owner-only, so it re-execs
via the same sudoers rule as `install`/`fix-filemode`.

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
2. installs the transparent `lake` shim (`bin/lake-shim`) as `$(dirname BIN)/lake`,
3. ensures `ROOT/{lakes,elan}` exist `2755`,
4. ensures the event-log dir (`LOG_DIR`, default `ROOT/log`) exists `3775`
   (setgid+sticky, group `GROUP`), so any group member writes its own
   `events.<user>.log` but cannot remove another's,
5. reconciles the `versions` manifest — each listed version is `install`ed
   (idempotent). The manifest is a **floor**: ad-hoc installs are never
   auto-removed, and pruning is manual via `uninstall`.

`test.sh` runs first in an isolated worktree: bash syntax + shellcheck, version
resolution unit tests, validation-rejects-junk tests, the overlay/hooks
scenarios, the build-seeding + push-gate scenarios, the warm/cold build-policy
scenarios (warm runs unslotted, cold serializes, foreground bails, background /
force-wait / slot-held build to completion), the `slots` scenarios (a held lock
probes as held without the probe itself holding it, a released one probes free
again), the opportunistic-prune-on-use scenarios (an absent or stale stamp
prunes and refreshes the stamp, a fresh stamp skips), the `lake` shim scenarios
(non-build passthrough, build delegation, no self-recursion), the event-log
scenarios (events written with the right fields across a use/seed/publish/gate
flow, an unwritable log dir does not break the command, and `stats` summarizes a
synthetic log), and the `verify` scenarios (a clean pass, then one violation
per check planted at a time against a hand-built cache tree with a stub
`elan`) — all with a stub `lake`. It does not touch the real cache or the
network.

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
- **Build store rotation.** The warm-build store keeps the newest build per
  (repo, toolchain) indefinitely and drops other builds past `BUILD_KEEP_DAYS`
  (default 7), rotated after each `publish-build`, on demand via `prune-builds`,
  and opportunistically at the end of `use` (at most once a day, guarded by a
  `$BUILDS/.last-prune` stamp file) — so a repo that stops being published to
  still gets swept the next time anyone `use`s it, with no cron required. A
  store no one ever `use`s again (and that stopped being published to) still
  keeps its last build indefinitely; a cron `prune-builds` covers that
  edge case if wanted.
- **Toolchain removal.** `uninstall` removes both a version's lake cache and its
  elan toolchain, independently and idempotently — a re-run on a half-removed
  version finishes whichever side is left. It skips the toolchain (with a note)
  when it is elan's default, since removing that breaks elan, and warns that any
  project pinning the removed toolchain via `lean-toolchain` will no longer
  build; `lean-cache` cannot enumerate project pins, so that warning is a
  caution, not a check.
