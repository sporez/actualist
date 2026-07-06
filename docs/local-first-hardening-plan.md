# Local-First Hardening Plan

This plan captures the code-review findings from July 6, 2026 and the intended fix order.

## Phase 1: Correctness Guardrail

Status: complete. `requireDatabase(for:)` now rejects mismatched opened budgets, with read/write regression tests.

1. Fix `LocalFirstActualStore.requireDatabase(for:)` so an opened database only serves its matching `budgetID`.
2. Add tests for cross-budget reads and writes:
   - Open budget A, request budget B month/accounts/transactions: throw.
   - Open budget A, attempt budget B mutation: throw.
3. Re-run the relevant tests.

## Phase 2: True Offline Local-First Writes

Status: complete. Durable outbox writes, local-write-first mutation flows, retry metadata, successful drain coverage, and Settings pending-sync visibility are implemented and covered by tests. Physical-device airplane-mode validation is still useful before shipping broadly.

The original write proof was network-first: it built CRDT messages, pushed them to the server, applied them locally, and then reloaded the UI. That proved message shape but gave up the main local-first advantage. The target model is local-first:

1. Add a durable local outbox table in the budget database with message identity, `timestamp`, `dataset`, `row`, `column`, serialized value, creation date, attempt count, last attempt date, and last error.
2. Change every local mutation flow from network-first to local-first:
   - Build messages.
   - Apply messages locally in one database transaction.
   - Insert the same messages into the outbox in that transaction.
   - Reload UI immediately from the local database.
   - Opportunistically drain the outbox if online, without blocking the local write result.
3. Make local apply plus outbox insertion atomic. A local write should either update local tables, insert CRDT messages, and enqueue outbound messages, or do none of those.
4. Add `LocalFirstActualStore.flushPendingLocalMessages(...)`:
   - Read pending outbox messages in timestamp order.
   - Send them through `SyncClient.pushAndPull`.
   - Apply returned remote messages.
   - Remove successfully pushed outbox rows.
   - Keep failed rows with error and attempt metadata.
   - Refresh caches after any local or remote changes.
5. Trigger outbox flush from manual Sync Now, budget open/foreground refresh, background refresh, and after local writes when a network path is available.
6. Surface sync state in the UI:
   - Local writes succeed immediately if the database transaction succeeds.
   - Show a pending-sync state while the outbox is non-empty.
   - Remote sync failures should not roll back local edits automatically.
   - CRDT/server merge behavior applies on the next pull unless a concrete conflict requires a product decision.

Acceptance:

- Airplane mode category assignment updates the budget immediately. Implemented at store/database level; device validation still pending.
- Relaunch offline preserves the pending local change. Covered by local store test.
- Reconnect and sync pushes the change to the server. Covered through the sync transport seam and outbox drain test.
- If server push fails, the outbox remains and retries later. Covered by failure metadata test.
- Tests cover offline write, app restart, retry, and successful drain.

## Phase 3: Security Hardening

Status: complete. ATS now allows cleartext only for local networking, remote HTTP
connection attempts are rejected before persistence, local HTTP shows a connection
warning, imported local-first budget artifacts are protected and excluded from
backups, and DEBUG network logs no longer include URLs with query strings,
headers values, or body snippets by default.

1. Replace global `NSAllowsArbitraryLoads` with a narrower App Transport Security policy.
2. Prefer HTTPS by default. Allow HTTP only for explicit local-network use, ideally with an insecure-connection warning.
3. Add file protection to imported budget databases, metadata, and temporary zip/import directories.
4. Decide whether budget databases should be excluded from backups, then set the file resource value accordingly.
5. Reduce DEBUG network logging:
   - No response bodies by default.
   - No file IDs or budget names unless diagnostics mode is enabled.
   - Keep endpoint, status code, and byte counts.

## Phase 4: Privacy

Status: complete. Background new-transaction notifications now use generic
preview content (`Actualist` / `New transactions found`) while preserving routing
metadata in `userInfo`; the debug notification confirmation no longer displays a
real account name. Detailed notification previews remain intentionally deferred
until there is an explicit opt-in setting.

1. Make background notification content generic by default:
   - Title: `Actualist`
   - Body: `New transactions found`
2. Respect the generic screenshot/privacy setting for all notification previews.
3. Consider a later explicit setting for detailed notification previews.

## Phase 5: Documentation And Drift

1. Update stale comments around budget-template support.
2. Document the write model:
   - Local transaction first.
   - Durable outbox.
   - Sync retry.
   - Remote merge behavior.
3. Add a short developer note for current limitations.

## Phase 6: File Splits

Split large files after behavior fixes so review stays clean:

1. `BudgetDatabase.swift` into read queries, transaction writes, budget writes, templates, sync apply, and schema helpers.
2. `BudgetView.swift` into picker, keypad, move-money, row, and banner components.
3. `LocalFirstActualStoreTests.swift` by sync/auth, reads, transaction writes, budget writes, and alerts.
4. `AccountTransactionsView.swift` into feed, row rendering, reconciliation, and delete/edit presentation.
5. `BudgetViewModel.swift` into assignment draft, move-money draft, alert derivation, and month helpers.
