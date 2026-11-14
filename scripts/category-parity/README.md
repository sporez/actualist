# Category parity harness

Generates the category fixture from Actual's own handlers at the pinned release
(`config/parity/oracle-pin.json`, v26.11.0). This directory holds only the generator
side. `CategoryOracleReplayTests` replays every case through the production store's
category commands.

- `generate.mjs`: runs the plan inside the oracle checkout under vitest and writes the
  fixture. `--check` regenerates into a temporary directory and diffs against the
  committed fixture. The Actual sources it depends on are pinned by sha256 in the file.
- `verify.mjs`: checks the committed fixture against the manifest and `cases.mjs`.
  Needs no oracle.
- `cases.mjs`: the seed world and the 37 case ids with their user input. Pure input, no
  expectations.
- `oracle-runner.template`: the vitest test copied into the oracle for one run and
  removed afterwards.
- Fixture: `ActualistTests/Fixtures/ActualCore26_11_0/Categories/`
  (`categories-contract.json`, `categories-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/category-parity/generate.mjs [--check]
node scripts/category-parity/verify.mjs
```

The oracle checkout must be at the pinned commit with a clean tree and `yarn install`
done. It is checked before and after the run and is never written to except for the
temporary runner, which is removed in a `finally`. Synthetic data only; nothing touches
a server, a real budget or Actualist persistence.

## What a case is

The world is an envelope budget seeded through upstream's own db functions
(`insertAccount`, `insertCategoryGroup`, `insertCategory`, `insertTransaction`, `db.insert`
for `zero_budgets`) with explicit ids: five groups (one empty, one hidden, one income),
eleven live categories (one hidden), one tombstoned category mapped to a live one, four
transactions and seven budget rows in 2026-08 and 2026-09. `insertCategory` puts a new row
at the front of its group, so the runner then pins each category's `sort_order` to its
listed position times 16384. The spreadsheet is loaded (`loadSpreadsheet`, `createBudget`
over `createdMonths` 2026-08 and 2026-09) because `must-category-transfer` and the transfer
in `category-delete` read it. The clock is frozen at 2026-09-27 (`TODAY` in `cases.mjs`).
The world's raw rows are dumped once as the contract's top-level `world`.

Each case does what Actual's UI sends (`desktop-client/src/budget/mutations.ts`) and calls
the real handler through `runHandler`. The "list" below is the client's category query
(`budget/queries.ts`: `send('get-categories')`); the runner calls the same handler.

| Action | Actual source | Sent |
| --- | --- | --- |
| Create category | `useSaveCategoryMutation` + `useCreateCategoryMutation` | nothing when another category in the target group has `name.toUpperCase()` equal to the typed text's (untrimmed); else `category-create {name, groupId, isIncome, hidden: false}` (the handler trims) |
| Rename category | `useSaveCategoryMutation` + `useUpdateCategoryMutation` | the same check against the other categories of the group; else `category-update` with the category entity from the list, `name` set to the typed text (the handler trims) |
| Hide, unhide category | `useSaveCategoryMutation` | the same check (it passes); `category-update` with the entity and `hidden` flipped |
| Create group | `useCreateCategoryGroupMutation` | `category-group-create {name}`; no client check, the server refuses an upper-case duplicate |
| Rename, hide, unhide group | `useUpdateCategoryGroupMutation` | nothing when another group has the same upper-case name; else `category-group-update` with the group entity minus `categories` |
| Move category | `useReorderCategoryMutation` | nothing when the target group has another category with the same upper-case name; else `category-move {id, groupId, targetId}` (`targetId` is the category to insert before, `null` is the end) |
| Move group | `useMoveCategoryGroupMutation` | `category-group-move {id, targetId}` |
| Delete category | `useDeleteCategoryMutation` | `must-category-transfer`; when true `category-delete {id, transferId}` with the case's transfer category, else `category-delete {id}` |
| Delete group | `useDeleteCategoryGroupMutation` | `must-category-transfer` for each category until one is true; then `category-group-delete {id, transferId}` or `{id}` |

`useDeleteCategoryFlow.ts` (the mobile delete confirmation) asks `must-category-transfer`
the same way; its source is pinned too. The recorded `mustTransfer` of a delete case is
the result Actual's UI acted on.

Per case the contract records `input`, `handlerCall` (method and payload sent, or `null`),
`handlerResult`, `handlerError` (an observation, never an expectation), `mustTransfer`
(delete cases), `messages` (every CRDT message in order), `writes` (the net cell writes:
the last value per dataset, row and column, sorted), `rows` (`category_groups`,
`categories`, `category_mapping` and the `zero_budgets` rows of 2026-08 and 2026-09 after
the action), `order` (live groups in Actual's `getCategoriesGrouped` order, each with its
live category ids) and `undo` (loot-core's `undo()` called once after the action: its
messages, rows and order; `null` when nothing was sent).

Three read cases send no write. `read-must-transfer` records `must-category-transfer` for
every live category; `read-outline` records the groups and categories of `get-categories`
(ids, names, hidden); `read-deleted-category-display` tombstones `cat-dining` with
`db.delete_` (another device's delete, no transfer), records the resulting `categories`
and `category_mapping` rows as `stateRows` so the replay can seed them, and records the
AQL read `transactions` of `acct-checking` with `category` and `category.name`.

Ids Actual mints (`id1`, ... from the loot-core uuid mock) are `uuid-N` by first
appearance in the case. Names and values are never normalized.

## Swift replay

`CategoryOracleReplayTests` seeds the `world` into a starter-schema database (starter rows
of the seeded tables and of `preferences` are deleted first; a read case's `stateRows`
replace whole tables), calls the production store method for the case and compares:

- `writes`: the net writes derived from the outbox messages the action appended, with the
  id the store mints aliased to `uuid-1`;
- `rows` and `order`: the same tables, and the groups of the Budget screen's month read
  (`budgetMonth(...).month.categoryGroups`) as ids;
- `outcome`: `ok` or `refused`, only for a case where Actual's UI sends a call;
- `actualistNeedsTransfer` (delete cases): Actualist's own transfer decision
  (`categoryNeedsTransfer`, for a group asked per category as
  `BudgetCategoryDeletionWorkflow.prepareGroup` does) against Actual's `mustTransfer`.
  The delete itself is called with the transfer category Actual's call carried.

Production calls are `createCategoryAndRefresh`, `createCategoryGroupAndRefresh`,
`renameCategoryAndRefresh`, `renameCategoryGroupAndRefresh`, `setCategoryHiddenAndRefresh`,
`setCategoryGroupHiddenAndRefresh`, `deleteCategoryAndRefresh`,
`deleteCategoryGroupAndRefresh`, and for moves a `BudgetCategoryOutlineDraft` built from
the month's category groups (as `BudgetCategoryReorderWorkflow.begin` does) whose
`moveCategory`/`moveGroup` result `command` goes to `applyCategoryOutlineAndRefresh`. The
reads use `categoryNeedsTransfer`, `budgetMonth` and `loadedAccountTransactions` (category
id and the category name the transaction list shows).

The recorded `undo` is not replayed by this suite; it is kept for a later undo oracle.
