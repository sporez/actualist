# Transaction duplicate and merge parity matrix

This directory holds an executable synthetic C4/C5 capture harness for Actual
v26.9.0. It intentionally has no expected handler outcomes: no gate is
converted into production semantics until the coordinator reviews runtime
observations and records the product decisions. Matrix `expectedObservation`
text is limited to source-defined capture intent, not an admitted product
policy.

`matrix.json` has 39 stable cases covering D1/D2 duplicate source graphs and
M1–M4 merge inputs. `transaction-command-parity.test.ts` seeds named graph
fixtures and calls Actual's real `transactions-batch-update` duplicate handler
or `transactions-merge` handler. It records per case: input/selected IDs,
before/after physical SQLite rows and reference rows, returned result or handler
refusal, forward CRDT messages, then the result of one actual upstream undo and
its row/reference/message effects. Handler refusals are captured as observations,
not treated as expected answers. Setup/capture failures identify the case and
fail the invocation.
The first setup/capture failure is durably recorded, stops the internal case
loop immediately, and fails the single Vitest test; Actual handler refusals are
recorded as normal per-case observations and do not stop the loop.
Do not exercise Actualist persistence, a server, a real budget, or user data.

The pinned upstream source and prepared transaction-oracle checkouts are
immutable provenance inputs. This lane owns a local copy at
`.artifacts/transaction-command-oracle/actual`; the runner canonicalizes and
requires the writable checkout to remain below this exact lane-owned artifact
root. It refuses shared Git identity, dirty source/candidate checkouts, existing
overlay targets, and spent run labels. It installs signal/EXIT cleanup before
creating scratch or copying overlays, and tracks the launch race through Bash
job control's one owned background job. Vitest and descendants share one
verified process group. On interruption or deadline, cleanup sends TERM then
CONT to that exact group, waits for quiescence, and sends KILL only to that
group if TERM grace expires. It retains overlays, scratch, and evidence if
process-group ownership or quiescence cannot be confirmed. PID/PGID,
runner/oracle status, launch/signal/TERM/KILL/quiescence/finish times, and
cleanup status are persisted. Success outcome is written only after group
quiescence, owned-file cleanup, and a clean checkout check. Evidence is retained
under `.artifacts/transaction-command-oracle/evidence`.
Do not invoke the existing transaction-query runner for this matrix: it
overlays only its own query harness.

Before using outcomes, the coordinator must explicitly decide: child selection
policy (D1); imported identity/payee, schedule, order, transfer, split error,
the real duplicate request's omission of category learning, and
cleared/reconciled handling (D2); caller-order/tie behavior
(M1); split-child/empty-family and malformed split policy (M2); transfer
destination, budget category, reconciliation and broken-pair policy (M3); and
full-graph atomic commit/undo representation (M4).

Historical second bounded invocation (spent; the runner explicitly refuses
this label even if its evidence directory is moved):

```text
scripts/transaction-command-parity/run-oracle.sh \
  --source-checkout "$ACTUALIST_PARITY_ORACLE_ROOT" \
  --actual-checkout "$ACTUALIST_ROOT/.artifacts/transaction-command-oracle/actual" \
  --evidence "$ACTUALIST_ROOT/.artifacts/transaction-command-oracle/evidence" \
  --run-label post-correction
```

The runner enforces Node 24.21.x, Yarn 4.17.1, Vitest 4.1.10, better-sqlite3
12.11.1, and Actual core 26.9.0. The exact underlying Vitest selection is
`@actual-app/core exec vitest --run
src/server/transactions/transaction-command-parity.test.ts --reporter=verbose
--bail=1`, with a 180-second process-group ceiling, ten-second TERM grace, and
ten-second bounded post-KILL quiescence confirmation (at most 200 seconds total
before evidence retention if a group remains unconfirmed).

The sole authorized `investigation` invocation was spent and stopped on its
first harness setup/capture failure at `D1-simple-root`:
`SqliteError: no such column: transfer_id`. The pinned Actual source proves this
was a harness readback-schema mismatch, not an Actual handler refusal:
`packages/loot-core/src/server/sql/init.sql` stores the physical column as
`transactions.transferred_id`, while
`packages/loot-core/src/server/aql/schema/index.ts` maps public `transfer_id`
to that physical name. `packages/loot-core/src/mocks/setup.ts` runs the pinned
migrations after creating the base schema with `init.sql`. The old raw-row SQL
queried the public alias directly from the physical table. The support reader
now explicitly aliases physical transaction columns and captures category/payee
mapping tables plus the seeded category/group reference rows. Seeds remain
public `TransactionEntity` inputs passed through Actual's `db.insertTransaction`
schema converter. The original failure evidence is preserved unchanged under
`.artifacts/transaction-command-oracle/evidence/investigation/`; it records one
failed setup and 38 pending cases, with no handler result or undo observation.
The corrected recorder preserves the pre-handler reference snapshot as
`referencesBefore` and adds `referencesAfterHandler` and `referencesAfterUndo`
alongside the transaction-row and CRDT snapshots. The existing M4 injected
conflict only mutates a transaction note, so it does not add a reference-row
checkpoint.
The separately authorized `post-correction` invocation exited 1 after capturing
nine cases. The tenth case, `D2-split-error-clone`, failed because its
`mismatched-split` graph had no builder. The remaining 29 cases did not run.
Both failed invocations retain their original evidence; neither establishes
complete C4/C5 behavior.

The coordinator's subsequent fixture audit added the missing builder and fixed
unintended one-child split imbalance, same-parent selection using different
parents, keep/drop labels using ambiguous tied dates, and an invalid-pair case
that did not reach its intended paired-amount failure. The malformed reciprocal
fixture now has an existing peer with a wrong backlink rather than a missing
peer. Rule rows are included in reference snapshots so learning side effects
and their undo are observable. The corrected no-learning case records that the
real desktop duplicate payload omits `learnCategories`, plus rule snapshots and
change flags before the handler, after the handler, and after undo. It does not
enable learning in the oracle. The imported-metadata D2 source is reconciled so
the duplicate path's forced unreconciled output is observable rather than
indistinguishable from preservation.

All 39 input graphs are now constructed and validated before the first handler
invocation. Validation checks selected IDs, unique row IDs, intended split
balance, reciprocal transfer pairs, and the named same-parent, keep/drop and
invalid-pair boundaries. A local pure-fixture check constructed the preceding
corrected 39-case graph successfully without loading Actual or invoking any
handler. The approved no-learning rename and reconciled-source change require
fresh pure-fixture evidence before runtime handoff; the prior audit hashes no
longer validate this candidate. Fixture construction evidence is never
compatibility evidence.

The sole newly admitted label is `policy-admission-20260929`; the historical
labels remain explicitly spent and every existing evidence directory remains a
refusal. Authorization of the label is not authorization to execute: the main
coordinator owns the one-run decision. Do not delete or reuse prior evidence.
