import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

import MockDate from 'mockdate';

import { aqlQuery } from '#server/aql';
import * as db from '#server/db';
import {
  advanceSchedulesService,
  app as schedulesApp,
  createSchedule,
  setNextDate,
  skipNextDate,
} from '#server/schedules/app';
import { updateRule } from '#server/transactions/transaction-rules';
import { q } from '#shared/query';
import type { RuleActionEntity, RuleConditionEntity } from '#types/models';

import {
  activatePeer,
  applyBatch,
  captureOperation,
  closeOracleDatabase,
  exportSeedDatabase,
  makePeer,
  persistActivePeer,
  requireOracle,
  resetOracleDatabase,
  scheduleSnapshot,
  snapshotPeer,
  transactionDates,
  type CapturedBatch,
  type ExchangeStep,
  type Peer,
  type ScheduleSnapshot,
} from './schedule-occurrence-oracle-support';

const EXPECTED_COMMIT = '59fe126f637d858c061e1eeedbef5436c8f2225a';
const TODAY = '2026-09-27';
const evidencePath = process.env.ACTUAL_SCHEDULE_PARITY_EVIDENCE;

type CaseEvidence = {
  acceptance: Record<string, unknown>;
  batches?: CapturedBatch[];
  exchanges?: ExchangeStep[];
  final?: Record<string, ScheduleSnapshot>;
  name: string;
  snapshots?: Record<string, ScheduleSnapshot>;
  unresolvedBlockers?: string[];
};

type OracleEvidence = {
  cases: CaseEvidence[];
  completed: boolean;
  failedCriterion: string | null;
  generatedAt: string;
  harness: {
    actualCommit: string;
    actualTag: string;
    actualVersion: string;
    peerExecution: string;
    schemaVersion: number;
  };
  productGate: {
    automaticPosting: string;
    duplicateFinding: string | null;
    manualPosting: string;
  };
  unresolvedBlockers: string[];
};

const evidence: OracleEvidence = {
  cases: [],
  completed: false,
  failedCriterion: null,
  generatedAt: new Date().toISOString(),
  harness: {
    actualCommit: EXPECTED_COMMIT,
    actualTag: 'v26.9.0',
    actualVersion: '26.9.0',
    peerExecution:
      'sequential global-database switching across independently cloned offline peers',
    schemaVersion: 1,
  },
  productGate: {
    automaticPosting: 'blocked-pending-oracle-result',
    duplicateFinding: null,
    manualPosting: 'blocked-pending-oracle-result',
  },
  unresolvedBlockers: [
    'Actualist has no posting implementation in this packet. Any peer labeled Actualist candidate below runs the pinned Actual v26.9.0 handler as an explicit surrogate; role reversal is not Actualist interoperability evidence.',
  ],
};

function writeEvidence(): void {
  if (!evidencePath) {
    throw new Error('ACTUAL_SCHEDULE_PARITY_EVIDENCE is required');
  }
  const destination = resolve(evidencePath);
  mkdirSync(dirname(destination), { recursive: true });
  writeFileSync(destination, `${JSON.stringify(evidence, null, 2)}\n`);
}

function localNoon(year: number, month: number, day: number): Date {
  return new Date(year, month - 1, day, 12, 0, 0, 0);
}

async function createBaseSchedule({
  date,
  forcedNextDate,
  id,
  postsTransaction,
  dateOperator = 'is',
  payee,
}: {
  date: string | Record<string, unknown>;
  dateOperator?: 'is' | 'isapprox';
  forcedNextDate?: string;
  id: string;
  payee?: string;
  postsTransaction: boolean;
}): Promise<{ accountID: string; scheduleID: string; seed: Uint8Array }> {
  await resetOracleDatabase();
  const accountID = `${id}-account`;
  await db.insertAccount({
    id: accountID,
    name: `${id} Checking`,
    offbudget: 0,
    closed: 0,
  });

  const conditions: RuleConditionEntity[] = [
    { op: 'is', field: 'account', value: accountID },
    { op: 'is', field: 'amount', value: -12000 },
    {
      op: dateOperator,
      field: 'date',
      value: date,
    } as RuleConditionEntity,
  ];
  if (payee) {
    conditions.splice(1, 0, { op: 'is', field: 'payee', value: payee });
  }

  await createSchedule({
    schedule: {
      id,
      name: id,
      posts_transaction: postsTransaction,
    },
    conditions,
  });

  if (forcedNextDate) {
    const nextDateRow = await db.first<{ id: string }>(
      'SELECT id FROM schedules_next_date WHERE schedule_id = ?',
      [id],
    );
    requireOracle(nextDateRow, `${id} has a next-date row to force`);
    const storedDate = Number(forcedNextDate.replaceAll('-', ''));
    await db.update('schedules_next_date', {
      id: nextDateRow.id,
      local_next_date: storedDate,
      local_next_date_ts: Date.now(),
      base_next_date: storedDate,
      base_next_date_ts: Date.now(),
    });
  }

  return { accountID, scheduleID: id, seed: await exportSeedDatabase() };
}

async function manualPost(peer: Peer, scheduleID: string, today = false) {
  return captureOperation(peer, today ? 'manual-post-today' : 'manual-post', () =>
    schedulesApp.handlers['schedule/post-transaction']({
      id: scheduleID,
      ...(today ? { today: true } : {}),
    }),
  );
}

async function automaticAdvance(peer: Peer, operation: string) {
  return captureOperation(peer, operation, () => advanceSchedulesService(true));
}

async function mergeBothOrders({
  batchA,
  batchB,
  scheduleID,
  seed,
}: {
  batchA: CapturedBatch;
  batchB: CapturedBatch;
  scheduleID: string;
  seed: Uint8Array;
}) {
  const observerAB = await makePeer(seed, 'observer-a-then-b', 'observer-ab');
  const observerBA = await makePeer(seed, 'observer-b-then-a', 'observer-ba');

  const abFirst = await applyBatch(observerAB, batchA, scheduleID);
  const abSecond = await applyBatch(observerAB, batchB, scheduleID);
  const baFirst = await applyBatch(observerBA, batchB, scheduleID);
  const baSecond = await applyBatch(observerBA, batchA, scheduleID);
  const replay = await applyBatch(observerAB, batchA, scheduleID);

  requireOracle(
    JSON.stringify(abSecond.after.graph) === JSON.stringify(baSecond.after.graph),
    'both CRDT exchange orders converge to the same transaction graph',
    { ab: abSecond.after.graph, ba: baSecond.after.graph },
  );
  requireOracle(
    JSON.stringify(replay.before.graph) === JSON.stringify(replay.after.graph),
    'replaying one generated batch is idempotent and is not a second generation',
    { before: replay.before.graph, after: replay.after.graph },
  );
  requireOracle(
    replay.insertedRawMessages.length === 0,
    'an exact CRDT replay inserts no new raw messages',
    replay.insertedRawMessages,
  );

  return {
    exchanges: [abFirst, abSecond, baFirst, baSecond, replay],
    final: {
      observerAB: abSecond.after,
      observerBA: baSecond.after,
    },
  };
}

async function caseOneTimeManualThenPeerAdvance(): Promise<CaseEvidence> {
  const { scheduleID, seed } = await createBaseSchedule({
    date: TODAY,
    id: 'case-1-one-time',
    postsTransaction: false,
  });
  const actual = await makePeer(seed, 'actual-manual', 'case1-actual');
  const peer = await makePeer(seed, 'peer-advance', 'case1-peer');
  const before = await snapshotPeer(actual, scheduleID);
  const posted = await manualPost(actual, scheduleID);
  const exchange = await applyBatch(peer, posted, scheduleID);
  const dueDayAdvance = await automaticAdvance(peer, 'advance-due-day');
  const dueDay = await snapshotPeer(peer, scheduleID);

  MockDate.set(localNoon(2026, 9, 28));
  const nextDayAdvance = await automaticAdvance(peer, 'advance-next-day');
  const nextDay = await snapshotPeer(peer, scheduleID);
  MockDate.set(localNoon(2026, 9, 27));
  const actualReceivesDueDay = await applyBatch(
    actual,
    dueDayAdvance,
    scheduleID,
  );
  const actualReceivesNextDay = await applyBatch(
    actual,
    nextDayAdvance,
    scheduleID,
  );

  requireOracle(before.status === 'due', 'case 1 begins due', before.status);
  requireOracle(
    dueDay.occurrenceTransactionIDs.length === 1,
    'case 1 due-day advancement does not duplicate the manual post',
    dueDay.occurrenceTransactionIDs,
  );
  requireOracle(
    dueDayAdvance.rawMessages.length === 0,
    'case 1 due-day advancement does not mutate a paid one-time schedule',
    dueDayAdvance.rawMessages,
  );
  requireOracle(
    nextDay.rawSchedule?.completed === 1,
    'case 1 next-day advancement completes the paid one-time schedule',
    nextDay.rawSchedule,
  );
  requireOracle(
    nextDay.occurrenceTransactionIDs.length === 1,
    'case 1 next-day advancement retains one occurrence transaction',
    nextDay.occurrenceTransactionIDs,
  );
  requireOracle(
    actualReceivesNextDay.after.occurrenceTransactionIDs.length === 1 &&
      actualReceivesNextDay.after.rawSchedule?.completed === 1,
    'case 1 both peers converge to one transaction and completed state',
    actualReceivesNextDay.after,
  );

  return {
    acceptance: {
      duplicateCount: 0,
      nextDayCompleted: true,
      outcome: 'manual post replayed to peer; advancement created no replacement',
    },
    batches: [posted, dueDayAdvance, nextDayAdvance],
    exchanges: [exchange, actualReceivesDueDay, actualReceivesNextDay],
    final: { actual: actualReceivesNextDay.after, peer: nextDay },
    name: 'one-time-manual-then-peer-advance',
    snapshots: { before, dueDay, nextDay },
  };
}

async function caseRecurringManualSameDayRerun(): Promise<CaseEvidence> {
  const { scheduleID, seed } = await createBaseSchedule({
    date: {
      start: TODAY,
      frequency: 'weekly',
      interval: 1,
      patterns: [],
    },
    id: 'case-2-recurring',
    postsTransaction: false,
  });
  const actual = await makePeer(seed, 'actual-manual', 'case2-actual');
  const peer = await makePeer(seed, 'peer-advance', 'case2-peer');
  const posted = await manualPost(actual, scheduleID);
  const exchange = await applyBatch(peer, posted, scheduleID);
  const advanced = await automaticAdvance(peer, 'advance-recurring');
  const afterAdvance = await snapshotPeer(peer, scheduleID);
  const rerun = await automaticAdvance(peer, 'same-day-service-rerun');
  const afterRerun = await snapshotPeer(peer, scheduleID);

  const skipped = await captureOperation(peer, 'skip-next-date', () =>
    skipNextDate({ id: scheduleID }),
  );
  const afterSkip = await snapshotPeer(peer, scheduleID);
  global.stepForwardInTime();
  const reset = await captureOperation(peer, 'reset-next-date', () =>
    setNextDate({ id: scheduleID, reset: true }),
  );
  const afterReset = await snapshotPeer(peer, scheduleID);
  const actualReceivesAdvance = await applyBatch(actual, advanced, scheduleID);
  const actualReceivesRerun = await applyBatch(actual, rerun, scheduleID);
  const actualReceivesSkip = await applyBatch(actual, skipped, scheduleID);
  const actualReceivesReset = await applyBatch(actual, reset, scheduleID);

  requireOracle(
    afterAdvance.occurrenceTransactionIDs.length === 1,
    'case 2 advancement retains the single manual occurrence',
    afterAdvance.occurrenceTransactionIDs,
  );
  requireOracle(
    afterAdvance.domainSchedule?.next_date === TODAY &&
      advanced.rawMessages.length === 0,
    'case 2 keeps a manually paid due-today recurrence on today',
    afterAdvance.domainSchedule,
  );
  requireOracle(
    rerun.rawMessages.length === 0,
    'case 2 same-day service rerun writes nothing',
    rerun.rawMessages,
  );
  requireOracle(
    afterRerun.occurrenceTransactionIDs.length === 1,
    'case 2 same-day rerun creates no duplicate',
    afterRerun.occurrenceTransactionIDs,
  );
  requireOracle(
    afterSkip.nextDate?.base_next_date === afterAdvance.nextDate?.base_next_date &&
      afterSkip.nextDate?.local_next_date !== afterAdvance.nextDate?.local_next_date,
    'case 2 skip changes local next date without replacing base next date',
    { afterAdvance: afterAdvance.nextDate, afterSkip: afterSkip.nextDate },
  );
  requireOracle(
    afterReset.nextDate?.base_next_date_ts !==
      afterSkip.nextDate?.base_next_date_ts,
    'case 2 explicit reset changes the base next-date timestamp',
    { afterSkip: afterSkip.nextDate, afterReset: afterReset.nextDate },
  );
  requireOracle(
    JSON.stringify(actualReceivesReset.after.nextDate) ===
      JSON.stringify(afterReset.nextDate),
    'case 2 both peers converge after advance, rerun, skip, and reset batches',
    {
      actual: actualReceivesReset.after.nextDate,
      peer: afterReset.nextDate,
    },
  );

  return {
    acceptance: {
      duplicateCount: 0,
      resetAfterSkipRecorded: true,
      sameDayRerunMessages: 0,
    },
    batches: [posted, advanced, rerun, skipped, reset],
    exchanges: [
      exchange,
      actualReceivesAdvance,
      actualReceivesRerun,
      actualReceivesSkip,
      actualReceivesReset,
    ],
    final: { actual: actualReceivesReset.after, peer: afterReset },
    name: 'recurring-manual-same-day-rerun',
    snapshots: { afterAdvance, afterReset, afterRerun, afterSkip },
  };
}

async function caseMissedCatchUp(): Promise<CaseEvidence> {
  const { scheduleID, seed } = await createBaseSchedule({
    date: {
      start: '2026-09-06',
      frequency: 'weekly',
      interval: 1,
      patterns: [],
    },
    forcedNextDate: '2026-09-06',
    id: 'case-3-missed-catchup',
    postsTransaction: true,
  });
  const manualPeer = await makePeer(seed, 'actual-manual', 'case3-manual');
  const automaticPeer = await makePeer(seed, 'peer-catchup', 'case3-auto');
  const manual = await manualPost(manualPeer, scheduleID);
  const manualSnapshot = await snapshotPeer(manualPeer, scheduleID);
  const exchange = await applyBatch(automaticPeer, manual, scheduleID);
  const catchup = await automaticAdvance(automaticPeer, 'automatic-catchup');
  const afterCatchup = await snapshotPeer(automaticPeer, scheduleID);
  const retry = await automaticAdvance(automaticPeer, 'automatic-catchup-retry');
  const afterRetry = await snapshotPeer(automaticPeer, scheduleID);
  const manualReceivesCatchup = await applyBatch(
    manualPeer,
    catchup,
    scheduleID,
  );
  const manualReceivesRetry = await applyBatch(
    manualPeer,
    retry,
    scheduleID,
  );

  requireOracle(
    transactionDates(afterCatchup).join(',') ===
      '20260906,20260913,20260920,20260927',
    'case 3 processes missed occurrences oldest to newest without replacing the manually posted occurrence',
    transactionDates(afterCatchup),
  );
  requireOracle(
    afterCatchup.occurrenceTransactionIDs.includes(
      manualSnapshot.occurrenceTransactionIDs[0],
    ),
    'case 3 preserves the manual transaction identity through catch-up',
    {
      manual: manualSnapshot.occurrenceTransactionIDs,
      final: afterCatchup.occurrenceTransactionIDs,
    },
  );
  requireOracle(
    retry.rawMessages.length === 0 &&
      afterRetry.occurrenceTransactionIDs.length === 4,
    'case 3 same-day retry neither skips nor duplicates an occurrence',
    { retry: retry.rawMessages, final: afterRetry.occurrenceTransactionIDs },
  );
  requireOracle(
    JSON.stringify(manualReceivesRetry.after.graph) ===
      JSON.stringify(afterRetry.graph),
    'case 3 both peers converge after catch-up and retry exchange',
    { manual: manualReceivesRetry.after.graph, automatic: afterRetry.graph },
  );

  return {
    acceptance: {
      dates: transactionDates(afterCatchup),
      manualIdentityPreserved: true,
      retryMessages: 0,
    },
    batches: [manual, catchup, retry],
    exchanges: [exchange, manualReceivesCatchup, manualReceivesRetry],
    final: {
      automaticPeer: afterRetry,
      manualPeer: manualReceivesRetry.after,
    },
    name: 'missed-two-occurrences-one-manual-before-catchup',
    snapshots: { afterCatchup, afterRetry, manual: manualSnapshot },
  };
}

async function caseApproximatePostToday(): Promise<CaseEvidence> {
  const { scheduleID, seed } = await createBaseSchedule({
    date: {
      start: '2026-09-26',
      frequency: 'weekly',
      interval: 1,
      patterns: [],
    },
    dateOperator: 'isapprox',
    forcedNextDate: '2026-09-26',
    id: 'case-4-approximate',
    postsTransaction: false,
  });
  const actual = await makePeer(seed, 'actual-post-today', 'case4-actual');
  const peer = await makePeer(seed, 'peer-advance', 'case4-peer');
  const posted = await manualPost(actual, scheduleID, true);
  const exchange = await applyBatch(peer, posted, scheduleID);
  const advanced = await automaticAdvance(peer, 'advance-after-post-today');
  const final = await snapshotPeer(peer, scheduleID);
  const actualReceivesAdvance = await applyBatch(actual, advanced, scheduleID);

  requireOracle(
    transactionDates(final).join(',') === '20260927',
    'case 4 Post Today keeps exactly one transaction dated today',
    transactionDates(final),
  );
  requireOracle(
    final.domainSchedule?.next_date !== '2026-09-26',
    'case 4 peer advancement moves beyond the missed approximate occurrence',
    final.domainSchedule,
  );
  requireOracle(
    final.occurrenceTransactionIDs.length === 1,
    'case 4 peer advancement creates no replacement transaction',
    final.occurrenceTransactionIDs,
  );
  requireOracle(
    JSON.stringify(actualReceivesAdvance.after.graph) === JSON.stringify(final.graph),
    'case 4 both peers converge to one Post Today graph',
    { actual: actualReceivesAdvance.after.graph, peer: final.graph },
  );

  return {
    acceptance: {
      duplicateCount: 0,
      postedDate: TODAY,
    },
    batches: [posted, advanced],
    exchanges: [exchange, actualReceivesAdvance],
    final: { actual: actualReceivesAdvance.after, peer: final },
    name: 'missed-approximate-post-today-peer-advance',
  };
}

async function caseManualVersusAutomatic(): Promise<CaseEvidence> {
  const { scheduleID, seed } = await createBaseSchedule({
    date: TODAY,
    id: 'case-5-manual-vs-auto',
    postsTransaction: true,
  });
  const manualPeer = await makePeer(seed, 'actual-manual', 'case5-manual');
  const automaticPeer = await makePeer(seed, 'actual-automatic', 'case5-auto');
  const manual = await manualPost(manualPeer, scheduleID);
  const automatic = await automaticAdvance(automaticPeer, 'automatic-service');
  const manualIsolated = await snapshotPeer(manualPeer, scheduleID);
  const automaticIsolated = await snapshotPeer(automaticPeer, scheduleID);

  requireOracle(
    manualIsolated.occurrenceTransactionIDs.length === 1 &&
      automaticIsolated.occurrenceTransactionIDs.length === 1,
    'case 5 each isolated peer independently generates one transaction',
    { manual: manualIsolated, automatic: automaticIsolated },
  );
  requireOracle(
    manualIsolated.occurrenceTransactionIDs[0] !==
      automaticIsolated.occurrenceTransactionIDs[0],
    'case 5 independently generated transaction IDs are distinct',
    {
      manual: manualIsolated.occurrenceTransactionIDs,
      automatic: automaticIsolated.occurrenceTransactionIDs,
    },
  );

  const merged = await mergeBothOrders({
    batchA: manual,
    batchB: automatic,
    scheduleID,
    seed,
  });
  const mergedCount = merged.final.observerAB.occurrenceTransactionIDs.length;
  requireOracle(
    mergedCount === 2,
    'case 5 records the converged duplicate as a product-gate finding',
    merged.final.observerAB.occurrenceTransactionIDs,
  );
  const manualReceivesAutomatic = await applyBatch(
    manualPeer,
    automatic,
    scheduleID,
  );
  const automaticReceivesManual = await applyBatch(
    automaticPeer,
    manual,
    scheduleID,
  );
  requireOracle(
    manualReceivesAutomatic.after.occurrenceTransactionIDs.length === 2 &&
      automaticReceivesManual.after.occurrenceTransactionIDs.length === 2,
    'case 5 both originating peers retain both independently generated IDs after exchange',
    {
      manualPeer: manualReceivesAutomatic.after.occurrenceTransactionIDs,
      automaticPeer: automaticReceivesManual.after.occurrenceTransactionIDs,
    },
  );

  evidence.productGate.duplicateFinding =
    'Pinned Actual converges two independently generated transaction IDs for one occurrence; exact replay remains idempotent.';
  evidence.productGate.automaticPosting = 'blocked-cross-client-duplicate-observed';
  evidence.productGate.manualPosting =
    'requires-explicit-multi-client-limitation-and-product-decision';

  return {
    acceptance: {
      convergedDuplicateCount: mergedCount,
      generatedIDs: {
        automatic: automaticIsolated.occurrenceTransactionIDs,
        manual: manualIsolated.occurrenceTransactionIDs,
      },
      productGate: 'automatic posting blocked',
      replayInsertedMessageCount:
        merged.exchanges[merged.exchanges.length - 1].insertedRawMessages.length,
    },
    batches: [manual, automatic],
    exchanges: [
      manualReceivesAutomatic,
      automaticReceivesManual,
      ...merged.exchanges,
    ],
    final: {
      automaticPeer: automaticReceivesManual.after,
      manualPeer: manualReceivesAutomatic.after,
      ...merged.final,
    },
    name: 'manual-vs-auto-isolated-both-exchange-orders',
    snapshots: { automaticIsolated, manualIsolated },
  };
}

async function automaticCollisionScenario({
  id,
  leftLabel,
  rightLabel,
}: {
  id: string;
  leftLabel: string;
  rightLabel: string;
}) {
  const { scheduleID, seed } = await createBaseSchedule({
    date: TODAY,
    id,
    postsTransaction: true,
  });
  const left = await makePeer(seed, leftLabel, `${id}-left`);
  const right = await makePeer(seed, rightLabel, `${id}-right`);
  const leftBatch = await automaticAdvance(left, `${leftLabel}-automatic-service`);
  const rightBatch = await automaticAdvance(
    right,
    `${rightLabel}-automatic-service`,
  );
  const merged = await mergeBothOrders({
    batchA: leftBatch,
    batchB: rightBatch,
    scheduleID,
    seed,
  });
  requireOracle(
    merged.final.observerAB.occurrenceTransactionIDs.length === 2,
    `${id} converges two independently auto-posted IDs`,
    merged.final.observerAB.occurrenceTransactionIDs,
  );
  const leftReceivesRight = await applyBatch(left, rightBatch, scheduleID);
  const rightReceivesLeft = await applyBatch(right, leftBatch, scheduleID);
  requireOracle(
    leftReceivesRight.after.occurrenceTransactionIDs.length === 2 &&
      rightReceivesLeft.after.occurrenceTransactionIDs.length === 2,
    `${id} leaves both originating peers with both generated IDs`,
    {
      left: leftReceivesRight.after.occurrenceTransactionIDs,
      right: rightReceivesLeft.after.occurrenceTransactionIDs,
    },
  );
  return {
    leftBatch,
    leftReceivesRight,
    merged,
    rightBatch,
    rightReceivesLeft,
  };
}

async function caseAutomaticVersusAutomatic(): Promise<CaseEvidence> {
  const actualPeers = await automaticCollisionScenario({
    id: 'case-6-actual-vs-actual',
    leftLabel: 'actual-a',
    rightLabel: 'actual-b',
  });
  const actualistLeft = await automaticCollisionScenario({
    id: 'case-6-actualist-left-surrogate',
    leftLabel: 'actualist-candidate-surrogate-using-actual-handler',
    rightLabel: 'actual',
  });
  const actualistRight = await automaticCollisionScenario({
    id: 'case-6-actualist-right-surrogate',
    leftLabel: 'actual',
    rightLabel: 'actualist-candidate-surrogate-using-actual-handler',
  });

  return {
    acceptance: {
      actualPeersDuplicateCount:
        actualPeers.merged.final.observerAB.occurrenceTransactionIDs.length,
      actualistLeftSurrogateDuplicateCount:
        actualistLeft.merged.final.observerAB.occurrenceTransactionIDs.length,
      actualistRightSurrogateDuplicateCount:
        actualistRight.merged.final.observerAB.occurrenceTransactionIDs.length,
      productGate: 'automatic posting blocked',
      roleImplementation:
        'all peers execute pinned Actual v26.9.0 handler; Actualist labels are direction-only surrogates',
    },
    batches: [
      actualPeers.leftBatch,
      actualPeers.rightBatch,
      actualistLeft.leftBatch,
      actualistLeft.rightBatch,
      actualistRight.leftBatch,
      actualistRight.rightBatch,
    ],
    exchanges: [
      actualPeers.leftReceivesRight,
      actualPeers.rightReceivesLeft,
      ...actualPeers.merged.exchanges,
      actualistLeft.leftReceivesRight,
      actualistLeft.rightReceivesLeft,
      ...actualistLeft.merged.exchanges,
      actualistRight.leftReceivesRight,
      actualistRight.rightReceivesLeft,
      ...actualistRight.merged.exchanges,
    ],
    final: {
      actualA: actualPeers.leftReceivesRight.after,
      actualB: actualPeers.rightReceivesLeft.after,
      actualistLeftActualPeer: actualistLeft.rightReceivesLeft.after,
      actualistLeftSurrogatePeer: actualistLeft.leftReceivesRight.after,
      actualistRightActualPeer: actualistRight.leftReceivesRight.after,
      actualistRightSurrogatePeer: actualistRight.rightReceivesLeft.after,
    },
    name: 'auto-vs-auto-and-reversed-actualist-role',
    unresolvedBlockers: [
      'The role-reversal subcases are not real Actualist interoperability because no Actualist posting command exists yet.',
    ],
  };
}

async function configureSplitRule(scheduleID: string): Promise<void> {
  const { data: ruleID } = await aqlQuery(
    q('schedules').filter({ id: scheduleID }).calculate('rule'),
  );
  const actions: RuleActionEntity[] = [
    {
      op: 'set-split-amount',
      value: -4000,
      options: { splitIndex: 1, method: 'fixed-amount' },
    },
    {
      op: 'set-split-amount',
      value: null,
      options: { splitIndex: 2, method: 'remainder' },
    },
    { op: 'link-schedule', value: scheduleID },
  ];
  await updateRule({ id: ruleID, actions });
}

async function splitScheduleEvidence(): Promise<{
  batch: CapturedBatch;
  snapshot: ScheduleSnapshot;
}> {
  const { scheduleID } = await createBaseSchedule({
    date: TODAY,
    id: 'case-7-split',
    postsTransaction: false,
  });
  await configureSplitRule(scheduleID);
  const configuredRule = await scheduleSnapshot(scheduleID);
  requireOracle(
    String(configuredRule.rawRule?.actions).includes('set-split-amount'),
    'case 7 split rule mutation is present in the scenario seed',
    configuredRule.rawRule,
  );
  const seed = await exportSeedDatabase();
  const peer = await makePeer(seed, 'actual-split', 'case7-split');
  const batch = await manualPost(peer, scheduleID);
  const snapshot = await snapshotPeer(peer, scheduleID);
  const parent = snapshot.graph.find(transaction => transaction.is_parent === 1);
  const children = snapshot.graph.filter(transaction => transaction.is_child === 1);

  requireOracle(parent?.schedule === scheduleID, 'case 7 split parent owns schedule');
  requireOracle(children.length === 2, 'case 7 split has two child rows', children);
  requireOracle(
    children.every(transaction => transaction.schedule == null),
    'case 7 split children do not carry schedule identity',
    children,
  );
  return { batch, snapshot };
}

async function transferScheduleEvidence(): Promise<{
  batch: CapturedBatch;
  snapshot: ScheduleSnapshot;
}> {
  await resetOracleDatabase();
  const sourceAccount = 'case-7-transfer-source';
  const destinationAccount = 'case-7-transfer-destination';
  await db.insertAccount({
    id: sourceAccount,
    name: 'Transfer source',
    offbudget: 0,
    closed: 0,
  });
  await db.insertAccount({
    id: destinationAccount,
    name: 'Transfer destination',
    offbudget: 0,
    closed: 0,
  });
  await db.insertPayee({
    id: 'case-7-source-transfer-payee',
    name: '',
    transfer_acct: sourceAccount,
  });
  const destinationPayee = await db.insertPayee({
    id: 'case-7-destination-transfer-payee',
    name: '',
    transfer_acct: destinationAccount,
  });
  const scheduleID = 'case-7-transfer';
  await createSchedule({
    schedule: { id: scheduleID, name: scheduleID, posts_transaction: false },
    conditions: [
      { op: 'is', field: 'account', value: sourceAccount },
      { op: 'is', field: 'payee', value: destinationPayee },
      { op: 'is', field: 'amount', value: -12000 },
      { op: 'is', field: 'date', value: TODAY },
    ],
  });
  const seed = await exportSeedDatabase();
  const peer = await makePeer(seed, 'actual-transfer', 'case7-transfer');
  const batch = await manualPost(peer, scheduleID);
  const snapshot = await snapshotPeer(peer, scheduleID);

  requireOracle(snapshot.graph.length === 2, 'case 7 transfer has two legs');
  requireOracle(
    snapshot.graph.every(transaction => transaction.schedule === scheduleID),
    'case 7 both transfer legs carry schedule identity',
    snapshot.graph,
  );
  requireOracle(
    snapshot.graph.every(transaction => transaction.transfer_id != null),
    'case 7 transfer legs point to each other',
    snapshot.graph,
  );
  return { batch, snapshot };
}

async function caseSplitAndTransferPropagation(): Promise<CaseEvidence> {
  const split = await splitScheduleEvidence();
  const transfer = await transferScheduleEvidence();
  return {
    acceptance: {
      split: {
        graphRows: split.snapshot.graph.length,
        scheduleOwners: split.snapshot.graph
          .filter(transaction => transaction.schedule != null)
          .map(transaction => transaction.id),
      },
      transfer: {
        graphRows: transfer.snapshot.graph.length,
        scheduleOwners: transfer.snapshot.graph
          .filter(transaction => transaction.schedule != null)
          .map(transaction => transaction.id),
      },
    },
    batches: [split.batch, transfer.batch],
    final: { split: split.snapshot, transfer: transfer.snapshot },
    name: 'split-and-transfer-schedule-propagation',
  };
}

describe('Actual v26.9.0 cross-client schedule occurrence identity oracle', () => {
  test('runs the mandatory seven-case matrix sequentially and records the product gate', async () => {
    requireOracle(evidencePath, 'ACTUAL_SCHEDULE_PARITY_EVIDENCE is set');
    MockDate.set(localNoon(2026, 9, 27));

    const cases = [
      caseOneTimeManualThenPeerAdvance,
      caseRecurringManualSameDayRerun,
      caseMissedCatchUp,
      caseApproximatePostToday,
      caseManualVersusAutomatic,
      caseAutomaticVersusAutomatic,
      caseSplitAndTransferPropagation,
    ];

    try {
      for (const runCase of cases) {
        evidence.cases.push(await runCase());
        writeEvidence();
      }
      evidence.completed = true;
      writeEvidence();
    } catch (error) {
      evidence.failedCriterion =
        error instanceof Error ? error.message : String(error);
      writeEvidence();
      throw error;
    } finally {
      MockDate.reset();
      await persistActivePeer();
      await closeOracleDatabase();
    }
  });
});
