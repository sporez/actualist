# Sync merkle re-pull parity harness

Records what upstream Actual's `fullSync` (`_fullSync` in
`packages/loot-core/src/server/sync/index.ts`) does against a sync server in many
scenarios, at the pinned release (`config/parity/oracle-pin.json`, v26.10.0).
This directory holds only the generator side; the Swift replay is separate.

Upstream sends `getMessagesSince(since)` (every local `messages_crdt` row with
timestamp > since) on every round, then recurses with
`since = Timestamp(diffTime, 0, '0')` until the server merkle matches the client
merkle. A round with the same `diffTime` ten times, or 100 rounds, rebuilds the
merkle and throws `SyncError('out-of-sync')`.

- `generate.mjs`: runs the plan inside the oracle checkout under vitest and
  writes the fixture. `--check` regenerates into a temporary directory and
  diffs against the committed fixture.
- `verify.mjs`: checks the committed fixture against the manifest and the plan.
  Needs no oracle.
- `cases.mjs`: the plan (named and seeded cases) and structural invariants. Pure
  data, no upstream expectations.
- `oracle-runner.template`: the vitest test copied into the oracle for one run
  and removed afterwards.
- Fixture: `ActualistTests/Fixtures/ActualCore26_10_0/SyncMerkle/`
  (`sync-merkle-contract.json`, `sync-merkle-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/parity/sync-merkle/generate.mjs [--check]
node scripts/parity/sync-merkle/verify.mjs
```

The oracle checkout must be at the pinned commit with a clean tree and
`yarn install` done. It is checked before and after the run and is never
written to except for the temporary runner, which is removed in a `finally`.
Generation takes about 5 to 7 seconds in total for all 221 cases. Two
consecutive runs produce byte-identical files. The contract is about 3.6 MB.

## Environment

- The client is an in-memory SQLite database from upstream's own test setup,
  with `setSyncingMode('enabled')`, `groupId`, `cloudFileId` and
  `lastSyncedTimestamp` set in prefs, and the clock replaced with node id
  `cccccccccccccccc`.
- The server is upstream's `mockSyncServer`, reached through the repo's
  `postBinary` mock. Its `/sync/sync` handler is wrapped to count requests and
  run events; the mock itself answers every request.
- `Date.now()` is frozen at `now` of each case (one hour after the window, so
  every setup timestamp is in the past and none trips the clock-drift check).
- `TZ=UTC`.

## What a case is

Every message writes a payee name: dataset `payees`, column `name`, row
`p-<n>`, value `S:<text>` (the contract header `message` records dataset,
column, client node, group id and file id). Timestamps are full Actual strings
such as `2026-07-04T12:00:00.000Z-0000-aaaaaaaaaaaaaaaa`.

- `setup` (applied before `fullSync`):
  - `lastSynced`: the client's `lastSyncedTimestamp` (at or after the newest
    shared message).
  - `shared`: on the client (`applyMessages`) and on the server.
  - `serverOnly`: on the server only; some older, some newer than
    `lastSynced`.
  - `clientPending`: on the client only, newer than `lastSynced` (what round 1
    sends).
  - `clientUnsent`: on the client only, older than `lastSynced` (only the
    merkle loop can find them).
  - `phantom`: timestamps inserted into the mock server's merkle with no
    message behind them (a genuinely diverged server).
  - Each message is `{ timestamp, row, value }`.
- `during`: events keyed to the Nth `/sync/sync` request (1-based), run when
  that request arrives, before the mock server processes it. An event that
  names a request that never happens does nothing.
  - `{ atRequest, serverReceives: [message] }`: another device pushes to the
    server.
  - `{ atRequest, clientCommits: [{ dataset, row, column, value }] }`: client
    local writes minted with `Timestamp.send()` and applied with
    `applyMessages` (the write path of `sendMessages` without its
    `scheduleFullSync`, which would wait on the sync already running).
- `now`, `seed`, `tags`, `source`, `description`.

## Recorded result (`result`, from upstream only)

- `outcome`: `ok`, `out-of-sync`, or `error:<message>`.
- `requests`: one entry per `/sync/sync` request in arrival order:
  `{ since, sentTimestamps, receivedTimestamps }` (summaries, below).
  `receivedTimestamps` is what the mock server answered with. `sentCount` is
  dropped; it equals `sentTimestamps.count`.
- `mintedCommits`: `[{ atRequest, row, timestamp }]` for each planned client
  commit that ran.
- `final`:
  - `serverTimestamps`: real messages on the server.
  - `clientTimestamps`: client `messages_crdt` timestamps.
  - `merkleEqual`: `merkle.diff(server merkle, client merkle) === null`.
  - `clientPayees`: client payee rows `p-*`; an entry is `id + "\t" + name`.
  - `serverMessagesFromClientCommits`: minted timestamps that reached the
    server.

Every list above is a summary `{ "count": N, "sha256": "<hex>", "items": [...] }`.
`items` (the entries sorted with the default JS string sort) is present only
when N <= 20. `sha256` is the lowercase hex SHA-256 of the UTF-8 string made by
sorting the entries the same way and joining them with `"\n"` (no trailing
newline); an empty list hashes the empty string. A timestamp entry is the
timestamp string.

## Cases

221 cases, seed `20261019`.

- **Named (21)**: empty no-op; shared only; pending 1, 499, 500, 501 and 1600;
  server messages newer only; an older message from another device; many older
  server messages; a missing old client message (one, many, and with older
  server messages); a client commit during request 1, 2 and 3; the server
  receiving another device's message during request 1 and 2; phantom with and
  without pending messages; a mix of everything.
- **Generated (200)** with `mulberry32(20261019 + n)`: shared 0-40, server-only
  0-40 (split older/newer), unsent 0-15, pending 0-700 (about 20% zero, 50% 1-50,
  27% 51-200, 3% 501-700), 0-3 events, phantom (1-2 entries) in about 5%.
  Pending is capped at 700 to keep the fixture small; 1600 is a named case.

## Observed upstream behavior

Recorded as oracle behavior, not decided here.

- Pending 1, 499, 500, 501 and 1600 all finish `ok` in one request: upstream
  sends every pending message at once.
- A message the server lacks but the client holds older than `lastSynced`
  (unsent) is found by the merkle loop and re-sent in a later round, ending
  `ok`.
- Every non-phantom case, 211 in all, ends `ok` with equal merkles. Every phantom
  case ends `out-of-sync` after 11 requests (13 in gen-018, where a
  client commit during request 2 changed the local clock and reset the counter once).
- A round sends all client messages newer than its `since`, including ones
  already on the server (later rounds of the mix case resend 73, 76, 83, 95,
  108 messages).
- A change of the local clock during a round (a mid-sync commit, or received
  messages advancing it) resets the guard counter (`localTimeChanged`).

## Swift replay

`ActualistTests/SyncMerkleOracleReplayTests.swift` replays every case through
the production sync (`SyncMerkleOracleReplaySupport.swift`): a starter budget
whose `messages_crdt` holds `shared`, `clientPending` and `clientUnsent`, with
`clientPending` also queued in `actualist_outbox` (base timestamp `lastSynced`);
`MerkleAwareSyncTransport` seeded with `shared` and `serverOnly` plus the
phantom timestamps; then `LocalFirstActualStore.refresh` (flush, then pull).

Compared per case: `outcome`, `merkleEqual`, the final server and client
timestamp sets (count and digest), the client's `p-*` payee rows (digest) and
the number of minted commits. Not compared: the request sequence. Actualist
uploads its outbox in batches of 500 with an upload confirmation, runs the
flush and the pull as separate requests, and after a merkle rebuild retries ten
more rounds where upstream gives up at once, so requests differ by design while
the outcome and final state must match.

Two replay rules follow from that:

- A mid-sync commit is minted by each client's own clock, so the replay swaps
  each timestamp it minted for upstream's minted timestamp of the same row
  before comparing sets.
- Only events upstream fired are replayed. An event keyed to a request number
  upstream never reached did not happen in the oracle run; Actualist makes more
  requests per sync and would otherwise reach it.

On the code before the re-send fix (re-pull rounds that only pulled) 166 of the
221 cases fail, 163 of them `out-of-sync` where upstream ends `ok`.
