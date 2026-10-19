# Hold parity harness

`generate.mjs` runs Actual's pinned hold-for-next-month handlers against a
synthetic SQLite budget and records what each step did. It writes
`hold-contract.json` and `hold-manifest.json` into
`ActualistTests/Fixtures/ActualCore26_10_0/Holds/`.

`verify.mjs` checks the committed fixture without the oracle: manifest pin,
generator and helper hashes, source hash list, fixture hash, schema, and the
16 reviewed case IDs.

Status: the fixture is committed and verified against Actual v26.10.0.
`ActualistTests/HoldOracleReplayTests.swift` replays it through the production
hold path (see "Swift replay"). `config/parity/domains.json` lists `holds` as
`covered`, with `HoldOracleReplayTests` as its oracle suite.

## Commands

The generator runs Actual's test runner inside the oracle checkout. It writes a
temporary runner file there and removes it afterwards. Point it at a scratch
clone of the pinned tag with `yarn install` done, not at a checkout you need to
keep clean.

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/hold-parity/generate.mjs
ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/hold-parity/generate.mjs --check
node scripts/hold-parity/verify.mjs
```

`--check` regenerates into a temporary directory and compares it with the
committed files. Without the oracle it exits 2. `verify.mjs` needs no oracle.
Any edit to `generate.mjs` changes its hash, so regenerate and re-run `--check`
and `verify.mjs`.

## Scope

- Synthetic data only. Account `checking`; categories `salary` and `groceries`;
  months `2026-06` through `2027-02`, contiguous so the From Last Month chain
  has no gap.
- Amounts are integer minor units.
- Actual core handlers run offline. There is no live server roundtrip.
- Each case records its setup inputs, the handler calls, the CRDT cells Actual
  wrote, and every month's sheet state after each step. There is no SQLite
  baseline; the setup inputs rebuild the starting state.

## Cases

"UI" means the budget menu or hold form sends this sequence. The menu offers
Hold only when To Budget is positive and no automatic hold is active, and offers
Reset only when a manual hold is set (`ToBudgetMenu.tsx`). Direct cases record
what the handler does when called outside those gates.

| # | Case | UI | Outcome recorded |
| --- | --- | --- | --- |
| 1 | `hold-partial-then-repeat-adds` | yes | 40000 then 20000 accumulate to a manual hold of 60000; July To Budget 90000 |
| 2 | `hold-full-available-to-budget` | yes | Holding 150000 leaves July To Budget at 0 |
| 3 | `hold-more-than-available-clamps` | yes | A 200000 request holds 150000 |
| 4 | `hold-repeat-clamps-to-remaining-to-budget` | yes | 100000 then 200000 hold 150000 in total |
| 5 | `release-hold-restores-to-budget` | yes | Hold 40000, reset: July To Budget back to 150000 |
| 6 | `release-without-stored-hold-row-writes-zero-hold` | direct | A reset with no stored row writes `zero_budget_months.buffered = 0` |
| 7 | `hold-after-release-starts-from-zero` | yes | Hold, reset, hold 20000: manual hold 20000 |
| 8 | `hold-rolls-into-next-month-available` | yes | July hold 40000; August From Last Month and To Budget 150000 |
| 9 | `hold-across-year-boundary-rolls-into-january` | yes | December hold 40000 returns to January From Last Month 150000 |
| 10 | `hold-noop-when-to-budget-is-zero` | direct | Hold returns `false`, writes no cells |
| 11 | `hold-noop-when-to-budget-is-negative` | direct | Hold returns `false`, writes no cells; To Budget stays −50000 |
| 12 | `release-manual-hold-reveals-automatic-income-hold` | yes | Reset of a 20000 manual hold reveals a 100000 automatic hold; the following income-carryover reset clears it; August shows the 25000 automatic hold |
| 13 | `hold-handler-replaces-automatic-income-hold-when-called-directly` | direct | Hold returns `true`: manual 30000 replaces automatic 100000; To Budget 120000 |
| 14 | `hold-in-tracking-budget-is-not-offered` | direct | Hold returns `false`; the income-carryover reset writes `reflect_budgets`, not `zero_budgets` |
| 15 | `hold-in-future-month-creates-stored-row` | yes | A hold of 1000 in 2027-01 creates the `zero_budget_months` row `2027-01` |
| 16 | `actualist-compatible-crdt-replays-into-actual-peer` | replay | Actualist-shaped cells (manual hold 45000 and an income-carryover reset) apply to Actual; July To Budget 105000 |

Case 16 is the only case built from Actualist-shaped cells, not from Actual's
own handler output. Its timestamps are fixed inputs, not Actual output.

## Normalization

- Timestamps are omitted from every recorded cell. Actual's timestamp is a
  wall-clock value plus a random client ID, so it is not stable. Dataset, row,
  column, `serializedValue`, and per-step order are kept exactly.
- `serializedValue` uses Actual's `N:<integer>` and `S:<text>` form. Booleans
  are stored as numbers; `carryover` false appears as `N:0`.
- State values are integer minor units. A `null` state field means Actual
  created no sheet cell for that month, for example `carryover-salary` in a
  month with no carryover row. The generator requires the eight core hold
  fields (`toBudget`, `availableFunds`, `fromLastMonth`, `totalIncome`,
  `totalBudgeted`, `manualHeldAmount`, `automaticHeldAmount`, `heldAmount`) to
  be non-null for envelope budgets. The check is skipped for tracking budgets,
  where the hold sheet cells are absent.
- `returned` is the handler's return value. Every recorded step completed
  without an error.

## Swift replay

`ActualistTests/HoldOracleReplayTests.swift` (suite `HoldOracleReplayTests`,
case `replaysHoldCase`) replays each case through the production path that
`LocalFirstActualStore.applyBudgetHoldAndRefresh` runs:
`BudgetDatabase.budgetHoldReview(month:)`, then
`budgetHoldMessages(command:review:builder:)`, then
`commitLocalSyncMessagesAndEnqueue`. The support file
`ActualistTests/HoldOracleReplaySupport.swift` builds a synthetic SQLite budget
from each case's `setup`, with the rows `generate.mjs` seeds. It does not use
`makeHoldFixture`, which seeds different rows.

Replayed actions:

- A `reset-income-carryover` immediately followed by `hold-for-next-month` is
  one hold action with that hold's month and amount. The cells of both steps
  are compared as one set, so the oracle's order does not matter.
- A standalone `reset-income-carryover` or `reset-hold` is a reset.
- Case 16's apply-messages step is a hold of the amount in its buffered cell.
- A standalone `hold-for-next-month` is not replayed. Only case 13 has one, and
  it is oracle-only.

Compared per case, in one flat comparison:

- `before.<month>.<field>`: each month's state before any action.
- `action<i>.outcome`: the hold's committed flag, when the oracle recorded one.
- `action<i>.cell.<dataset>/<row>/<column>`: the cells the action committed.
  Timestamps are omitted. Values for one key are sorted and joined with `|`.
- `action<i>.<month>.<field>`: each month's state after the action.

State fields: `toBudget`, `fromLastMonth`, `totalIncome`, `totalBudgeted`,
`manualHeldAmount`, `automaticHeldAmount`, `heldAmount`. Months run from
2026-06 through 2027-02. `availableFunds`, the grocery fields, and
`salaryCarryover` are not compared.

Replay normalization:

- `totalBudgeted` is negated on the Swift side for every comparison, to match
  Actual's sheet sign. Every other amount is compared as stored.
- A refused hold is a `LocalFirstError` thrown by `budgetHoldMessages`. It is
  outcome `false` with no cells. Other errors propagate. A reset that the
  oracle recorded before a refused hold (cases 10 and 11) is not replayed, so
  its cells are excluded. Its effect is checked through the state fields.

Oracle-only cases (`oracleOnly` in `generate.mjs`), not replayed:

- Case 13: neither UI reaches it. Actualist refuses the direct call, while
  Actual replaces the automatic hold. Not registered as a finding because the
  UI never sends it.
- Case 14: neither UI reaches it. Actualist refuses the tracking budget as
  unsupported, while Actual writes `reflect_budgets`. Not registered for the
  same reason.

Known divergences from Actual, each keyed to its own case in the test. The
known-issue marker wraps only the divergent check, and only when the fixture
expects the divergent shape. A fixed divergence then fails as a stale marker.

- OP-20 (`config/parity/known-divergences.json`): the oracle writes a new
  income-carryover row's `month` identity as text (`S:202607`), and Actualist
  writes a number (`N:202607`). Under SQLite integer affinity the observable
  state is the same. Nine cases: 1, 2, 3, 4, 5, 7, 8, 9, and 15.
- OP-21: API-level only; the menu never sends this reset. A reset-hold with no
  stored hold writes the income-carryover rows, and the oracle writes
  `zero_budget_months.buffered = 0`. Case 6. The fixture marks it
  `uiReachable: false`, but it is still registered because Actualist does not
  refuse the call.

Actualist's `N:` month identity in case 16 matches its own writes, so case 16
is not OP-20.
