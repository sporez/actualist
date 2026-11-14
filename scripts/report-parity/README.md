# Report parity

Compares Actualist's Reports reads with the report spreadsheets of the Actual desktop client at
the pinned release (`config/parity/oracle-pin.json`). The oracle is Actual's own code: the net
worth, cash flow, spending and calendar spreadsheets run in loot-core's vitest on an offline
in-memory database, with the client `send` forwarded to the in-process handlers.

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean pinned Actual checkout> node scripts/report-parity/generate.mjs
node scripts/report-parity/generate.mjs --check     # fresh generation equals the committed fixture
node scripts/report-parity/verify.mjs               # no oracle: manifest pins, hashes, case shape
```

Fixture: `ActualistTests/Fixtures/ActualCore26_11_0/Reports/reports-{contract,manifest}.json`.
Replay: `ReportOracleReplayTests` (`ActualistTests/ReportOracleReplay*.swift`).

## How the oracle runs

- `generate.mjs` writes `oracle-runner.template` and a vitest config (with `@vitejs/plugin-react`, which
  `cash-flow-spreadsheet.tsx` needs) into the oracle checkout, runs them, and removes them in `finally`.
  It never installs packages and fails before running if any pinned source differs (sha256 of the
  spreadsheets, `makeQuery.ts`, `reports/util.ts`, `spendingAverageRange.ts`, `ReportOptions.ts`,
  `budgetDataQuery.ts`, the aql schema, views, compiler and executor, `months.ts`, the db layer,
  the rule-to-AQL conversion and loot-core's vitest config).
- The world is seeded through loot-core's own `db` functions with explicit ids (`cases.mjs`), twice:
  `envelope` (budgets in `zero_budgets`) and `tracking` (budgets in `reflect_budgets`, `budgetType`
  preference). Both share accounts, payees, categories and transactions. The fixture stores the raw
  table rows of each world and the Swift replay seeds its starter schema from them.
- The clock is 2026-09-15 12:00 UTC (`TZ=UTC`), 2026-09-30 for the `-late` cases. `Date` is faked with
  `vi.useFakeTimers({toFake: ['Date']})`. `monthUtils.currentDay()` returns 2017-01-01 while
  `global.IS_TESTING` is true, so the runner clears it only around each report call (the factory call
  and the invocation) and restores it in `finally`.
- Net worth and cash flow points carry the period they cover, derived with the same `months.ts` range
  functions the spreadsheet uses; JSX labels and display strings are dropped.

## World

Accounts: `acct-checking`, `acct-card` (negative balance) and `acct-closed` (closed, with history) on
budget; `acct-invest`, `acct-house` off budget; `acct-gone` tombstoned with tombstoned history.
Categories: an expense group (`cat-groceries`, `cat-dining`, hidden `cat-hidden`), an income group
(`cat-salary` is income; `cat-in-income-group` has `is_income` 0), and a hidden group with
`cat-hidden-grp`. Transactions run 2026-03 to 2026-09 with expenses on days 1, 15, 28, 29, 30 and 31, a
refund, a zero amount, uncategorized rows, linked transfers (same date, different dates, on to off
budget), a transfer payee with no linked leg, a split with categorized children, a split whose parent
is deleted and whose children are live, and one row dated 2026-09-20 (after today). Budgets cover
2026-06 to 2026-09 on every expense category plus `cat-salary`.

## Cases (25)

| Kind | Actual call | Cases |
| --- | --- | --- |
| net worth | `createSpreadsheet` | Monthly 2026-04..09 for non-closed accounts, the `accounts-get` set (the UI's `useAccounts()`) and on-budget accounts; Daily 2026-09; a range starting before the earliest transaction |
| cash flow | `cashFlowByDate` | monthly and daily, plus an `account is acct-checking` condition |
| spending | `createSpendingSpreadsheet` | 2026-09 vs 2026-08 and 2026-07 vs 2026-06; budget type envelope and tracking for 2026-09 and 2026-08; average range last 3 months; a category condition (`cat-dining`) and an account condition |
| calendar | `calendarSpreadsheet` | 2026-07..09 with `firstDayOfWeekIdx` unset ('0'), '1' and '9'; `transfer is false` |
| today 2026-09-30 | one case of each kind | net worth daily, cash flow daily, spending, calendar |

## What Actualist is compared with

Dashboard: `fetchReportsDashboard(range:)` cards and `fetchNetWorthReport(range:)`. Explorer:
`fetchReportExplorer(query:)`. Where both map to one Actual case, both are compared, as separate fields of
that case (`dashboard`, `explorer`).

| Actual | Dashboard | Explorer |
| --- | --- | --- |
| net worth `graphData.data[].y`, `<acct>`, `netWorth` | `netWorth.points`, `balance`, `change` (monthly, all live accounts only) | `netWorth` points' `endingBalance` and `totals.endingBalance`; each account's balance from a one-account query |
| cash flow per period income and expenses; `totalIncome`, `totalExpenses` | `cashFlow` income and expenses (monthly, unfiltered, anchor month) | `cashFlow` points and totals |
| spending `compare`, `compareTo`, `average`, `budget` | `monthComparison`, `budgetOverview` actual and budget points, `threeMonthAverage` (unfiltered cases) | `spendingAverage` (month to date for `compare`, whole month for `average`), `budgetOverview` over the whole month for `budget`, `spending` over `startDate..endDate` for `totalTotals` |
| calendar months and days | `transactionCalendar` (leading blanks, day income and expenses, month totals) | `cashFlow` daily with off-budget accounts and the card's transfer filter |

Ranges: an explorer or dashboard range ends at `min(end of the last month, today)`, the clock the
spreadsheet applies, except net worth (Actual's recorded `start`/`end`) and the spending reads described
above. Filters: an `account is X` condition is an account filter; a `category is X` condition is a category
filter with uncategorized rows excluded (Actual's filter excludes them); `transfer is false` is the
calendar card's `transfer is false` condition, which Actualist reads from the `calendar-card` dashboard row.

## Mapping rules

Applied to Actual's recorded values and nothing else (`ReportOracleReplaySupport.swift`):

- (a) Sign: Actualist shows spending, expenses and budget as positive where Actual has negative; the
  replay compares `-actualist` with Actual.
- (b) Actual's spending `budget` is fractional; the expected value is `Math.round` of it (half toward
  +infinity, `floor(x + 0.5)`), then rule (a).
- (c) Day-28 bucket folding: both sides use 28 buckets; compared bucket by bucket.
- (d) Values after today: Actual has null. A bucket Actualist does not produce is null. A number where
  Actual has null is a mismatch.

No other mapping. Every case is compared strictly: no `withKnownIssue`, no known-divergence entries.

## Recorded but not compared

Actualist has no counterpart:

- cash flow `totalTransfers`, `totalChange`, `balance` and per-period transfers and balance (Actualist
  separates transfers only through a filter, and has no running balance);
- spending `totalAssets`, `totalDebts` (Actual splits positive and negative rows; only the net,
  `totalTotals`, is compared);
- net worth `totalChange` against the explorer (the explorer's `balanceChange` is measured from before the
  first point, Actual's from the first point; the dashboard `change` is compared).

## Out of scope

Reports Actualist does not have (summary, custom, budget analysis, crossover, age of money, forecast,
sankey), the Weekly and Yearly intervals, spending average ranges other than the last three months, and
Actualist-only outputs: `cashFlow.uncategorized`, the budget overview variance, drilldown lists, range
presets and range limits.
