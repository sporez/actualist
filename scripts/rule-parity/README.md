# Rules-engine parity harness

Generates the rules fixture from Actual's own `runRules` at the pinned release
(`config/parity/oracle-pin.json`, v26.10.0). Phase 4 of the oracle parity plan.
This directory holds only the generator side; the Swift replay is separate.

- `generate.mjs`: runs the plan inside the oracle checkout under vitest and
  writes the fixture. `--check` regenerates into a temporary directory and
  diffs against the committed fixture.
- `verify.mjs`: checks the committed fixture against the manifest and the plan.
  Needs no oracle.
- `cases.mjs`: the plan (named and seeded cases). Pure data, no expectations.
- `oracle-runner.template`: the vitest test copied into the oracle for one run
  and removed afterwards.
- Fixture: `ActualistTests/Fixtures/ActualCore26_10_0/Rules/`
  (`rules-contract.json`, `rules-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/rule-parity/generate.mjs [--check]
node scripts/rule-parity/verify.mjs
```

The oracle checkout must be at the pinned commit with a clean tree and
`yarn install` done. It is checked before and after the run and is never
written to except for the temporary runner, which is removed in a `finally`.
Generation takes about 6 seconds.

## What a case is

Each case is one synthetic budget, a set of rules, and one or more input
transactions.

- **Budget setup** (`setup`): accounts (on-budget, off-budget, closed),
  category groups and categories (including an income category), payees
  (including two transfer payees), existing transactions (read by
  `BALANCE_OF` and the running-balance variable) and, when a case opts in,
  schedules created through upstream's `createSchedule`. All of it goes
  through upstream's own `db.insert*` and `createSchedule` functions.
- **Rules** (`rules`): inserted with upstream's `insertRule` (ids are explicit
  so ranking ties are stable) and loaded with `loadRules`, the way budget load
  does. Stage is `pre`, `null` (default) or `post`; `conditionsOp` is `and` or
  `or`.
- **Inputs** (`runs[].transaction`): the exact object passed to `runRules`.
  A key that is absent in the JSON was absent in the call, which upstream
  treats differently from `null` for id-typed fields.
- **Expected** (`runs[].output`): what `runRules` returned. Also recorded per
  run: `evaluated` (rules whose conditions were evaluated, in order, with
  whether they matched), `applied` (rules whose actions ran, in order, which
  includes a schedule rule that bypasses its conditions), and `createdPayees`
  (payees `payee_name` created).
- **Input tables** (`input`): the upstream rows of `accounts`,
  `category_groups`, `categories`, `payees`, `transactions`, `schedules` and
  `rules` after setup, so a replay can insert them into its own starter
  schema. Rule conditions and actions are stored with upstream's internal field
  names (`description`, `imported_description`), exactly as in a budget file.

## Environment

- `today` is `2026-10-15` for `Date`, `global.currentMonth` and
  `currentDay()`. Under `IS_TESTING` upstream's `currentDay()` ignores fake
  timers and returns `2017-01-01`, so the runner replaces it with the fixed
  day. Rule templates and formulas read it as `today`.
- Time zone: `TZ=America/New_York` for node and vitest, recorded as
  `timeZone` in the manifest. The Swift replay uses the same zone.
- Amounts are integer minor units and are never normalized.

## Normalization (only this)

- Ids Actual mints during a case (new payees, split children) are renamed
  `uuid-N` by first appearance in the case's runs. Every other id is explicit.
  A schedule's linked rule id is pinned to `rule-sched-<name>` after
  `createSchedule` mints a random one, so ranking ties do not depend on it.
- Dumped table rows are sorted by primary key and `_ts` columns are dropped.
- `_account`, `_account_name` and `_category_name` (the joined lookups the
  engine attaches for condition evaluation) are dropped from outputs.
- `_ruleErrors` is kept: formula actions always add it (usually `[]`).

## Generation

Seed `20261011` (`mulberry32`), recorded in the manifest. Every generated case
is committed with its own seed. Specs below are in `cases.mjs`.

| Family | Count | Shape |
| --- | --- | --- |
| `gen-cond-<field>-<op>-<n>` | 126 | One condition spec (63 field/operator/value combinations) × 2 seeded variants. A target rule with the condition plus a seeded action, stage, and rule id, and a distractor rule. Inputs are the spec's hit and miss overrides of the base transaction (boundary values for amount, date and text). |
| `gen-action-<action>` | 34 | Each action spec behind `payee is`, plus a second rule on `notes contains` with a seeded other action and seeded stages. Four inputs: base, non-matching control, off-budget account, inflow. |
| `gen-rank-NN` | 40 | 2 to 4 rules that all match the base transaction, each with a seeded stage, condition operator and action, so stage, rank score and id tie-break decide the result. |
| `gen-join-NN-and/or` | 24 | Two conditions joined by `and` or `or`; inputs break none, the first, the second, or both. |

Condition fields: `payee`, `payee_name`, `imported_payee`, `notes`, `amount`
(with `inflow`/`outflow` options), `date` (day, month, year, recurrence
objects including weekend skip and an ended series), `account`
(including `onBudget`/`offBudget`), `category`, `category_group`, `cleared`,
`reconciled`. Operators: `is`, `isNot`, `oneOf`, `notOneOf`, `contains`,
`doesNotContain`, `matches`, `hasTags`, `hasAnyTag`, `gt`, `gte`, `lt`, `lte`,
`isapprox`, `isbetween`, `onBudget`, `offBudget`, wherever upstream defines
them for the field.

Actions (34): `set` of category, payee, transfer payee, `payee_name`, notes
(value, null, empty), cleared, reconciled, account, date, amount,
`imported_payee`; `prepend-notes`; `append-notes`; `set` with a `formula`
(notes, amount, date, cleared, `BALANCE_OF` by id and by name,
`category_name`); `set` with a Handlebars `template` (notes, amount, date,
regex helper, cleared); `link-schedule`; `delete-transaction`; and a
multi-field action.

Seeded condition, rank and join cases draw only from actions the production
preview can express (see below). The `gen-action-*` cases and the named cases
cover the rest.

## Named cases

Fixed ids that survive a seed change. Rules and Inputs are counts.

| Case | Rules | Inputs | What it checks |
| --- | --- | --- | --- |
| `control-no-rules` | 0 | 2 | No rules: runRules returns the transaction unchanged apart from derived fields. |
| `control-non-matching` | 1 | 1 | A rule whose condition matches nothing leaves the transaction unchanged. |
| `payee-is-resolved-payee-id` | 2 | 4 | A payee-is rule matches the resolved payee ID; a display name or an unresolved payee does not. |
| `imported-payee-raw-text` | 1 | 4 | An imported_payee rule matches the raw bank text case-insensitively and renames the payee. |
| `imported-payee-empty-null-absent` | 1 | 4 | imported_payee is "" matches empty and null text; an absent imported_payee is treated as empty by string conditions. |
| `imported-payee-firstchar-index` | 1 | 3 | imported_payee oneOf is found through the first-character rule index. |
| `notes-set-null-and-empty` | 2 | 3 | Rules that set notes to null and to an empty string, in separate stages. |
| `notes-prepend-append-empty-and-existing` | 2 | 3 | prepend-notes and append-notes on null, empty and populated notes. |
| `transfer-payee-set-by-rule` | 1 | 2 | A rule sets a transfer payee; the category and account stay as they are. |
| `payee-set-then-later-payee-rules` | 3 | 2 | A later payee-is rule sees the payee an earlier rule set, but payee_name is computed once before any rule runs. |
| `payee-isnot-single-condition` | 1 | 3 | A lone payee-isNot rule runs for every payee but the excluded one. |
| `index-excludes-or-rule-with-two-indexed-conditions` | 2 | 5 | A rule with both a payee and an imported_payee condition is indexed under both values, so a candidate lookup can skip it even when an or join would match. |
| `payee-absent-vs-null-id-conditions` | 3 | 3 | Id-typed conditions on an absent field never match, while null matches is-null. |
| `offbudget-account-sets-category` | 1 | 2 | A rule on an off-budget account sets a category. |
| `regex-special-characters-case-insensitive` | 2 | 3 | matches with escaped metacharacters; the pattern is lowercased and the text is lowercased. |
| `regex-uppercase-class-is-lowercased` | 1 | 2 | The value is lowercased before it is compiled, so \D in a pattern behaves as \d. |
| `amount-isapprox-boundaries` | 2 | 7 | isapprox uses a 7.5% rounded threshold: -10000 spans -10750..-9250; a small value has threshold 0. |
| `amount-isbetween-reversed-and-inclusive` | 2 | 5 | isbetween sorts its bounds and is inclusive; inflow and outflow options flip the sign handling. |
| `amount-zero-with-inflow-outflow-options` | 2 | 3 | A zero amount against inflow and outflow options. |
| `date-recurring-schedule-style-value` | 3 | 6 | date conditions with a recurrence object: exact, approximate, weekend skip and an ended series. |
| `date-month-and-year-values` | 2 | 3 | date is with a month value and a year value. |
| `schedule-rule-links-by-conditions` | 0 | 4 | A transaction without a schedule that matches a schedule rule gets the schedule linked; a completed schedule rule is still a rule upstream. |
| `schedule-attached-runs-its-rule-regardless-of-conditions` | 2 | 4 | A transaction already attached to a schedule runs that schedule rule without its conditions and skips other schedules rules. |
| `schedule-rule-with-plain-conditions-active-and-completed` | 0 | 3 | Schedule rules with an exact date and a payee: the active one links its schedule; upstream also links a completed schedule. |
| `link-schedule-action-then-later-rules` | 1 | 2 | A user rule links a schedule; the schedule is set on the output. |
| `same-field-last-rule-wins-within-stage` | 2 | 1 | Two rules set the same category in one stage; the higher-scored (is) rule runs later and wins over contains. |
| `same-field-stage-order` | 3 | 1 | Pre, default and post rules set the same category; post wins. Ids are the reverse of stage order. |
| `same-score-id-tie-break` | 2 | 1 | Two equally scored rules in one stage run in id order; the later id wins. |
| `rank-scores-by-operator` | 3 | 1 | A rule of only exact operators is scored double and runs after looser rules in the same stage. |
| `notes-unicode-and-case` | 4 | 4 | contains, matches and hasTags with accents, ligature-like capitals, a dotted capital I and emoji. |
| `hastags-edge-cases` | 1 | 6 | hasTags requires a whole tag: not a prefix, not a double hash, not mid-word. |
| `delete-transaction-then-later-rules` | 2 | 2 | delete-transaction sets the tombstone; later rules still run. |
| `formula-balance-of` | 3 | 4 | BALANCE_OF by account id, by name, for an unknown account, and on the same day as history. **Oracle-only:** production fail-closes formula set actions: a rule with one is not evaluated. |
| `balance-variable-in-templates-and-formulas` | 2 | 2 | The running balance variable in a template and in a formula. **Oracle-only:** production fail-closes Handlebars template actions; there is no template engine. |
| `formula-errors-and-non-numeric` | 4 | 1 | Invalid formulas and non-numeric results are reported in _ruleErrors and leave the field alone. **Oracle-only:** preview does not return _ruleErrors. |
| `template-edge-values` | 4 | 2 | Templates producing NaN amounts, invalid dates, booleans and helper calls. **Oracle-only:** production fail-closes Handlebars template actions; there is no template engine. |
| `payee-name-creates-or-reuses-payee` | 3 | 4 | Setting payee_name creates a payee when none has that name, reuses an existing one, and clears the payee for an empty name. **Oracle-only:** preview does not create payees or return payee_name. |
| `category-group-condition-after-category-change` | 3 | 2 | A category_group condition sees the group of a category set earlier in the chain. |
| `transfer-and-parent-conditions-in-run-rules` | 2 | 2 | transfer and parent conditions read fields runRules does not populate, so they match only when the input carries them. |
| `invalid-and-empty-rules-are-ignored` | 4 | 1 | A rule with an invalid operator, an invalid action field, or no conditions never runs; a valid rule still does. |
| `set-cleared-and-reconciled` | 2 | 2 | Rules set cleared and reconciled. **Oracle-only:** preview does not return reconciled. |
| `set-account-and-date-and-amount` | 3 | 2 | Rules change account, date and amount; a later rule reads the changed values. |
| `split-fixed-and-remainder-interaction` | 1 | 2 | Interaction check only (split math is covered by split-parity): fixed-amount and remainder splits from one rule. |
| `split-amount-formula-literal-and-balance-of` | 1 | 2 | Interaction check: set-split-amount with method formula, a literal and a BALANCE_OF value, with a remainder split. |
| `split-parent-fields-in-formula` | 1 | 1 | Interaction check: a split child formula reads the parent_* variables added in 26.10. **Oracle-only:** production fail-closes formula set actions: a rule with one is not evaluated. |

## Upstream behavior worth knowing

- **Candidate indexers.** `runRules` unions two indexers (`imported_payee` by
  first character, `payee` by value). A rule with no `imported_payee`
  condition is always a candidate through the first, and one with no `payee`
  condition through the second, so only a rule with *both* an indexed
  `payee` and `imported_payee` condition (`is`, `isNot`, `oneOf`, `notOneOf`)
  can be skipped. An `isNot` rule is indexed under its own value, so an `or`
  rule of two `isNot` conditions is skipped for most transactions even though it
  would match. See `index-excludes-or-rule-with-two-indexed-conditions`.
- **`payee_name`** is looked up once before any rule runs; a payee changed by an
  earlier rule updates `payee` but not `payee_name`.
- **`matches`** lowercases the pattern before compiling it, so `\D` behaves as
  `\d`. An invalid pattern never matches.
- **Absent versus null.** An absent id-typed field (`payee`, `category`,
  `account`) fails every operator, including `isNot` and `notOneOf`; `null`
  matches `is null`. String-typed fields treat both as empty text.
- **`transfer` and `parent` conditions** read fields `runRules` does not
  populate, so they match only when the input carries them.
- **Formula amounts.** `=amount * 2` and `{{balance}}`-style values go through
  `amountToInteger(round(x * 100) / 100)`, so a formula result for a minor-unit
  amount is scaled by 100 again. The oracle output is the truth; see the
  `formula-*` and `balance-variable-*` cases.
- **Template amounts** are not rounded: a template producing `12.5` leaves a
  fractional amount (`template-edge-values`).
- **Schedules.** A transaction with a `schedule` runs that schedule's rule
  without its conditions and skips other schedule rules. A completed schedule's
  rule is still an ordinary rule upstream.
- **26.10 `parent_*`** variables (`parent_notes`, `parent_imported_payee`,
  `parent_amount`, `parent_payee`, `parent_account`) exist only on split child
  actions; `split-parent-fields-in-formula` is the one case that reaches them.

## Swift replay

`ActualistTests/RuleOracleReplayTests.swift` and `RuleOracleReplaySupport.swift`
replay every non-oracle-only case through the production
`BudgetDatabase.previewRules(for:dateTimeZone:)` (the path Bank Sync and manual
entry use), with the time zone fixed to `America/New_York`.

- **Seeding.** Each case inserts the fixture's `input` tables (`accounts`,
  `category_groups`, `categories`, `payees`, `rules`, `schedules`,
  `transactions`) into a fresh starter database, after clearing the starter
  rows. Columns are the upstream names, as dumped.
- **Draft.** Each run's input transaction becomes a `TransactionDraft`: payee
  id, imported payee, notes, amount, account, category, cleared, reconciled,
  sort order and schedule come straight from the input. The date is that civil
  day in the fixed zone. `payeeName` is the seeded payee's name, and
  `isTransfer` is whether the payee is a transfer payee, as production sets
  them. `isParent` is false.
- **Compared** (whole value, exact numbers): `account`, `date`, `amount`,
  `payee`, `notes`, `category`, `cleared`, `schedule`, `deleted` (the
  tombstone), and `splits` (amount, category, payee, notes, sort order per
  child, in order). The preview reports an unchanged account, payee, amount,
  date and cleared as nil, so those fields are the preview overlaid on the
  draft; notes, category and schedule are the preview's own value.
- **Not compared, and why.**
  - `imported_payee`, `reconciled`: the preview does not return them. Cases
    whose rules set them are oracle-only.
  - Created payees (`payee_name` actions) and `_ruleErrors`: the preview creates
    no payees and reports no rule errors. Those cases are oracle-only.
  - `is_parent`, `error`, child `id`, `starting_balance_flag`: derived or
    minted by the oracle's split helper.
  - `evaluated` and `applied` lists: diagnostics with no Swift counterpart.
  - Runs whose input leaves `payee`, `category` or `account` absent (rather
    than null): a production draft always carries them, so absence cannot be
    expressed. Upstream fails every operator on an absent id field, `isNot`
    included. These runs are skipped by `isReplayable`; the other runs of the
    same case are still replayed.
- **Oracle-only because production fail-closes them:** formula `set` actions,
  Handlebars template actions, and any rule setting `imported_payee`,
  `reconciled` or `payee_name` (non-split `set` actions outside the editable
  fields leave the rule unevaluated). `set-split-amount` with a formula is
  supported and replayed.
- **No clock seam.** Rules read the wall clock only for the split-formula
  `today` variable (`RuleSplitActionExecutor.swift`, `today:` argument). No
  replayed case reads `today`, so the fixed fixture day is not injected.
- **Divergences.** Known differences are registered as OP-36 to OP-45 in
  `config/parity/known-divergences.json`. Each divergent case lists its exact
  `run.field` paths in the test, wrapped in `withKnownIssue`; every other
  field of the case stays strict.
- **Shared pools.** Seeded condition, rank and join cases leave out the
  actions behind OP-36, OP-37 and OP-38 (set account, delete-transaction,
  set-notes-to-empty) so each divergent case has one cause. The `gen-action-*`
  cases and the named cases exercise those actions on their own.

## Oracle-only cases

A case is `oracleOnly` (with the reason in the manifest) when its rules use
something the production preview (`previewRules`) cannot return or run:
`imported_payee`, `reconciled`, `payee_name` (new payee creation), formula `set`
actions and Handlebars templates (production fail-closes both) or `_ruleErrors`. They stay in the
fixture. The count and reasons are in `rules-manifest.json`.

## Scope notes

- Split actions are covered by `scripts/split-parity`; two split cases here are
  interaction checks only.
- The fixture records outputs for the transaction `runRules` receives. It does
  not test the persistence paths that call it (bank sync, import).
