# Live lab interop checks (opt-in)

Evidence harness for the audit remediation plan (decision D11). It runs
against a disposable Actual server you control. Nothing here runs in normal
unit runs and nothing here contains an address or a password.

## Environment

Shell and Node (`run.sh`):

- `ACTUAL_LAB_URL`: base URL of the disposable server.
- `ACTUAL_LAB_PASSWORD`: its password.
- `ACTUAL_LAB_HANDOFF_DIR`: scratch folder shared between Node and the Swift
  tests (file IDs, ids, counts; no credentials). Keep it under `.artifacts/`.
- `ACTUALIST_PARITY_ORACLE_ROOT`: the pinned, read-only Actual checkout (tag and
  commit in `config/parity/oracle-pin.json`) with `node_modules`. `run.sh` refuses
  to run unless `scripts/parity/lib/oracle-pin.mjs oracle-root` accepts it (HEAD at
  the pin, pinned tag, clean tree), and checks again afterwards.

Swift tests (`ActualistTests/LiveLabInteropTests.swift`): the same three
`ACTUAL_LAB_*` names, passed as `TEST_RUNNER_ACTUAL_LAB_URL`,
`TEST_RUNNER_ACTUAL_LAB_PASSWORD` and `TEST_RUNNER_ACTUAL_LAB_HANDOFF_DIR`
(xcodebuild strips the prefix). Without them every test is skipped.

## Check 1: New Budget

1. `scripts/test.sh unit LiveLabInteropTests/createNewBudgetOnLab()` creates an
   `Interop Check <id>` budget through the production flow and writes
   `newbudget.json` to the handoff folder.
2. Download `/sync/download-user-file` for that file id (header
   `X-ACTUAL-FILE-ID`, `X-ACTUAL-TOKEN` from `/account/login`), unzip, and run
   `scripts/parity/new-budget-schema/run.sh check <db> <metadata> <result.json>`:
   load, schedule create, preference write, saved filter create.

## Check 2: two-client merkle convergence

Steps in order (`run.sh <step>` for Node, `scripts/test.sh unit ...` for Swift):

1. `run.sh seedA`: Node client A writes an account, a category and three
   transactions to the Check 1 budget and syncs (`peer-seed.json`).
2. `run.sh offlineB`: Node client B (separate data dir) downloads, then
   reinitializes with no server and writes two transactions offline.
3. Swift `mergePhaseAOpenWriteSync()`: production `LocalFirstActualStore` and
   `ActualServerSyncClient` open the budget, sync, add a local transaction and
   sync again. Its newest timestamp is now newer than B's pending messages.
4. `run.sh syncB`: B pushes messages older than Actualist's newest.
5. Swift `mergePhaseBResync()`: Actualist reopens and syncs; only the merkle
   re-pull can bring B's messages in. It counts `/sync/sync` requests.
6. `run.sh final`, then `run.sh compare`: A syncs, and the transaction sets
   (id, amount, category, account) and the `messages_clock` merkle hashes of A,
   B and Actualist are compared (`convergence-result.json`).

Delete the `Interop Check` files afterwards (`/sync/delete-user-file`).

## Check 3: sync batches and mid-sync edits

1. `scripts/test.sh unit LiveLabSyncBatchTests` with `TEST_RUNNER_ACTUAL_LAB_SYNC_BATCH=1`
   (plus the three `TEST_RUNNER_ACTUAL_LAB_*` names): four `Interop Check`
   budgets, each with an outbox of 500, 501 or 1,600 messages or one edit made
   during the upload, must each sync in one refresh with nothing left queued.
   File IDs and expected counts go to `sync-batch.json`.
2. `run.sh syncBatchCheck`: Actual downloads each budget, syncs, and must see
   every payee; then it deletes the budgets (`sync-batch-result.json`).

## Check 4: Actual v26.11.0 parity fixes

Swift `LiveLabActual2611Tests` with `TEST_RUNNER_ACTUAL_LAB_V2611=1` (plus the
three `TEST_RUNNER_ACTUAL_LAB_*` names), interleaved with two Node steps:

1. Swift `v2611Prepare()`: a new `Interop Check v2611 main` budget through the
   production flow (`v2611.json`).
2. `run.sh v2611Seed`: Actual adds accounts, a split-formula rule
   (`=parent_amount * 0.5`, a `BALANCE_OF` split, a remainder), three
   equal-distance import ties (both plain; one with its own imported ID; the
   same date), and a future split transaction with one split payee. It records
   its own `rules-run` split amounts and dry-run import matches
   (`v2611-seed.json`).
3. Swift `v2611Actualist()`: the production store previews the same rule and
   prepares the same import as a CSV and must match Actual; converts the split
   transaction to a schedule; and, after today's automatic-posting run, creates
   a posting schedule due today, which must post on the next sync
   (`v2611-actualist.json`).
4. Swift `v2611ClockDrift()`: on two more budgets, a change committed with a
   device clock ten minutes fast must be refused by the server (`clock-drift`,
   shown as `LocalFirstError.clockDrift`, still queued) and one four minutes
   fast must sync; an unparsable timestamp sent raw must come back as
   `invalid-timestamp` (`v2611-drift.json`). The server must run a build with
   upstream #8905 (after v26.11.0; the lab's nightly image).
5. `run.sh v2611Check`: Actual reads the converted schedule's split payee
   actions and posts it, sees the same-day row, finds no refused change on the
   server and the four-minute one present, then deletes the three budgets
   (`v2611-result.json`).
