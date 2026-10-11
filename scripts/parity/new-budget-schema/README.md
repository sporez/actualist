# New Budget schema generator and interop checker

Evidence harness for audit item 1.1 (Z1). It builds a fresh budget through
upstream Actual's real `createBudget` path and loads budgets through upstream's
real `loadBudget` path. There is no server and no network (`fetch` is replaced
by a throwing stub in `no-network-setup.mjs`).

## Requirements

- `ACTUALIST_PARITY_ORACLE_ROOT`: a clean checkout of the pinned Actual release
  (tag and commit in `config/parity/oracle-pin.json`) with `node_modules`
  installed. `scripts/parity/lib/oracle-pin.mjs` checks HEAD, the tag and the
  clean tree before the run and again after it (exit 97 on change). Nothing is
  installed or written there.
- node `v24.21.0`, `python3`, `sqlite3`.

Outputs go to `NEWBUDGET_OUT_DIR` (default
`<repo>/.artifacts/audit-remediation-2026-10/newbudget-schema`, gitignored).
`drift` uses its own temp folder and removes it after a passing run.

## Generate

```sh
export ACTUALIST_PARITY_ORACLE_ROOT=/path/to/clean/actual-checkout
scripts/parity/new-budget-schema/run.sh generate
```

`generate.test.mjs` copies `default-db.sqlite`, writes default `metadata.json`,
and runs `_loadBudget -> updateVersion -> migrate()` including the JS
migrations. `dump.py` then writes to the output folder:

- `schema.sql`: tables, indexes and triggers in creation order (views and
  `sqlite_*` tables excluded). Replays into an empty database.
- `migrations.txt`: `__migrations__` ids.
- `meta.json`: `__meta__` rows without `view-hash`.
- `seed-rows.json`: every row of every non-empty table (includes the raw
  `__meta__` view-hash row and the `messages_clock` row; ids from the JS
  migrations are random UUIDs and change per run).
- `starter-schema.json`: per-table `PRAGMA table_info`, tables sorted by name.

`manifest.py` then writes `newbudget-manifest.json`: the pinned release, the
sha256 of each oracle source behind the schema (the create-budget handler,
`createBudget`, `updateVersion`, `migrate()`, `default-db.sqlite` and every
file in `packages/loot-core/migrations`), the harness files, and the sha256 of
`starter-schema.json` and `migrations.txt`. `seed` is `null`: the generator uses
no random seed.

The committed fixtures in the pinned fixture directory (`NewBudget/`) are
`starter-schema.json`, `migrations.txt` and `newbudget-manifest.json`.

## Drift

```sh
export ACTUALIST_PARITY_ORACLE_ROOT=/path/to/clean/actual-checkout
scripts/parity/new-budget-schema/run.sh drift
```

Regenerates into a temp folder and compares it with the committed fixture:
`starter-schema.json` and `migrations.txt` byte for byte, and the manifest with
`generatedAt` removed from both sides. Exit 1 names the drifted files. The temp
folder is removed only after a passing run, so a failure can be inspected.

## Verify (no oracle, no network)

```sh
node scripts/parity/new-budget-schema/verify.mjs
```

Checks the manifest's pin, fixture file hashes, harness file hashes, the
recorded oracle source list, and the table and migration counts against the
committed files.

## Interop check

```sh
scripts/parity/new-budget-schema/run.sh check <db.sqlite> [metadata.json] [result.json]
```

Copies the database into a temp budget dir, runs upstream `load-budget`
(applied-migrations check, `loadClock`, `updateViews`), then tries schedule
create, preference write and saved-filter create. Prints pass/fail per step
into the result JSON and exits non-zero on any failure.

## Swift source

```sh
scripts/parity/new-budget-schema/run.sh emit-swift [target.swift]
```

Writes the Swift starter-schema source from `schema.sql` and `seed-rows.json`
(tables, indexes and the seeded dashboard). With no target it writes
`$NEWBUDGET_OUT_DIR/ActualStarterSchema.swift`; it never writes into the repo by
default. Copy the output into `Actualist/LocalFirst/Database/ActualStarterSchema.swift`
deliberately. Never edit that file by hand; regenerate after a new `generate` run.
To check the Swift seed itself, run the `seedWrittenForUpstreamInterop` test,
copy the `db.sqlite` it leaves in the test process's temp directory, and pass it
to `run.sh check`.

`replay.py <out-dir> <db>` rebuilds a database from `schema.sql`, the migration
ids and the seed rows alone (proof that the dump is sufficient).
