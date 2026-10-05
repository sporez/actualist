# Transaction query and saved-filter parity oracle

This tooling-only overlay answers transaction research gates Q1–Q3 against the
real pinned Actual Budget v26.9.0 filter handlers, condition-to-AQL compiler, and
transaction query executor. It does not implement Actualist production behavior.

The runner copies the two TypeScript harness files into an **isolated writable,
dependency-ready clone** of Actual, executes one bounded Vitest selection, writes
evidence outside both Actual checkouts, and removes only its owned overlay files.
The shared pinned source is provenance input only and is never overlaid.

## Predetermined matrix

The matrix has exactly **46 stable case identities**:

- **Q1 — 33 authored conditions:** date `is`, `isapprox`, `gt`, `gte`, `lt`,
  `lte`, month, and year; every authored account operator; every authored payee
  operator plus null; every authored category operator plus uncategorized/null.
  The synthetic rows include inclusive/exclusive date boundaries, mapped payee
  and category IDs, multiple-ID operands, negation, on/off-budget accounts,
  split rows, context rows, and a tombstone.
- **Q3 — 5 family comparisons:** date, account, payee, category, and free-text
  child matching. Every case executes both `splits: all` and `splits: grouped`,
  recording physical matches separately from selected roots and attached family
  context.
- **Q2 — 8 handler equivalence cases:** exact and reordered conditions,
  duplicate-condition multiplicity, number versus string values, options key
  order, one-condition `and` versus `or`, multi-condition join control, and a
  duplicate live name.

Each case is written as `pending`, then durably updated to `running` and finally
`passed` or `failed`. A hard interruption can therefore leave the exact last
case visible without inventing an observation for it. The result also includes
the complete predetermined identity list, normalized CRDT messages, raw saved
filter/domain rows, compiled AQL filters, physical query rows, grouped rows, and
explicit context IDs.

`sourcePrediction` is pre-run analysis from the pinned source. It is deliberately
separate from `assertions` and from runtime `observed` evidence. A green process
means all 46 cases ran and their independent assertions passed; it does not turn
the prediction field into an observation or authorize C2 production work.

## Ownership and prerequisites

Only the sprint coordinator may execute this oracle. The writable checkout must
be a disposable isolated clone under that coordinator's sole ownership. It must
not be the shared source checkout or a worktree sharing the source checkout's Git
common directory.

Required inputs:

- read-only source and writable clone both at Actual tag `v26.9.0`, commit
  `59fe126f637d858c061e1eeedbef5436c8f2225a`;
- `@actual-app/core` version `26.9.0`;
- Node `24.21.x`, repository Yarn `4.17.1`, and installed Vitest;
- existing `node_modules/.yarn-state.yml` and `better-sqlite3` `12.11.1` native
  binary in the writable clone.

The runner never installs dependencies, contacts a server, or reads credentials.
The normal loot-core node-test setup supplies the in-memory SQLite database and
normal network mocks. All accounts, payees, categories, mappings, filters, and
transactions are synthetic.

The pinned Electron filesystem adapter requires `ACTUAL_DATA_DIR`. The runner
does not inherit or infer it: every run creates the unique owned directory
`<evidence>/<run-label>/actual-data`, marks its ownership, and passes that exact
path explicitly to the child.

## Exact coordinator command

Prepare a distinct dependency-ready clone first, then run:

```sh
scripts/transaction-query-parity/run-oracle.sh \
  --source-checkout "$ACTUALIST_PARITY_ORACLE_ROOT" \
  --actual-checkout /absolute/path/to/isolated-dependency-ready-actual \
  --evidence "$ACTUALIST_ROOT/.artifacts/parity-sprint-20260927/transaction-query-parity" \
  --run-label investigation
```

The runner records the exact underlying command in
`<evidence>/investigation/exact-command.txt`. Its only executable oracle
selection is:

```text
@actual-app/core Vitest --run \
  src/server/transactions/transaction-query-parity.test.ts \
  --reporter=verbose --bail=1
```

The outer wall-clock ceiling is **180 seconds** and the harness test timeout is
170 seconds. The runner starts the child in a new process group, durably records
the supervisor PID and child process-group ID, forwards interruption only to
those owned processes, waits 10 seconds after `TERM`, and uses `KILL` only for
that still-live owned group. It retains the overlay if termination cannot be
confirmed rather than deleting files under a live process. The owned
`actual-data` directory is removed only after process termination and ownership
are both confirmed. Ordinary assertion/runtime failures retain their JSON,
logs, provenance, command, and exit evidence while removing only the confirmed
owned scratch directory. Unconfirmed termination or ownership retains the
scratch directory and records why.

Run-label directories are single-use (`investigation` or `post-correction`),
including a preflight failure. The evidence
root must contain a `.artifacts` path segment and must be outside the source and
writable Actual checkouts. It may be inside the Actualist checkout that owns the
script. The runner also rejects wrong refs,
shared Git identity, dirty tracked files, missing dependencies, occupied overlay
targets, and an already-spent run label.

## Evidence layout

Each run directory contains:

- `oracle-result.json`: durable per-case gate input, prediction, assertions,
  observed output, and state;
- `oracle.log`, `oracle.exit`, and `outcome.env`;
- `provenance.env`: tool paths/versions and SHA-256 hashes for harness, pinned
  source owners, dependency state, and native SQLite binding;
- `exact-command.txt`;
- `oracle-source/`: the exact harness and runner sources used;
- `actual-data-cleanup.env`: owned scratch path, termination confirmation, and
  whether cleanup removed or retained it;
- `source-git-status.txt`, `pre-overlay-git-status.txt`, and
  `post-cleanup-git-status.txt`.

Interpret a missing result, `completed: false`, any pending/running case, a
nonzero `oracle.exit`, or post-cleanup tracked changes as incomplete evidence.
Do not replace a failed observation with the source prediction.

## Pinned source owners

The harness records hashes and line references for:

- `packages/loot-core/src/server/filters/app.ts` — create/update name and
  condition equivalence;
- `packages/loot-core/src/server/rules/condition.ts` and
  `transactions/transaction-rules.ts` — validation, serialization, null special
  cases, and AQL conversion;
- `packages/loot-core/src/server/aql/schema/executors.ts` — physical versus
  grouped split execution and `_unmatched` context;
- `packages/desktop-client/src/components/filters/FiltersMenu.tsx` and
  `SavedFilterMenuButton.tsx` — authored condition and handler payload shapes;
- `packages/desktop-client/src/queries/index.ts` — free-text transaction query
  shape;
- the transaction-filter schema migration and model types.

No generated fixture is promoted automatically. The coordinator must review the
complete result and make the Q1/Q2/Q3 product decisions before using it to change
contracts or begin C2.
