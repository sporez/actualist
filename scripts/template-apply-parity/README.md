# Apply Templates parity harness

`generate.mjs` runs Actual's pinned goal-template apply and overwrite handlers
against seeded synthetic SQLite budgets and records what they wrote. It writes
`template-apply-contract.json` and `template-apply-manifest.json` into
`ActualistTests/Fixtures/ActualCore26_10_0/TemplateApply/`.

`verify.mjs` checks the committed fixture without the oracle: manifest pin,
generator, harness and helper hashes, upstream source hash list, fixture hash,
case IDs and order, and family/funding coverage.

Status: the fixture is committed and verified against Actual v26.10.0. The Swift
replay runs every case (see "Swift replay"); its confirmed divergences are
registered as OP-24 and OP-25 and are `intended`. `config/parity/domains.json`
lists `apply-templates` as `covered`, with `TemplateApplyOracleReplayTests` as
its oracle suite.

## Commands

The generator writes a temporary runner into the oracle checkout, runs it with
vitest, and removes it afterwards. Point it at a clean scratch clone of the
pinned tag with dependencies installed. Do not point it at a checkout you need
to keep clean.

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/template-apply-parity/generate.mjs
ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/template-apply-parity/generate.mjs --check
node scripts/template-apply-parity/verify.mjs
```

`--check` regenerates into a temporary directory and compares it with the
committed files through `scripts/parity/lib/fixture-diff.mjs`. Without the oracle
it exits non-zero. `verify.mjs` needs no oracle. Any edit to `generate.mjs` or
the harness changes its hash, so regenerate, then run `--check` and `verify.mjs`.

The oracle run takes about 5 seconds for 166 cases on the pinned checkout. The
committed contract is about 2 MB.

## Scope

- Synthetic data only. One account and six categories (one income, five
  expense). No sync server and no personal data.
- Amounts are integer minor units in transactions, budgets and goals. Note and
  UI template amounts are display units, as Actual parses them.
- The date seam is `global.currentMonth = '2026-10'`. Schedule targets use
  `current_month`, so no clock mock is needed.
- Operation months are 2026-10 through 2027-01. Each case applies, overwrites
  or runs a subset apply (see "Excluding cases") in one of them.

## Cases

166 cases: 135 whole-month cases (120 generated and 15 named), followed by 31
excluding cases (see "Excluding cases").

Generated cases cover 8 families (`fixed`, `priority`, `schedule`,
`average-copy`, `percent`, `remainder`, `goal-by`, `limit-refill`) crossed with
5 funding states (`above`, `below`, `exact`, `zero`, `negative`), with 3 cases
per combination. Each generated case picks an operation month and kind
(apply or overwrite) from one seeded random stream. About 20% of generated cases
seed a random existing budget on a target category, so apply's skip-budgeted
branch is exercised.

Named cases are fixed:

| Case | What it pins |
| --- | --- |
| `tapply-named-ended-schedule` | A schedule template points at a completed schedule |
| `tapply-named-deleted-category` | A deleted category with a template note is excluded from the run |
| `tapply-named-priority-clamp` | Priority templates exceed To Budget, so the lowest priority is clamped |
| `tapply-named-average-missing-months` | An average over six months with spending in only two of them |
| `tapply-named-yearly-sinking-fund` | A yearly periodic template divided across months |
| `tapply-named-schedule-by-id` | A UI schedule template links to a schedule by id rather than by name |
| `tapply-named-stale-note-goal-def` | A notes-sourced goal definition with no matching template note is cleared |
| `tapply-named-tracking-budget` | Templates in a tracking budget fund from total saved |
| `tapply-named-jpy-currency` | Templates in a zero-decimal currency |
| `tapply-named-leap-year-periodic` | A monthly periodic template across the February 2028 leap day |
| `tapply-named-year-boundary-by` | A by-date spend template evaluated in January, across the year boundary |
| `tapply-named-overwrite-existing-budget` | Overwrite replaces a category that already has a budget |
| `tapply-named-apply-skips-budgeted` | Apply leaves a category that already has a budget unchanged |
| `tapply-named-no-templates` | Apply with no template definitions reports up to date |
| `tapply-named-orphan-goal-reset` | A stored goal with no template definition is reset |

## Excluding cases

The last 31 cases call `budget/apply-multiple-templates` over a subset of the
month's categories. They are the oracle for an apply that skips chosen
categories. They are appended after the 135 whole-month cases, which keep their
IDs, order and content (their recorded output is byte-identical).

Each case records this operation:

```json
{ "kind": "overwrite-excluding" | "fill-empty-excluding", "month": "YYYY-MM",
  "excludedCategoryIds": ["..."], "categoryIds": ["..."] }
```

`excludedCategoryIds` is fixed by the case. `categoryIds` is the exact list given
to the handler, computed in the harness from the seeded state just before the
operation:

- `overwrite-excluding`: the whole-month scope minus the excluded categories.
  The whole-month scope is what Actual's whole-month apply iterates
  (`getCategories()` in `goal-template.ts`: visible groups, visible
  categories, tombstones dropped, and income categories dropped unless the
  budget is tracking), in that order.
- `fill-empty-excluding`: the same list minus every category that has a stored
  template and a nonzero budget in the month. Plain apply skips those, but the
  subset handler always forces and would overwrite them. A category with no
  template stays in the list, because the orphan-goal reset runs for it
  whatever its budget.
- An empty list fails the generator: Actual falls back to every category when
  it gets none.

An excluding case also records `order`: `wholeMonth` (the order of
`categoryIds`) and `handler` (the order the handler iterates them).

All excluding cases store UI-sourced definitions (`template_settings`
`{"source":"ui"}`), never notes, so none depend on note regeneration (OP-24).
The harness computes the list around the funding step's note-template store
and restore, so an excluding case must not rely on note-only templates.

Order. The handler loads its categories with `q('categories')` and no explicit
sort, so they come back by the aql default `sort_order, id` across all groups
(`aql/schema/index.ts` `customizeQuery`). The whole-month run walks
`q('category_groups')` (default `is_income, sort_order, id`) and each group's
categories by `sort_order, id`. The two orders agree only when category sort
orders follow group order. They decide who receives the last cent of a
Remainder split and which category a priority clamp reaches first. The two
`order-*` cases give a second group's categories lower sort orders than the
first group's, so the orders differ. Production runs a month apply with
excluded categories in the handler's `sort_order, id` order, and the Swift
replay checks it against these cases.

Named: `tapply-named-excluding-` plus `priority-levels` (the higher-priority
category skipped), `remainder-split`, `budgeted-category` (an excluded
category's budget stays spent), `orphan-goals` (kept goal reset, excluded goal
untouched), `tracking-income` (income category excluded), `fill-empty-mixed`,
`priority-clamp`, `all-but-one`, `invalid-template` (an excluded category names
a schedule that does not exist, which makes Actual reject the whole-month run;
the subset run applies the rest), `order-remainder` and
`order-priority-clamp`.

Generated: `tapply-generated-excluding-<family>-<state>-1` for the families
`fixed`, `priority`, `remainder` and `percent` crossed with the 5 funding
states (20 cases). They use their own random stream (`seed + 1`), choose one
excluded category, and pick `overwrite-excluding` or `fill-empty-excluding`. Funding counts only the
categories in `categoryIds`.

### How funding is set

Each case first runs a probe pass: it loads the sheet, stores the note templates,
and asks Actual's dry run what each template would budget. Remainder and
goal-only categories are left out of that demand total, and for apply so are
categories that already have a budget. The probe's effects on `categories` are
then reverted, so the recorded `input` shows note templates unexpanded.

The target is the demand plus, minus, or equal to a generated delta, or zero, or
the negative delta. Envelope budgets are funded with one income transaction in
the operation month. Tracking budgets are funded with an income budget row in
`reflect_budgets`, because tracking total saved is budgeted income minus
budgeted spending. The sheet is reloaded and the funded balance is asserted to
equal the target before the operation runs. A mismatch fails the generator.

## Fixture layout

Each case has:

- `input`: the post-setup tables, dumped before the operation.
- `before`: the operation month's balance and per-category budget, goal and
  long-goal cells before the operation.
- `funding`: the demand, probe, target and income amount that set To Budget.
- `expected`: the notification (`message`, `pre`, `count`, `sticky`), any error,
  the balance and category cells after the operation, persisted budget rows for
  the operation month, and goal definitions and template settings for every
  category.

Goals persist in `zero_budgets` for envelope budgets and in `reflect_budgets`
for tracking budgets. Both are included in the dump.

## Normalization

Only these rules are applied to the recorded output:

- Actual's mock UUID tokens (`idN`) are replaced by `uuid-N` in order of first
  appearance within each case.
- Columns ending in `_ts` are dropped. They are timestamp columns that vary per run.
- Rows are sorted by primary key.

Values are not rounded or converted, and amounts are compared exactly.

## Swift replay

`ActualistTests/TemplateApplyOracleReplayTests.swift` replays all 166 cases
through the production apply path. The support is in
`TemplateApplyOracleReplaySupport.swift`. Each case seeds the starter schema
from `input`, then runs `budgetTemplateApply(command:month:currentMonth:db:builder:)`
inside `commitUserActionPlan(source: .ui, expectedMode:)`, as
`applyBudgetTemplateAndRefresh` does. Apply maps to `.fillEmpty` and overwrite to
`.overwrite`. `fill-empty-excluding` and `overwrite-excluding` map to the same
modes with `excluding(excludedCategoryIds)`; production derives the remaining
list itself, so `categoryIds` is not passed in. `currentMonth` is read from the fixture's `syntheticData`, not the
clock. The store path passes no `currentMonth`, so the replay exercises the
engine's date parameter rather than the store's.

Each case compares `balance`, `categories`, `persistedBudgets`, and
`goalDefinitions` after the same normalization. Up-to-date cases must write zero
messages. `notification` and `error` are not compared. Actualist does not
produce the upstream message strings (`templates-applied`,
`templates-up-to-date`, `template-errors`), so they stay oracle-only until the
product decides whether to surface them. A partition test checks that the
replayed IDs and the manifest's oracle-only IDs cover all 166 cases.

### Two replays

- **Test A** (`replaysTemplateApplyCase`) runs each case exactly as the fixture
  states it. It is the authoritative comparison. A note-only category keeps a
  null stored `goal_def`, as the case's input says.
- **Test B** (`replaysTemplateEngineWithStoredDefinitions`) isolates the apply
  engine. For each category whose input `goal_def` is null and whose oracle
  definition is non-null, it stores the oracle's `goal_def` and sets
  `template_settings` to `{"source":"ui"}`. That keeps the stale-note guard out
  of those categories. `templateSettings` is removed from both sides of B's
  `goalDefinitions` comparison, because only A compares it. B uses the oracle's
  output as input because the oracle regenerates each definition from its note
  before the apply, and production does not (OP-24). B asks whether the engine
  computes the same numbers once the definition exists.

### Setup mirroring

The oracle's harness creates a zero budget row for every live expense category
when it loads the sheet (upstream `createAllBudgets`). The replay seeds the same
rows for the operation month wherever the case supplies none. An excluding case
leaves no row for a category outside its `categoryIds`, so the replay seeds only
those categories there. Tracking budgets
(`preferences` `budgetType = tracking`) use `reflect_budgets`, and envelope
budgets use `zero_budgets`. Those rows are harness setup, not production
behavior.

### Units

No unit conversion or rounding is applied. Oracle `goal_def` amounts are display
units, and Test B agrees with the oracle in 165 cases, so the stored and oracle
units match.

### Results

Confirmed against Actual v26.10.0 on 2026-10-11, and with the excluding cases on
2026-10-29:

- Test A: 33 pass (`tapply-named-no-templates`, `tapply-named-schedule-by-id`
  and the 31 excluding cases); 133 known-issue results, which are the note-only
  candidates. 132 are OP-24 and `tapply-named-stale-note-goal-def` is OP-25.
- Test B: 165 pass; `tapply-named-stale-note-goal-def` is the one known-issue
  result, under OP-25.

The OP-24 entry in `config/parity/known-divergences.json` lists the 132 cases.
The OP-25 entry lists the stale case. Both are open with a review date of
2026-10-25. `BudgetDatabase+TemplateNoteSync.swift` describes both behaviors as
intentional, so the product decides whether either is a divergence to fix.

## Not covered

- Sync, CRDT message replay, and outbox behavior.
- The template editor and browser (see `scripts/template-parity/`, a separate
  domain).
- The UI apply review sheet.
