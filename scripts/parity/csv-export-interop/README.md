# CSV export → Actual importer observation harness

This source-only candidate connects Actualist's production Swift CSV encoder to
the pinned Actual 26.9.0 parser and desktop mapping helpers. It does **not** run
Actual's import/apply workflow and does not claim a lossless split round trip.

## Inputs and owned outputs

- The read-only Actual checkout is
  `/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual`,
  at commit `59fe126f637d858c061e1eeedbef5436c8f2225a`.
- `source-freeze.sha256` covers the harness scripts/config/profile and README,
  the fixture producer and production encoder, the selected `scripts/test.sh`
  and destination-loader inputs, exact Node 24.21.0, and the pinned
  parser/export/mapping/dependency inputs. The machine-local
  `scripts/lib/destinations.sh` is read to select the simulator but is not
  copied or included in the manifest.
- Each attempt exclusively creates the fresh mode-0700
  `/Users/neil/CC/actualist-dev/.artifacts/csv-export-interop` directory. Any
  existing root or symlinked path is refused. Failure preserves the root and
  every receipt/log for owner review; there is no retry or cleanup path.
- Generated fixture, observations, COW overlay, Node home/cache/tmp, receipts,
  and logs remain under that DEV-owned output root. The established Dev
  `.derivedData` and `scripts/test.sh` lock remain under their existing DEV
  paths. The runner never removes or reclaims `.artifacts/.test-run.lock`.

The source freeze verifies the pinned sources; it is not a filesystem security
boundary. The copy and Node commands run with `readonly-inputs.sb`, which denies
all outbound/inbound networking and all writes under both
`/Users/neil/CC/actualist` and `/Users/neil/.yarn/berry/cache`. The profile does
not impose a general read allowlist or deny normal writes outside those protected
trees. Node's home, cache and temporary paths are redirected into the owned
output. The COW overlay is writable and isolated under that output. Xcode and
CoreSimulator run outside this Node/copy profile: their normal system-managed
writes and simulator IPC are expected. The main owner still audits simulator
hosts after the wrapper returns.
The Swift test contains no network operation, but the Xcode invocation is not
under an OS network-deny profile; the owner must ensure package resolution is
already satisfied locally. If Xcode would need a network fetch, stop and obtain
separate review of an Xcode-specific profile that preserves simulator IPC.

## One-shot orchestration and deadlines

`run-proposal.sh` loads the pinned simulator UDID and execs the single
`orchestrate.py` controller. Its monotonic 1,440-second deadline begins before
output creation, source/pin checks, source-freeze verification and the APFS
copy-on-write clone. Preparation is capped at 90 seconds. Swift is capped at
1,200 seconds; Node is capped at 120 seconds. Each stage is additionally capped
by the remaining shared deadline. The stage helper reserves a combined final
10-second cleanup/receipt window, with the final second reserved for its receipt;
the orchestrator reserves one second within each stage ceiling to reap the helper. Preparation
and the two stage ceilings total at most 1,410 seconds, leaving 30 seconds for
inter-stage checks, bounded postflight verification and final receipt work.
Postflight commands use the shared deadline and retain a two-second controller
reserve. Early completion leaves unused time; no later stage is lengthened
beyond its own ceiling.

Preparation commands are bounded, each in an exact owned process group. APFS
copy-on-write uses `/bin/cp -cR` inside the same protected-input profile. Git
verification uses `--no-optional-locks` and `GIT_OPTIONAL_LOCKS=0`. No package
installation or downloads are invoked.

The Swift stage invokes only the selected fixture method through the existing
`scripts/test.sh` wrapper. It uses the pinned `Actualist Dev` scheme,
machine-configured simulator UDID, and shared DEV `.derivedData`; caller
overrides are rejected. `TEST_RUNNER_` variables carry the fixture path and
encoder/test hashes into the test process. An interrupted or failed wrapper
leaves the wrapper's lock untouched and requires owner recovery. The receipt
does not claim simulator-host quiescence. If the Swift stage fails, is
interrupted, leaves its lock, or lacks either fixture file, the Node stage does
not start.

The Node stage runs the pinned Yarn release and Vitest from the COW overlay
inside the protected-input profile. It uses the exact Node binary and the
frozen Vitest parser/mapping sources. The stage helper checks and, if needed,
terminates only the exact process group it created. No next stage begins after
a failed or unresolved stage. Any unresolved helper/payload is recorded by
exact PID/PGID when available; outputs are retained for main-owner audit.

The initial fresh output root is exclusively created and its canonical identity
is rechecked before stages. This rejects static symlinks and path substitution
detected at those checks. It is not a defense against a concurrent same-user
replacement between checks and child path use; the protected-tree Seatbelt deny
remains authoritative for writes to the Actual checkout and global Yarn cache.

## Cases and interpretation

The production encoder generates ordinary debit and credit rows, a two-child
split family, all three status strings, embedded comma/quote/CRLF and Unicode,
formula-trigger strings in all exported string columns (including Date), empty
names, and `Int.min`. Actual's real `parseFile` must reproduce every expected
raw field. The real desktop `applyFieldMappings`, `parseDate`,
`parseAmountFields`, and `parseCategoryFields` then produce an observation.

The observation keeps raw and mapped values separate. It records that Account
is selected externally, Category_Group/Split_Amount/Cleared are not restored by
these mappings, status is a separate import choice, split rows are not
reconstructed, and JavaScript extreme-number precision is observational.

## Prerequisites and public command

This candidate is **not authorized to run**. A main-owner review and separate
bounded approval are still required. The pinned checkout must be clean, its
dependencies present, the configured simulator available, and no other test,
DerivedData, or simulator owner active.

Exact one-shot public command (not run during this source-only change):

```sh
cd /Users/neil/CC/actualist-dev
ACTUALIST_CSV_INTEROP_OUTPUT="$PWD/.artifacts/csv-export-interop" \
  scripts/parity/csv-export-interop/run-proposal.sh
```

The copy and Node/Yarn stages cannot access the network under Seatbelt. The
workflow does not intentionally access a server or live budget; however, the
Xcode stage's package-resolution networking is not OS-denied and must be
confirmed unnecessary before authorization. A passing observation means only
that this generated fixture passed the pinned parser/mapping stage;
compatibility remains unaccepted until the raw/mapped artifact and
simulator-host audit are reviewed.

## Approval-only fake orchestration diagnostic

`diagnose-orchestrator.py` is a separate source-only diagnostic entry point; it
does not change the public runner or production stage behavior. If separately
authorized, it imports only the deadline/stage coordinator and uses Python
fake-payload processes plus one synthetic unresolved receipt. It does not call
`run-proposal.sh`, read the pinned Actual checkout, create a fixture, or invoke
Node/Yarn, Xcode, Simulator, a server, network access or Seatbelt. It exclusively
creates a separate mode-0700 DEV artifact root and removes nothing.

Exact proposed diagnostic command (not run or authorized):

```sh
cd /Users/neil/CC/actualist-dev
python3 scripts/parity/csv-export-interop/diagnose-orchestrator.py
```

The driver uses a 28-second monotonic internal ceiling; the requested approval
ceiling is one invocation, no retry, at most 30 seconds. It writes
`diagnostic-report.json`, stage logs, stage receipts and owner/reaping receipts
under `.artifacts/csv-export-interop-diagnostic-<run-id>/`. Failure evidence is
retained. Acceptance requires the report to say `passed`, duration ≤28 seconds,
and each check to be true: stage cap wins when narrower; remaining total wins
when narrower; cleanup and receipt reserves fit inside both caps; the timed-out
fake process group and every fake supervisor are reaped by exact recorded IDs;
timeout/failure and a synthetic unresolved-quiescence receipt each stop the next
stage; and no diagnostic artifact is partially removed. The synthetic unresolved
case does not leave a live payload or claim a real quiescence failure.

This diagnostic and the real 1,440-second one-shot run require separate user
authorization. The diagnostic is recommended first because it exercises deadline
handoff and fail-closed/reaping evidence without touching the simulator or
production inputs.
