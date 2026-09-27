# Schedule occurrence identity oracle

This overlay runs pinned Actual v26.9.0 schedule handlers against synthetic,
isolated local databases. It records the mandatory seven-case occurrence matrix
without contacting an Actual server or modifying Actualist production code.

The oracle is an investigation gate, not a fixture generator. A green process
means the reviewed assertions and evidence capture completed. It does **not**
mean cross-client uniqueness or Actualist interoperability exists. Source
inspection predicts independently generated rows in cases 5 and 6, but the
oracle records either one-row uniqueness or two-row convergence neutrally. Exact
CRDT replay is asserted independently from that result.

## Provenance and safety

- Required Actual tag/version: `v26.9.0` / `26.9.0`.
- Required commit: `59fe126f637d858c061e1eeedbef5436c8f2225a`.
- Required prepared tools: Node `24.21.x`, Yarn `4.17.1`, and the checkout's
  installed Vitest executable.
- Runtime timezone is pinned to `UTC` and recorded.
- Native SQLite export requires `ACTUAL_DATA_DIR` because the pinned electron
  backend backs an in-memory database up to a temporary file before reading its
  bytes. The runner supplies a new mode-700 synthetic directory owned by the run
  label, records it, and removes it only after the owned process group stops.
- The same backend reopens serialized in-memory databases only from a Node
  `Buffer`; the overlay converts its peer byte copies back to `Buffer` at that
  boundary. Baselines otherwise stay in `:memory:` databases. Test-mode prefs
  avoid document-directory writes, and Vitest mocks async storage, so no other
  filesystem root is required by this harness.
- Inputs are synthetic accounts, schedules, rules, and transactions only.
- Peers are cloned from one local baseline, assigned different CRDT clock nodes,
  kept offline, and activated sequentially because loot-core owns one global
  database/runtime at a time.
- The fixed peer matrix uses unique deterministic 16-character hexadecimal
  clock-node IDs. Human-readable peer labels remain evidence labels only. Before
  case 1, the harness rejects duplicate/invalid IDs and verifies every node
  through Actual's serialized-clock format and `Timestamp.parse` round trip.
- Vitest replaces `uuid.v4` with one deterministic process-global counter.
  Production handlers use random UUIDs. Distinct oracle IDs prove separate
  generation events; they do not prove production randomness.
- No remote server, credentials, sync token, encryption key, or personal budget
  is used.

The runner requires both the read-only pinned source and a distinct writable
clone. It rejects identical checkout paths and shared git-common-directory
identity, so the overlay cannot target the supplied source checkout or one of
its linked worktrees. Before creating any evidence path, it also rejects an
evidence root equal to or nested beneath either checkout. It rejects wrong
source revisions, tracked changes, existing overlay files, or a spent run label.

The invocation has a 600-second ceiling and a 10-second termination grace. Its
supervisor creates one process group for this invocation and signals only that
group. It never uses a blanket process kill. Exit `124` means timeout; `130` or
`143` means interruption. The outer signal trap owns the exact supervisor and
recorded child process group, waits for confirmed termination before removing
the overlay, and captures post-cleanup git status on interruption. Every outcome
is written numerically. Startup identity, graceful termination, and forced-stop
confirmation are each bounded to 10 seconds, for a 30-second outer-cleanup
ceiling in the worst signal race.

## Exact coordinator command shape

Run from the Actualist checkout containing this directory. Set the three paths
outside tracked source, then make an isolated copy that preserves the prepared
dependencies:

```sh
set -e -o pipefail
SOURCE=${ACTUAL_PINNED_SOURCE:?set-pinned-source-path}
WORK=${ACTUAL_ORACLE_CLONE:?set-distinct-writable-clone-path}
EVIDENCE=${ACTUAL_ORACLE_EVIDENCE:?set-evidence-root-path}
test ! -e "$WORK"
cp -cR "$SOURCE" "$WORK"
scripts/schedule-parity/run-oracle.sh \
  --source-checkout "$SOURCE" \
  --actual-checkout "$WORK" \
  --evidence "$EVIDENCE" \
  --run-label investigation
```

The allowance is one `investigation` run. If and only if review identifies a
specific harness defect and the overlay is corrected, the one permitted rerun is:

```sh
scripts/schedule-parity/run-oracle.sh \
  --source-checkout "$SOURCE" \
  --actual-checkout "$WORK" \
  --evidence "$EVIDENCE" \
  --run-label post-correction
```

Each label writes only beneath `$EVIDENCE/<run-label>/`; a correction cannot
overwrite the investigation's result, log, source, provenance, command, status,
or cleanup evidence. Do not rename labels or create another evidence root to
evade the allowance.

The failed `investigation` evidence is durable and must remain untouched. The
remaining authorized invocation uses `post-correction`, including its own
synthetic data directory and evidence files.

The single Vitest invocation contains one sequential test. It stops at the first
failed invariant. The active case is checkpointed after each captured batch,
exchange, and named snapshot, so a failed invariant or bounded interruption
retains current-case structured evidence when the process had time to write it.
Review `oracle-result.json`; do not infer uniqueness from process exit alone.

## Seven cases and assertions

1. **One-time manual then peer advance:** manual post is exchanged to a second
   peer; due-day advancement creates no row, and next-day advancement completes
   the schedule without replacing the transaction. The completion receipt stays
   on the sender's later clock before the civil test date is restored.
2. **Recurring manual and same-day rerun:** peer advancement keeps a manually
   paid due-today recurrence on today, and rerun writes nothing. A subsequent
   skip changes only local next date. The mocked instant advances one second
   before explicit reset, which changes the base timestamp without changing day.
3. **Missed catch-up:** the oldest occurrence is manually posted, then the peer
   service posts later missed occurrences oldest-to-newest. Retry writes nothing
   and retains the manually generated ID.
4. **Approximate Post Today:** the transaction is dated today; another peer's
   advancement recognizes it through Actual's date window and creates no
   replacement.
5. **Manual versus automatic while isolated:** both peers independently run a
   handler. A-then-B and B-then-A must converge to the same graph; the observed
   one-or-two-row count and IDs determine the finding. Replaying A's exact CRDT
   batch must add no message or transaction.
6. **Automatic versus automatic and role reversal:** two Actual handlers run on
   isolated peers, then both role directions repeat with labels reversed. Before
   exchange, each originating peer must contain one occurrence; both generated
   IDs and their observational equality are recorded without presuming they
   differ. Counts are recorded neutrally with the same convergence and replay
   assertions. Until Actualist has a posting implementation, its label is a
   pinned-Actual-handler surrogate and is not interoperability evidence.
   Automatic posting stays blocked regardless of this surrogate result.
7. **Split and transfer propagation:** a real schedule rule creates a split whose
   parent alone carries `schedule`; a real transfer handler creates two linked
   legs and both carry `schedule`. Each graph is exchanged to a second peer and
   compared with its source; exact replay must insert nothing. There is only one
   generated batch per subcase, so a two-batch order comparison is not applicable.

Expected complete structure: 7 cases, 23 captured operation batches, 45 exchange
records, 4 two-batch order scenarios, and 6 exact replay controls.

## Evidence shape

For each run label, the runner writes:

- `provenance.env`: source/clone git identities, tag/commit, package versions,
  exact Node/Yarn bootstrap/Yarn release/Vitest/Python paths, timezone, ceiling,
  termination grace, and SHA-256 hashes for the executed Node/Yarn/Vitest tools,
  overlay, and real handler/sync sources.
- `exact-command.txt`: the exact single Vitest command using the recorded paths.
- `oracle.log`, `oracle.exit`, and `outcome.env`: complete output, numeric status,
  and completed/timeout/interrupted classification.
- `synthetic-data-cleanup.env`: the exact native-SQLite temporary directory and
  whether it was removed, blocked, or never created.
- `oracle-result.json`: top-level completion/failure and conditionally derived
  product-gate finding; completed cases plus the checkpointed current case; raw
  outbound CRDT batches; before/after exchange snapshots; transaction IDs,
  dates, split/transfer graph, raw rule and next-date rows/timestamps, status,
  final counts, both merge orders, and replay evidence.
- `oracle-source/`: the exact README, runner, test, and support source used.
- `post-cleanup-git-status.txt`: writable-clone status after overlay removal.

The unresolved blocker is intentional: no Actualist posting command exists in
this packet. Case 6 cannot establish Actualist/Actual interoperability. A
duplicate result blocks automatic posting directly; a one-row result still
leaves automatic posting blocked until its uniqueness contract and real
Actualist interoperability are demonstrated.
