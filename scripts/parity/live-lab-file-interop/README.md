# Live lab ZIP and CSV interop (opt-in)

Moves real files both ways between Actualist's production code and the pinned
Actual's own code, against a disposable Actual server, and compares the
results. Nothing here runs in normal unit runs and nothing here contains an
address or a password.

```sh
scripts/parity/live-lab-file-interop/run.sh          # everything, then cleanup and a PASS/FAIL summary
scripts/parity/live-lab-file-interop/run.sh <step>   # prepare | swiftA | verifyZip | swiftB | verifyCSV | cleanup | summary
```

## Environment

The same as `scripts/parity/live-lab-interop/`: `ACTUAL_LAB_URL`,
`ACTUAL_LAB_PASSWORD` and `ACTUALIST_PARITY_ORACLE_ROOT`, from the
environment or the gitignored `scripts/lib/lab.env`. `ACTUAL_LAB_HANDOFF_DIR`
defaults to `.artifacts/live-lab-file-interop/`; every full run empties it
(the vite cache is kept). Swift steps run through `scripts/test.sh` with
`ACTUALIST_SCHEME` defaulting to `Actualist Dev` and the lab values passed
as `TEST_RUNNER_*`. The Swift suite is `ActualistTests/LiveLabFileInteropTests.swift`;
it is skipped unless `source.json` is in the handoff folder.

## Source budget

`Lab · Interop Source`, a `standard` profile budget. The full run creates it
with `scripts/lab/budgets.sh` when the server lacks it and otherwise reuses it.
The CSV checks use two of its accounts: the one with the most split
transactions and the open account with the most transactions and no splits.

## Steps

1. `prepare` (Node, Actual): download the source, `api.exportBudget()` to
   `actual-export.zip`, export each CSV account the way the account screen's
   Export does (`transactions-export-query`) to `actual-<key>.csv`, and record
   balances and a table digest (`source.json`, `source-digest.json`).
2. `swiftA` (Actualist): open the source, record balances, snapshot the local
   database, `exportPortableBudgetArchive` to `actualist-export.zip`, export the
   same CSVs to `actualist-<key>.csv`, then `importPortableBudget` of
   `actual-export.zip` (registered on the server; `imported.json`), open it
   and snapshot it.
3. `verifyZip` (Node): Actual imports `actualist-export.zip` locally
   (`api.importBudget`), and downloads the copy Actualist registered. Each copy,
   and Actualist's own, is compared with the source.
4. `swiftB` (Actualist): import each `actual-<key>.csv` into a new account of
   the imported budget through `prepareTransactionCSVImport` and
   `applyTransactionCSVImport` (every row accepted), snapshot, then sync.
5. `verifyCSV` (Node): compare the two CSVs of each account, import both into
   new accounts of a local Actual copy with the import modal's steps and
   defaults, then compare those rows with Actualist's local import and with
   the server copy after Actualist's sync.
6. `cleanup`: delete the server file Actualist registered in step 2.

## What is compared

- **Table digest**: every table's live rows (`tombstone = 0` where the column
  exists), every column, order-independent. Engine bookkeeping that differs
  between copies of one budget is left out and only counted: `messages_*`,
  `kvcache*`, `sqlite_*`, and Actualist's local `actualist_*` tables.
- **Balances**: the all-time sum of each account in Actual, against Actual's
  balances on the copy and Actualist's account balances.
- **CSV rows**: date, amount, payee name, notes, category name, cleared,
  parent and child flags, as a multiset. Starting balance rows are left out.
  Actual's import modal clears every row by default; Actualist keeps each
  row's Cleared value, so the import comparison is also reported ignoring
  cleared.

The reports are `report-zip.json` and `report-csv.json`; `summary.mjs` prints
one PASS/FAIL line per check and sets the exit status.
