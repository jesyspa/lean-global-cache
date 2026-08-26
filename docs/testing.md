# Testing

Read this before adding a case to `test.sh` or when the deploy gate's runtime
matters.

## Tiers

`test.sh` runs the push tier by default — what the deploy gate pays for on every
deploy. `BOTS_RUN_SLOW=1 ./test.sh` adds the nightly tier, and is what a nightly
runner invokes for full coverage. The push tier ends by naming how much it
deferred.

Two markers put a case in the nightly tier:

- A whole group: add its name to `NIGHTLY_SUITES` instead of `SUITES`.
- A single case: wrap it in `if slow "<description>"; then ... fi`.

Defer a case when its end-to-end round-trip through the real CLI costs more than
the deploy gate should pay and a push-tier case already covers the behaviour it
exercises — the nightly case guards a variant, never the core path. Never defer
a case to make a number.

## Groups

Every section of the suite is a group function (`group_<name>`), listed in
`SUITES`. The runner executes groups concurrently, buffers each one's output, and
replays it in declaration order, so a parallel run reads like a serial one.
`TEST_JOBS=1 ./test.sh` runs one group at a time when a failure needs untangling.

A group is hermetic. `new_cache` gives it its own cache root, build store, `HOME`
and build-slot lock dir, so no group can observe another's state — or the real
`/opt/bots/lean` tree, or the host's build slots. A new group calls `new_cache`
first, then builds every fixture it needs; sharing a fixture across groups is
what makes them serial again.

## Fixtures

`new_lake_project`, `new_gate_project` and `new_policy_projects` build the
standard project shapes; `write_lake_stub` writes the stub `lake` that stands in
for every build. No case runs a real Lean build or touches the network.

`gitc` runs git with the lean-cache-managed hooks live; `gitq` disables them.
Fixture plumbing goes through `gitq` — a commit or checkout in a `use`d repo
re-enters the CLI through the hooks, which costs more than the git call itself.
Use `gitc` where the hook firing is the thing under test.
