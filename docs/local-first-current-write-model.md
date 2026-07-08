# Local-First Current Write Model

This note records the current local-first write behavior after the hardening work
from July 6, 2026.

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

## Current Write Coverage

The developer write gate currently enables:

- Account creation, including the account row and its transfer payee.
- Simple transaction creation.
- Basic non-split, non-transfer transaction edits.
- Simple transaction deletion through Actual tombstone semantics.
- Categorizing existing transactions.
- Transfer and split transaction create/edit/delete.
- Category budget assignment.
- Move money.
- Fixed-amount budget templates.

## Current Limitations

- Local-first writes are still behind the developer write gate.
- Bank sync, reconcile, and rule preview/apply remain disabled in local-first
  write testing.
- Budget templates only support the ported deterministic fixed-amount behavior;
  unsupported template types are refused instead of approximated.
- Physical-device airplane-mode validation is still useful before broad shipping.
