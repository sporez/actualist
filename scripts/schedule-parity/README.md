# Schedule occurrence identity oracle

This overlay runs the pinned Actual v26.9.0 schedule handlers against synthetic,
isolated local databases. It records the mandatory seven-case occurrence matrix
without contacting an Actual server or modifying Actualist production code.

The oracle is an investigation gate, not a fixture generator. A green process
means the predetermined assertions and evidence capture completed. It does
**not** mean cross-client uniqueness exists. Cases 5 and 6 deliberately require
the observed independently generated duplicate IDs to be recorded as a product
gate finding while also proving that replaying the exact same CRDT batch is
idempotent.

## Provenance and safety

- Required Actual tag/version: `v26.9.0` / `26.9.0`.
- Required commit: `59fe126f637d858c061e1eeedbef5436c8f2225a`.
- Required prepared tools: Node `24.21.x`, Yarn `4.17.1`.
- Inputs are synthetic accounts, schedules, rules, and transactions only.
- Peers are cloned from one local baseline, assigned different CRDT clock nodes,
  kept offline, and activated sequentially because loot-core owns one global
  database/runtime at a time.
- No remote server, credentials, sync token, encryption key, or personal budget
  is used.
- The source checkout supplied to the runner must be an isolated writable copy.
  Never overlay the shared read-only pinned source.

The runner refuses a wrong commit/version/toolchain, tracked pre-existing changes,
an existing overlay target, or a repeated run label. It removes only the two
overlay files it installed and records the resulting git status.

## Exact coordinator commands

Run from the Actualist checkout containing this directory. Make a new APFS
copy-on-write clone of the already prepared, read-only upstream tree so its
installed dependencies are preserved without writing into the shared source:

```sh
set -e -o pipefail
SOURCE=/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual
WORK=/private/var/folders/ld/kccghyv92pq_jzkjwvlwz8980000gn/T/opencode/actual-schedule-oracle
EVIDENCE=/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/schedule-identity-oracle
test ! -e "$WORK"
cp -cR "$SOURCE" "$WORK"
mkdir -p "$EVIDENCE"
scripts/schedule-parity/run-oracle.sh \
  --actual-checkout "$WORK" \
  --evidence "$EVIDENCE" \
  --run-label investigation
```

The allowance is one `investigation` run. If and only if review identifies a
specific harness defect and the overlay is corrected, the one permitted rerun is:

```sh
scripts/schedule-parity/run-oracle.sh \
  --actual-checkout "$WORK" \
  --evidence "$EVIDENCE" \
  --run-label post-correction
```

Do not rename labels, create a second evidence root to evade the allowance, or
retry an unchanged failure. The single Vitest invocation contains one sequential
test that executes all seven cases and stops at the first failed acceptance
criterion. Review `oracle-result.json` before deciding whether the product gate
passed; do not infer uniqueness from exit status alone.

## Seven cases and assertions

1. **One-time manual then peer advance:** manual post is exchanged to a second
   peer; due-day advancement creates no row, and next-day advancement completes
   the schedule without replacing the transaction.
2. **Recurring manual and same-day rerun:** peer advancement keeps a manually
   paid due-today recurrence on today, and rerun writes nothing. A subsequent
   skip changes only local next date, and explicit reset changes the base
   timestamp.
3. **Missed catch-up:** the oldest occurrence is manually posted, then the peer
   service posts later missed occurrences oldest-to-newest. Retry writes nothing
   and retains the manually generated ID.
4. **Approximate Post Today:** the transaction is dated today; another peer's
   advancement recognizes it through Actual's date window and creates no
   replacement.
5. **Manual versus automatic while isolated:** both peers generate distinct IDs.
   Applying A then B and B then A converges to both IDs. Replaying A's exact CRDT
   batch adds no messages or transaction, proving generation—not replay—caused
   the duplicate.
6. **Automatic versus automatic and role reversal:** two Actual handlers run on
   isolated peers, then both role directions are repeated with the peer labels
   reversed. Until Actualist has a posting implementation, its labeled role is
   explicitly a pinned-Actual-handler surrogate and is not interoperability
   evidence. All three subcases preserve the duplicate product-gate finding.
7. **Split and transfer propagation:** a real schedule rule creates a split whose
   parent alone carries `schedule`; a real transfer handler creates two linked
   legs and both carry `schedule`.

## Evidence shape

The runner writes:

- `provenance.env`: commit, package/tool versions, source paths, run label, and
  SHA-256 hashes for the overlay and real handler/sync sources.
- `exact-command.txt`: the exact single Vitest command.
- `oracle.log` and `oracle.exit`: complete process output and numeric status.
- `oracle-result.json`: top-level completion/failure and product-gate decision;
  per-case raw outbound CRDT batches, before/after exchange snapshots, transaction
  IDs/dates/split-transfer graph, raw rule and next-date rows/timestamps, status,
  final counts, both merge orders, and replay evidence.
- `oracle-source/`: the exact README, runner, test, and support source used.
- `post-cleanup-git-status.txt`: isolated upstream status after overlay removal.

The result's top-level unresolved blocker is intentional: no Actualist posting
command exists in this packet, so case 6 cannot establish real Actualist/Actual
interoperability. A duplicate observed in cases 5 or 6 blocks automatic posting;
it must not be reframed as exactly-once behavior or hidden behind local dedupe.
