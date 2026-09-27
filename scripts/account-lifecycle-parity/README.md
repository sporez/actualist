# Account lifecycle parity oracle

This tool overlays a focused Vitest harness into an **isolated** checkout of
Actual Budget v26.9.0, executes the real loot-core account handlers against the
normal in-memory SQLite test database, and promotes normalized CRDT/domain
evidence into Actualist's fixture directory.

It is intentionally not a reimplementation of account lifecycle behavior. The
harness calls `account-update`, `account-reopen`, `account-close`,
`account-unlink`, schedule creation/advancement, and History undo through the
pinned loot-core handler/mutator stack. Provider HTTP calls remain mocked by
loot-core's normal node-test setup. No Actual server URL, token, bank account,
or personal budget is used.

## Ownership and prerequisites

Only the sprint coordinator may run this oracle. The checkout passed to
`--actual-checkout` must be an isolated disposable clone/worktree under that
coordinator's sole ownership. Never point the generator at the shared
read-only source checkout. `--evidence` is also required and must name a unique,
not-yet-existing directory beneath an existing parent outside every Actual
checkout. In particular, never write run evidence under the shared upstream
source.

Required inputs:

- Actual `v26.9.0` at commit
  `59fe126f637d858c061e1eeedbef5436c8f2225a`;
- Node 24.x (the prepared checkout used Node 24.21.x);
- the repository-pinned Yarn `4.17.1` release;
- a completed focused `@actual-app/core` dependency setup, including root
  `node_modules/.yarn-state.yml` and the resolved `better-sqlite3` 12.11.1
  native binary;
- a clean tracked Actual checkout. The generator refuses tracked changes and
  refuses to overwrite an unowned harness overlay.

Reuse the coordinator's approved immutable dependency-ready setup when
preparing the isolated checkout; this tool never runs an install. It verifies
and records hashes for `yarn.lock`, `.yarnrc.yml`,
`node_modules/.yarn-state.yml`, the resolved `better-sqlite3` package manifest
and entry point, and the native addon selected by the package's installed
`bindings` resolver. These hashes identify the available install used by the
run; they do not claim a byte-for-byte audit of every transitive dependency.

The generator creates only these temporary untracked files in the isolated
Actual checkout and removes them only after their run evidence is archived:

```text
packages/loot-core/src/server/accounts/account-lifecycle-parity.test.ts
packages/loot-core/src/server/accounts/account-lifecycle-parity-support.ts
.actualist-account-lifecycle-oracle.json
.actualist-account-lifecycle-vitest-<invocation-id>.json
.actualist-account-lifecycle-process.json
```

The generator makes no network or server request. Provider calls remain inside
loot-core's node-test `#server/post` mock. If a timed-out owned process group
cannot be confirmed stopped, the generator reports its process-group ID and
retains these temporary paths instead of claiming safe cleanup.

Every runtime attempt archives a unique evidence directory before cleanup or
fixture promotion. Depending on which checkpoints were reached, it contains:

```text
run.json
result.json
ownership.json
vitest-report.json
raw-oracle-checkpoint.json
vitest.log
generator-error.log
```

`run.json` records the child and validation outcome, PID/PGID, normalized
command, dependency identity, generator hash, and hashes of available evidence
files. `result.json` is initialized before promotion or cleanup and then
atomically records their final status; a surviving `pending` value means the
generator did not establish completion. A failed raw checkpoint is diagnostic
only: it may contain cases completed before `--bail=1` stopped Vitest and is
never promoted as a fixture. If evidence archiving or result initialization
fails, fixture promotion is refused and checkout-local checkpoints are retained.

## Predetermined invocation

From the Actualist repository root:

```sh
node scripts/account-lifecycle-parity/generate.mjs \
  --actual-checkout /absolute/path/to/isolated-actual-v26.9.0 \
  --evidence /absolute/path/to/actualist-artifacts/account-lifecycle-run-001
```

The generator performs exactly one runtime command, from the isolated Actual
checkout root. The equivalent normalized command is:

```sh
TZ=UTC \
ACTUALIST_ACCOUNT_LIFECYCLE_ORACLE_OUTPUT='/absolute/path/to/isolated-actual-v26.9.0/.actualist-account-lifecycle-oracle.json' \
node .yarn/releases/yarn-4.17.1.cjs workspace @actual-app/core run test:node \
  src/server/accounts/account-lifecycle-parity.test.ts \
  --bail=1 \
  --reporter=json \
  --outputFile='/absolute/path/to/isolated-actual-v26.9.0/.actualist-account-lifecycle-vitest-<invocation-id>.json'
```

Both output paths passed to Vitest are absolute. `TZ=UTC` pins fixture dates;
matching Actual's local-calendar close date remains an explicit B2 product gate,
not a conclusion from this fixture. The exact normalized argv, working
directory, pinned environment values, 180,000 ms execution ceiling, 5,000 ms
termination grace, tool versions, dependency identities, source hashes, harness
hashes, and generation date are written to the generated manifest.

Vitest receives `--bail=1`. The generator owns the child and its descendants as
one detached POSIX process group and durably records its PID/PGID in the
isolated checkout. At the three-minute ceiling or a catchable parent interrupt,
it sends `SIGTERM` only to that group and waits five seconds. It sends `SIGKILL`
to that same group only if the recorded child is still active, avoiding a later
signal after its PGID could be reused. It then waits one second to confirm exit.
An abrupt parent exit makes a final synchronous `SIGTERM` attempt and leaves the
ownership record for coordinator recovery. It never uses a blanket process
kill. Fixture promotion cannot begin until the child exits successfully and the
owned process group is gone.

The intended generated files are:

```text
ActualistTests/Fixtures/ActualCore26_9_0/AccountLifecycle/
  account-lifecycle-oracle.json
  manifest.json
```

An alternative destination may be supplied with `--output`. Promotion uses a
temporary directory and rename only after Vitest exits zero, every predetermined
case is present exactly once, and the run-specific evidence archive is complete.
Both the final evidence path and its run-specific staging path must not already
exist.

## Predetermined cases and assertions

The harness has no case filter. One invocation must complete exactly 22 cases
across all of these groups:

- open/closed rename and History inverse, plus the core handler's unchanged,
  whitespace, exact-duplicate, and case-variant input boundary;
- reopen plus repeated reopen behavior and History inverse;
- empty-account deletion and History restoration;
- nonempty zero-balance close;
- positive and negative nonzero closes;
- on-budget → on-budget, on-budget → off-budget (hidden category), off-budget
  → on-budget, and off-budget → off-budget transfer/category behavior;
- self-transfer refusal with zero CRDT/domain change;
- split-parent balance exclusion and split-child inclusion;
- forced simple deletion and a forced split/paired-transfer graph deletion;
- SimpleFIN local unlink;
- GoCardless last-reference remote removal, shared-bank suppression, absent
  token behavior, and swallowed remote failure;
- an active schedule reference before close, after close, and after reopen,
  including automatic-posting eligibility;
- rename, reopen, empty/zero/nonzero close undo boundaries, including proof
  that local provider unlink is outside the close undo group.

Every case asserts normalized raw CRDT cells and selected relational rows. The
fixture stores synthetic IDs and amounts only. CRDT timestamps and SQLite
message IDs are deliberately omitted because they are transport ordering noise;
the remaining message order is preserved.

## Stop conditions and correction budget

The generator stops without promoting fixtures if any of these occurs:

- the commit, tag, package version, Node major, or Yarn version differs;
- dependency setup evidence or the resolved native SQLite 12.11.1 binary is
  absent;
- pinned source or harness files are missing;
- the isolated checkout has tracked changes;
- an overlay/output path already exists and is not owned by this invocation;
- the explicit evidence destination is absent, overlaps the fixture output, is
  inside the isolated Actual checkout, or already exists;
- Vitest exits nonzero or its JSON report does not describe a passing run;
- the three-minute execution ceiling is reached; if process-group exit cannot
  be confirmed, temporary files are retained for coordinator-owned recovery;
- the raw output schema, case IDs, case count, or synthetic-data declaration
  differs from the reviewed contract;
- a generated file fails the reviewed manifest invariants or a recorded SHA-256
  does not match;
- run evidence cannot be archived before cleanup and fixture promotion.

The approved execution budget is one coordinator-owned generation/investigation
and, only after a concrete correction, at most one post-correction generation.
Do not retry unchanged code, broaden to the upstream suite, run another worker's
checkout, or count source inspection as oracle proof.
