# admin/ — one-time root setup

These scripts need root and are **not** run by `deploy.sh`. Run them once, by
hand, when adopting this repo on a host. Order:

1. `sudo ./admin/migrate-ownership.sh` — take ownership of the existing
   `/opt/bots/lean` tree as `hostbot`, drop pre-4.28 versions, strip the
   per-file ACLs, and remove group/other write. Best done at a quiet moment:
   anything that was writing into the shared cache will start failing after
   this (which is the point — the cache is now read-only to consumers).

2. `sudo ./admin/install-sudoers.sh` — install `/etc/sudoers.d/lean-cache`
   so any `bots`-group user can run `lean-cache install`/`uninstall` as
   `hostbot`.

After both, deploy the repo through the hostbot deploy-handler as usual;
`deploy.sh` installs the CLI and reconciles the `versions` manifest.
