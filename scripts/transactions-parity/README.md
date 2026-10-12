# Transactions parity harness (creation)

Compares the exact CRDT cells Actualist writes when it **creates** a transaction
with the cells the pinned Actual (`config/parity/oracle-pin.json`) writes for the
same action. Update, delete, batch update and categorization are not covered.

## What runs upstream

`oracle-runner.template` is written into the oracle checkout, run once with
vitest on an offline in-memory database, and removed. For each case in
`matrix.json` it seeds one shared world (two on-budget accounts, two off-budget
accounts, their transfer payees, expense and income categories including
`Starting Balances`) and calls the handlers a client calls:

| Kind | Handlers |
| --- | --- |
| `manual` | `payee-create` (when the case types a new payee) + `transactions-batch-update` `added` |
| `transfer` | `transactions-batch-update` `added` with a transfer payee (transfer.ts adds the paired leg) |
| `import` | `transactions-import` (`reconcileTransactions` insert; CSV and Bank Sync share the insert) |
| `starting-balance` | `account-create` with a balance (account and its transfer payee are dropped; Starting Balance payee and opening row are kept) |

The messages are read back from `messages_crdt`, in write order.

## Normalization

- Minted ids (`id1`, `id2`, ...) are renamed by role: `txn-paired`, `txn-new`,
  `payee-new`, `acct-new`. The new transaction of a manual or transfer case is
  the explicit id `txn-new`.
- `sort_order` is `<sort-order>` when Actual writes it (its value is the frozen
  clock); only presence is compared.
- Amounts, dates and every other value are never normalized.

## Swift side

`ActualistTests/TransactionCreateOracleReplayTests.swift` (+ `...Support.swift`)
builds a starter budget seeded with the same world and runs the production
writers (`resolveOrCreatePayeeMessages`, `createSimpleTransactionMessages`,
`createTransferTransactionMessages`, `makeBankSyncOpeningBalanceMessages`),
mirroring the store's payee resolution and the import insert draft, then compares
the cells as a multiset. Each difference is attributed to a registered divergence
(`config/parity/known-divergences.json`, OP-86 (intended)); unattributed differences
fail strictly.

The editor rule that an off-budget account carries no category is applied before
the writer, because the editor owns it.

## Not in the fixture

- **Schedule posts** (`schedule/post-transaction`): the harness could not make
  the handler resolve the schedule's account in a bare test database, so no
  cells were captured. Posting is covered by the schedules domain
  (`ScheduleOracleReplayTests`, `post-transaction-*`).
- **Bank Sync opening balance with a first download**: replayed through the
  `starting-balance` cases (same `insertTransaction` cells as `account-create`);
  the download-derived amount and date belong to bank-sync-parity.
- **Rule-learning writes** (`learnCategories`): not requested, so no rule cells.

## Commands

```sh
set -a; . scripts/lib/lab.env; set +a
node scripts/transactions-parity/generate.mjs           # regenerate the fixture
node scripts/transactions-parity/generate.mjs --check   # fail on drift
node scripts/transactions-parity/verify.mjs             # no oracle needed
scripts/test.sh unit TransactionCreateOracleReplayTests
```
