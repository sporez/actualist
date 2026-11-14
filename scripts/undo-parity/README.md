# Undo parity harness

Generates the Undo fixture from Actual's own handlers and `undo()` at the pinned release
(`config/parity/oracle-pin.json`, v26.11.0). This directory holds only the generator side.
`UndoOracleReplayTests` replays every case through the production store and History undo.

- `generate.mjs`: runs the plan inside the oracle checkout under vitest and writes the fixture.
  `--check` regenerates into a temporary directory and diffs against the committed fixture. The
  Actual sources it depends on are pinned by sha256 in the file.
- `verify.mjs`: checks the committed fixture against the manifest and `cases.mjs`, and that the
  Payees undo lists partition the Payees fixture. Needs no oracle.
- `cases.mjs`: the seed world, the 10 case ids with their user input, and the Payees undo lists.
  Pure input, no expectations.
- `oracle-runner.template`: the vitest test copied into the oracle for one run and removed afterwards.
- Fixture: `ActualistTests/Fixtures/ActualCore26_11_0/Undo/` (`undo-contract.json`, `undo-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/undo-parity/generate.mjs [--check]
node scripts/undo-parity/verify.mjs
```

The oracle checkout must be at the pinned commit with a clean tree and `yarn install` done. It is
checked before and after the run and is never written to except for the temporary runner. Synthetic
data only.

## What a case is

The world is an envelope budget seeded through upstream's db functions with explicit ids: accounts
`acct-checking` and `acct-card`, an expense group with `cat-groceries`, `cat-dining` and `cat-bills`
(plus an empty income group, which Actual's envelope summary needs to build the sheet), payee
`payee-grocer` and the two transfer payees, 2026-09 budgets (groceries 40000, dining 10000) and the
transactions `t-simple`, `t-uncat`, `t-split` (children `t-split-1` and `t-split-2`) and the transfer
pair `t-xfer` (checking leg) and `t-xfer-card`. The clock is frozen at 2026-09-15.

Each case builds the payload the mobile UI sends, calls the real handler through `runHandler`, then
calls `undo()` once per undoable call:

| Case | Actual source | Sent |
| --- | --- | --- |
| assign | `mobile/budget/BudgetCell.tsx` -> `budget/mutations.ts` `useBudgetActions` | `budget/budget-amount {month, category, amount}` |
| move | `mobile/budget/ExpenseCategoryListItem.tsx` -> `useBudgetActions` | `budget/transfer-category {month, amount, from, to, currencyCode}` |
| create | `mobile/transactions/TransactionEdit.tsx` (`onSave`, `realizeTempTransactions`, `diffItems`) | `transactions-batch-update {added, deleted, updated, learnCategories: true}` |
| edit | `PayeeAutocomplete.tsx` (`handleSelect`), `payees/mutations.ts`, then `TransactionEdit.tsx` `onSave` | `payee-create {name}`, then `transactions-batch-update {updated: [{id, amount, payee}], learnCategories: true}`; two undo steps |
| delete | `TransactionEdit.tsx` `onDelete` (`deleteTransaction` from `shared/transactions.ts`) | `transactions-batch-update {deleted}` (a split sends parent and children) |
| categorize | `TransactionEdit.tsx` `onSave` | `transactions-batch-update {updated: [{id, category}], learnCategories: true}` |
| batch-delete | `hooks/useTransactionBatchActions.ts` `onBatchDelete`, used by `mobile/transactions/TransactionList.tsx` | `transactions-batch-update {added, deleted, updated}` |
| batch-categorize | `useTransactionBatchActions.ts` `onBatchEdit` (`category`) | `transactions-batch-update {added, deleted, updated}` |

The mobile payloads are built with the client's own shared helpers (`updateTransaction`,
`deleteTransaction`, `diffItems`, `applyChanges`, `realizeTempTransactions`). The mobile new-transaction
screen also calls `rules-run` per field; the world has no rules, so that call is not made.

Per case the contract records `handlerCall` (the ordered list of calls sent), `handlerResults`,
`handlerError` (an observation), `messages` and net `writes` for the action, `undoCalls`,
`undoMessages` and net `undoWrites`, and `rowsBefore`, `rowsAfterAction` and `rowsAfterUndo`. Rows:
`transactions` (the physical columns the transaction-command harness records), `zero_budgets` for
2026-09, `payees` and `payee_mapping`. Minted ids (`id1`, ...) are `uuid-N` by first appearance.

## Swift replay

`UndoOracleReplayTests` seeds `world`, performs the action through the production store write the UI
uses, undoes the newest History record with `undoBudgetActionAndRefresh(actionID:budgetID:)` and
compares `outcome` (`applied` or `blocked`), `rowsBefore`, `rowsAfterAction`, the net `undoWrites`
(outbox messages the undo appended) and `rowsAfterUndo`. `sort_order` is not compared.

| Case | Store entry point |
| --- | --- |
| assign | `assignCategoryBudgetAndRefresh` |
| move | `moveMoneyAndRefresh` with `BudgetMoveMoneyCommand.move` |
| create, edit | `TransactionDraftBuilder.makeSubmissionDraft`, then `createTransactionAndRefresh` / `updateTransactionAndRefresh` |
| delete | `deleteTransactionAndRefresh` |
| categorize | `categorizeTransactionAndRefresh` |
| batch-delete, batch-categorize | `reviewTransactionBatch`, then `commitTransactionBatch` |

The Payees fixture's recorded `undo` is replayed too (no new generation): the Payees suite's own
seeding and command, then `undoLastPayeeMutationAndRefresh`, compared on the undo's net writes and the
rows after it. The manifest's `payeeUndo` lists the Payees case ids replayed and the ones not, with
reasons (no call sent, Actualist refuses the command, or Actual's undo failed: `learn-global-off`
throws `SyncError: invalid-schema`).

## Not covered

- Duplicate and merge: `TransactionCommandOracleReplayTests` already replays them against Actual's undo.
- The template action: too broad for this step.
- Categories and account groups: Actualist has no undo for them.
