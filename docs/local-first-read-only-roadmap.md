# Local-First Native Read-Only Roadmap

## Summary

This roadmap extends the local-first proving work after Budget and Accounts parity. The next goal is to make every existing Actualist view work in `BackendMode.localFirstSync` from the native Actual SQLite plus CRDT sync path, while keeping the entire local-first backend read-only.

REST mode must remain intact. Local-first mode should treat the normal Actual server, downloaded SQLite database, and applied CRDT messages as its source of truth. No write path should be attempted until read parity is solid across the app.

## Phased Plan

### Phase 0: Lock The Read-Only Contract

- Define local-first v1 as native read parity only: Budget, Accounts, Spending, account transactions, transaction detail/editor display, uncategorized review, Settings, budget switching, account ordering, theme, privacy mode, and diagnostics all render without REST.
- Keep all writes unavailable in local-first mode: budget assignment, move money, templates, add account, transaction create/edit/delete/categorize, bank sync, reconcile, rule preview/apply, and background refresh.
- Add a single local-first capability helper so views check one source for read-only availability instead of scattering backend checks.

### Phase 1: Harden Native Sync/Open As The Shared Read Refresh

- Make open-budget always follow this sequence: open imported SQLite, configure sync, pull/apply CRDT messages, refresh native caches.
- Add an explicit local-first refresh method used by Budget, Accounts, Spending, and Settings. It should pull CRDT messages, then invalidate and reload native read caches.
- Keep token, server URL, selected file/group id, metadata, and node id separate from REST settings and keychain storage.

### Phase 2: Finish Repository Seams

- Extend `TransactionRepositoryProtocol` to cover read surfaces currently coupled to `ActualDataStore`: cached account/spending pages, refresh, load older, search, editor options, and uncategorized transactions.
- Route `AppState.makeTransactionRepository()` to `LocalFirstActualStore` in local-first mode.
- Move `AccountTransactionsView`, `SpendingTransactionsView`, `UncategorizedTransactionsViewModel`, and transaction editor option loading off direct `appState.dataStore` access.
- Keep mutation methods on existing protocols for REST compatibility, but local-first implementations must throw `LocalFirstError.unsupportedWrite`.

### Phase 3: Native Transaction And Lookup Reads

- Add `BudgetDatabase` reads for payees, payee mappings, category mappings, transfer payees, account names, category names, transactions by account, spending/all-account transactions, search, pagination, split parents/children, tombstones, cleared/reconciled state, notes, imported payee, and transfer account display names.
- Base queries on Actual's semantics, not inferred REST shapes: use mapped category/payee ids, exclude split parents from totals, preserve split children for category display, and exclude children whose parent is tombstoned.
- Map rows into existing `ActualTransaction`, `LoadedAccountTransactions`, `TransactionEditorOptions`, and `LoadedUncategorizedTransactions` models so the UI stays mostly unchanged.

### Phase 4: Make Every View Read-Only Functional

- Budget: keep current native month parity, add local alert derivation only for view-only alerts that can open read-only sheets, and leave write actions hidden or disabled.
- Accounts: keep native balances and ordering; hide Add Account in local-first mode.
- Spending and Account Transactions: show transaction feeds, search, load older, balances, category/payee/account labels, split rows, transfer labels, and empty/loading/error states from SQLite.
- Transaction editor/detail: allow viewing transaction details using existing presentation where practical, but disable save, delete, payee/category mutation, rule preview, and split editing in local-first mode.
- Settings: show backend, selected native budget, sync status, last CRDT applied count/timestamp, account ordering, display density, theme, privacy mode, and local-first reset/reimport actions.

### Phase 5: Parity Audit Before Writes

- Add a documented parity checklist comparing Actual web vs Actualist local-first for budget month totals, account balances, account transaction lists, spending feed, search results, uncategorized transactions, transfers, splits, hidden/closed/off-budget accounts, tombstones, and multiple months.
- Use `docs/local-first-parity-checklist.md` as the manual throwaway-budget walkthrough for this audit.
- Add a read parity gate before any local-first write work begins.
- Keep write-design notes in a later section only: CRDT message generation, HLC/node id, conflict behavior, sync retry, and rollback strategy are out of implementation scope until the read gate passes.

## Interface Changes To Plan

- `TransactionRepositoryProtocol` becomes the single transaction read/write seam for both REST and local-first.
- `LocalFirstActualStore` conforms to `BudgetRepositoryProtocol`, `AccountRepositoryProtocol`, and `TransactionRepositoryProtocol`.
- `BudgetDatabase` remains the only local-first SQLite reader; SwiftUI views and view models never query GRDB directly.
- Add a small local-first sync status model for Settings with selected file, group id, last sync timestamp, last applied message count, and last error.

## Test Plan

- Unit tests for `BudgetDatabase` transaction reads: account feed, spending feed, search, pagination, payee/category mappings, transfer payees, splits, tombstones, off-budget handling, closed accounts, cleared/reconciled flags, notes, and imported payee.
- Repository tests for local-first `TransactionRepositoryProtocol`: cached pages, refresh after CRDT apply, load older, search, editor options, uncategorized transactions, and unsupported write errors.
- View-model tests for Budget, Accounts, Spending, account transactions, transaction detail/editor read-only state, uncategorized read-only state, and Settings account ordering in local-first mode.
- Verification ladder: focused local-first unit tests, full `ActualistTests`, simulator smoke, then Airy install/launch with a non-production Actual budget.

## Assumptions

- The existing Budget and Accounts local-first proof remains the baseline and should not be rewritten except to share refresh/status plumbing.
- All existing Actualist tabs and reachable sheets should render safely, but write-only workflows may be hidden in local-first mode.
- No local-first writes, rule application, bank sync, reconcile, or background refresh are attempted until the read-only parity checklist passes.
- Actual core remains the behavioral reference whenever SQLite interpretation is unclear.
