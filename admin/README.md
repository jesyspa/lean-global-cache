# admin/ — one-time root setup

These scripts are only needed on **multi-user (shared-writer) hosts**. A
single-user host skips them entirely — the built-in defaults make the current
user the owner, so no sudo rule is needed.

The scripts read `OWNER`, `GROUP`, `ROOT`, and `BIN` from the config
(`/etc/lean-cache.conf` or `LEAN_CACHE_*` env vars), so they automatically
use the same values as the CLI. See
[`lean-cache.conf.example`](../lean-cache.conf.example) for the fleet's settings.

For a shared host, run these scripts once, by hand, when adopting this repo.
Order:

1. `sudo ./admin/install-config.sh` — install `/etc/lean-cache.conf` from
   [`lean-cache.conf.example`](../lean-cache.conf.example), then edit it to this
   host's values. Do this **first**: until the config exists the CLI and the
   other admin scripts fall back to single-user defaults (the calling user and
   `$HOME/.local/share`), which is wrong for a shared cache.

2. `sudo ./admin/migrate-ownership.sh` — take ownership of the existing cache
   tree as OWNER, drop pre-4.28 versions, strip the per-file ACLs, and remove
   group/other write. Best done at a quiet moment: anything that was writing
   into the shared cache will start failing after this (which is the point —
   the cache is now read-only to consumers).

3. `sudo ./admin/install-sudoers.sh` — install `/etc/sudoers.d/lean-cache`
   so any GROUP-member user can run `lean-cache install`/`uninstall` as OWNER.

After all three, deploy the repo through the hostbot deploy-handler as usual;
`deploy.sh` installs the CLI and reconciles the `versions` manifest.
