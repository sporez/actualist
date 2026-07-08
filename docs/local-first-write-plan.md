# Local-First Write And Feature Restoration Plan

## Summary

This plan is now active. Local-first read parity has been marked complete, so the next goal is to restore writes conservatively while keeping Actual's native SQLite and CRDT sync model as the source of truth.

The first write proof should be narrow: create a transaction in Actualist, sync it through `/sync/sync`, verify it appears in Actual web, then pull it back into Actualist from SQLite. Broader mutation surfaces should remain disabled until the CRDT write substrate is proven.

## Current Baseline

- `LocalFirstActualStore` already conforms to the budget, account, and transaction repository protocols.
- Local-first reads load from `BudgetDatabase`, and sync currently pulls remote CRDT messages into SQLite.
- Supported local-first mutation methods apply CRDT messages locally, enqueue
  outbox rows, reload local caches, and then opportunistically flush.
- `BackendCapabilities` keeps write affordances hidden or disabled until each
  surface is implemented and the developer local-write gate is enabled.
- The existing transaction editor supports selecting an existing payee or typing a new payee name on the fly.

## Non-Negotiables

- Use a throwaway budget for every write proof until this plan is complete.
- Keep SwiftUI views out of SQLite and CRDT details. Writes must flow through repositories and store methods.
- Do not enable a UI write action until its local-first repository implementation has focused tests and a manual Actual web verification.
- After any successful write, pull/sync and reload the affected SQLite-backed read caches before the UI returns to clean state.
- Preserve existing Actualist behavior for custom payees: a typed payee name with no selected payee ID must create or resolve the payee as part of the transaction write.
- Leave unsupported mutation types explicitly blocked instead of attempting partial best-effort writes.

## Phase 0: Record The Read Gate

Status: complete. The read-only gate has passed and write implementation may begin.

Completed gate:

- Budget totals match closely enough for write work.
- Account balances match closely enough for write work.
- Account transaction feeds match closely enough for write work.
- Spending/search behavior matches closely enough for write work.
- Transfers, splits, hidden/closed/off-budget accounts, and tombstones are understood.
- Read-only controls do not risk mutating real data.
- Accepted differences and blocking issues are documented.

Acceptance:

- The checklist has a PASS decision.
- No blocking read parity mismatch remains before write implementation begins.

## Phase 1: Build The CRDT Write Substrate

Add the infrastructure needed to generate, apply, and sync local messages without enabling any user-facing write.

Implementation:

- Add a local CRDT message builder for:
  - dataset
  - row
  - column
  - serialized value
  - timestamp
  - message envelope
- Add Hybrid Logical Clock handling tied to the budget's persisted node ID.
- Add Actual sync value serialization for null, numbers, strings, and booleans using the same wire format that `BudgetDatabase` already decodes.
- Add `BudgetDatabase.applyLocalSyncMessages(...)` that atomically:
  - applies row/column updates to SQLite
  - inserts matching rows into `messages_crdt`
  - rejects unknown datasets or columns unless explicitly allowed
- Add `SyncClient.pushAndPull(...)` that:
  - pulls latest remote messages first
  - sends local message envelopes in `ActualSync_SyncRequest.messages`
  - applies returned remote messages
  - reports applied/pushed message counts for diagnostics
- Add a local mutation transaction boundary in `LocalFirstActualStore`:
  - require an open budget
  - pull latest
  - validate current local state
  - apply local messages
  - push and pull
  - invalidate and reload affected caches

Acceptance:

- Unit tests prove local messages are inserted into `messages_crdt` and reflected in SQLite reads.
- Duplicate and newer-message behavior still protects local state.
- Pull-only sync behavior remains unchanged for read refreshes.
- No UI write capability is enabled yet.

## Phase 2: First Write Proof - Create Transaction

Implement only simple transaction creation first, then prove end-to-end sync.

Initial scope:

- Single-account transaction.
- Non-split.
- Non-transfer.
- Existing category or uncategorized.
- Existing payee or typed new payee.
- Notes and cleared state.

Custom payee requirement:

- Match existing Actualist behavior: if `TransactionDraft.payeeID` is nil and `TransactionDraft.payeeName` is non-empty, local-first creation must create or resolve a real payee row before creating the transaction.
- The transaction should sync with the payee relationship Actual web expects, not remain as a local-only display string.
- If a case-insensitive matching live payee already exists, reuse it instead of creating a duplicate.
- If no matching payee exists, generate the payee CRDT messages and include the new payee ID in the transaction messages.
- After sync, reload payees/editor options so the new payee appears in future pickers.

Implementation:

- Replace `LocalFirstActualStore.createTransactionAndRefresh(...)` for the supported simple case.
- Keep split and transfer drafts blocked with a clear unsupported-write error.
- Generate transaction IDs and payee IDs using Actual-compatible IDs.
- Write the transaction and any new payee through CRDT messages, not direct ad hoc SQL.
- After sync, reload:
  - account transaction cache for the affected account
  - spending feed cache
  - account balances
  - selected budget month
  - budget alerts
  - editor payee/category options

Acceptance:

- Create a transaction with an existing payee in Actualist.
- Verify it appears in Actual web.
- Relaunch Actualist and verify it renders from SQLite.
- Create a transaction with a brand-new typed payee in Actualist.
- Verify the new payee and transaction appear correctly in Actual web.
- Create another transaction using that payee and verify Actualist reuses the payee ID.
- Edit the created row in Actual web, pull refresh in Actualist, and verify convergence.

## Phase 3: Transaction Mutation Parity

Restore transaction writes in increasing risk order.

Order:

1. Categorize an existing uncategorized transaction.
2. Edit simple transaction fields: date, account, amount, payee, category, notes, and cleared.
3. Delete a transaction using Actual's tombstone semantics.
4. Create and edit transfers.
5. Create and edit split transactions.

## Phase 4: Account Creation

Status: implemented for the existing Add Account sheet.

Scope:

- Create budget and off-budget accounts from `AccountsView`.
- Generate the `accounts` row through local CRDT messages.
- Generate the linked empty-name transfer payee when the budget schema supports
  `payees.transfer_acct`, plus payee mapping when present.
- Reload account displays from SQLite and enqueue pending sync messages.

Still out of scope:

- Initial balance entry.
- Bank linking or provider sync setup.
- Account edit, close, delete, reconcile, and bank sync actions.

Acceptance for each step:

- The repository method no longer throws `unsupportedWrite` only for the supported case.
- Unsupported variants stay blocked.
- Focused tests cover generated messages, cache reloads, and failure behavior.
- Manual verification confirms Actual web and Actualist converge after sync.

## Phase 4: Budget Writes

Restore budget-screen mutations only after transaction writes are stable.

Order:

1. Assign category budget amount.
2. Move money between categories and To Budget.
3. Cover overspending.
4. Apply category templates.
5. Apply month templates.

Implementation notes:

- Budget writes should target Actual's native budget tables through CRDT messages.
- The UI must not calculate final category availability or To Budget after submit.
- After sync, reload the budget month and alerts from SQLite.

Acceptance:

- Actual web and Actualist agree on category budgeted, spent, balance, To Budget, and overspending alerts after each write.
- Month switching and relaunch still render the updated state from SQLite.

## Phase 5: Account And Server-Backed Operations

Restore account and server-backed features last.

Order:

1. Add account.
2. Reconcile account.
3. Rule preview/apply.
4. Bank sync.

Notes:

- Add account is likely a native CRDT write.
- Reconcile may be a mix of transaction updates and cleared-state logic.
- Rule preview/apply needs confirmation against Actual core behavior before enabling.
- Bank sync should be treated as a separate server-operation proof followed by pull/diff, not as a normal local SQLite mutation.

Acceptance:

- Each operation has a clear local-first contract before UI enablement.
- Server-backed operations report progress and errors through existing view-model state.
- Read caches are refreshed from SQLite after completion.

## Phase 6: Offline Queue, Conflict Handling, And Hardening

Only start this phase once online writes work.

Scope:

- Offline pending-write queue.
- Retry and backoff.
- Sync status for pending, pushed, pulled, failed, and conflicted states.
- Conflict tests where Actual web edits the same row while Actualist has local changes.
- Encrypted-budget write support if encrypted budgets are in scope.
- Diagnostics for local node ID, latest HLC timestamp, pending message count, last sync error, and last applied remote count.
- Recovery tools for reimporting the budget and discarding pending local writes.

Acceptance:

- Online writes do not regress.
- Offline writes sync after reconnect.
- Conflict behavior is understood and documented before use with a real budget.

## Verification Ladder

Run verification in this order for each phase:

1. Focused local-first unit tests.
2. Full `ActualistTests`.
3. Simulator smoke against a throwaway Actual budget.
4. Actual web comparison.
5. Airy install/launch only after simulator proof.

## Suggested Commit Breakdown

1. `docs: add local-first write plan`
2. `feat: add local-first CRDT write substrate`
3. `test: cover local-first local message application`
4. `feat: create simple local-first transactions`
5. `test: cover local-first transaction creation`
6. `feat: support custom payees in local-first transaction creation`
7. Follow-up commits per restored mutation family.

## First Implementation Target

The first implementation target should be Phase 1 plus the smallest supported slice of Phase 2:

```text
typed or selected payee
single account
single transaction
optional category
optional notes
cleared flag
sync to Actual web
reload from SQLite
```

That proves the important part: Actualist can generate native Actual CRDT writes, push them through `/sync/sync`, and converge with Actual web while preserving the existing transaction editor behavior.
