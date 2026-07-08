# Actualist Web Parity Feature Roadmap

Date: 2026-07-08

## Purpose

This roadmap compares the current Actualist iOS app with the feature surface
offered by the Actual Budget web/PWA app, then orders the remaining work into
practical phases.

The intent is not to clone every web screen directly. Actualist should stay a
native, compact iOS client, but it should preserve Actual's budgeting semantics
and avoid partial write support that can silently mis-budget real data.

## Research Sources

Official Actual Budget references used for the web/PWA feature surface:

- Product overview: <https://actualbudget.org/>
- Budgeting: <https://actualbudget.org/docs/budgeting/>
- Categories: <https://actualbudget.org/docs/budgeting/categories/>
- Accounts: <https://actualbudget.org/docs/accounts/>
- Reconciliation: <https://actualbudget.org/docs/accounts/reconciliation/>
- Transactions and importing: <https://actualbudget.org/docs/transactions/importing/>
- Rules: <https://actualbudget.org/docs/budgeting/rules/>
- Bank sync: <https://actualbudget.org/docs/advanced/bank-sync/>
- Schedules: <https://actualbudget.org/docs/schedules/>
- Reports: <https://actualbudget.org/docs/reports/>
- Experimental features: <https://actualbudget.org/docs/experimental/>
- Budget templates: <https://actualbudget.org/docs/experimental/goal-templates/>
- Sync: <https://actualbudget.org/docs/getting-started/sync/>

## Current Actualist State

Actualist is already beyond the original read-only plan. The current app has:

- Local-first budget opening, sync, and offline read behavior.
- Encrypted budget support.
- Budget, Spending, Accounts, account transaction feeds, Settings, and
  uncategorized review surfaces.
- Search and pagination for transaction feeds.
- Background refresh alerts based on local-first sync plus transaction diffs.
- A durable local-first write outbox.
- Developer-gated write support for:
  - Simple transaction creation.
  - Basic transaction edits.
  - Transaction deletion through Actual tombstone semantics.
  - Categorizing existing transactions.
  - Transfer and split transaction create/edit/delete.
  - Category budget assignment.
  - Move money.
  - Fixed-amount budget templates.

Current known limitations:

- Local-first writes are still behind the developer write gate.
- Bank sync remains disabled in the native local-first path.
- Reconcile remains disabled.
- Account lifecycle writes beyond creation remain disabled.
- Rule preview/apply remains disabled.
- Budget templates only support deterministic fixed monthly amounts.
- Unsupported template types are correctly refused instead of approximated.
- Physical-device airplane-mode validation is still useful before broad write
  shipping.

## Actual Web/PWA Feature Surface

Actual Budget web/PWA includes these major feature groups:

- Local-first budgeting with multi-device sync and optional end-to-end
  encryption.
- Envelope budgeting, To Budget, rollover, move money, holding funds for next
  month, overspending handling, and budget shortcuts.
- Category and category group management, hidden categories, notes, delete and
  merge flows.
- Account management, including on-budget and off-budget accounts, add, rename,
  close, delete, and reopen flows.
- Transaction management, including manual add, import, splits, transfers,
  filtering, payees, tags, bulk actions, duplicate avoidance, and cleared state.
- Rules for automatic payee/category cleanup and other transaction automation.
- Bank sync via server-side providers such as SimpleFIN, GoCardless, Pluggy.ai,
  and related integrations.
- Reconciliation and cleared/locked transaction workflows.
- Schedules for recurring and one-time transactions, auto-add or manual approval,
  transaction matching, and suggestions.
- Reports, including cash flow, net worth, spending analysis, summary/calendar
  widgets, custom reports, and experimental report widgets.
- Experimental features including budget templates, budget automation,
  end-of-month cleanup, rule action templating, formula mode, balance forecast,
  budget analysis, Sankey reports, and payee locations.
- Budget templates covering simple, up-to, by-date, periodic, percent, schedule,
  average, copy, remainder, priorities, and goal directives.

## Roadmap

### Phase 1: Finish Budget Templates

Templates should be the next product slice. The app already has a ported fixed
monthly amount path, and the rest of the template system is the largest
partially-working gap.

Goals:

- Finish the allocation-core template types:
  - `copy`
  - `periodic`
  - non-zero priorities
  - available-funds clamp
  - `remainder`
  - `up to` limits
- Add aggregate-driven templates:
  - `average`
  - `percentage`
- Add schedule and time-spread templates:
  - `schedule`
  - `spend`
  - `by`
  - weekly cases
- Add goal and edge behavior:
  - `#goal`
  - refill
  - goal indicators
  - tracking-budget differences
  - orphan-goal cleanup
- Keep the refusal guard until each type has parity coverage.
- Add Actual-web parity checks per template type and mode before exposing broad
  user-facing support.

Release gate:

- A template apply in Actualist should either match Actual web or write nothing.
  No approximate template support should ship.

### Phase 2: Budget Workflow Parity

After templates, close the high-frequency budget management gaps.

Goals:

- Hold for next month and reset next-month buffer.
- Rollover negative category balances.
- Auto-hold income categories if supported by the selected Actual workflow.
- Budget shortcuts:
  - copy last month
  - set to average
  - set to spent
  - zero out
  - budget remaining
- Category and group lifecycle:
  - create
  - rename
  - hide/unhide
  - reorder if needed
  - notes
  - delete/merge
- Template and goal status indicators in category rows.

Release gate:

- Budget totals, category balances, To Budget, and overspending must reconcile
  against Actual web after every write.

### Phase 3: Transaction Workflow Parity

Actualist already has substantial transaction write support. This phase should
graduate it from developer proof to normal guarded product behavior.

Goals:

- Promote gated transaction writes after physical-device and offline validation.
- Clear and unclear transactions.
- Locked/reconciled transaction behavior.
- Tags.
- Richer transaction filters.
- Bulk actions.
- Rule preview/apply.
- Rule creation/update after payee/category edits.
- Keep file import lower priority unless mobile import becomes a clear need.

Release gate:

- Transaction edits must update affected account feeds, Spending, Budget, and
  relaunch/sync state consistently.

### Phase 4: Accounts, Bank Sync, And Reconciliation

This phase is important but more coupled to server-owned behavior and provider
integrations.

Goals:

- Reconciliation UI:
  - statement balance entry
  - cleared total
  - difference
  - lock/clear transactions
- Account lifecycle:
  - rename
  - notes
  - close
  - reopen
  - delete
- Bank sync triggers:
  - sync one linked account
  - sync all linked accounts
  - clear provider/server copy that credentials are server-side and not E2E
    encrypted
- Prefer local/off-budget account lifecycle before linked-account setup flows.

Release gate:

- Reconciliation must match Actual's cleared/locked semantics before it is
  enabled for real budgets.

### Phase 5: Schedules

Schedules are a separate product surface and should follow core
budget/transaction/account parity.

Goals:

- Read-only schedules list.
- Upcoming scheduled transactions in account feeds.
- Create/edit recurring schedules.
- Manual approval vs auto-add.
- Link transactions to schedules.
- Schedule matching and suggestions.
- Schedule-backed templates once the schedules model is reliable.

Release gate:

- Schedule-created transactions and manually matched transactions must sync and
  display the same way Actual web expects.

### Phase 6: Reports

Start with mobile-native reports instead of cloning the full dashboard builder.

Goals:

- Net worth.
- Cash flow.
- Spending by category.
- Spending by payee.
- Spending by account.
- Monthly income/expense summary.
- Budget analysis.
- Custom report builder later.

Release gate:

- Reports should be read-only and derived from local SQLite first. They should
  not block core budgeting/write parity.

### Phase 7: Power Features And Settings

These are lower priority unless they block trust, debugging, or daily use.

Goals:

- Export, backup, and restore workflows.
- Reset sync and reset local cache tools.
- Date, number, currency, and first-day-of-week settings.
- More sync/outbox diagnostics.
- Theme settings.
- Undo/redo only if the local CRDT/outbox model can support it cleanly.

## Recommended Next Step

Continue with Phase 1 and treat template parity as the next release-quality
milestone. The current app is already past read-only; the next risk is silent
mis-budgeting. The safest rule is:

```text
Template support either matches Actual web exactly or refuses to write.
```

Once template parity is complete, the write gate can be revisited with a much
stronger foundation.
