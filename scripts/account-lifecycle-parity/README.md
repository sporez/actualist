# Account lifecycle parity oracle

This tool overlays a focused Vitest harness into the Actual Budget oracle
checkout named by `ACTUALIST_PARITY_ORACLE_ROOT`, pinned in
`config/parity/oracle-pin.json`. It executes the real loot-core account handlers
against the normal in-memory SQLite test database and promotes normalized
CRDT/domain evidence into Actualist's fixture directory.

It is intentionally not a reimplementation of account lifecycle behavior. The
harness calls `account-update`, `account-reopen`, `account-close`,
`account-unlink`, schedule creation/advancement, and History undo through the
pinned loot-core handler/mutator stack. The harness installs explicit mocks for
every `#server/post` HTTP entry point and checks those seams before any case;
unexpected methods fail rather than reaching a network. No Actual server URL,
real token, bank account, or personal budget is used.

Database and rule setup runs under loot-core's normal test environment. For
each nonconcurrent case, the harness then fixes the clock at noon UTC on
2026-09-27, temporarily selects Actual's real production-calendar path, and
preflights the real `currentDay()` export before invoking handlers. That path
remains active through schedule-service shutdown. Cleanup restores the exact
prior `IS_TESTING` value and resets the clock even when a handler or cleanup
step fails; the harness does not partially mock the cached months module.

## Ownership and prerequisites

`ACTUALIST_PARITY_ORACLE_ROOT` must be a clean checkout of the pinned tag and
commit. `scripts/parity/lib/oracle-pin.mjs` checks it before the run and again
after cleanup. `--evidence` is required for a generation run. It must name a
unique, not-yet-existing directory beneath an existing parent outside the oracle
checkout.

Required inputs:

- the Actual tag and commit recorded in `config/parity/oracle-pin.json`;
- Node 24.x (the prepared checkout used Node 24.21.x);
- the repository-pinned Yarn `4.17.1` release;
- a completed focused `@actual-app/core` dependency setup, including root
  `node_modules/.yarn-state.yml` and the resolved `better-sqlite3` 13.0.3
  native binary;
- a clean Actual checkout (untracked files included). The generator refuses
  to overwrite an existing harness overlay.

The generator never runs an install. It verifies
and records hashes for `yarn.lock`, `.yarnrc.yml`,
`node_modules/.yarn-state.yml`, the resolved `better-sqlite3` package manifest
and entry point, and the prebuilt native addon that the package's own loader
(`lib/binding.js`, `getPrebuildPath()`) selects. These hashes identify the available install used by the
run; they do not claim a byte-for-byte audit of every transitive dependency.

The generator creates only these temporary untracked files in the oracle
checkout, removes them after their run evidence is archived, and then checks
that the checkout is clean again:

```text
packages/loot-core/src/server/accounts/account-lifecycle-parity.test.ts
packages/loot-core/src/server/accounts/account-lifecycle-parity-support.ts
.actualist-account-lifecycle-oracle.json
.actualist-account-lifecycle-vitest-<invocation-id>.json
.actualist-account-lifecycle-process.json
```

The generator makes no network or server request. The overlaid harness replaces
all `#server/post` HTTP exports; only its `post` spy accepts the synthetic
GoCardless removal cases, while every other transport fails on invocation. If a
timed-out owned process group cannot be confirmed stopped, the generator reports
its process-group ID and retains these temporary paths instead of claiming safe
cleanup.

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

## Commands

From the Actualist repository root, with `ACTUALIST_PARITY_ORACLE_ROOT` set to
the oracle checkout:

```sh
# Regenerate. Writes a fresh fixture and manifest; it never replaces the committed directory.
node scripts/account-lifecycle-parity/generate.mjs \
  --evidence /absolute/path/to/new-unique-evidence-dir \
  --output /absolute/path/to/new-fixture-dir/AccountLifecycle

# Check the committed fixture without an oracle or network.
node scripts/account-lifecycle-parity/verify.mjs

# Regenerate into a scratch directory and compare with the committed fixture.
node scripts/account-lifecycle-parity/generate.mjs --check
```

`--check` exits 1 on drift, printing the first differing line of each file, and
exits 2 when `ACTUALIST_PARITY_ORACLE_ROOT` is unset. It takes no `--evidence` or
`--output`. Its scratch directory is removed only after the comparison passes.
The only normalized field is the manifest's `generatedAt`. Because the generator
refuses to replace an existing fixture directory, a regeneration written with
`--output` is copied into the committed directory after review.

The generator performs exactly one runtime command, from the oracle checkout
root. The equivalent normalized command is:

```sh
TZ=UTC \
ACTUALIST_ACCOUNT_LIFECYCLE_ORACLE_OUTPUT='/absolute/path/to/oracle/.actualist-account-lifecycle-oracle.json' \
node .yarn/releases/yarn-4.17.1.cjs workspace @actual-app/core run test:node \
  src/server/accounts/account-lifecycle-parity.test.ts \
  --bail=1 \
  --reporter=json \
  --outputFile='/absolute/path/to/oracle/.actualist-account-lifecycle-vitest-<invocation-id>.json'
```

Both output paths passed to Vitest are absolute. `TZ=UTC` pins fixture dates;
matching Actual's local-calendar close date remains an explicit B2 product gate,
not a conclusion from this fixture. The exact normalized argv, working
directory, pinned environment values, 180,000 ms execution ceiling, 5,000 ms
termination grace, tool versions, dependency identities, source hashes, harness
hashes, and generation date are written to the generated manifest. The manifest
also records `seed: null`: the harness uses no random seed.

Vitest receives `--bail=1`. The generator owns the child and its descendants as
one detached POSIX process group and durably records its PID/PGID in the
oracle checkout. At the three-minute ceiling or a catchable parent interrupt,
it sends `SIGTERM` only to that group and waits five seconds. It sends `SIGKILL`
to that same group only if the recorded child is still active, avoiding a later
signal after its PGID could be reused. It then waits one second to confirm exit.
An abrupt parent exit makes a final synchronous `SIGTERM` attempt and leaves the
ownership record for coordinator recovery. It never uses a blanket process
kill. Fixture promotion cannot begin until the child exits successfully and the
owned process group is gone.

The intended generated files are:

```text
ActualistTests/Fixtures/<fixtureDirectory>/AccountLifecycle/
  account-lifecycle-oracle.json
  account-lifecycle-manifest.json
```

The manifest uses a unique basename because Xcode flattens these synchronized
test resources into the test bundle. The earlier accepted observation fixture
was renamed byte-for-byte; its recorded generator hash still identifies the
generator used for that observation, rather than this filename-only adjustment.

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

Every case records normalized raw CRDT cells and selected relational rows. The
fixture stores synthetic IDs and amounts only. CRDT timestamps and SQLite
message IDs are deliberately omitted because they are transport ordering noise.
The oracle's raw CRDT emission order is recorded in the fixture but is not
compared; see the Actualist replay comparison below.

## Actualist replay comparison

`ActualistTests/AccountLifecycleOracleFixtureTests.swift` replays each of the 16
oracle cases Actualist supports through production `BudgetDatabase` on a fresh
SQLite file seeded from the oracle's synthetic inputs, then compares the result
with the committed observation. Scenarios live in
`AccountLifecycleOracleScenarios.swift`; comparison, normalization, and seeds
live in `AccountLifecycleOracleSupport.swift`.

Production entry point per case:

| Cases | Production entry point |
| --- | --- |
| `rename-open-history`, `rename-closed`, `rename-handler-input-boundary` | `commitAccountLifecycleMutation(.rename(...))`; the boundary case submits four names and catches the refused duplicate |
| `reopen-repeat-history` | `commitAccountLifecycleMutation(.reopen(...))`, twice |
| `close-empty-history`, `close-zero`, `close-positive-on-to-on-history`, `close-negative-on-to-on`, `close-on-to-off-hidden-category`, `close-off-to-on`, `close-off-to-off`, `close-self-transfer-refusal`, `close-split-balance`, `close-unlink-undo-boundary` | `accountLifecycleReview(request:localDay:)`, then `commitAccountLifecycleReview(_:now:localDay:transferIDs:)` only when the review has no blockers |
| `unlink-simplefin` | `makeBankSyncUnlinkMessages(accountID:builder:)`, then `commitLocalSyncMessagesAndEnqueue(_:now:)` |
| `schedule-close-reopen-eligibility` | close as above, `advanceSchedules(budgetID:today:now:)`, reopen, `advanceSchedules` |

Normalization rules. These are the only transformations applied to either side:

1. Message order is not compared. Both message lists are sorted by canonical
   form and compared as multisets, so a missing or extra message fails.
2. CRDT timestamps and message IDs are dropped. Only dataset, row, column, and
   value are kept.
3. Row IDs: the transfer legs use the injected IDs `id2` (source) and `id3`
   (destination). The production-generated UUID of the posted scheduled
   transaction is aliased to `id4`.
4. The clock is the fixed `now` and local day (2026-09-27) the oracle uses.
5. Values: production's typed serialization (`0:` null, `N:` number, `S:`
   string) is parsed into the oracle's JSON-like values. Booleans are compared
   as the oracle's `0`/`1` numbers. Numbers are compared exactly, never rounded
   or scaled.
6. Row snapshots are matched by `id`. Every field the oracle records must be
   present and equal; extra replay columns are ignored.
7. Before each forced schedule run, the local `metadata.json` day marker is
   deleted (`clearScheduleDayMarker`), matching the oracle's force-run.
8. Seed schema defaults (`isParent`, `isChild`, `tombstone`,
   `starting_balance_flag`, and `reconciled` default `0`; `cleared` defaults
   `1`) mirror Actualist's starter schema. Seeds use only the oracle's synthetic
   names and values.

Not replayed:

- `undoMessages` and `afterUndo`. History undo is not offered for account
  actions (`Actualist/LocalFirst/ActionLog/BudgetActionUndo.swift:366-367`).
- `remoteCalls`. They record the oracle's mocked transport and are kept only in
  the fixture; Actualist's replay has no transport seam.

Known divergences. The replay matches the oracle exactly. Message arrays are
compared as multisets, so any missing or extra message, or any state mismatch,
fails. The one intended difference is `OP-22`: rename trims its input and skips
an unchanged name, so the `rename-handler-input-boundary` case lacks the oracle's
messages for those submissions; that single check is wrapped in `withKnownIssue`.

Oracle-only cases. These six are listed in the manifest's `oracleOnly` field
with a reason each. They are not registered as divergences:

| Case | Reason |
| --- | --- |
| `forced-delete-simple` | Actualist has no forced delete for an account that still has transactions; product decision open. |
| `forced-delete-split-transfer-graph` | Actualist has no forced delete for an account that still has transactions; product decision open. |
| `unlink-gocardless-last-reference` | Actualist unlinks SimpleFIN accounts only; GoCardless is not supported. |
| `unlink-gocardless-shared-bank` | Actualist unlinks SimpleFIN accounts only; GoCardless is not supported. |
| `unlink-gocardless-without-token` | Actualist unlinks SimpleFIN accounts only; GoCardless is not supported. |
| `unlink-gocardless-remote-failure` | Actualist unlinks SimpleFIN accounts only; GoCardless is not supported. |

The test asserts that the replayed cases and the oracle-only list partition all
22 oracle case IDs, and that the committed manifest's provenance matches the
pinned Actual.

## Stop conditions and correction budget

The generator stops without promoting fixtures if any of these occurs:

- the commit, tag, package version, Node major, or Yarn version differs;
- dependency setup evidence or the resolved native SQLite 13.0.3 binary is
  absent;
- pinned source or harness files are missing;
- the oracle checkout is not at the pinned commit and tag, or has any
  uncommitted or untracked change (checked before the run and after cleanup);
- an overlay/output path already exists and is not owned by this invocation;
- the explicit evidence destination is absent, overlaps the fixture output, is
  inside the oracle checkout, or already exists;
- Vitest exits nonzero or its JSON report does not describe a passing run;
- the three-minute execution ceiling is reached; if process-group exit cannot
  be confirmed, temporary files are retained for manual recovery;
- the raw output schema, case IDs, case count, or synthetic-data declaration
  differs from the reviewed contract;
- a generated file fails the reviewed manifest invariants or a recorded SHA-256
  does not match;
- run evidence cannot be archived before cleanup and fixture promotion.

The earlier single-use evidence directories are historical; each generation now
needs a fresh `--evidence` path. The 2026-10-10 re-pin to v26.10.0 regenerated
the fixture with the same 22 cases and byte-identical oracle JSON; only the
manifest's provenance fields changed. Do not retry unchanged code, broaden to
the upstream suite, or count source inspection as oracle proof.
