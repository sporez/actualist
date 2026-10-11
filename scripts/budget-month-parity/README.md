# Budget-month parity harness

Oracle for envelope month math and budget writes: To Budget, carry-in, carryover,
assign, move, transfer, cover, and hold. Actual's `budget/*` handlers run
against a synthetic in-memory budget, and the CRDT cells and sheet state they
produce are recorded as the expected values for the Swift replay.

Domain: `budget-month` in `config/parity/domains.json`. This harness does not
edit that file; see "Domain registration" below.

## Commands

```sh
# Regenerate the fixture. Needs a clean oracle checkout of the pinned release.
ACTUALIST_PARITY_ORACLE_ROOT=<clean-actual-v26.10.0> node scripts/budget-month-parity/generate.mjs

# Regenerate into a temp directory and diff against the committed fixture (run twice).
ACTUALIST_PARITY_ORACLE_ROOT=<clean-actual-v26.10.0> node scripts/budget-month-parity/generate.mjs --check

# Check the committed fixture without an oracle: pins, hashes, plan identity,
# step and setup equality, state shape, and the author's expectations.
node scripts/budget-month-parity/verify.mjs
```

The oracle comes only from `ACTUALIST_PARITY_ORACLE_ROOT`, through
`pinnedOracleRoot()` and `assertPinnedOracle()`. The generator checks the pinned
package version and the hashes of every source file it reads before it runs.
It checks the oracle again after the run. A failed expectation writes the
synthetic records to the system temp directory and writes no fixture.

Outputs in `ActualistTests/Fixtures/ActualCore26_10_0/BudgetMonth/`:

- `budget-month-contract.json`: one record per case, in plan order.
- `budget-month-manifest.json`: pins, generator and helper hashes, seed, `today`,
  case counts, the fixture hash, `caseIDs`, and oracle-only entries.

## Files

- `cases.mjs`: the pure plan. Named cases, seeded generated cases, and the
  expectation checker. No oracle needed. `verify.mjs` rebuilds the plan from it.
- `oracle-runner.template`: a vitest file that the generator copies into the
  oracle checkout and removes afterwards. It runs each case through
  `runHandler(handlers[...])`.
- `generate.mjs`: pins the source hashes, runs the runner, checks expectations,
  and writes the contract and manifest. `--check` compares with the committed fixture.
- `verify.mjs`: the no-oracle verifier.

## Clock

The harness fixes `today` at `2026-10-15`. Upstream `monthUtils.currentMonth()`
returns `global.currentMonth`, or `2017-01` when `IS_TESTING` is set, and it
does not read the clock. The runner therefore sets `global.currentMonth` from
`today`, and it also fakes `Date`. Without the hook, the average and carry-in
windows start in 2016-12.

## Seed and cases

- Seed `20261011`. A `mulberry32` stream derives one seed per generated case.
  Each case's seed is recorded.
- 26 named cases, 6 of them oracle-only (below). 60 generated cases.
- Named cases share the sheet window 2026-06..2027-02. The leap-day case uses
  2028-01..2028-03. Their setup is listed in `cases.mjs`.
- Generated cases use two windows, each starting two months before the first
  step month. Window start 2026-11 covers 2026-09..2027-11 and crosses year end.
  Window start 2027-11 covers 2027-09..2028-11 and includes 2028-02-29.
  Each case has 4 to 6 expense categories, optional hidden categories and a
  hidden group, uncategorized and off-budget (`savings`) transactions,
  pre-seeded budgets with carryover flags, buffers, and 4 to 9 steps.
- Steps: assign, move, transfer-available, cover, set-carryover, hold,
  reset-hold, and reset-income-carryover.

Named cases carry hand-derived expectations. They check that the setup was read
as intended. They are not stored results. Generated cases carry none, but any
step error fails generation.

Current numbers (generation time, not required totals): 86 cases, 460 steps,
0 step errors. 50 steps write no cells: no-op moves and covers, refused holds,
and similar. The fixture is 5.6 MB. Generation takes about 4 seconds, including vitest.

## Rollover all overspending

Upstream v26.10.0 has no bulk "roll over all overspending" handler. The UI sends
one `budget/set-carryover` per category (`envelope/BalanceMenu.tsx`,
`desktop-client/src/budget/mutations.ts`). Actualist's
`allExpenseCategoryCarryoverMessages` (`BudgetDatabase+BudgetWrites.swift`) is
therefore checked against the sum of per-category toggles. The named case
`rollover-all-expense-equals-per-category-toggles` records those toggles. The
Swift replay must confirm that the bulk action writes the same per-category
carryover cells, for the same categories and starting month.

## Normalization

- Message timestamps and message IDs are dropped. Timestamps include a random
  client ID, and IDs depend on insertion order.
- Each step's cells are sorted by dataset, row, and column. Writes to the same
  cell keep their order, so the last write wins on replay.
- Cell values keep Actual's serialized form, such as `N:-30000` and `S:groceries`.
- Sheet state is read after each step, for the months at or after the step's
  `affectedFrom`. `expected` is read after the last step for every sheet month.
- Missing cells are recorded as `null`. A non-integer money value fails the run.
- Amounts are integer minor units, USD.
- Cell and month-state keys are fixed by the runner, not by upstream output order.

## Upstream fields

Recorded per category (envelope): `budget-<id>`, `sum-amount-<id>`,
`leftover-<id>`, `leftover-pos-<id>`, `carryover-<id>`.
Recorded for the month (envelope): `to-budget`, `available-funds`,
`from-last-month`, `total-income`, `total-budgeted`, `total-spent`,
`total-leftover`, `last-month-overspent`, `buffered`, `buffered-auto`,
`buffered-selected`.
Tracking adds `spent-with-carryover-<id>`, `total-saved`, `real-saved`, and
`total-budget-income`, and drops `leftover-pos-<id>`.

Upstream fields with no Actualist counterpart in the current model:
`leftover-pos-<id>` (an internal envelope cell), `buffered` and `buffered-auto`
as separate values (Actualist's automatic income hold is described in
`BudgetDatabase+EnvelopeHolds.swift`), and `spent-with-carryover-<id>`.

## Oracle-only actions

Actualist has no handler for these. Each is recorded for the Swift side to
decide whether to implement:

- `budget/copy-previous-month`
- `budget/set-zero`
- `budget/set-3month-avg`
- `budget/cover-overbudgeted`
- `budget/copy-until-year-end`
- `budget/transfer-category` on a tracking budget (`tracking-move-money-oracle-only`).
  Actualist refuses this in `BudgetActionEligibility`. Upstream still writes it
  to `reflect_budgets`, so the case records only what Actual writes.

## Swift replay notes

Entry point: `BudgetMonthOracleReplay.replay` (`ActualistTests/BudgetMonthOracleReplaySupport.swift`).
Each action goes through the production write seam for its handler, and reads
go through `BudgetDatabase.fetchBudgetSnapshot`. Tests are in
`BudgetMonthOracleReplayTests.swift`; the partition test checks that replayed
cases and oracle-only cases together cover all 86 manifest cases.

Write seams: `budget-amount` through `assignCategoryBudgetMessages`; move through
`moveMoneyMessages`; hold through `BudgetDatabase+HoldWrites`; reset-hold and
income-carryover reset through the same file; set-carryover through
`LocalFirstActualStore+Mutations`.

- Cover without an amount: the replay reads the `to` category's negative balance
  through `fetchBudgetMonth` before the write, then moves that amount. This mirrors
  `OverspentCoverSelectionWorkflow.coverCommands` (`OverspentCoverSelectionWorkflow.swift:72-84`),
  which has no source clamp. This is a replay-side choice; the oracle recorded the
  amount it was given.
- Transfer categories: the literal `to-budget` maps to no category. `move(_:from:to:)`
  takes an optional category for this reason.
- Set-carryover horizon: the replay passes `fixtureNow` (2026-10-15).
  Production uses the current date plus 12 months (`categoryCarryoverHorizonMonth`).
  This is OP-33.
- Refusals: ten holds are refused on both sides with "no money is available to
  hold". These are shared refusals, not divergences. The replay's eleventh refusal
  is generated-034-2027-11's hold, which is refused while the automatic income-carryover
  hold is active; the oracle commits it. That is OP-34.

Normalization:

- Envelope `total-budgeted` is negated to match the sheet (`envelope.ts:150`).
  Tracking's is not (`tracking.ts:97`), so the replay does not negate tracking.
- Compared summary fields: `to-budget`, `available-funds`, `from-last-month`,
  `buffered-selected`, `total-income`, `total-budgeted`, `total-spent`,
  `total-leftover`, `total-budget-income`, `total-saved`, `real-saved`, and
  `last-month-overspent`. The last is compared as OP-35: Actualist exposes 0 for it,
  and the oracle reports last month's overspend as a negative number.
- Compared category fields: `budgeted`, `spent`, `leftover`, `carryover`.
- Not compared (upstream-only, see Upstream fields): summary `buffered`,
  `buffered-auto`; category `leftover-pos`, `spent-with-carryover`.
- Each step compares the committed cells as a set. A mismatch path names the
  case, the step (`before.`, `step<n>.`, or `final.`), the month, and the field.

Seam gap: a standalone `reset-income-carryover` whose month has a stored manual hold
clears that hold in production, and the oracle does not. The replay stops before that
step, compares only the prefix, and skips the final states. Five cases stop this way:
`generated-017-2026-11` (step 8), `generated-045-2026-11` (step 1), and
`generated-023-2026-11`, `generated-046-2027-11`, and `generated-048-2027-11`
(step 0). Each case's attachment records its stop as a `SEAM` line. These five cases
are partially replayed. The production reset is reachable only through the hold review.

Consistency checks (`BudgetMonthConsistency.swift`): Actualist's own month read is
checked against Actualist's own category values, never against the oracle. Envelope
months only; tracking months have no To Budget.

- `available-funds` = total income + from last month.
- `from-last-month` = previous To Budget + previous hold.
- `total-budgeted`, `total-spent`, `total-leftover`, `total-income` = sums over
  their category groups.
- `to-budget` = total income + from last month + overspent carried from last month
  - total budgeted - hold.
- Each category leftover = budgeted + spent + last month's carry-in.
- Not checked, because Actualist does not expose the inputs: the manual/automatic
  split of the hold (`buffered`, `buffered-auto`; only the effective hold is exposed),
  and the account balances and uncategorized activity that produce `to-budget`.
- Not checked, because it is not one of Actualist's identities: the exposed
  `lastMonthOverspent`. To Budget takes last month's overspend from `envelopeCarryIn`,
  and no screen or widget reads the field. It is compared with the oracle instead (OP-35).

These checks are strict and are never wrapped in `withKnownIssue`. Against the
pinned oracle, every identity holds on every envelope state (checked by a
local script that is not committed). On the production replay, every identity holds
in every case. The exposed `lastMonthOverspent` is the one defect found, and it is
compared as OP-35 rather than as an identity: `BudgetDatabase+BudgetReads.swift:53`
sets it to 0, while `envelopeCarryIn` computes the value and the snapshot discards it.
Its `to-budget` identity still holds.

Classification (`BudgetMonthOracleDivergences.swift`): each mismatch is classified
by its path, step label, and values, into OP-26 through OP-35.

- A cell or outcome row is classified directly. A `last-month-overspent` field row
  is classified directly as OP-35, and it never anchors another divergence's cascade.
- A summary or cascade row at or after the case's first directly classified step
  takes that OP. This is co-occurrence within the case, not a trace of the row's
  cause. The registry summaries of OP-26 through OP-30 say so.
- Rows before the first classified step, `before.` rows, rows in a case with no
  classified step, and every `.consistency.` row stay unclassified and must be empty.
- Per case, the classifier's counts are recorded as a test attachment named
  `<case>-split.txt` (`BMSPLIT` line), readable in the result bundle. They are not
  printed to stdout.
- Planned follow-up, not implemented: a counterfactual check, in which the divergent
  step's output is corrected and the month is re-derived, to confirm that the
  attributed cascade rows disappear. Until then, downstream attribution is unverified.

Stale markers: each OP's case set is a literal in `BudgetMonthOracleReplayTests.swift`
and derived from a local, uncommitted mirror of the classifier. A listed case whose
divergence disappears fails with "Known issue was not recorded". An unlisted case
that shows a divergence fails strictly.

## Domain registration

`config/parity/domains.json` already lists `budget-month` as `partial`. This harness
does not edit it. `oracleSuites` is empty, so `scripts/parity.sh verify budget-month`
does not run the Swift replay. Adding `BudgetMonthOracleReplayTests` there, and any
status change, is a decision for the maintainer and is not made here.
