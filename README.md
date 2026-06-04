# lean-global-cache

Owns the shared Lean/mathlib package cache under `/opt/bots/lean` and exposes a
CLI (`lean-cache`) that bots use to install, remove, and link mathlib versions.

## Why

The cache used to be group-writable and owned by whichever bot happened to
publish each version. Bots wrote into it directly — stray `lake update`/
`git checkout`/`cache get` in the shared checkouts clobbered it for everyone,
and a publish under the wrong umask once left an entire version unreadable to
the rest of the group.

This repo makes the cache **single-writer**: every file is owned by `hostbot`
and is not group-writable. Consumers can only read it, so they cannot clobber
it. All mutation goes through one CLI that applies a deterministic umask and
permission pass every time.

## CLI

```
lean-cache install <version>     # build & install a mathlib version
lean-cache uninstall <version>   # remove a version
lean-cache link <version>        # print the packages path to symlink against
lean-cache use [version] [path]  # set up .lake/packages in a project
lean-cache list                  # installed versions + sizes
lean-cache resolve <version>     # show normalized toolchain/rev/slug
```

`<version>` accepts `4.30`, `4.30.0`, `v4.30.0`, `leanprover/lean4:v4.30.0`, or
an RC like `4.30.0-rc2`. Bare `major.minor` expands to `major.minor.0`;
otherwise the version is exact (no "latest patch" resolution).

`install` and `uninstall` re-exec themselves as `hostbot` via sudo, so they work
from any bots-group user while always producing hostbot-owned files. `link`,
`use`, `list`, and `resolve` are read-only and need no privilege.

### Consuming the cache from a project

```bash
cd ~/dev/my-lean-project          # has a lean-toolchain file
lean-cache use                    # links .lake/packages to the shared cache
lake exe cache get                # near-instant; oleans already present
lake build                        # builds your code into project-local .lake/build
```

Your project's own build artifacts live in `.lake/build`; only mathlib's
prebuilt oleans are read from the shared cache, so read-only access is enough.

## Layout it manages

```
/opt/bots/lean/elan/                    ELAN_HOME — lean toolchains
/opt/bots/lean/lakes/<slug>/packages/   per-version package cache (mathlib + deps)
```

`<slug>` is the toolchain version with dots replaced by dashes, e.g.
`v4-30-0`. Consumers symlink `.lake/packages` at
`/opt/bots/lean/lakes/<slug>/packages`.

## Setup & deployment

One-time root setup (ownership migration + sudoers) — see
[admin/README.md](admin/README.md). After that, deploy through the hostbot
deploy-handler: `deploy.sh` installs the CLI to `/opt/bots/bin/lean-cache` and
reconciles the [`versions`](versions) manifest (a floor of versions to keep
present — it never auto-removes).

See [DESIGN.md](DESIGN.md) for the full rationale, install internals, and known
limitations.
