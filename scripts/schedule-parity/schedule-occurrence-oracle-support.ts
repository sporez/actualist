import { Buffer } from 'node:buffer';

import {
  getClock,
  makeClock,
  serializeClock,
  setClock,
  Timestamp,
} from '@actual-app/crdt';

import * as sqlite from '#platform/server/sqlite';
import { aqlQuery } from '#server/aql';
import * as db from '#server/db';
import { loadMappings } from '#server/db/mappings';
import { app as schedulesApp } from '#server/schedules/app';
import {
  deserializeValue,
  receiveMessages,
  setSyncingMode,
  type Message,
} from '#server/sync';
import {
  loadRules,
  resetState as resetRules,
} from '#server/transactions/transaction-rules';
import {
  DEFAULT_UPCOMING_SCHEDULE_DAYS,
  getHasTransactionsQuery,
  getStatus,
} from '#shared/schedules';
import { q } from '#shared/query';

export type Peer = {
  bytes: Uint8Array;
  label: string;
  node: string;
};

export type RawCRDTMessage = {
  column: string;
  dataset: string;
  id: number;
  row: string;
  timestamp: string;
  value: string;
};

export type CapturedBatch = {
  messages: Message[];
  operation: string;
  peer: string;
  rawMessages: RawCRDTMessage[];
};

export type RawTransaction = {
  account: string;
  amount: number;
  date: number;
  id: string;
  is_child: number;
  is_parent: number;
  parent_id: string | null;
  payee: string | null;
  schedule: string | null;
  tombstone: number;
  transfer_id: string | null;
};

type RawSchedule = Record<string, string | number | null>;
type RawRule = Record<string, string | number | null>;
type RawNextDate = Record<string, string | number | null>;

export type ScheduleSnapshot = {
  crdt: RawCRDTMessage[];
  domainSchedule: Record<string, unknown> | null;
  graph: RawTransaction[];
  nextDate: RawNextDate | null;
  occurrenceTransactionIDs: string[];
  rawRule: RawRule | null;
  rawSchedule: RawSchedule | null;
  scheduleID: string;
  status: string | null;
};

export type ExchangeStep = {
  after: ScheduleSnapshot;
  applied: CapturedBatch;
  before: ScheduleSnapshot;
  insertedRawMessages: RawCRDTMessage[];
  receiver: string;
};

let activePeer: Peer | null = null;

const PEER_NODE_ID_PATTERN = /^[0-9A-F]{16}$/;

function validatedPeerNodeID(node: string, label: string): string {
  if (!PEER_NODE_ID_PATTERN.test(node)) {
    throw new Error(
      `Oracle peer ${label} has invalid CRDT node ID ${JSON.stringify(node)}; expected 16 uppercase hexadecimal characters`,
    );
  }
  return node;
}

export function assertPeerNodeClockRoundTrips(
  nodeIDs: Readonly<Record<string, string>>,
): void {
  const ownersByNodeID = new Map<string, string>();

  for (const [owner, candidate] of Object.entries(nodeIDs)) {
    const nodeID = validatedPeerNodeID(candidate, owner);
    const existingOwner = ownersByNodeID.get(nodeID);
    if (existingOwner != null) {
      throw new Error(
        `Oracle peer node ID collision: ${existingOwner} and ${owner} both use ${nodeID}`,
      );
    }
    ownersByNodeID.set(nodeID, owner);

    const serializedClock = serializeClock(
      makeClock(new Timestamp(0, 0, nodeID)),
    );
    const clockRecord = JSON.parse(serializedClock) as { timestamp?: unknown };
    const serializedTimestamp = clockRecord.timestamp;
    const parsedTimestamp =
      typeof serializedTimestamp === 'string'
        ? Timestamp.parse(serializedTimestamp)
        : null;
    if (
      parsedTimestamp == null ||
      parsedTimestamp.node() !== nodeID ||
      parsedTimestamp.toString() !== serializedTimestamp
    ) {
      throw new Error(
        `Oracle peer ${owner} node ID does not round-trip through Actual clock serialization: ${JSON.stringify(serializedTimestamp)}`,
      );
    }
  }
}

async function saveAndCloseActivePeer(): Promise<void> {
  if (activePeer == null) {
    if (db.getDatabase() != null) {
      db.closeDatabase();
    }
    return;
  }
  if (db.getDatabase() == null) {
    activePeer = null;
    return;
  }

  activePeer.bytes = new Uint8Array(
    await sqlite.exportDatabase(db.getDatabase()),
  );
  db.closeDatabase();
  activePeer = null;
}

async function reloadRuntimeForCurrentDatabase(): Promise<void> {
  await schedulesApp.stopServices();
  await loadMappings();
  await loadRules();
  schedulesApp.startServices();
}

export async function activatePeer(peer: Peer): Promise<void> {
  if (activePeer === peer) {
    return;
  }

  await saveAndCloseActivePeer();
  // The pinned node/electron backend accepts an in-memory database only as a
  // Node Buffer. A plain Uint8Array is valid for the browser backend but is
  // interpreted as an invalid filename by better-sqlite3.
  db.setDatabase(await sqlite.openDatabase(Buffer.from(peer.bytes)));
  await db.loadClock();
  await reloadRuntimeForCurrentDatabase();
  activePeer = peer;
}

export async function persistActivePeer(): Promise<void> {
  if (activePeer == null || db.getDatabase() == null) {
    return;
  }

  activePeer.bytes = new Uint8Array(
    await sqlite.exportDatabase(db.getDatabase()),
  );
}

export async function closeOracleDatabase(): Promise<void> {
  await schedulesApp.stopServices();
  await saveAndCloseActivePeer();
  setSyncingMode('disabled');
  resetRules();
}

export async function resetOracleDatabase(): Promise<void> {
  await closeOracleDatabase();
  await global.emptyDatabase()();
  await loadMappings();
  await loadRules();
  schedulesApp.startServices();
  setSyncingMode('offline');
}

export async function exportSeedDatabase(): Promise<Uint8Array> {
  if (activePeer != null) {
    await persistActivePeer();
    return new Uint8Array(activePeer.bytes);
  }

  const database = db.getDatabase();
  if (database == null) {
    throw new Error('Cannot export an unopened oracle database');
  }
  return new Uint8Array(await sqlite.exportDatabase(database));
}

export async function makePeer(
  seed: Uint8Array,
  label: string,
  node: string,
): Promise<Peer> {
  const peer = {
    bytes: new Uint8Array(seed),
    label,
    node: validatedPeerNodeID(node, label),
  };
  await activatePeer(peer);

  const previousClock = getClock();
  const peerClock = makeClock(
    new Timestamp(
      previousClock.timestamp.millis(),
      previousClock.timestamp.counter(),
      peer.node,
    ),
    previousClock.merkle,
  );
  setClock(peerClock);
  db.runQuery(
    'INSERT OR REPLACE INTO messages_clock (id, clock) VALUES (1, ?)',
    [serializeClock(peerClock)],
  );
  await persistActivePeer();
  return peer;
}

async function latestMessageID(): Promise<number> {
  const row = await db.first<{ id: number | null }>(
    'SELECT MAX(id) AS id FROM messages_crdt',
  );
  return row?.id ?? 0;
}

async function rawMessagesAfter(id: number): Promise<RawCRDTMessage[]> {
  return db.all<RawCRDTMessage>(
    `SELECT id, timestamp, dataset, row, column, value
       FROM messages_crdt
      WHERE id > ?
      ORDER BY id`,
    [id],
  );
}

function decodedMessage(row: RawCRDTMessage): Message {
  const timestamp = Timestamp.parse(row.timestamp);
  if (timestamp == null) {
    throw new Error(`Invalid CRDT timestamp in oracle row ${row.id}`);
  }

  return {
    column: row.column,
    dataset: row.dataset,
    row: row.row,
    timestamp,
    value: deserializeValue(String(row.value)),
  };
}

export async function captureOperation(
  peer: Peer,
  operation: string,
  action: () => Promise<unknown>,
): Promise<CapturedBatch> {
  await activatePeer(peer);
  const cursor = await latestMessageID();
  await action();
  const rawMessages = await rawMessagesAfter(cursor);
  await persistActivePeer();

  return {
    messages: rawMessages.map(decodedMessage),
    operation,
    peer: peer.label,
    rawMessages,
  };
}

export async function applyBatch(
  receiver: Peer,
  batch: CapturedBatch,
  scheduleID: string,
): Promise<ExchangeStep> {
  await activatePeer(receiver);
  const before = await scheduleSnapshot(scheduleID);
  const cursor = await latestMessageID();
  await receiveMessages(batch.messages);
  const insertedRawMessages = await rawMessagesAfter(cursor);
  const after = await scheduleSnapshot(scheduleID);
  await persistActivePeer();

  return {
    after,
    applied: batch,
    before,
    insertedRawMessages,
    receiver: receiver.label,
  };
}

function graphForSchedule(
  allTransactions: RawTransaction[],
  scheduleID: string,
): RawTransaction[] {
  const connectedIDs = new Set(
    allTransactions
      .filter(transaction => transaction.schedule === scheduleID)
      .map(transaction => transaction.id),
  );

  let changed = true;
  while (changed) {
    changed = false;
    for (const transaction of allTransactions) {
      const isConnected =
        connectedIDs.has(transaction.id) ||
        (transaction.parent_id != null &&
          connectedIDs.has(transaction.parent_id)) ||
        (transaction.transfer_id != null &&
          connectedIDs.has(transaction.transfer_id)) ||
        allTransactions.some(
          candidate =>
            connectedIDs.has(candidate.id) &&
            (candidate.parent_id === transaction.id ||
              candidate.transfer_id === transaction.id),
        );

      if (isConnected && !connectedIDs.has(transaction.id)) {
        connectedIDs.add(transaction.id);
        changed = true;
      }
    }
  }

  return allTransactions
    .filter(transaction => connectedIDs.has(transaction.id))
    .sort((left, right) => left.id.localeCompare(right.id));
}

function relevantCRDTMessages(
  messages: RawCRDTMessage[],
  scheduleID: string,
  relatedIDs: Set<string>,
): RawCRDTMessage[] {
  return messages.filter(message => {
    if (relatedIDs.has(message.row) || message.row === scheduleID) {
      return true;
    }
    return String(message.value).includes(scheduleID);
  });
}

export async function scheduleSnapshot(
  scheduleID: string,
): Promise<ScheduleSnapshot> {
  const rawSchedule =
    (await db.first<RawSchedule>('SELECT * FROM schedules WHERE id = ?', [
      scheduleID,
    ])) ?? null;
  const nextDate =
    (await db.first<RawNextDate>(
      'SELECT * FROM schedules_next_date WHERE schedule_id = ?',
      [scheduleID],
    )) ?? null;
  const rawRule = rawSchedule?.rule
    ? ((await db.first<RawRule>('SELECT * FROM rules WHERE id = ?', [
        rawSchedule.rule,
      ])) ?? null)
    : null;

  const allTransactions = await db.all<RawTransaction>(
    `SELECT id,
            isParent AS is_parent,
            isChild AS is_child,
            parent_id,
            date,
            acct AS account,
            amount,
            description AS payee,
            transferred_id AS transfer_id,
            schedule,
            tombstone
       FROM transactions
      WHERE tombstone = 0
      ORDER BY id`,
  );
  const graph = graphForSchedule(allTransactions, scheduleID);
  const occurrenceTransactionIDs = graph
    .filter(transaction => transaction.schedule === scheduleID)
    .map(transaction => transaction.id)
    .sort();

  const {
    data: [domainScheduleValue],
  } = await aqlQuery(q('schedules').filter({ id: scheduleID }).select('*'));
  const domainSchedule = domainScheduleValue
    ? (domainScheduleValue as Record<string, unknown>)
    : null;
  let status: string | null = null;
  if (domainScheduleValue != null) {
    const { data: hasTransactions } = await aqlQuery(
      getHasTransactionsQuery([domainScheduleValue]),
    );
    const hasTransaction = hasTransactions
      .filter(Boolean)
      .some(row => row.schedule === scheduleID);
    status = getStatus(
      domainScheduleValue.next_date,
      domainScheduleValue.completed,
      hasTransaction,
      domainScheduleValue.custom_upcoming_length ??
        DEFAULT_UPCOMING_SCHEDULE_DAYS,
    );
  }

  const relatedIDs = new Set<string>([
    scheduleID,
    ...graph.map(transaction => transaction.id),
  ]);
  if (nextDate?.id) {
    relatedIDs.add(String(nextDate.id));
  }
  if (rawSchedule?.rule) {
    relatedIDs.add(String(rawSchedule.rule));
  }
  const crdt = relevantCRDTMessages(
    await db.all<RawCRDTMessage>(
      `SELECT id, timestamp, dataset, row, column, value
         FROM messages_crdt
        ORDER BY id`,
    ),
    scheduleID,
    relatedIDs,
  );

  return {
    crdt,
    domainSchedule,
    graph,
    nextDate,
    occurrenceTransactionIDs,
    rawRule,
    rawSchedule,
    scheduleID,
    status,
  };
}

export async function snapshotPeer(
  peer: Peer,
  scheduleID: string,
): Promise<ScheduleSnapshot> {
  await activatePeer(peer);
  return scheduleSnapshot(scheduleID);
}

export function transactionDates(snapshot: ScheduleSnapshot): number[] {
  return snapshot.graph
    .filter(transaction => transaction.schedule === snapshot.scheduleID)
    .map(transaction => transaction.date)
    .sort();
}

export function requireOracle(
  condition: unknown,
  criterion: string,
  details?: unknown,
): asserts condition {
  if (!condition) {
    const suffix = details === undefined ? '' : `: ${JSON.stringify(details)}`;
    throw new Error(`schedule occurrence acceptance failed — ${criterion}${suffix}`);
  }
}
