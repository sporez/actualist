# Plan: Paginated transactions (large-feed performance)

Status: local-first row-count windowing implemented; older REST/date-window notes retained as historical context.

## Local-first implementation

The local-first app now loads account and Spending feeds as bounded SQLite windows:

- Initial account and Spending loads fetch 100 top-level rows.
- Split children are included with a selected split parent, so paged feeds do not render incomplete split rows.
- `loadOlderTransactions` and `loadOlderSpendingTransactions` append the next 100-row window and update `reachedEnd`.
- Refreshes, remote-sync reloads, and post-write reloads replace the currently loaded window instead of rebuilding full history.
- Account mutation paths still populate affected account caches with a bounded first page so write flows can immediately show fresh local state.
- Screen load order is local-first: the local window is rendered before network sync/revalidation runs.

## Context

`ActualAPIClient.transactions(budgetID:accountID:)` fetches an account's **entire history**
with `since_date=1900-01-01` — no window, no paging. For accounts with tens of thousands of
transactions this means a large JSON payload, a full `[ActualTransaction]` decode, the whole
array held in memory, and a 12s request timeout that a big history can blow. The SWR data
store (`ActualDataStore`) removed the *refetch-every-visit* cost, but the first load of a large
account is still heavy.

Goal: load a recent window first (fast first paint, small payload) and lazily load older
transactions on demand, **without** weakening the existing "never show stale data" guarantee.

### Key facts that make this safe

- **The displayed "Working Balance" comes from the separate `/balance` endpoint**
  (`AccountTransactionsView` reads `loaded.balance`, fetched independently in
  `ActualDataStore.refreshAccountTransactions`). Paginating the transaction *list* therefore
  never changes the displayed balance — correctness is independent of how many rows are loaded.
- The list is already grouped and sorted by date descending (`TransactionGrouping`), so a
  date-windowed model maps naturally onto the UI.
- The API supports `since_date` (required), `until_date` (optional), and `page`+`limit`
  (both-or-neither). The 200 response is a bare `data: [Transaction]` array — **no total count
  and no next-page cursor.**

## Approach: date-windowed, open recent bound (recommended)

Model the loaded data as a single contiguous date range with an **open upper bound**:
`[oldestLoadedDate, +∞)`. A single `oldestLoadedDate` fully describes what is currently loaded.

- **Initial load:** `since_date = today − windowSize`, no `until_date`. The open upper bound also
  catches today/future-dated transactions.
- **Load older:** fetch the delta window `[oldestLoadedDate − windowSize, oldestLoadedDate − 1d]`
  and prepend; move `oldestLoadedDate` back. If the delta is empty and we've passed the account's
  earliest activity, set `reachedEnd = true`.
- **Refresh / SWR revalidate / post-write invalidation:** refetch `[oldestLoadedDate, +∞)` and
  **replace** the loaded set. Refetching the whole loaded range (not merge-append) is what makes
  edits, **deletes**, and date-moves correct — a merge-by-id that only adds would leave deleted
  rows on screen. The cost is bounded by what the user has actually paged into view.

### Why not `page`+`limit`

Offset pages drift when a write inserts/deletes a row, producing duplicates or skips on the next
fetch, and with no total/cursor we can only detect the end by a short page. Date windows are
idempotent (a range refetch is authoritative for that range), which preserves the
never-stale guarantee through mutations. Date-windowing wins on correctness.

### Trade-off to note

Refetching the full loaded range on every background revalidate undercuts pagination for a user
who has paged very deep. Optional refinement (defer until measured): background SWR refetches
only the most-recent window, while explicit pull-to-refresh refetches the full loaded range.

## Implementation phases

**Phase 1 — API client.** Add `since_date` / `until_date` parameters to
`ActualAPIClient.transactions(budgetID:accountID:since:until:)` (default `since` keeps current
behavior only where still needed). Unit-test the query-item construction.

**Phase 2 — Store model.** Replace the plain `transactionsByAccount` value with a small
`AccountTransactionsPage { transactions, oldestLoadedDate, reachedEnd }` cache entry. Add:
- `loadInitialTransactions(budgetID:accountID:)` — recent window.
- `loadOlderTransactions(budgetID:accountID:)` — delta window, prepend, update `reachedEnd`.
- Update `refreshAccountTransactions` (used by appear/refresh/invalidation) to refetch
  `[oldestLoadedDate, +∞)` and replace, preserving `oldestLoadedDate`.
- `cachedAccountTransactions` composes from the page's `transactions` (unchanged shape).
- Keep balance + categories/payees exactly as today (balance stays independent).
Tests: initial window, load-older extends the range, `reachedEnd` on empty delta, write
invalidation replaces the range (deleted row disappears; date-move out of window drops it), and
that balance is untouched by windowing.

**Phase 3 — View.** `AccountTransactionsView` gains a bottom sentinel that calls
`loadOlderTransactions` when it appears (auto-load on scroll), plus a footer state
(spinner / "Load older transactions" / "Beginning of history"). Grouping already recomputes via
the existing `.onChange(of: transactions)`.

**Phase 4 — Tune + verify.** Pick `windowSize` (see decisions). Update the integration tests
whose stubs assert `since_date=1900-01-01` to the windowed `since_date`. Build + install to a
device and verify against a large account: fast first paint, smooth older-loading, balance
correct, and that editing/deleting a visible transaction still updates without stale rows.

## Files

- `Actualist/API/ActualAPIClient.swift`, `Actualist/API/ActualAPIClientProtocol.swift`
- `Actualist/Data/ActualDataStore.swift`
- `Actualist/Features/Transactions/AccountTransactionsView.swift`
- Tests: `ActualistTests/ActualDataStoreTests.swift`, and the windowed `since_date` update in
  `ActualistTests/TransactionEditorViewModelTests.swift`.

## Decisions to confirm before implementing

1. **Window unit/size.** Date-based (e.g. 90 days per window) vs a transaction-count target.
   Date-based fits the grouped timeline; count-based gives predictable payloads on heavy accounts.
2. **Older-loading UX.** Auto-load on scroll (recommended) vs an explicit "Load older" button.
3. **Background-refresh scope.** Refetch the full loaded range every revalidate (simplest,
   strongest freshness) vs recent-window-only for background + full range on pull-to-refresh.

## Out of scope

- Offline/disk persistence of transactions (separate effort).
- Search across full history (would need a server-side search endpoint or full fetch).
