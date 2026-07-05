# Local-First Read Parity Checklist

Use this as a quick manual run before starting any local-first write work. The goal is not to build a perfect fake budget. The goal is to create enough ordinary Actual data that mismatches are easy to spot in Actualist.

Run this against a throwaway budget only.

## Test Budget Setup

Create a new Actual budget named:

- [ ] `Actualist Local-First Test`

Create these accounts:

- [ ] `Everyday Checking` - on budget, open
- [ ] `Rewards Credit Card` - on budget, open
- [ ] `Emergency Savings` - off budget, open
- [ ] `Old Closed Checking` - on budget, closed after adding one old transaction

Create these categories:

- [ ] `Food`
- [ ] `Gas`
- [ ] `Subscriptions`
- [ ] `Split Test`
- [ ] `Hidden Test` - hide it after adding one categorized transaction

Create data in the current month:

- [ ] Add income into `Everyday Checking`, categorized as income.
- [ ] Budget some money into `Food`, `Gas`, `Subscriptions`, and `Split Test`.
- [ ] Add a `Grocery Mart` transaction in `Everyday Checking`, category `Food`, with note `alpha-search`.
- [ ] Add a `Fuel Stop` transaction in `Rewards Credit Card`, category `Gas`.
- [ ] Add a `Streaming Service` transaction in `Rewards Credit Card`, category `Subscriptions`.
- [ ] Add an uncategorized `Mystery Store` transaction in `Everyday Checking`.
- [ ] Add a transfer from `Everyday Checking` to `Emergency Savings`.
- [ ] Add a split transaction in `Everyday Checking` with children in `Food` and `Split Test`.
- [ ] Add one transaction, then delete it, so tombstones exist in sync history.
- [ ] Add one transaction in last month so month switching has something to compare.
- [ ] Add one transaction in `Old Closed Checking`, then close the account.

Optional but useful:

- [ ] In Actual web, record screenshots or written values for budget totals, account balances, and the account transaction lists.
- [ ] Let Actual finish syncing before opening Actualist.

## Actualist Setup

- [ ] Install and launch the current build on Airy or simulator.
- [ ] Connect Actualist to the normal Actual server.
- [ ] Select `Actualist Local-First Test`.
- [ ] Open Settings and confirm the selected budget/file is shown.
- [ ] Pull to refresh or relaunch once so local-first sync has applied current messages.

## Budget Screen

Compare Actual web vs Actualist:

- [ ] Current month title matches.
- [ ] To-budget amount matches.
- [ ] Total budgeted matches.
- [ ] Total spent matches.
- [ ] Category group totals match.
- [ ] `Food`, `Gas`, `Subscriptions`, and `Split Test` balances match.
- [ ] Hidden category behavior is acceptable and documented.
- [ ] Uncategorized alert count includes `Mystery Store`.
- [ ] Overspending alert appears only if the test budget actually overspends.
- [ ] Read-only behavior is correct: budget/move/template write controls are hidden or blocked.

Notes:

```text

```

## Accounts Screen

Compare Actual web vs Actualist:

- [ ] `Everyday Checking` balance matches.
- [ ] `Rewards Credit Card` balance matches.
- [ ] `Emergency Savings` appears in the expected off-budget grouping.
- [ ] `Old Closed Checking` appears or stays collapsed according to the UI design.
- [ ] Account ordering matches the selected Actualist ordering.
- [ ] Add Account is hidden or blocked in local-first mode.

Notes:

```text

```

## Account Transactions

Open `Everyday Checking`:

- [ ] Transactions are newest first.
- [ ] `Grocery Mart` amount, date, payee, category, and note are correct.
- [ ] `Mystery Store` is present and uncategorized.
- [ ] Transfer row displays the linked account name correctly.
- [ ] Split parent displays correctly.
- [ ] Split children display correctly when the row is opened.
- [ ] Deleted transaction is not visible.
- [ ] Search for `alpha-search` finds `Grocery Mart`.
- [ ] Search for `Grocery` finds `Grocery Mart`.
- [ ] Opening a row shows details without allowing save/delete/category mutation.

Open `Rewards Credit Card`:

- [ ] `Fuel Stop` appears with `Gas`.
- [ ] `Streaming Service` appears with `Subscriptions`.
- [ ] Credit card balance sign/display matches Actualist's expected convention.

Notes:

```text

```

## Spending Feed

- [ ] Spending feed includes rows across `Everyday Checking` and `Rewards Credit Card`.
- [ ] Account labels are visible and correct.
- [ ] Off-budget transfer behavior matches Actual web/expected Actualist behavior.
- [ ] Search finds `Grocery Mart`.
- [ ] Search finds `Streaming Service`.
- [ ] Split rows behave consistently with account transactions.
- [ ] Deleted transaction is not visible.

Notes:

```text

```

## Uncategorized Review

- [ ] Budget alert opens the uncategorized review sheet.
- [ ] `Mystery Store` appears.
- [ ] Categorized, transfer, split parent, and deleted rows do not appear as uncategorized.
- [ ] Categorize/save controls are hidden, disabled, or fail cleanly as read-only.
- [ ] Closing the sheet returns to the budget screen cleanly.

Notes:

```text

```

## Month Switching And Refresh

- [ ] Switch to last month.
- [ ] Last-month transaction appears in the right month.
- [ ] Current-month-only transactions do not leak into last month views.
- [ ] Switch back to current month.
- [ ] Pull/refresh sync does not duplicate rows.
- [ ] Relaunch Actualist and confirm the selected budget reopens.
- [ ] Turn network off, relaunch, and confirm already-imported budget data still renders.

Notes:

```text

```

## Background Refresh Alerts

This validates the read-only background sync alert path.

- [ ] Enable New Transaction Alerts in Settings.
- [ ] Send Actualist to the background.
- [ ] In Actual web, add a new transaction to `Everyday Checking`.
- [ ] Wait for background refresh or manually bring the app forward and background it again.
- [ ] If an alert fires, it names the account and count correctly.
- [ ] Opening the alert navigates to the right account.
- [ ] The new transaction is highlighted or marked pending-new if that UI is visible.
- [ ] Updating an existing transaction does not create a false "new transaction" alert.
- [ ] Deleting a transaction does not create a false "new transaction" alert.

Notes:

```text

```

## Final Gate

Do not start local-first write work until this section is filled out.

- [ ] Budget totals match closely enough for write work.
- [ ] Account balances match closely enough for write work.
- [ ] Account transaction feeds match closely enough for write work.
- [ ] Spending/search behavior matches closely enough for write work.
- [ ] Transfers, splits, hidden/closed/off-budget accounts, and tombstones are understood.
- [ ] Read-only controls do not risk mutating real data.
- [ ] Any accepted differences are listed below.
- [ ] Any blocking differences have an issue or follow-up note.

Accepted differences:

```text

```

Blocking issues:

```text

```

Decision:

- [ ] PASS: Local-first read parity is good enough to begin write design.
- [ ] FAIL: Fix blocking read parity issues before write design.
