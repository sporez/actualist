// The sync merkle re-pull case plan: named cases plus seeded generated cases.
//
// Pure data. generate.mjs runs every case through Actual's own fullSync
// against the upstream mock sync server; verify.mjs rebuilds this plan without
// an oracle and compares it with the committed fixture. Expected outputs are
// never written here; they come only from the oracle.
//
// Every message is a payee name write: dataset "payees", column "name", row
// "p-<n>", value "S:<text>". Timestamps are full Actual timestamp strings.

import { createHash } from 'node:crypto';

export const SEED = 20261019;
export const TIME_ZONE = 'UTC';
export const DATASET = 'payees';
export const COLUMN = 'name';
export const CLIENT_NODE = 'cccccccccccccccc';
export const GROUP_ID = 'group';
export const FILE_ID = 'file';
export const GENERATED_CASES = 200;

const OTHER_NODES = ['aaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbb', 'dddddddddddddddd'];
const BASE_MILLIS = Date.UTC(2026, 6, 4, 12, 0, 0);
// All timestamps of a case fall in [BASE, BASE + WINDOW); the client clock reads one hour later.
const WINDOW_MILLIS = 3 * 60 * 60 * 1000;
const NOW_MILLIS = BASE_MILLIS + WINDOW_MILLIS + 60 * 60 * 1000;

export function mulberry32(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let value = Math.imul(state ^ (state >>> 15), 1 | state);
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value;
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

const timestampString = (offset, node) => `${new Date(BASE_MILLIS + offset).toISOString()}-0000-${node}`;
const byTimestamp = (left, right) => (left.timestamp < right.timestamp ? -1 : left.timestamp > right.timestamp ? 1 : 0);

// counts: shared, serverOlder, serverNewer, pending, unsent, phantom, during:[{atRequest, serverReceives?, clientCommits?}]
function buildCase({ id, source, description, seed, tags, counts }) {
  const rng = mulberry32(seed);
  const used = new Set();
  const pick = (low, high) => {
    for (;;) {
      const value = low + Math.floor(rng() * (high - low));
      if (!used.has(value)) {
        used.add(value);
        return value;
      }
    }
  };
  let rowCounter = 0;
  const nextRow = () => `p-${++rowCounter}`;
  const message = (offset, node) => {
    const row = nextRow();
    return { timestamp: timestampString(offset, node), row, value: `S:Synthetic ${row} v${Math.floor(rng() * 1000)}` };
  };
  const otherNode = () => OTHER_NODES[Math.floor(rng() * OTHER_NODES.length)];
  const anyNode = () => (rng() < 0.4 ? CLIENT_NODE : otherNode());

  const sharedHigh = Math.floor(WINDOW_MILLIS * 0.4);
  const shared = Array.from({ length: counts.shared }, () => message(pick(0, sharedHigh), anyNode()));
  const newestShared = shared.reduce((max, entry) => Math.max(max, Date.parse(entry.timestamp.slice(0, 24)) - BASE_MILLIS), -1);
  let lastSyncedOffset = (newestShared >= 0 ? newestShared : Math.floor(rng() * sharedHigh) + Math.floor(WINDOW_MILLIS * 0.1))
    + 1 + Math.floor(rng() * 60000);
  while (used.has(lastSyncedOffset)) lastSyncedOffset += 1;
  used.add(lastSyncedOffset);

  const clientUnsent = Array.from({ length: counts.unsent }, () => message(pick(0, lastSyncedOffset), CLIENT_NODE));
  const serverOnly = [
    ...Array.from({ length: counts.serverOlder }, () => message(pick(0, lastSyncedOffset), otherNode())),
    ...Array.from({ length: counts.serverNewer }, () => message(pick(lastSyncedOffset + 1, WINDOW_MILLIS), otherNode())),
  ];
  const clientPending = Array.from({ length: counts.pending }, () => message(pick(lastSyncedOffset + 1, WINDOW_MILLIS), CLIENT_NODE));
  const phantom = Array.from({ length: counts.phantom }, () => timestampString(pick(0, WINDOW_MILLIS), otherNode())).sort();

  const during = (counts.during ?? []).map(event => {
    if (event.serverReceives !== undefined) {
      return {
        atRequest: event.atRequest,
        serverReceives: Array.from({ length: event.serverReceives }, () => message(pick(0, WINDOW_MILLIS), otherNode())).sort(byTimestamp),
      };
    }
    return {
      atRequest: event.atRequest,
      clientCommits: Array.from({ length: event.clientCommits }, () => {
        const row = nextRow();
        return { dataset: DATASET, row, column: COLUMN, value: `S:Synthetic ${row} v${Math.floor(rng() * 1000)}` };
      }),
    };
  });

  return {
    id,
    source,
    description,
    seed,
    tags,
    now: new Date(NOW_MILLIS).toISOString(),
    setup: {
      lastSynced: timestampString(lastSyncedOffset, CLIENT_NODE),
      shared: shared.sort(byTimestamp),
      serverOnly: serverOnly.sort(byTimestamp),
      clientPending: clientPending.sort(byTimestamp),
      clientUnsent: clientUnsent.sort(byTimestamp),
      phantom,
    },
    during,
  };
}

const NO_COUNTS = { shared: 0, serverOlder: 0, serverNewer: 0, pending: 0, unsent: 0, phantom: 0, during: [] };

function named(id, description, tags, counts) {
  return buildCase({
    id: `named-${id}`,
    source: 'named',
    description,
    seed: SEED + 1000 + namedSeedCounter++,
    tags,
    counts: { ...NO_COUNTS, ...counts },
  });
}
let namedSeedCounter = 0;

function namedCases() {
  namedSeedCounter = 0;
  return [
    named('empty-noop', 'No messages anywhere.', ['noop'], {}),
    named('shared-only', 'Everything shared; nothing to send or receive.', ['noop'], { shared: 12 }),
    named('pending-1', 'One new local message.', ['pending'], { shared: 5, pending: 1 }),
    named('pending-499', '499 new local messages.', ['pending', 'large'], { shared: 5, pending: 499 }),
    named('pending-500', '500 new local messages.', ['pending', 'large'], { shared: 5, pending: 500 }),
    named('pending-501', '501 new local messages.', ['pending', 'large'], { shared: 5, pending: 501 }),
    named('pending-1600', '1600 new local messages.', ['pending', 'large'], { shared: 5, pending: 1600 }),
    named('server-newer-only', 'The server holds newer messages from another device.', ['server'], { shared: 5, serverNewer: 6 }),
    named('server-older-message', 'Another device message older than the client newest arrives.', ['server', 'merkle'], { shared: 8, serverOlder: 1 }),
    named('server-older-many', 'Several older messages from other devices plus a pending one.', ['server', 'merkle'], { shared: 10, serverOlder: 7, pending: 2 }),
    named('client-unsent-one', 'The server lacks one old client message.', ['unsent', 'merkle'], { shared: 8, unsent: 1 }),
    named('client-unsent-many', 'The server lacks several old client messages and the client has pending ones.', ['unsent', 'merkle'], { shared: 10, unsent: 6, pending: 3 }),
    named('client-unsent-and-server-older', 'Old client messages missing on the server and old server messages missing on the client.', ['unsent', 'server', 'merkle'], { shared: 10, unsent: 4, serverOlder: 4 }),
    named('commit-during-request-1', 'A local write lands while request 1 is in flight.', ['during'], { shared: 6, pending: 2, during: [{ atRequest: 1, clientCommits: 2 }] }),
    named('commit-during-request-2', 'A local write lands while request 2 (a re-pull round) is in flight.', ['during', 'merkle'], { shared: 8, unsent: 2, serverOlder: 2, during: [{ atRequest: 2, clientCommits: 2 }] }),
    named('commit-during-request-3', 'A local write lands while request 3 is in flight.', ['during', 'merkle'], { shared: 8, unsent: 3, serverOlder: 3, during: [{ atRequest: 3, clientCommits: 1 }] }),
    named('server-receives-during-request-1', 'Another device writes to the server while request 1 is in flight.', ['during', 'server'], { shared: 6, pending: 2, during: [{ atRequest: 1, serverReceives: 3 }] }),
    named('server-receives-during-request-2', 'Another device writes to the server while request 2 is in flight.', ['during', 'server', 'merkle'], { shared: 8, unsent: 2, serverOlder: 2, during: [{ atRequest: 2, serverReceives: 2 }] }),
    named('phantom', 'The server merkle holds a timestamp with no message behind it.', ['phantom', 'diverged'], { shared: 8, phantom: 1 }),
    named('phantom-with-pending', 'A phantom timestamp with pending local messages.', ['phantom', 'diverged'], { shared: 8, pending: 5, phantom: 1 }),
    named('mix-all', 'Pending, unsent, older and newer server messages and mid-sync events together.', ['mix', 'during', 'merkle'], {
      shared: 25, serverOlder: 8, serverNewer: 8, pending: 60, unsent: 6,
      during: [{ atRequest: 1, clientCommits: 2 }, { atRequest: 2, serverReceives: 3 }, { atRequest: 2, clientCommits: 1 }],
    }),
  ];
}

function generatedCases() {
  const cases = [];
  for (let index = 1; index <= GENERATED_CASES; index += 1) {
    const seed = SEED + index;
    const rng = mulberry32(seed ^ 0x9e3779b9);
    const between = (low, high) => low + Math.floor(rng() * (high - low + 1));
    const roll = rng();
    const pending = roll < 0.2 ? 0 : roll < 0.7 ? between(1, 50) : roll < 0.97 ? between(51, 200) : between(501, 700);
    const serverTotal = between(0, 40);
    const serverOlder = Math.floor(serverTotal * rng());
    const duringCount = rng() < 0.35 ? 0 : between(1, 3);
    const during = Array.from({ length: duringCount }, () => {
      const atRequest = between(1, 3);
      return rng() < 0.5 ? { atRequest, serverReceives: between(1, 5) } : { atRequest, clientCommits: between(1, 4) };
    });
    const phantom = rng() < 0.05 ? between(1, 2) : 0;
    const counts = {
      shared: between(0, 40),
      serverOlder,
      serverNewer: serverTotal - serverOlder,
      pending,
      unsent: rng() < 0.35 ? 0 : between(1, 15),
      phantom,
      during,
    };
    const tags = ['generated', ...(pending > 500 ? ['large'] : []), ...(phantom > 0 ? ['phantom'] : [])];
    cases.push(buildCase({
      id: `gen-${String(index).padStart(3, '0')}`,
      source: 'generated',
      description: `Seeded mix ${index}.`,
      seed,
      tags,
      counts,
    }));
  }
  return cases;
}

export function buildPlan() {
  return {
    dataset: DATASET,
    column: COLUMN,
    clientNode: CLIENT_NODE,
    groupId: GROUP_ID,
    fileId: FILE_ID,
    cases: [...namedCases(), ...generatedCases()],
  };
}

const OUTCOME = /^(ok|out-of-sync|error:.*)$/;

// The summary the runner records for a list: count, sha256 of the sorted entries joined by "\n",
// and the sorted entries when there are at most 20.
export function summarize(entries) {
  const sorted = [...entries].sort();
  const summary = { count: sorted.length, sha256: createHash('sha256').update(sorted.join('\n'), 'utf8').digest('hex') };
  if (sorted.length <= 20) summary.items = sorted;
  return summary;
}

function summaryFailures(name, value) {
  if (!value || !Number.isInteger(value.count) || !/^[0-9a-f]{64}$/.test(value.sha256 ?? '')) return [`${name} is not a summary`];
  const failures = [];
  const hasItems = Array.isArray(value.items);
  if (hasItems !== (value.count <= 20)) failures.push(`${name} items present only when count <= 20`);
  if (hasItems) {
    if (value.items.length !== value.count) failures.push(`${name} count differs from items`);
    if (JSON.stringify(summarize(value.items)) !== JSON.stringify(value)) failures.push(`${name} digest differs from items`);
  }
  return failures;
}

// Structural invariants of a recorded case. They restate what the harness itself guarantees and
// never assert an upstream result; a violation means the runner or the fixture is broken.
export function expectationFailures(record, planCase) {
  const failures = [];
  const result = record.result;
  if (!result) return ['result is missing'];
  if (!OUTCOME.test(result.outcome)) failures.push(`unknown outcome ${result.outcome}`);
  if (!Array.isArray(result.requests) || result.requests.length < 1) {
    failures.push('no /sync/sync request was recorded');
    return failures;
  }
  const setup = planCase.setup;
  const first = result.requests[0];
  if (first.since !== setup.lastSynced) failures.push('request 1 did not start at lastSynced');
  if (JSON.stringify(first.sentTimestamps) !== JSON.stringify(summarize(setup.clientPending.map(entry => entry.timestamp)))) {
    failures.push('request 1 did not send exactly the pending messages');
  }
  for (const [index, request] of result.requests.entries()) {
    failures.push(...summaryFailures(`request ${index + 1} sentTimestamps`, request.sentTimestamps));
    failures.push(...summaryFailures(`request ${index + 1} receivedTimestamps`, request.receivedTimestamps));
  }
  const final = result.final;
  if (!final) return [...failures, 'final is missing'];
  for (const key of ['serverTimestamps', 'clientTimestamps', 'clientPayees', 'serverMessagesFromClientCommits']) {
    failures.push(...summaryFailures(`final.${key}`, final[key]));
  }
  if (typeof final.merkleEqual !== 'boolean') failures.push('final.merkleEqual is not a boolean');
  const minted = (result.mintedCommits ?? []).map(commit => commit.timestamp);
  const clientSetup = [...setup.shared, ...setup.clientUnsent, ...setup.clientPending].map(entry => entry.timestamp);
  if (final.clientTimestamps?.count < clientSetup.length + minted.length) failures.push('client holds fewer messages than it was given');
  if (final.serverTimestamps?.count < setup.shared.length) failures.push('server holds fewer messages than were shared');
  const committed = planCase.during.flatMap(event => event.clientCommits ?? []);
  if (minted.length > committed.length) failures.push('more minted commits than planned');
  if (final.clientPayees?.count < clientSetup.length + minted.length) failures.push('client has fewer payees than messages');
  return failures;
}
