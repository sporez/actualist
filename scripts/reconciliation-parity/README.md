# Reconciliation parity fixtures

`ActualistTests/Fixtures/ActualCore26_10_0/Reconciliation/` holds the outputs of
Actual's pinned reconciliation code, run under vitest in the oracle checkout.
`reconciliation-manifest.json` records the pinned release, source and helper
hashes, the fixture hash, and the case count. `reconciliation-contract.json`
holds twelve reviewed cases: `cleared-balance`, `finish`,
`adjustment-rule-projection`, `adjustment-rule-delete`, `lock`, `unlock`,
`done-nonzero-difference`, `adjustment-rule-clears-notes`, and four real-row
unlock cases: `unlock-split-member`, `unlock-split-parent`,
`unlock-split-member-unreconciled-parent` and `unlock-simple-row`.

Regenerate against a clean checkout of the pinned Actual tag (with
`yarn install` done):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/reconciliation-parity/generate.mjs
```

Check that the committed fixture and manifest match a fresh generation (needs
the oracle; exits 2 without it):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/reconciliation-parity/generate.mjs --check
```

Verify the committed manifest and fixture without an oracle:

```sh
node scripts/reconciliation-parity/verify.mjs
```

Consumer suites: `ActualCoreReconciliationOracleFixtureTests` and
`ReconciliationOracleReplayTests`, which replays each replayed case through the
production `BudgetDatabase` writes (see Swift replay below).

## How each case is produced

Except for the four `unlock-*` cases below, the desktop-client functions in
`reconciliation.ts` run under vitest with `@actual-app/core` and the AQL and
send layers mocked. Each case's `input` is
the scripted data the mocks returned, so a consumer can seed an equivalent
database. The `value` is what the oracle did with that input.

Two evidence levels exist, and the fixture labels which is which:

- **Executed.** The mocked functions ran and their calls were recorded.
- **Source-guard, not executed.** `done-nonzero-difference` records
  `lastReconciledStamp` with `evidence: "source-guard, not executed"`. The
  stamp lives in `onDoneReconciling` on the unexported `AccountInternal` class
  in `Account.tsx`, so it cannot be called from the generator. The generator
  checks that the source still stamps `last_reconciled` unconditionally after
  `finishReconciliation`, and fails if it does not.

`adjustment-rule-clears-notes` runs in two stages:

1. Core stage. A vitest runner in `loot-core` inserts a rule (condition
   `contains notes "Reconciliation"`, action `set notes null`), reloads the
   rules, realizes the adjustment, and calls `runRules`. This is Actual's real
   rules engine. Its output is recorded as `ruleEngineInput` and
   `ruleEngineOutput`, with ids and dates normalized.
2. Desktop stage. The `rules-run` mock asserts that the payload equals the
   core input (ids and dates normalized). If not, the test fails. The mock then
   returns the core output with the realized id reattached.

`ruleEngineOutput.notes` is `null`, so the rule clears notes. The oracle keeps
that `null`. It does not restore the default note. Swift restores the default
note (`BudgetDatabase+Reconciliation.swift`). This is registered as OP-17.

## Real-row unlock cases

The four `unlock-*` cases do not script the query. They run in the loot-core
stage on real rows in loot-core's in-memory database, reproducing the call
sequence of the desktop `unlockTransaction`
(`packages/desktop-client/src/accounts/reconciliation.ts`, which cannot be
imported from loot-core):

1. Seed the rows with upstream's `db.insertAccount` and `db.insertTransaction`.
2. Run `q('transactions').filter({ id }).select('*').options({ splits: 'grouped' })`
   through the real `query` handler, the handler the client's `send('query', …)`
   reaches (upstream code).
3. `ungroupTransactions`, then `updateTransaction(transactions, { ...transaction,
   reconciled: false })` (upstream code, `shared/transactions.ts`).
4. Send `{ updated: diff.updated }` to the real `transactions-batch-update`
   handler (upstream code) and read every row's `reconciled` back from SQLite.

Harness glue is the seed data (step 1) and the code that calls steps 2–4 in the
desktop function's order, with the find-by-id early return, in place of its
`send` transport. The desktop function itself is not run.

Each case records `input.rows` (the seeded rows, grouped for seeding),
`input.groupedQueryResult` (what the real query returned), `value` (the
`updated` batch as sent, unprojected) and `readback` (`before`, `after` and the
`changed` ids of every row's `reconciled`). The seeded family is a parent
(-5000) with children `child-a` (-2000) and `child-b` (-3000).

| Case | Unlocks | Query returned | Sent | `reconciled` changed |
| --- | --- | --- | --- | --- |
| `unlock-split-member` | `child-a`, reconciled parent | the whole family | nothing | none |
| `unlock-split-parent` | `parent` | the whole family | parent and both children | all three |
| `unlock-split-member-unreconciled-parent` | `child-a`, unreconciled parent | the whole family | both children | both children |
| `unlock-simple-row` | a simple row | that row | that row | that row |

So in Actual, unlocking a child of a reconciled parent is a no-op: the grouped
query returns the family, but `makeChild` copies the parent's `reconciled`, so
the update carries no change. Unlocking the parent unlocks the family. Swift
unlocks each reconciled family row and writes `reconciled = false` to all three
(`BudgetDatabase+Reconciliation.swift`). This is registered as OP-19 and is
intended (user decision 2026-10-11): unlocking any part of a split unlocks the
family.

## Oracle-only cases

These cases are listed in `reconciliation-manifest.json` with a reason. Their
replay test does not run them.

- `adjustment-rule-projection`: the expected output comes from a scripted
  rules-run outcome. No production rules seed reproduces it without a seam.
  Real-rules coverage is `adjustment-rule-clears-notes`, and the Phase 4 rules
  harness covers the rest.
- `done-nonzero-difference`: source-guard only. The oracle client stamp rule is
  not executed.

## Null-cell rule

Expected row cells are compared only where a write can change the seeded row. An
expected `null` cell is dropped when the seeded row already holds null or has no
value for that column, because that write changes nothing and no outbox message
records it. A null written over a non-null seeded value stays required. The rule
applies in `ReconciliationOracleReplaySupport.swift` (`expectedRowCells`) to
`lock`, `unlock` and the `unlock-*` cases.

## Swift replay

`ReconciliationOracleReplayTests` replays each replayed case through
`ReconciliationOracleReplay` and compares the whole output, with these Swift-side
adjustments. None of them changes an amount.

- Row arrays are compared sorted by `id` (`OracleValue.sortedByID`), because
  Actual leaves row order unspecified.
- The `query` key of `cleared-balance` and the `realized` key of
  `adjustment-rule-clears-notes` are dropped from the expected value. The replay
  does not produce them: `query` is the AQL the oracle built, and `realized` is the
  pre-adjustment row the oracle's rule stage recorded.
- The null-cell rule above applies to the three row-writing cases.

`cleared-balance` is a scripted sum: the mock computes it from `scriptedRows`
with the same filter, so the value checks the query's shape and filter, not the
SQL. The recorded `query` is the AQL state the oracle built.

## Normalization rules

The generator's `selected()` helper normalizes what depends on runtime identity
or the current day. Nothing else is changed.

| Field | Rule |
| --- | --- |
| `id` | `child-a` and `child-b` are kept. Any other non-null id becomes `<generated>`. Null stays null. |
| `parentID` | Any non-null value becomes `<generated>`. This is a uuid-derived id, like `id`. |
| `date` | Becomes `<current-day>` by default. Exception: `added` and `deleted` in `adjustment-rule-projection` keep their raw date (`2026-09-01`), because the rule sets that literal value. |
| `amount` | Never normalized. Amounts are integer minor units. |

`adjustment-rule-clears-notes` normalizes `id`, `date`, and `sort_order` in its
core-stage input and output. `sort_order` is `Date.now()` and is not recorded.

## Entities

`entities` lists the stable refs (`checking`, `savings`, `bank`, `fees`) with
scripted labels. The refs are the literal ids the oracle receives. The names are
for seeding a database; the oracle does not produce them.

## Manifest

`sourceFiles` holds the nine reviewed contract sources and stays at nine (the
Swift consumer asserts this count). `evidenceSourceFiles` holds the six sources
behind evidence that is not in the contract list: `Account.tsx` (the Done stamp
site), the loot-core rules files (`transaction-rules.ts`, `rule.ts`,
`action.ts`) and the handlers behind the real unlock cases (`server/main.ts`,
`server/transactions/app.ts`).
