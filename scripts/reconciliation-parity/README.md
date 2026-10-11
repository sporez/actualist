# Reconciliation parity fixtures

`ActualistTests/Fixtures/ActualCore26_10_0/Reconciliation/` holds the outputs of
Actual's pinned reconciliation code, run under vitest in the oracle checkout.
`reconciliation-manifest.json` records the pinned release, source and helper
hashes, the fixture hash, and the case count. `reconciliation-contract.json`
holds nine reviewed cases: `cleared-balance`, `finish`,
`adjustment-rule-projection`, `adjustment-rule-delete`, `lock`, `unlock`,
`done-nonzero-difference`, `adjustment-rule-clears-notes`, and
`unlock-split-member`.

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

The desktop-client functions in `reconciliation.ts` run under vitest with
`@actual-app/core` and the AQL and send layers mocked. Each case's `input` is
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

`unlock-split-member` uses a scripted grouped parent with two reconciled
children, and the scripted grouped query is assumed to return the full family
for a child id. The `value` is the batch the oracle sent, unprojected: no field
is dropped or defaulted. That batch records no `reconciled` write for the
parent or either child. `makeChild` takes `reconciled` from the parent rather
than from the child data, so unlocking `child-a` through the family path never
emits `reconciled: false`. Swift unlocks each reconciled family row and writes
`reconciled = false` to all three (`BudgetDatabase+Reconciliation.swift`). This
is registered as OP-19. Whether unlocking a split member should unlock its
family is a product decision. The evidence rests on the scripted query shape,
so a real query that returns the family differently could change the result.

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
`lock`, `unlock`, and `unlock-split-member`.

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
Swift consumer asserts this count). `evidenceSourceFiles` holds the four sources
behind evidence that is not in the contract list: `Account.tsx` (the Done stamp
site) and the loot-core rules files (`transaction-rules.ts`, `rule.ts`,
`action.ts`).
