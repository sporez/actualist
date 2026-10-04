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
- `ACTUAL_UPSTREAM_DIR`: the pinned, read-only Actual v26.9.0 checkout
  (`59fe126f`) with `node_modules`. `run.sh` refuses to run unless HEAD matches
  and `git status` is clean, and re-checks afterwards.

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
