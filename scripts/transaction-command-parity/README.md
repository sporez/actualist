# Transaction duplicate and merge parity harness

Generates the transaction-command fixture from Actual's own handlers at the
pinned release (`config/parity/oracle-pin.json`, v26.10.0). This directory holds
only the generator side. `TransactionCommandOracleReplayTests` replays every case
through the database review, commit and undo path.

- `generate.mjs`: runs the matrix inside the oracle checkout under vitest and
  writes the fixture. `--check` regenerates into a temporary directory and diffs
  against the committed fixture.
- `verify.mjs`: checks the committed fixture against the manifest and the matrix.
  Needs no oracle.
- `matrix.json`: the 39 case IDs (D1/D2 duplicate source graphs, M1–M4 merge
  inputs), each with its selected row IDs in caller order and a named graph.
  Pure input, no expectations.
- `oracle-runner.template`: the vitest test copied into the oracle for one run
  and removed afterwards. It also holds the 39 graph builders.
- Fixture: `ActualistTests/Fixtures/ActualCore26_10_0/TransactionCommand/`
  (`transaction-command-contract.json`, `transaction-command-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/transaction-command-parity/generate.mjs [--check]
node scripts/transaction-command-parity/verify.mjs
```

The oracle checkout must be at the pinned commit with a clean tree and
`yarn install` done. It is checked before and after the run and is never written
to except for the temporary runner, which is removed in a `finally`. Generation
takes about 3 seconds. Synthetic data only; nothing touches a server, a real
budget or Actualist persistence.

## What a case is

Each case seeds one synthetic graph through upstream's `db.insertTransaction`,
then calls the real handler:

- **Duplicate (D1/D2).** The selected rows are read with a grouped AQL query,
  realized with `ungroupTransaction`/`realizeTempTransactions` and reset to
  uncleared and unreconciled, exactly as the desktop client builds them. They
  go to `transactions-batch-update` as `added` only, so category learning is
  not requested.
- **Merge (M1–M4).** The selected IDs, in matrix order, go to
  `transactions-merge`.

Upstream's undo (`undo()`) then runs once. A handler refusal is recorded as an
observation (`handler.outcome: "refused"` with its text), never treated as an
expected answer.

Per case the fixture records:

| Field | Content |
| --- | --- |
| `selected` | the selected row IDs in caller order |
| `input.transactions` | the seeded rows as physical `transactions` columns (`acct`, `isParent`, … aliased to `account`, `is_parent`, …; `category_mapping_id` and `payee_mapping_id` hold the mapped ids), so a replay can insert them into its own starter schema |
| `handler` | `outcome` `ok` with `result`, or `refused` with `error` |
| `afterHandler.transactions` | every physical row after the handler, tombstones included |
| `forwardMessages` | the CRDT messages the handler wrote, in order |
| `undo` | `outcome`, `error` when it failed, the messages it wrote, and every row afterwards |
| `conflict` | M4 undo-conflict only: a later note change applied before undo, with its message and the rows after it |
| `referenceChanges` | only when a checkpoint changed a reference table (duplicates add category and payee mapping rows) |
| `rules` | the learning case only: rule rows before, after the handler and after undo, with `learnCategoriesRequested: false` |

The accounts, categories, groups, payees, schedules, mappings and rule rows that
every case starts from are recorded once as top-level `referenceData`.

## Determinism and normalization

- `generatedAt` is not recorded. `TZ` is UTC and `Date.now()` is frozen by
  loot-core's test setup.
- Ids Actual mints (`id1`, `id2`, … from the test setup's uuid mock, restarted
  per case) become `uuid-N` by first appearance in the case. Setup ids are
  explicit and untouched. A minted id inside longer text fails generation.
- `sort_order` `123456789` is the frozen `Date.now()` Actual assigns a row that
  has none. It is recorded but is not a comparable value.
- Repeated CRDT messages (a handler writing the same cell twice) are kept
  verbatim and in order; that is what Actual wrote.
- Amounts and dates are never normalized. Row order is by `id` (an unspecified
  order in Actual, so a replay compares sorted by `id`); messages keep Actual's
  write order.

## Ratified contract

The September sprint's admitted contract
(`reference/plans/done/dev-sprint-2026-09/transaction-commands-implementation-admission.md`)
is the user's decision, ratified 2026-10-11. Where Actualist deliberately differs
from this fixture, the difference is intended:

- Duplicating a malformed split is refused (Actual clones it).
- Merging a selected split child, a zero-child or malformed split, or a broken or
  partial transfer pair is refused (Actual merges some of these).
- Undo after a merge is blocked when the rows changed since (Actual's in-memory
  undo is not conflict-checked).
- A selected split child duplicates its whole family.

A replay therefore compares the cases the contract accepts and handles the cases
above as registered divergences, not as fixture edits.

## Gates

The matrix covers the decisions the contract settles: child selection (D1);
imported identity and payee, schedule, order, transfer, split error, omission of
category learning, and cleared/reconciled reset (D2); caller-order and tie
behavior (M1); split-child, empty-family and malformed-split handling (M2);
transfer destination, budget category, reconciliation and broken-pair handling
(M3); and full-graph commit and undo (M4). Actual's undo history is in memory
(`server/undo.ts`); there is no durable transaction action log to compare.

## Manifest

`transaction-command-manifest.json` records the pin, the sha256 of the oracle
sources used (`sourceFiles`), the generator and helper hashes, `caseCount`,
`caseIDs`, `normalization`, and `oracleOnly` (empty: every case is replayed).
