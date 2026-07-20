# Local-First Current Write Model

This note records the current local-first write behavior after the hardening work
from July 6, 2026.

## Read And Refresh Lifecycle

SQLite is the durable local source of truth. `LocalFirstActualStore` keeps
in-memory projections of data already read from SQLite so repeated view
appearances can paint without another disk query; those projections are an
acceleration layer, not a second durable cache.

For a previously imported selected budget:

1. App launch opens the selected local SQLite database before presenting the
   main tabs.
2. Each data view paints from its in-memory projection when available and reads
   SQLite locally on appearance. View appearance never starts its own network
   request.
3. The app coordinator starts one coalesced CRDT sync per foreground session.
4. A successful sync applies remote messages to SQLite, reloads store
   projections, and publishes one data revision so visible views re-read their
   local state.
5. A failed or slow sync leaves the existing local content visible and only
   changes connection/error status.

Pull-to-refresh and every in-view refresh button use the same forced-refresh
operation: join any in-flight sync, otherwise pull CRDT messages once, then
re-read local data. Remote budget discovery is separate and occurs only during
onboarding, budget selection, or an explicit reimport.

## Write Flow

Local-first writes are local transaction first:

1. The feature view model builds an explicit write command.
2. `LocalFirstActualStore` validates that the requested `budgetID` matches the
   opened local database.
3. `LocalFirstSyncMessageBuilder` builds Actual CRDT messages for the mutation.
4. `BudgetDatabase` applies the messages to local tables and inserts the same
   messages into `actualist_outbox` inside one database transaction.
5. The UI reloads immediately from the local database.
6. The store opportunistically flushes the outbox when a sync path is available.

A local write is successful once the local database transaction succeeds. Remote
sync failure does not roll the local edit back.

## Durable Outbox

Pending local messages live in `actualist_outbox` with message identity, dataset,
row, column, serialized value, creation date, attempt count, last attempt date,
and last error.

`LocalFirstActualStore.flushPendingLocalMessages(...)` sends pending messages in
timestamp order through `SyncClient.pushAndPull`. Successfully pushed messages
are removed. Failed messages stay queued with retry metadata and are retried on
later sync attempts.

Manual Sync Now, budget open/foreground refresh, background refresh, and local
write completion can all attempt an outbox flush.

## Remote Merge Behavior

After a successful push, the sync client applies returned remote messages to the
local database and refreshes in-memory caches. Actual's CRDT sync semantics remain
the conflict model. Product-specific conflict resolution should only be added
after a concrete conflict case is observed.

## Current Product Write Coverage

These native local-first writes are normal product capabilities:

- Account creation, including the account row and its transfer payee.
- Simple transaction creation.
- Basic non-split, non-transfer transaction edits.
- Simple transaction deletion through Actual tombstone semantics.
- Categorizing existing transactions.
- Transfer and split transaction create/edit/delete.
- Category budget assignment.
- Move money.
- Category carryover changes.

## Current Limitations

- Provider bank-sync triggers are outside Actualist's app scope; the former menu
  action and repository contract have been removed.
- Reconcile and rule preview/apply remain unavailable.
- Budget templates remain behind the Experimental Features toggle and only
  support the ported deterministic fixed-amount behavior; unsupported template
  types are refused instead of approximated.
- Physical-device airplane-mode validation is still useful before broad shipping.
