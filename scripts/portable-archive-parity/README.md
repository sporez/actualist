# Portable archive parity harness

Round-trips the budget ZIP between the pinned Actual (v26.11.0, `config/parity/oracle-pin.json`)
and Actualist's production portable code, without a server. `PortableArchiveOracleReplayTests`
replays the fixture. The opt-in live-lab harness `scripts/parity/live-lab-file-interop/` stays for
the server path (registration, sync, CSV).

- `generate.mjs`: runs `oracle-runner.template` inside the oracle checkout under vitest and writes
  the fixture. `--check` regenerates into a temporary directory and diffs against the committed
  fixture (byte for byte; the ZIP is reproducible because the clock is frozen and Actual's uuid is
  mocked). The Actual sources it depends on are pinned by sha256 in the file.
- `verify.mjs`: checks the committed fixture against the manifest. Needs no oracle.
- `oracle-runner.template`: the loot-core vitest test, copied into the oracle and removed afterwards.
- `produce-actualist-export.sh`: direction B's producer step (below).
- Digest: `scripts/parity/lib/table-digest.mjs`, shared with the live-lab harness.
- Fixture: `ActualistTests/Fixtures/ActualCore26_11_0/PortableArchive/`.

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/portable-archive-parity/generate.mjs [--check]
node scripts/portable-archive-parity/verify.mjs
scripts/portable-archive-parity/produce-actualist-export.sh   # only to refresh actualist-export.zip
```

The oracle checkout must be at the pinned commit with a clean tree and `yarn install` done. It is
checked before and after the run and is never written to except for the temporary runner. Synthetic
data only.

## The world

Seeded through upstream's db functions and handlers with explicit ids, in a real budget directory
created by `create-budget`: two on-budget accounts, one off-budget, one closed, in two account
groups; category groups and categories (a hidden group and a hidden category); payees, one merged;
transactions (plain, a split, a transfer pair, a tombstoned row); a rule; a schedule (`schedule/create`);
envelope budget amounts for 2026-09 and 2026-10; a category note; two synced preferences. Actual's
own starter rows (default groups and categories, dashboard widgets, 60 migrations) come with it.

## Direction A, Actual to Actualist

Actual's `export-budget` handler writes `actual-export.zip`. Actual's `import-budget` (type
`actual`) reads it into a fresh budget directory, and the digest of that database plus each
account's all-time balance (AQL sum, splits inline) is `actual-export-digest.json`.

The replay imports `actual-export.zip` through `PortableBudgetWorkflows.importPortableBudget`: the
production validate, sync reset, install and registration path. Only the registration transport is
replaced (`PortableBudgetImportSyncResetTests.AcceptingRegistrationTransport`); every import path
needs a server for that step. It then opens the budget as the app does (`openImportedBudget`),
digests the opened database with the same rules and compares table by table, and compares the
Accounts screen balances.

## Direction B, Actualist to Actual

`produce-actualist-export.sh` runs one Swift test,
`PortableArchiveOracleReplayTests/produceActualistExport()`, which does nothing unless
`ACTUALIST_PRODUCE_PORTABLE_EXPORT=1` (passed as `TEST_RUNNER_...`). It imports `actual-export.zip`
and writes `PortableBudgetWorkflows.exportPortableBudgetArchive` to
`.artifacts/portable-archive-parity/actualist-export.zip`; the script copies it to the fixture folder
as `actualist-export.zip`. That ZIP is an input, not a generated file. Regenerate it only when the
exporter, importer or `actual-export.zip` changes: run the producer, then `generate.mjs`.

`generate.mjs` imports `actualist-export.zip` with Actual and records
`actualist-export-digest.json`: `zip` is the database as written in the ZIP, `afterActualImport` is
what Actual reads, plus balances. The manifest records the sha256 of both ZIPs.

- B1 (`actualReadsTheActualistExportAsItsOwn`): `afterActualImport` and the balances equal Actual's
  own `actual-export-digest.json`. An export that loses or alters data fails here.
- B2 (`currentExporterReproducesTheCommittedExport`): the current exporter on a fresh import of
  `actual-export.zip` writes a database whose digest equals `zip`. A failure means the committed
  input is stale: regenerate it, then review the difference.

## Digest

Every table's live rows (`tombstone = 0` where the column exists), all columns, order independent.
`messages_*`, `kvcache*`, `sqlite_*` and `actualist_*` tables are only counted. Actualist's import
sync reset empties `messages_crdt`, `messages_clock` and `messages_pending` and deletes
tombstoned rows of the sync-reset tables, so neither shows in the digest.
