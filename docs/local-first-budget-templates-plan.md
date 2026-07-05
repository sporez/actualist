# Local-First Budget Templates Plan (Phase 4, Steps 4–5)

## Premise

Local-first is the only backend. Budget templates are **deterministic math over
data already in our SQLite** — the loot-core "spreadsheet" the engine reads
(`to-budget`, per-category `leftover`/`carryover`, income, N-month history,
prior-month budgets, schedules) is just cached derived values, most of which
`BudgetDatabase.fetchBudgetMonth` already computes. So we **port the engine**; we
do not defer and we do not offload (the Actual sync server has no template
endpoint — REST `applyBudgetTemplates` just proxies to the same in-process
loot-core engine).

Because the surface is large (~12 template types + priorities + remainder), this
lands in typed phases behind a hard **refuse-on-unsupported** guard, so anything
we *do* apply matches Actual web exactly and partial support never mis-budgets.

## Source Of Truth

`/Users/neil/CC/actual-http-api/node_modules/@actual-app/api/dist/index.js`
(loot-core), regions:

- `goaltemplates.ts` — `applyTemplate`/`overwriteTemplate`/`applySingle`/
  `applyMultiple`, `getTemplates`, `computeTemplates`, `processTemplate`,
  `setBudgets`, `setGoals`, `distributeRemainder`.
- `CategoryTemplateContext` — `init`, `runTemplatesForPriority`, and the per-type
  `runSimple`/`runCopy`/`runPeriodic`/`runSpend`/`runPercentage`/`runBy`/
  `runSchedule`/`runAverage`/`runRefill`; limits (`limitToString`, `getLimitExcess`).
- schemaConfig — `categories.goal_def` (structured template JSON).
- REST proxy: `actual-http-api/src/v1/budget.js` `applyBudgetTemplates` →
  `budget/apply-goal-template` etc. (confirms REST runs the same engine).

**Frozen contract. Do not re-derive from memory.**

## Prerequisite (Step 0): Consolidate Write Gates

The three capability flags `allowsLocalFirstTransactionCreation` /
`allowsLocalFirstBudgetAssignment` / `allowsLocalFirstMoveMoney` are **already all
wired to the single setting** `settings.localFirstTransactionCreationEnabled`
(`AppState.capabilities`), so they are pure redundancy.

- Collapse to one flag `allowsLocalFirstWrites`; rename the persisted setting to
  `localFirstWritesEnabled` (decode the old key as a fallback so dev state
  survives). Update `updateLocalFirst…` method and the Settings toggle/copy.
- Every write capability (`canCreateTransactions`, …, `canMoveMoney`, and the new
  `canApplyBudgetTemplates`) references the single flag. Keep the semantic `canX`
  accessors — they map to distinct UI affordances and read clearly at call sites;
  only the underlying flag collapses.
- `canApplyBudgetTemplates` flips from `!isReadOnly` to the shared flag when
  Phase T1 lands (before that it stays blocked).

This removes the flag clutter and gives templates a gate for free.

## Data Model

- **Templates live in `categories.goal_def`** (JSON), authored by the GUI template
  editor. `getTemplates()` is `JSON.parse(goal_def)`. Raw `#template` notes are the
  legacy path (`storeNoteTemplates` converts notes→`goal_def`, `unparse` the
  reverse). **We read `goal_def` directly**; note parsing is out of scope (optional
  later).
- `goal_def` is a list of typed entries. Common fields: `type`, `directive`
  (`template`/`goal`), `priority`. Per type: `simple{monthly?, limit?}`,
  `copy{lookBack}`, `periodic{amount, period{amount,period}, starting, limit?}`,
  `percentage{percent, category, previous?}`, `by{amount, month, annual?, repeat?}`,
  `spend{amount, month, from?}`, `schedule{name, full?, adjustment?}`,
  `average{numMonths, adjustment?}`, `remainder{weight?, limit?}`, `goal{amount}`,
  `limit{amount, period, hold?, start?}`, `refill`.
- **Apply writes `zero_budgets`** via the existing `assignCategoryBudgetMessages`
  primitive (`setBudget`). Goal-only entries write `goal`/`long_goal` (`setGoal`).
- `amountToInteger(amount, decimalPlaces)`: `goal_def` amounts are decimals; convert
  to minor units using the budget's currency decimal places (default 2).

## Engine (port of `computeTemplates`)

Per-category inputs, all from SQLite (reuse/extend `fetchBudgetMonth`'s envelope math):

| loot-core sheet value | local source |
|---|---|
| `leftover-<cat>` (prior month) + `carryover-<cat>` | category balance carried from prior month; app already derives balance + carryover |
| `to-budget` (month) | `BudgetMonth.toBudget` |
| `budget-<cat>` / `goal-<cat>` (current) | `zero_budgets` for the month |
| income total | sum of income-category activity (already have `totalIncome`) |
| N-month spend history (average) | SQL sum of category activity over N prior months |
| prior-month budget (copy) | `zero_budgets` for `month - lookBack` |
| schedules (schedule/spend/by) | `schedules` table |
| currency decimal places | `preferences` (`defaultCurrencyCode`), default 2 |

Algorithm (faithful to `computeTemplates`):

1. Load in-scope categories with non-null `goal_def`; JSON-decode.
2. Build a `TemplateContext` per category with the inputs above; skip income
   categories in envelope budgets.
3. Available budget starts at month `to-budget`; add back each category's current
   `budgeted` (unless goal-only) and any limit excess.
4. Collect the set of `priority` values; iterate ascending. For each priority, run
   every category's templates-for-priority in order, decrementing available.
5. `distributeRemainder`: split leftover available across `remainder` templates by
   weight (respecting limits).
6. Apply: `setBudget` per category — **fill-empty** sets only where `budgeted == 0`;
   **overwrite** forces the computed value. `setGoal` for goal entries.

Modes (match REST/loot-core): `apply` (whole month, fill-empty), `overwrite`
(whole month, force), `apply-single` (one category, overwrite), `apply-multiple`
(category set, overwrite).

## Refusal Guard (parity safety, every phase)

Until all types are ported, any apply whose scope includes a template type — or a
limit/priority/remainder interaction — not yet implemented returns a clear
`unsupportedTemplate` error and **writes nothing**. Guarantees: whatever we apply
equals Actual web. The guard is removed type-by-type as phases land.

## Phasing (by data dependency)

**Phase T1 — constants + allocation core.** `simple` (fixed `monthly`), `copy`
(prior-month budget), `periodic`; priority ordering; `remainder` (weight split);
`limit`/"up to" with hold/carryover; fill-empty vs overwrite; single/multiple/
whole-month. Covers the dominant GUI case ("$X every month"). No history/income.

**Phase T2 — aggregates.** `average` (N-month history), `percentage` (% of income
or another category, incl. `previous`).

**Phase T3 — schedules & time-spread.** `schedule`, `spend`, `by` (spread to a
target month, with `annual`/`repeat`), `week`.

**Phase T4 — goals & edges.** `goal`/`refill` (`setGoal`), weekly/hold limits,
tracking-budget vs envelope differences, orphan-goal cleanup.

Each phase: port the `runX` exactly, wire its SQL inputs, add unit tests with
hand-computed expectations, shrink the refusal guard, and add an Actual-web parity
check.

## Write Path (code shape)

- `BudgetDatabase`:
  - `readCategoryGoalDefs(categoryIDs?)` → `[categoryID: [TemplateEntry]]` (decode).
  - input queries: `categoryLeftover(month, cat)`, `monthToBudget(month)`,
    `categoryBudget(month, cat)`, `nMonthSpend(cat, months)`, `incomeTotal(month)`,
    `priorBudget(month, lookBack, cat)`, `schedule(name)`.
  - `budgetTemplateMessages(mode, scope, month, builder)` → runs the engine, emits
    `zero_budgets` messages via the existing assign primitive (+ `setGoal`), or
    throws `unsupportedTemplate`.
- `LocalFirstActualStore.applyBudgetTemplateAndRefresh` → build messages, push,
  apply, reload budget month + alerts (same pattern as assign/move-money).
- `BackendCapabilities.canApplyBudgetTemplates` → `allowsLocalFirstWrites` (T1+).

## Testing

- Per-type unit tests over a fixture budget: set `goal_def`, apply, assert each
  category's `budgeted` equals a hand-computed value; cover fill-empty vs overwrite,
  single vs multiple, priorities, remainder split, limits.
- Refusal test: an apply whose scope includes an unported type writes nothing and
  errors.
- Parity ladder: throwaway budget — author templates in Actual web's GUI editor,
  apply in Actualist, diff every category `budgeted` against Actual web; repeat per
  phase and per mode.

## Risks & Mitigations

- **Envelope parity** (`leftover`/`carryover`): must match `fetchBudgetMonth` and
  Actual exactly — reuse the existing envelope derivation, don't reinvent.
- **Priority/remainder ordering**: port `runTemplatesForPriority` +
  `distributeRemainder` literally; test with multi-priority + remainder fixtures.
- **Rounding/currency**: use `amountToInteger` semantics and the budget's decimal
  places.
- **Silent divergence**: the refusal guard is the backstop — no partial apply ever
  writes an amount we can't guarantee matches Actual.

## Progress Tracker

`[x]` done, `[~]` in progress, `[ ]` not started.

**Step 0 — gate consolidation** (sha 21795ca)
- [x] Collapse 3 write flags → `allowsLocalFirstWrites`; rename setting w/ fallback.
- [x] Capabilities reference single flag; Settings toggle/copy + tests updated.

**Phase T1 — constants + allocation core**
- [ ] `readCategoryGoalDefs` + decode model.
- [ ] Engine skeleton: context, priorities, remainder, limits, modes.
- [ ] `runSimple` / `runCopy` / `runPeriodic`.
- [ ] `applyBudgetTemplateAndRefresh` wired; `canApplyBudgetTemplates` → flag.
- [ ] Refusal guard for unported types.
- [ ] Unit tests + Actual-web parity for T1.

**Phase T2 — aggregates**
- [ ] `runAverage` (+ N-month spend query).
- [ ] `runPercentage` (+ income/source-category query).
- [ ] Tests + parity.

**Phase T3 — schedules & time-spread**
- [ ] schedules read; `runSchedule` / `runSpend` / `runBy` / week.
- [ ] Tests + parity.

**Phase T4 — goals & edges**
- [ ] `setGoal` path; `refill`; weekly/hold limits; tracking-budget differences.
- [ ] Tests + parity.

**Post**
- [ ] Remove refusal guard once all types land.
- [ ] Optional: `#template` note parsing for legacy budgets.
