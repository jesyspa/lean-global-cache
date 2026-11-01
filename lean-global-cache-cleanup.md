# Test scratch adoption

Both public test entrypoints enter the substrate private-scratch context before suite work begins: `test.sh` and `test-real-lean.sh`. They select the helper from `BOTS_HOST_SOURCE_ROOT`, then `BOTS_LIB`, then `/opt/bots/lib`; nested contexts are verified and reused. This preserves the existing suite behavior while giving all default temporary-directory allocations kernel-owned cleanup on managed Linux hosts.

Scratch producer review: `mktemp`/`mkdtemp` sites in `test.sh` and `test-real-lean.sh` use the default temp location and therefore follow the launcher's `TMPDIR`. Other `mktemp` calls in CLI/deploy/admin code are production staging paths, not test scratch escapes. Test scratch paths stay within the managed temp namespace.
