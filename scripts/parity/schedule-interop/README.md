# Schedule interoperability bridge source gate

Status: **source implementation present; runtime remains blocked on a new
explicit schedule live-lease grant**. The in-flight portability D0 child is
not this lease. Do not replace or extend it, and do not borrow its allowance.

This directory records the source-frozen boundary for a future genuine
Swift↔Actual schedule bridge. It deliberately contains no server bootstrap and
no substitute sync/CRDT implementation. A separate disposable live lease, not
`scripts/parity/d0-source-approved/`, must produce the operator-reviewed
handoff. Nothing here starts, initializes, seeds, or stops an Actual server.

## Production entrypoints traced

Pinned Actual source is the clean checkout at
`/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual`,
revision `59fe126f637d858c061e1eeedbef5436c8f2225a`.

The real Node automatic-advancement entrypoint is
`packages/loot-core/src/server/schedules/app.ts`:

- `advanceSchedulesService(syncSuccess)` performs paid-occurrence advancement
  and automatic posting.
- The initialized runtime exposes it as
  `internal.send('schedule/force-run-service')` through the registered handler.
- `packages/api/index.ts` initializes `@actual-app/core/server/main` and returns
  that production `lib`; this is not the old direct-handler surrogate.
- `api.downloadBudget(syncId)` opens the real downloaded peer and `api.sync()`
  reaches `api/sync`, production `sync/index.ts`, the protobuf encoder, the
  remote `/sync/sync` endpoint, and `receiveMessages` for local import.

The Node role is therefore source-reachable. The **Actualist automatic role is
not**: Packet 2C2 runtime/automatic posting is outside this authorization and no
production Actualist automatic service is available. Matrix case 6 remains
`BLOCKED`; it must never be reported as passed or skipped by substituting a
second Actual handler.

The Swift manual writer is
`LocalFirstActualStore.postSchedule`: it performs `pullAndReload` before
re-reading the review/status, atomically writes through
`BudgetDatabase.postScheduleOccurrence`, and schedules its normal outbox flush.
A future bridge must instantiate the store with the production
`ActualServerSyncClient`, retain the successful pre-write sync, and observe the
normal post-write flush. A fake transport, direct database call, copied handler,
or hand-written message encoder is not acceptable.

## Current hard gates

1. **No separate live lease is granted.** Portability D0 owns
   `127.0.0.1:5006` and its current child. This bridge does not start, attach
   to, or clean up that server, and it does not replace that child. The only
   proposed owner is the non-executed design in
   `.artifacts/sprint-next/schedule-interop-fixed-port-design.md`. This
   directory still contains no server bootstrap and no executable lease runner.
2. **One selector cannot truthfully complete all roles.** Case 6 needs an
   Actualist automatic writer, which remains unavailable by scope. It must stay
   blocked while the supported manual cases are split into bounded selectors.

The installed `xcodebuild` manual documents that `TEST_RUNNER_<VAR>` is
forwarded to every test-runner process with the prefix stripped. The Node peer
therefore invokes the unchanged `scripts/test.sh` wrapper with only these
non-secret values:

- `TEST_RUNNER_SCHEDULE_INTEROP_CONTROL_ORIGIN`
- `TEST_RUNNER_SCHEDULE_INTEROP_RUN_ID`
- `TEST_RUNNER_SCHEDULE_INTEROP_ACTUAL_REVISION`
- `TEST_RUNNER_SCHEDULE_INTEROP_FREEZE_ID`

`SCHEDULE_INTEROP_ADMITTED_REMOTE_ORIGIN` (operator environment, optional) names
one disposable lab server origin the peer may talk to besides loopback.

The test sees the corresponding `SCHEDULE_INTEROP_*` names. No custom
`.xctestrun`, scheme change, or shared runner edit is needed. Credentials stay
in a host mode-`0600` file and are delivered to the configured test only in the
body of a run-scoped loopback response; no secret enters argv, the
`TEST_RUNNER_*` environment, or committed output.

The test-local identity adaptation does not broaden shared fixture support. It
closes the helper's initial `file-1`/`group-1` session, imports the official
Node-created fixture through `BudgetFileManager`, registers the receipted
synthetic cloud file/group identity, and reopens it before real sync.

The earlier minimal helper database was rejected as the Node seed: Actual's
`importActual` unconditionally deletes `kvcache` and `kvcache_key`, which that
minimal fixture does not contain, before loading and migrating the budget. The
corrected source creates Actual's real starter through the initialized pinned
runtime, adds the synthetic account/schedule through public API methods, exports
that valid database, uploads it, and gives those exact archive bytes to Swift.
There is no fake schema workaround.

The future schedule live lease, not the portability D0 driver, supplies two
mode-`0600` JSON files to the Node process:
an operator-reviewed handoff with schema version, run ID, pinned Actual
revision, loopback server origin on a port other than 5006–5008, ownership nonce, exact synthetic budget name,
fresh file ID, baseline file IDs/hash, and a proof that the candidate is absent;
and a
credentials file with schema version, run ID, and disposable session token.
The baseline hash is SHA-256 of UTF-8 `JSON.stringify(sortedFileIDs)`.
Their paths remain Node-only environment values. The outer owner must
exclusively pre-create separate mode-`0700` run and cache roots with matching
mode-`0600` `.owner.json` nonce markers. The run root initially contains only
that marker, so handoff/credential files remain outside it; Vitest writes solely
below the distinct pre-owned cache root.

## Safety and evidence contract

- Accept only `http://127.0.0.1:<port>` as the handoff server origin, with no
  userinfo, query, fragment, or path. Reject ports 5006, 5007, and 5008. Do not accept a hostname
  aliases, or configured/personal endpoints. This peer does not start that
  server.
- Bind the recording proxy only to `127.0.0.1:5007` and the Swift control
  server only to `127.0.0.1:5008`. Do not fall back to an ephemeral port. A
  bind failure fails the run.
- Require exclusively pre-owned mode-`0700` run/cache roots and matching nonce
  markers before any bridge output. Refuse a mismatched marker or unexpected
  initial run-root content.
- Compare the live remote listing with the receipted baseline immediately before
  the first upload. After upload require exactly one live matching
  file-ID/name/group identity.
- Keep token/password material only in a mode-`0600` run-local credentials
  file. Never put it in argv, committed files, logs, manifests, or readable
  protocol captures.
- Keep both SQLite peers isolated. Only the disposable server may exchange
  messages between them.
- Capture synthetic pre/post transaction projections, raw protobuf
  request/response bytes, redacted decoded tuple hashes, applied counts, sync
  phase attribution, and hashes. Redact authorization and generated identifiers
  before writing human-readable output.
- A successful sync before every Swift manual post is mandatory. A successful
  sync alone is not acceptance.
- The earlier-date-rule case must reject the Swift write before commit when a
  rule moves the transaction before Actual's occurrence lower bound. The future
  Node side must independently establish its resulting paid/retry behavior.
- No result may claim distributed uniqueness. Isolated synced peers may converge
  two random transaction IDs.

`LocalFirstActualStoreScheduleInteropTests.swift` is disabled when the control
origin is absent. When configured, it uses the production
`ActualServerSyncClient`, establishes a successful sync, then calls production
`LocalFirstActualStore.postSchedule` (which performs its own second mandatory
sync) and awaits the normal store-created outbox flush task. The Node peer seeds
an official exported fixture through the owned API source overlay, downloads it into
an isolated client, then calls production `api.sync()` to import and assert the
Swift transaction.

The Node peer puts a transparent loopback proxy in front of the disposable
server for both production clients. It writes raw `/sync/sync` request/response
protobuf bodies mode `0600`, decodes message tuples through the owned CRDT source
overlay backed by pinned generated schemas (never a bespoke codec), and records only hashes and
synthetic counts in the redacted result manifest.

Vitest's root, cache, data directories, and evidence paths are all owned
Actualist paths. The overlays use explicit pinned source imports and the freeze
hashes every direct entry/schema/plugin/filesystem source; the protected pinned
checkout is never selected as the runtime cwd or output root.

`cases.json` is the frozen scenario/role inventory. `source-freeze.json` and
`verify-source-freeze.sh` protect the reviewed source boundary; the verifier
only hashes local files and performs no build, test, Node, server, simulator,
network, or oracle action.

## Proposed bounded execution after all gates pass

This peer does not launch itself. The only proposed owner is
`.artifacts/sprint-next/schedule-interop-fixed-port-design.md`. Presence of
this source is not a grant. The lease must not borrow the in-flight D0
allowance.

1. One new explicit grant with the named ceiling in that design. No retry.
2. One Node bridge process using pinned `@actual-app/api` and its production
   importer/runtime. It owns exactly one unchanged-wrapper child invocation.
3. One focused Swift invocation per pre-approved selector using the installed
   `TEST_RUNNER_` forwarding seam; no batching into a near-full suite and no
   parallelism override.
4. No retries. Any infrastructure failure consumes that run and stops the gate.

The first supported selector should remain:

```text
LocalFirstActualStoreScheduleInteropTests/realSyncFirstSwiftPostExportsActualMessages
```

The schedule live lease, not the D0 driver, would launch the pinned source
test with this environment shape after it has created the reviewed handoff and
credentials files. `SCHEDULE_INTEROP_D0_HANDOFF_FILE` is a historical name; the
producer is the schedule lease. Values shown here are paths/labels, never
credential contents. This command is not granted:

```sh
SCHEDULE_INTEROP_RUN_ID="$RUN_ID" \
SCHEDULE_INTEROP_ACTUALIST_ROOT=/Users/neil/CC/actualist-dev \
SCHEDULE_INTEROP_RUN_ROOT="/Users/neil/CC/actualist-dev/.artifacts/parity-sprint-20260927/schedule-interop/$RUN_ID" \
SCHEDULE_INTEROP_CACHE_ROOT="/Users/neil/CC/actualist-dev/.artifacts/parity-sprint-20260927/schedule-interop/cache-$RUN_ID" \
SCHEDULE_INTEROP_D0_HANDOFF_FILE="$D0_HANDOFF_0600" \
SCHEDULE_INTEROP_CREDENTIAL_FILE="$D0_CREDENTIALS_0600" \
node /Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/.yarn/releases/yarn-4.17.1.cjs \
  vitest run \
  --config /Users/neil/CC/actualist-dev/scripts/parity/schedule-interop/node-peer.vitest.config.ts \
  /Users/neil/CC/actualist-dev/scripts/parity/schedule-interop/node-peer.test.ts
```

The schedule live lease remains responsible for the approved exact-process
deadline, termination/reap evidence, source-freeze check, and cleanup. This
peer does not start or initialize the server, does not bind port 5006, and has
no fallback or retry.

Case 6 cannot enter that acceptance run until Packet 2C2 separately supplies an
Actualist automatic role. A passing manual bridge does not establish automatic
posting or distributed uniqueness.
