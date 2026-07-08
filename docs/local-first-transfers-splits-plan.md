# Local-First Transfers & Splits Plan (Phase 3, Steps 4–5)

## Goal

Finish Phase 3 ("Transaction Mutation Parity") to 100% by adding **create, edit,
and delete of transfers and split transactions** to the local-first store, so
Actualist and Actual web converge after sync. This is the last and riskiest slice
of Phase 3; everything here mutates real budget rows through CRDT messages.

Steps 1–3 (categorize, simple-field edit, simple delete) are already landed. This
plan covers the remaining steps 4 (transfers) and 5 (splits), plus the delete
behavior those shapes require.

## Progress Tracker

Living checklist — updated as work lands so a new agent can resume mid-stream.
`[x]` done, `[~]` in progress, `[ ]` not started. Notes call out the commit/sha.

**Commit 1 — plan doc**
- [x] Write and save this plan.
- [x] Commit the plan doc. (sha e5a3d42)

**Commit 2 — create transfers & splits** (sha dd24b19)
- [x] `BackendCapabilities`: add `canWriteTransfers` / `canWriteSplits`.
- [x] `BudgetDatabase.createTransferTransactionMessages`.
- [x] `BudgetDatabase.createSplitTransactionMessages`.
- [x] `LocalFirstActualStore.createTransactionAndRefresh` dispatch (transfer/split/simple).
- [x] Fixture: add `transferred_id` + `isChild` columns, 2nd account + transfer payees.
- [x] Tests: create transfer (test 1), create split (test 2), split mismatch (test 3).
- [x] Capability truth-table updates (test 10) across all 7 blocks.
- [x] Full `ActualistTests` green; commit.

Note: shared helpers `resolveTransactionRowColumns` + `transactionRowMessages` in
BudgetDatabase build any row shape (source/paired/parent/child); reused by edit.
Also `transferDestinationAccountID` / `transferPayeeID(forAccount:)` resolvers.

**Commit 3 — edit transfers & splits** (sha fec83ed)
- [x] `BudgetDatabase.updateTransactionMessages` (main row + child diff + transfer transitions).
      Replaced `updateSimpleTransactionMessages`; returns `TransactionWriteResult`
      (messages + affected accounts/transactions). Removed dead
      `validateSimpleTransactionReferences`.
- [x] `LocalFirstActualStore.updateTransactionAndRefresh` dispatch + affected-cache reload.
- [x] Tests: edit split child add/remove/amount (test 4), simple↔transfer (test 5),
      transfer amount/dest repoint (test 6), simple↔split (test 7). Fixture gained a
      third account (`savings` + transfer payee) for the destination-repoint test.
- [x] Full `ActualistTests` green; commit.

**Commit 4 — delete complex + UI unblock** (this commit)
- [x] `BudgetDatabase.deleteTransactionMessages` (parent+children, transfer remove).
      Replaced `deleteSimpleTransactionMessages`; returns `TransactionWriteResult`.
- [x] `LocalFirstActualStore.deleteTransactionAndRefresh` dispatch + affected-cache reload.
- [x] UI: replaced `isComplexTransactionEdit` with `writesAllowed(_:)` (shape→capability),
      simplified editor read-only notice, account-view delete gated by row shape
      (`canWriteSplits`/`canWriteTransfers`/`canDeleteTransactions`), settings copy.
- [x] Tests: delete split parent (test 8), delete transfer (test 9).
- [x] Full `ActualistTests` green (128 tests); lint passed; commit.

**Post-implementation (owner: user)**
- [ ] Simulator smoke on a throwaway budget.
- [ ] Actual-web convergence for create/edit/delete of transfer and split.

## Source Of Truth

All semantics below were taken from the bundled Actual engine (loot-core) during
source inspection. This path is a historical reference only; Actualist does not
depend on `actual-http-api` at runtime:

`/Users/neil/CC/actual-http-api/node_modules/@actual-app/api/dist/index.js`

Key regions referenced:

- `../loot-core/src/server/transactions/transfer.ts` — `addTransfer`,
  `removeTransfer`, `updateTransfer`, `onInsert`, `onUpdate`, `onDelete`,
  `clearCategory`, `getPayee`, `getTransferredAccount`.
- `../loot-core/src/server/transactions/index.ts` — `batchUpdateTransactions`,
  `idsWithChildren`.
- `../loot-core/src/shared/transactions.ts` — `makeChild`, `recalculateSplit`,
  `splitTransaction`, `updateTransaction`, `deleteTransaction`.
- `../loot-core/src/server/aql/schema/index.ts` — transactions schema + defaults.
- schemaConfig `views.transactions.fields` — AQL field → physical column map.
- `data/migrations/1614782639336_trans_views2.sql` — the read view.

**Do not re-derive these from memory. This plan is the frozen contract.**

## Authoritative Data Model

CRDT messages are written with **physical column names** (loot-core `insert`
runs `convertForInsert` → `conform`, which maps each AQL field to its physical
column via `fieldRef` before emitting one message per non-null field).

AQL field → physical column (transactions):

| AQL field       | Physical column        | Notes |
|-----------------|------------------------|-------|
| `account`       | `acct`                 | required |
| `payee`         | `description`          | resolves through `payee_mapping` |
| `is_parent`     | `isParent`             | boolean (camelCase) |
| `is_child`      | `isChild`              | boolean (camelCase) |
| `transfer_id`   | `transferred_id`       | id of the paired transfer row |
| `imported_id`   | `financial_id`         | not touched here |
| `imported_payee`| `imported_description` | not touched here |
| `category`      | `category`             | resolves through `category_mapping` |
| `parent_id`     | `parent_id`            | id of the split parent |
| `amount`        | `amount`               | integer minor units, required |
| `date`          | `date`                 | integer `YYYYMMDD`, required |
| `notes`         | `notes`                | |
| `cleared`       | `cleared`              | boolean, schema default `true` |
| `reconciled`    | `reconciled`           | boolean, schema default `false` |
| `sort_order`    | `sort_order`           | float, schema default `Date.now()` |
| `tombstone`     | `tombstone`            | boolean |

Read view `v_transactions_layer2` / `v_transactions_internal`:

- `is_parent`/`is_child` are read **from the stored columns** (`isParent`/`isChild`),
  not derived from `parent_id`. A child row **must** set `isChild = true` or it
  will appear as a top-level transaction (double-count risk).
- `category` is forced `NULL` for parents: `CASE WHEN isParent = 1 THEN NULL ...`.
- `parent_id` is forced `NULL` when `isChild = 0`.
- Row is excluded unless `date IS NOT NULL AND acct IS NOT NULL AND (isChild = 0 OR parent_id IS NOT NULL)`.
- Alive view excludes a child whose parent is tombstoned.

Column-name tolerance: this app already probes `["acct","account"]`,
`["description","payee"]`, `["isParent","is_parent"]`. New probes:
`["transferred_id","transfer_id"]` and `["isChild","is_child"]`. Real Actual
budgets use the first of each pair; test fixtures will add the real names.

## loot-core Semantics (Frozen Contract)

### Transfer create — `addTransfer(transaction, transferredAccount)`

Given a just-inserted row `T` whose payee has a `transfer_acct` (= the
destination account `transferredAccount`):

1. `fromPayee` = `SELECT id FROM payees WHERE transfer_acct = T.account`
   (the **source** account's transfer payee).
2. Insert a paired row `P`:
   - `account = transferredAccount`
   - `amount  = -T.amount`
   - `payee   = fromPayee`
   - `date    = T.date`
   - `transfer_id = T.id`
   - `notes   = T.notes || null`
   - `cleared = false`
   - `category` left null.
3. Update `T`: `transfer_id = P.id`.
4. `clearCategory(T, transferredAccount)`: if
   `accounts[T.account].offbudget === accounts[transferredAccount].offbudget`,
   set **both** `T.category` and `P.category` to null. (Our editor already forces
   transfer category to null, so both are null regardless — see Accepted
   Divergences.)

Destination lookup — `getTransferredAccount`: `transfer_acct` of the row's payee.

### Transfer remove — `removeTransfer(transaction)`

- Fetch paired `P = getTransaction(T.transfer_id)`.
- If `P.is_child`: update `P` → `{ transfer_id: null, payee: null }` (keep the row,
  it's someone's split child).
- Else: delete `P` (tombstone).
- Update `T` → `{ transfer_id: null }`.

### Transfer update — `updateTransfer(transaction, transferredAccount)`

- `payee = getPayee(T.account)` (source transfer payee).
- Update paired `T.transfer_id` row → `{ account: transferredAccount, payee,
  notes: T.notes, amount: -T.amount }`. (Note: loot-core does **not** update the
  paired `date` or `cleared` here. Match exactly.)
- `clearCategory` as above.

### Insert/Update/Delete dispatch

- `onInsert(T)`: if `getTransferredAccount(T)` → `addTransfer`.
- `onUpdate(T)`:
  - `T.is_parent` → `removeTransfer` (a split parent can never be a transfer).
  - `transferredAccount && !T.transfer_id` → `addTransfer`.
  - `!transferredAccount && T.transfer_id` → `removeTransfer`.
  - `transferredAccount && T.transfer_id` → `updateTransfer`.
- `onDelete(T)`: if `T.transfer_id` → `removeTransfer`.

### Splits — `makeChild` / `batchUpdateTransactions`

- A split is stored flat: one parent + N child rows.
- Parent: `is_parent = true`, `category = null` (forced on insert/update when
  `is_parent`), `amount = total`.
- Child (`makeChild`): inherits `account`, `date`, `cleared` from parent; carries
  its own `category` and `amount`; `payee` inherits parent's payee unless
  overridden; `is_child = true`, `parent_id = parent.id`, `error = null`,
  `sort_order` descending (`-1, -2, …`).
- `insertTransaction` forces `category = null` when `is_parent` or the account is
  off-budget.
- Delete expands to children: `idsWithChildren` adds every row whose
  `parent_id` is in the deleted set; each is tombstoned.
- Split invariant: `sum(child.amount) === parent.amount`, else
  `SplitTransactionError`. Our editor already enforces this before submit; the
  store re-checks and rejects mismatches with `invalidLocalWrite`.

## Editor Model (What Drafts We Must Support)

`TransactionDraft` (unchanged): `isTransfer: Bool`, `splits: [TransactionSplitDraft]`,
`isSplit == splits.count >= 2`. Each `TransactionSplitDraft` carries `id: String?`
(existing child id on edit, nil for new), `categoryID`, `amountMinorUnits` (signed).

On edit prefill (`apply`): `splitRows` are built from `subtransactions` (each with
`transactionID` = existing child id); `selectedPayeeID` = the transfer payee id for
a transfer. So on submit we can diff children by id and detect transfer via the
selected payee's `transfer_acct`.

Transitions reachable from the editor once complex edits are unblocked:
simple↔split (add/remove split rows), simple↔transfer (pick/clear a transfer
payee), transfer↔split, and field edits within a shape.

## Implementation

### Capabilities (`BackendCapabilities`)

Add, gated on the existing `allowsLocalFirstTransactionCreation` dev flag:

- `canWriteTransfers` — create/edit/delete transfer transactions.
- `canWriteSplits` — create/edit/delete split transactions.

These replace the current hard blocks so the editor and account view can offer
the affordances only when the dev flag is on. Non-dev / offline stays fully
blocked, same as the other write gates.

### Store (`LocalFirstActualStore`)

- `createTransactionAndRefresh`: remove the `unsupportedTransferWrite` /
  `unsupportedSplitWrite` guards; dispatch to transfer / split / simple message
  builders. Reload every affected account (source + transfer destination) and
  month; return `ChangedResources` covering all touched rows.
- `updateTransactionAndRefresh`: fetch existing row shape, reconcile to the draft
  shape (transfer transitions + child diff), reload all affected accounts/months.
- `deleteTransactionAndRefresh`: expand to children (tombstone parent + children)
  and run the transfer-remove path when the row has a `transferred_id`. Keep the
  simple path.

The store keeps the existing "push, apply, reload affected caches" ordering and
`resolveOrCreatePayeeMessages` for the parent/main payee (a transfer's selected
payee resolves to itself with no new messages).

### Database (`BudgetDatabase`) new message builders

All return `[ActualSyncDecodedMessage]` and read existing state in one
`queue.read`; none apply. Physical column names via the probes above.

1. `createTransferTransactionMessages(draft, sourceID, payeeID, builder) -> (messages, destinationAccountID)`
   - Require `transferred_id` column. Resolve `destination = payees.transfer_acct
     WHERE id = payeeID`; require it. Resolve `fromPayee = payees.id WHERE
     transfer_acct = draft.account`; require it.
   - Emit source row (simple-row columns, `category` null, `transferred_id =
     pairedID`) + paired row (`acct = destination`, `amount = -amount`,
     `description = fromPayee`, `category` null, `transferred_id = sourceID`,
     `cleared = false`, `notes` mirrored, `isParent = false`, `parent_id = null`,
     `tombstone = false`).
2. `createSplitTransactionMessages(draft, parentID, payeeID, builder) -> messages`
   - Validate `sum(splits) == amount`. Emit parent (`isParent = true`, `category`
     null, `amount = total`) + each child (`acct`/`date` from parent, `amount`,
     `category`, `description = payeeID`, `parent_id = parentID`, `isChild = true`
     if column exists, `sort_order` descending if column exists, `cleared` from
     draft, `tombstone = false`). New child ids via `UUID`.
3. `updateTransactionMessages(transactionID, draft, payeeID, builder) -> (messages, affectedAccountIDs, affectedTransactionIDs)`
   - Fetch existing: `isParent`, `transferred_id`, `acct`, existing child rows
     `(id, category, amount)`.
   - **Main row**: `acct`, `date`, `amount` (= draft total), `description =
     payeeID`, `category` = null when transfer/split else `draft.categoryID`,
     `notes`, `cleared`, `isParent = draft.isSplit`.
   - **Children**: if `draft.isSplit`, diff — update existing (by id): `acct`,
     `date`, `amount`, `category`, `description`; insert new children; tombstone
     removed children. If not split, tombstone all existing children.
   - **Transfer transition** (mirror `onUpdate`):
     - now split (`isParent`) and had `transferred_id` → remove transfer.
     - `nowTransfer && !hadTransfer` → add transfer (create paired, set main
       `transferred_id`).
     - `!nowTransfer && hadTransfer` → remove transfer (paired child →
       `{transferred_id:null, description:null}`; else tombstone paired; main
       `transferred_id = null`).
     - `nowTransfer && hadTransfer` → update transfer (paired `acct = dest`,
       `description = sourceTransferPayee`, `notes`, `amount = -amount`).
   - Return affected account ids (original, draft.account, old/new destination)
     and transaction ids (main, paired, touched children) so the store reloads
     them.
4. `deleteTransactionMessages(transaction, builder) -> (messages, affectedAccountIDs)`
   - Tombstone the row; if `isParent`, tombstone all live children; if
     `transferred_id`, run the remove-transfer path on the paired row. Replaces
     the simple-only `deleteSimpleTransactionMessages` (or wraps it for the simple
     case).

### UI

- `TransactionEditorViewModel`: drop `isComplexTransactionEdit` read-only gating;
  submit dispatches through the store (no change needed beyond removing the block
  and the capability check). Keep the split-total mismatch guard.
- `TransactionEditorView`: remove the "split/transfer edits not available" notice;
  drive `isReadOnly` from the new capabilities.
- `AccountTransactionsView`: allow delete of complex rows when the matching
  capability is on (remove the `isSimpleTransaction` restriction for the
  dev-gated transfer/split capabilities).
- `SettingsView`: update the developer copy to list transfers and splits.

## Accepted Divergences

- ~~**On↔off-budget transfer category.**~~ **FIXED (sha pending).** The store now
  applies loot-core `clearCategory`: categories are nulled only when both accounts
  share the same `offbudget` flag; a cross-budget transfer keeps a category on the
  on-budget side. The editor allows a category on an on-budget→off-budget transfer
  (`isCategoryReadOnly`/`transferAllowsCategory`) and preserves it on submit and
  edit. `BudgetDatabase.transferCategory` is the single source for the rule, used
  by create and update; the paired row is nulled on same-budget edits.
- **`sort_order` fidelity.** We assign descending child `sort_order` for correct
  in-split ordering, and omit `sort_order` on top-level rows (as the existing
  simple-create path already does). Top-level ordering in Actual web falls back to
  its own tie-break; local reads order by date then id. Cosmetic only.
- **Paired `date`/`cleared` on transfer update.** Matches loot-core: updating a
  transfer does not repoint the paired row's date/cleared.

## Testing

Extend the writable-store fixture: add `transferred_id` and `isChild` columns to
`transactions`; add a second on-budget account and its transfer payee rows
(`payees.transfer_acct`), so both directions resolve.

Unit tests (LocalFirstActualStoreTests):

1. Create transfer → two linked rows, negated amounts, both categories null,
   `transferred_id` cross-links, both accounts + month reloaded.
2. Create split → parent (`isParent`, category null) + children summing to total,
   children present as subtransactions, month spent reflects children.
3. Split-total mismatch rejected with `invalidLocalWrite`.
4. Edit split: change a child amount, add a child, remove a child → diff applied,
   removed child tombstoned, sum preserved.
5. Edit simple → transfer (add transfer) and transfer → simple (remove transfer,
   paired tombstoned).
6. Edit transfer amount/destination → paired updated (negated amount, new dest,
   source transfer payee).
7. Edit simple → split and split → simple (children tombstoned, `isParent`
   cleared).
8. Delete split parent → parent + all children tombstoned.
9. Delete transfer → row tombstoned and paired unlinked/tombstoned.
10. Capability truth-table updates for `canWriteTransfers` / `canWriteSplits`.

Verification ladder (per `local-first-write-plan.md`): focused tests → full
`ActualistTests` → simulator smoke on a throwaway budget → Actual web comparison
for each of create/edit/delete of transfer and split → Airy install only after
simulator proof.

## Risks & Mitigations

- **Double-count from missing `isChild`.** Mitigated: children always set
  `isChild = true`; test 2/7 assert children are not top-level and totals match.
- **Orphaned / half-linked transfers.** Mitigated: require `transferred_id`
  column and both transfer payees before emitting any transfer messages; both
  sides written in one message batch (atomic apply).
- **Wrong physical column names.** Mitigated: names frozen from the schemaConfig
  map and view SQL above; fixtures use the real names.
- **Shape-transition matrix bugs.** Mitigated: explicit per-transition tests
  (5, 6, 7) and mirroring `onUpdate` exactly.
- **Budget corruption on a real file.** Mitigated: dev-flag gated, throwaway
  budget only until manual Actual-web convergence passes for every case.

## Commit Breakdown

1. `docs: add local-first transfers and splits plan` (this file).
2. `feat: create local-first transfers and splits`
   (+ `test: cover local-first transfer and split creation`).
3. `feat: edit local-first transfers and splits`
   (+ tests for transitions and child diffing).
4. `feat: delete local-first transfers and splits`
   (+ tests) and UI unblock (editor, account view, settings copy).

Each commit builds and passes the full suite independently.
