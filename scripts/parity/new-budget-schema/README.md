# New Budget schema generator and interop checker

Evidence harness for audit item 1.1 (Z1). It builds a fresh budget through
upstream Actual's real `createBudget` path and loads budgets through upstream's
real `loadBudget` path. There is no server and no network (`fetch` is replaced
by a throwing stub in `no-network-setup.mjs`).

## Requirements

- `ACTUAL_UPSTREAM_DIR`: the pinned Actual v26.9.0 checkout
  (`59fe126f637d858c061e1eeedbef5436c8f2225a`) with `node_modules` installed.
  It is read-only here. `run.sh` refuses to run unless HEAD matches the pin and
  `git status --short` is empty, and re-checks after the run. Nothing is
  installed or written there.
- node `v24.21.0`, `python3`, `sqlite3`.

The Vite cache and every output go to `NEWBUDGET_OUT_DIR`
(default `<repo>/.artifacts/audit-remediation-2026-10/newbudget-schema`, gitignored).

## Generate

```sh
export ACTUAL_UPSTREAM_DIR=/path/to/pinned/actual
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

`replay.py <out-dir> <db>` rebuilds a database from those files alone (proof
that the dump is sufficient).

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
scripts/parity/new-budget-schema/run.sh emit-swift
```

Writes `Actualist/LocalFirst/Database/ActualStarterSchema.swift` from
`schema.sql` and `seed-rows.json` (tables, indexes and the seeded dashboard).
Never edit that file by hand; regenerate after a new `generate` run.
To check the Swift seed itself, run the `seedWrittenForUpstreamInterop` test,
copy the `db.sqlite` it leaves in the test process's temp directory, and pass it
to `run.sh check`.
