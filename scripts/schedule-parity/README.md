# Schedule Parity

Oracle harness for Actual's schedule engine: next date, occurrence lists,
status, advancement after posting, and turning a future transaction into a
one-time schedule. Expected values come only from running
the pinned Actual release (see `config/parity/oracle-pin.json`). The committed
fixture is `ActualistTests/Fixtures/ActualCore26_10_0/Schedules/`:

- `schedules-contract.json`: one record per case.
- `schedules-manifest.json`: oracle pin, sha256 of every oracle source file
  used, generator and helper hashes, seed, case counts, case IDs, fixture hash,
  `timeZone`, the fixed `today`, and the oracle-only lists.

## Commands

```sh
# Regenerate (needs a clean checkout of the pinned release with yarn install done)
ACTUALIST_PARITY_ORACLE_ROOT=<oracle> node scripts/schedule-parity/generate.mjs
# Regenerate into a temporary directory and diff against the committed fixture
ACTUALIST_PARITY_ORACLE_ROOT=<oracle> node scripts/schedule-parity/generate.mjs --check
# Hashes, plan identity and record shape; no oracle needed
node scripts/schedule-parity/verify.mjs
```

The generator refuses unless the oracle HEAD is the pinned commit with a clean
tree, and checks again afterwards (`scripts/parity/lib/oracle-pin.mjs`). It
writes a vitest file into the checkout, runs it with `TZ=America/New_York`, and
removes it. A full run takes about 4 seconds.

## Fixed inputs

- **Seed:** `20261011` (`cases.mjs`). Each seeded case gets its own seed,
  recorded in the case.
- **Time zone:** `America/New_York`, asserted inside the run. Swift uses
  local-noon `Date` values, so the harness includes cases around the DST
  changes on 2026-03-08 and 2026-11-01.
- **Clock:** the `Date` clock is faked to local noon of the case's day (plus a
  growing number of seconds so every write is later than the one before).
  Actual's test setup pins `currentDay()` to 2017-01-01 through
  `global.IS_TESTING`; the runner turns that flag off so `currentDay()` follows
  the fake clock, as in production. Stateful cases default to
  `today = 2026-10-11`; each step names its own day.

## Case families

| Family | What runs | Records |
| --- | --- | --- |
| `recurrence` (136) | `getNextDate`, `getNextDateAfter`, the oracle's rschedule occurrence list, and the `schedule/get-upcoming-dates` handler, at several `from` days per condition | per `from`: `nextDate`, `nextDateNoSkipWeekend`, `nextDateAfter`, 6 `occurrences` (`raw` and weekend-`adjusted`), `upcoming`; each outcome as `{value, error}` |
| `status` (49) | `getStatus` and `getUpcomingDays` over today offsets, completed/paid flags and upcoming lengths (`7`, `1`, `14`, `oneMonth`, `currentMonth`, `2-week`, `3-day`, `1-month`, `12-month`, `1-year`, `0-day`, `5-week`, and the default) | per row: `status`, `error` |
| `conversion` (10) | the web app's `createSingleTimeScheduleFromTransaction` (`desktop-client/src/util/schedule-actions.ts`, "Schedule this future transaction") on an in-memory budget, its `send()` calls forwarded to the server handlers of the same name | `input` (the register row passed in), `calls`, `sent.scheduleCreate` (conditions and schedule fields), `sent.ruleUpdateActions`, and the `stored` schedule and rule rows |
| `stateful` (68) | `createSchedule`, `advanceSchedulesService`, `skipNextDate`, `setNextDate`, `updateSchedule` and `schedule/post-transaction` on an in-memory budget, with the schedule json-path service running | `before` and, after every step, `after`: `schedules`, `nextDates`, `paths`, `rules`, `transactions`, `effective` (next date, completed, has-transaction, status) and `preview` |

Recurrence: 26 named (3 of them plain dates) plus 110 seeded. Seeded configs
cross daily/weekly/monthly/yearly, intervals 1 to 12, day-of-month patterns
(including 29, 30, 31 and -1), weekday ordinals (including -1), multiple
patterns, skip-weekend before/after, and all three end modes, with start dates
at month ends, 2028-02-29 and year end. `from` days sit before the start, on
the start, between occurrences, near the end and after the end.

Conversion cases pass rows shaped like the transactions view (a parent grouped
with its children), so amounts are always numbers (`IFNULL(amount, 0)`). They
cover plain rows with and without payee, category and notes, an empty-string
payee, zero and income amounts, and splits whose children carry their own
payees, categories and notes.

Stateful scenarios build their schedules through upstream's own
`createSchedule` at the schedule's `createdOn` day, then move the clock. No
table row is hand-built. Steps: `advance` (with `syncSuccess` on or off),
`skip`, `setNextDate`, `update` (date or amount edit, `resetNextDate`),
`payNextDate` (inserts a transaction linked to the schedule at the current next
date plus an offset) and `post`. Named scenarios cover posting on and off,
several missed occurrences, an already paid occurrence, an ended-on-date
schedule, an after-N schedule reaching its count, one-time schedules, closed
accounts, completed schedules, approximate amounts, no payee, exact versus
approximate date lookback, custom upcoming lengths, skipping (including weekend
solving and ended schedules), manual date edits, and DST days.

## Normalization

Only these rules. Amounts and dates are never normalized.

1. Mock UUIDs (`id<number>`, from Actual's test `uuid` mock) become
   `uuid-<number>` in order of first appearance within a case, in record key
   order. This covers rule, account, payee, next-date row and transaction IDs
   and the same IDs inside rule JSON. Schedule IDs are chosen by the harness
   (`schedule-<key>`) and are not renamed.
2. Columns ending in `_ts` are dropped. Which next date is effective depends on
   comparing two of them, so each `nextDates` row keeps a derived
   `localIsEffective` flag.
3. Rows are ordered by primary key (transactions by date, then ID).
4. Raw table columns keep Actual's storage form (dates as `YYYYMMDD` integers).
   `effective`, `preview` and recurrence outputs use ISO day strings.
   `sort_order` columns are derived from the fixed fake clock, so they are
   deterministic; a replay should not compare them.

Errors are recorded as text. One seeded condition (`gen-recur-062-...`) has an
impossible pattern (monthly every 12 months on a day that never recurs) and
makes rschedule throw "Failed to find a matching occurrence in 50 iterations";
a replay should compare that the call fails, not the library's wording.

## Swift replay

`ScheduleOracleReplayTests` (recurrence, status, partition, pin) and `ScheduleOracleStatefulReplayTests` (steps,
creation) replay the fixture through production code in `ActualistTests/ScheduleOracleReplaySupport.swift` and
`ScheduleStatefulReplaySupport.swift`. Case ids are listed in `ScheduleOracleReplayCaseIDs.swift`; the partition
test checks replayed plus oracle-only equals the manifest. Production schedule code uses a GMT calendar and civil
day strings, so the fixed `America/New_York` zone only shapes the `Date` values injected as `now` (local noon of
each step's day). Today is injected through the `today:`, `now:` and `asOf` parameters.

Oracle function to production seam:

| Oracle | Production seam |
| --- | --- |
| `getNextDate(cond, from)` | `ScheduleRuleProjection.dateRule(from:)` (the stored-rule decoder), then `ScheduleRuleMutation.initialNextDate(for:asOf:)`, which `createSchedule` and a date edit call |
| `getNextDate(..., noSkipWeekend)` | the same two primitives `initialNextDate` is built from, `nextOccurrence(onOrAfter:applyWeekendAdjustment: false)` then `lastOccurrence(applyWeekendAdjustment: false)` |
| `getNextDateAfter(cond, after)` | `ScheduleRuleMutation.nextDateAfterSkip(recurrence:currentDayID:)`, what `skipNextDate` calls |
| `getStatus`, `getUpcomingDays` | `ScheduleStatus.resolve(...)` and `ScheduleUpcomingLength.days(for:today:)`: the exact calls `BudgetDatabase.fetchSchedules(budgetID:today:)` makes per schedule (stored upcoming length, or "7"), so the pure call is the read path's own logic |
| `advanceSchedulesService(true)` | `BudgetDatabase.advanceSchedules(budgetID:today:now:)` (the day marker `metadata.json` is removed before each run, since Actual keeps none per call) |
| `skipNextDate`, `setNextDate({advance: true})` | `scheduleMutationReview` then `BudgetDatabase.skipNextDate(review:now:)` |
| `setNextDate({reset: true})` | `BudgetDatabase.updateSchedule(review:fields:asOfDayID:now:)` with `resetNextDate` |
| `updateSchedule` date or amount edit | `updateSchedule` with `ScheduleEditFields.dateRule` / `.amount` |
| `schedule/post-transaction` | `BudgetDatabase.postScheduleOccurrence(...)`, with the draft built as `LocalFirstActualStore.postSchedule` builds it |
| `createSchedule` | `BudgetDatabase.createSchedule(_:now:)` with `asOfDayID` the case's `createdOn` |
| `createSingleTimeScheduleFromTransaction` | `ScheduleTransactionConversionPlanner.plan(from:scheduleID:)`, the whole definition `BudgetDatabase.convertFutureTransaction` stores |

How each family compares:

- **Recurrence:** each `from` compares `nextDate`, `nextDateNoSkipWeekend` and `nextDateAfter`. An oracle error and a
  null result both mean "no date", and a production throw or nil matches either; error wording is not compared.
- **Status:** `upcomingDays` and every row's status.
- **Steps:** before each step the oracle's snapshot of the state before it is seeded into a fresh starter database
  (rules, schedules, next dates, json paths, transactions, accounts, payees, preferences), so a divergence in one step
  cannot carry into the next. This uses oracle output as input, like the Apply Templates test B. The production
  operation then runs and the database projection is compared with the step's `after` snapshot: schedule rows
  (`completed`, `posts_transaction`, `name`, `custom_upcoming_length`, `tombstone`), next-date rows (`local_next_date`,
  `base_next_date`, `localIsEffective`), the effective next date, completion and status per schedule, every
  transaction column listed in the support file, and the date, amount, payee and account of each schedule rule. A
  step that throws, and an automatic-posting refusal, are compared too (`completes`, `refusals`). A `payNextDate`
  step is an oracle input, so only its snapshot is re-read.
- **Conversion:** the planner's conditions against `sent.scheduleCreate.conditions` and its actions against the
  server's `link-schedule` (by `op` and `value`) followed by the client's copied actions from `rule-update`, both in
  order, plus `posts_transaction` and the name (intended difference OP-87). The payee condition's field is taken from
  the `stored` rule: Actual saves `payee` as `description`, and its unused-payee query matches only that name, so the
  planner writes it that way. Other stored differences (`acct`, the added `type`) are read back the same by Actual and
  are not compared.
- **Creation:** `createSchedule` replays each setup schedule on a fresh database (accounts and payees seeded from
  the fixture) and compares schedule fields, next-date rows and rule summaries with the `before` snapshot.

Excluded from the replay, each with its reason:

- `recurrence.queries[].occurrences.raw` / `adjusted`: production has `nextOccurrence` only, no occurrence-list API.
  Chaining `nextOccurrence` would be a loop that lives in the test: production enumerates occurrences one step at a
  time during advancement and never as a list.
- `recurrence.queries[].upcoming`: `schedule/get-upcoming-dates` has no production counterpart.
- `stateful steps[].after.preview`: `computeSchedulePreviewTransactions` has no production counterpart.
- `nextDateAfter` for a one-time condition, and for a weekend `from` day on a weekend-skipping schedule: a one-time
  schedule cannot be skipped in production, and a weekend-skipping schedule's current next date is never a Saturday
  or Sunday, so those inputs are not reachable.
- `schedules_json_paths` rows (seeded, not compared): Actual's service writes them; Actualist reads the rule's
  conditions directly.
- Transaction `id` (the replay's ids are its own), `sort_order` and `raw_synced_data` (clock- and sync-derived).
- `completed` in the creation comparison: creation cannot set it.
- Whole cases listed under `oracleOnly` in the manifest: a `setNextDate` step with neither or both of `advance` and
  `reset` (no production entry; skip and `resetNextDate` are its two callers). The generator marks any case
  containing such a step. An `advance` step with `syncSuccess: false` replays through
  `advanceSchedules(postingAllowed: false)`.

Known divergences found by the replay are registered as OP-51 to OP-53 and OP-87 in
`config/parity/known-divergences.json`.

## Upstream behavior worth knowing

- **Creation reads "today" as a UTC date.** `createSchedule` calls
  `getNextDate(dateCond)` whose default start is `new Date(currentDay())`.
  `new Date('YYYY-MM-DD')` is UTC midnight, so west of UTC `startOfDay` lands on
  the previous local day. In `America/New_York`, a daily-every-3-days schedule
  from 2026-10-01 created on 2026-10-11 gets next date 2026-10-10, not
  2026-10-13 (`create-negative-offset-timezone`). Swift's `initialNextDate`
  starts from the given day, so it differs in zones behind UTC.
- Weekly and yearly recurrences ignore `patterns`; only monthly uses them.
- A date condition with operator `is` gets no early-payment lookback; only
  `isapprox` matches a transaction up to 2 days before the occurrence
  (`advance-exact-date-early-not-paid` versus `advance-early-payment-lookback`).
- A paid recurring schedule that posts transactions does not advance on the day
  it is due; one that does not post advances through `setNextDate`.

## Follow-ups

- Run the Swift replay with a second time zone (a zone east of UTC) once the
  creation quirk above has a decision.
