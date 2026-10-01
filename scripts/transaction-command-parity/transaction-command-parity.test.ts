import { expect, test, vi } from 'vitest';
import { readFileSync } from 'node:fs';

import { aqlQuery } from '#server/aql';
import * as db from '#server/db';
import { loadMappings } from '#server/db/mappings';
import { handlers } from '#server/main';
import { runHandler } from '#server/mutators';
import { setSyncingMode } from '#server/sync';
import { clearUndo, undo } from '#server/undo';
import { q } from '#shared/query';
import {
  realizeTempTransactions,
  ungroupTransaction,
} from '#shared/transactions';
import type { TransactionEntity } from '#types/models';

import {
  CommandOracleRecorder,
  crdtMarker,
  crdtMessagesSince,
  normalizeError,
  rawReferenceRows,
  rawTransactionRows,
  toJSON,
  type CommandCase,
  type JSONValue,
} from './transaction-command-parity-support';

const uuidState = vi.hoisted(() => ({ next: 1 }));
vi.mock('uuid', async importOriginal => {
  const original = await importOriginal<typeof import('uuid')>();
  return {
    ...original,
    v4: () =>
      `00000000-0000-4000-8000-${String(uuidState.next++).padStart(12, '0')}`,
  };
});

const CASES = loadCases();
// Validate every input graph before the first Actual handler can run. A later
// missing or mislabeled fixture must not spend a partial capture invocation.
for (const item of CASES) buildFixture(item);

test(
  'captures the complete D1/D2/M1-M4 transaction command matrix from Actual handlers',
  async () => {
    const recorder = new CommandOracleRecorder(CASES);
    const setupFailures: string[] = [];
    try {
      setSyncingMode('offline');
      for (const item of CASES) {
        try {
          recorder.begin(item.id);
          uuidState.next = 1;
          await global.emptyDatabase()();
          clearUndo();
          await seedReferenceData();
          const fixture = await seedCase(item);
          const marker = await crdtMarker();
          const referencesBefore = await rawReferenceRows();
          const before = await rawTransactionRows();
          let handlerResult: JSONValue | null = null;
          let handlerError: string | null = null;

          try {
            handlerResult = toJSON(await executeActualHandler(item, fixture.selectedIDs));
          } catch (error) {
            // A handler refusal is evidence, not an assumed failure. The gate
            // owner decides whether that refusal is the supported contract.
            handlerError = normalizeError(error);
          }

          const referencesAfterHandler = await rawReferenceRows();
          const after = await rawTransactionRows();
          const forwardMessages = await crdtMessagesSince(marker);
          let conflictObservation: JSONValue | null = null;
          if (
            item.id === 'M4-undo-conflict-after-merge'
          ) {
            if (typeof handlerResult === 'string') {
              const rowsBeforeMutation = await rawTransactionRows();
              const markerBeforeMutation = await crdtMarker();
              await db.updateTransaction({
                id: handlerResult,
                notes: 'synthetic post-merge conflict',
              });
              const rowsAfterMutation = await rawTransactionRows();
              const markerAfterMutation = await crdtMarker();
              conflictObservation = {
                markerAfterMutation,
                markerBeforeMutation,
                messages: toJSON(await crdtMessagesSince(markerBeforeMutation)),
                rowsAfterMutation,
                rowsBeforeMutation,
              };
            } else {
              conflictObservation = {
                injection: 'not-applied',
                reason: 'merge did not return a kept transaction ID',
              };
            }
          }
          const undoMarker = await crdtMarker();
          let undoError: string | null = null;
          try {
            await runActualUndo();
          } catch (error) {
            undoError = normalizeError(error);
          }
          const undoMessages = await crdtMessagesSince(undoMarker);
          const afterUndo = await rawTransactionRows();
          const referencesAfterUndo = await rawReferenceRows();
          const duplicateLearningObservation =
            item.id === 'D2-duplicate-does-not-request-learning'
              ? {
                  // Actual's desktop duplicate request sends only `added`; the
                  // batch handler therefore retains learnCategories=false.
                  learnCategoriesRequested: false,
                  rulesAfterHandler: referencesAfterHandler.rules,
                  rulesAfterUndo: referencesAfterUndo.rules,
                  rulesBefore: referencesBefore.rules,
                  rulesChangedAfterHandler:
                    JSON.stringify(referencesBefore.rules) !==
                    JSON.stringify(referencesAfterHandler.rules),
                  rulesChangedAfterUndo:
                    JSON.stringify(referencesBefore.rules) !==
                    JSON.stringify(referencesAfterUndo.rules),
                }
              : null;
          recorder.pass(item.id, {
            actionLogObservation: {
              historyModel: 'Actual 26.9 server/undo.ts in-memory MESSAGE_HISTORY; no durable transaction action-log table',
              undoInvocations: 1,
              undoError,
              undoMessages: toJSON(undoMessages),
              rowsAfterUndo: afterUndo,
            },
            after,
            afterUndo,
            before,
            conflictObservation,
            duplicateLearningObservation,
            forwardMessages: toJSON(forwardMessages),
            handlerError,
            handlerResult,
            referencesAfterHandler,
            referencesAfterUndo,
            referencesBefore,
            selectedIDs: fixture.selectedIDs,
            undoError,
            undoMessages: toJSON(undoMessages),
          });
        } catch (error) {
          const failure = `${item.id}: ${normalizeError(error)}`;
          setupFailures.push(failure);
          recorder.fail(item.id, failure);
          break;
        }
      }
    } finally {
      setSyncingMode('disabled');
      recorder.finish(setupFailures);
    }
    expect(setupFailures).toEqual([]);
  },
  170_000,
);

function loadCases(): CommandCase[] {
  const matrixPath = new URL('./transaction-command-parity-matrix.json', import.meta.url);
  const matrix = JSON.parse(readFileSync(matrixPath, 'utf8')) as {
    cases: CommandCase[];
  };
  return matrix.cases;
}

async function executeActualHandler(item: CommandCase, selectedIDs: string[]) {
  if (item.gate === 'D1' || item.gate === 'D2') {
    const { data } = await aqlQuery(
      q('transactions')
        .filter({ id: { $oneof: selectedIDs } })
        .select('*')
        .options({ splits: 'grouped' }),
    );
    const transactions = data as TransactionEntity[];
    const added = transactions.reduce<TransactionEntity[]>(
      (newTransactions, transaction) =>
        newTransactions.concat(
          realizeTempTransactions(ungroupTransaction(transaction)).map(clone => ({
            ...clone,
            cleared: false,
            reconciled: false,
          })),
        ),
      [],
    );
    return runHandler(
      handlers['transactions-batch-update'],
      { added },
      { name: 'transactions-batch-update' },
    );
  }

  return runHandler(
    handlers['transactions-merge'],
    selectedIDs.map(id => ({ id })),
    { name: 'transactions-merge' },
  );
}

async function seedReferenceData(): Promise<void> {
  await db.insertCategoryGroup({ id: 'group-oracle', name: 'Oracle', is_income: 0 });
  await db.insertCategory({
    id: 'category-food',
    name: 'Food',
    cat_group: 'group-oracle',
    is_income: 0,
  });
  await db.insertAccount({ id: 'acct-main', name: 'Main' });
  await db.insertAccount({ id: 'acct-target', name: 'Target' });
  await db.insertAccount({ id: 'acct-off-a', name: 'Off budget A', offbudget: 1 });
  await db.insertAccount({ id: 'acct-off-b', name: 'Off budget B', offbudget: 1 });
  await db.insertPayee({ id: 'payee-regular', name: 'Merchant' });
  await db.insertPayee({ id: 'payee-to-target', name: 'Transfer to Target', transfer_acct: 'acct-target' });
  await db.insertPayee({ id: 'payee-to-off-a', name: 'Transfer to Off A', transfer_acct: 'acct-off-a' });
  await db.insertPayee({ id: 'payee-to-off-b', name: 'Transfer to Off B', transfer_acct: 'acct-off-b' });
  await db.insertPayee({ id: 'payee-to-main', name: 'Transfer to Main', transfer_acct: 'acct-main' });
  await db.insertWithUUID('schedules', { id: 'schedule-oracle', sort_order: 1 });
  await loadMappings();
}

type SeededCase = { selectedIDs: string[] };

function buildFixture(item: CommandCase): TransactionEntity[] {
  const rows: TransactionEntity[] = [];
  const add = (row: Partial<TransactionEntity> & { id: string }) => {
    rows.push(transaction(row));
  };
  const simple = (id: string, extra: Partial<TransactionEntity> = {}) =>
    add({ id, ...extra });
  const split = (
    rootID: string,
    childIDs: string[],
    mismatch = false,
    imported = false,
  ) => {
    const amounts = childIDs.map((_, index) =>
      mismatch ? -300 : childIDs.length === 1 ? -1000 : index === 0 ? -400 : -600,
    );
    add({
      id: rootID,
      is_parent: true,
      category: null,
      payee: imported ? 'payee-regular' : null,
      imported_id: imported ? `financial-${rootID}` : null,
      imported_payee: imported ? 'Imported Merchant' : null,
      schedule: imported ? 'schedule-oracle' : null,
      error: mismatch
        ? { type: 'SplitTransactionError', version: 1, difference: -1000 - amounts.reduce((sum, value) => sum + value, 0) }
        : null,
    });
    childIDs.forEach((id, index) =>
      add({
        id,
        is_child: true,
        parent_id: rootID,
        amount: amounts[index],
        payee: 'payee-regular',
        category: 'category-food',
        sort_order: -(index + 1),
      }),
    );
  };
  const transferPair = (
    id: string,
    peerID: string,
    destination: 'acct-target' | 'acct-off-a' | 'acct-off-b',
    options: { reconciledPeer?: boolean; offBudgetCategory?: boolean; reciprocal?: boolean } = {},
  ) => {
    const destinationPayee =
      destination === 'acct-target'
        ? 'payee-to-target'
        : destination === 'acct-off-a'
          ? 'payee-to-off-a'
          : 'payee-to-off-b';
    add({
      id,
      account: 'acct-main',
      amount: -1000,
      payee: destinationPayee,
      category: options.offBudgetCategory ? 'category-food' : null,
      transfer_id: peerID,
    });
    add({
      id: peerID,
      account: destination,
      amount: 1000,
      payee: 'payee-to-main',
      category: destination === 'acct-target' ? null : 'category-food',
      transfer_id: options.reciprocal === false ? 'different-origin' : id,
      reconciled: options.reconciledPeer ?? false,
    });
  };

  switch (item.graph) {
  case 'simple':
    simple('simple');
    break;
  case 'split-two':
    split('split-root', ['split-child-a', 'split-child-b']);
    break;
  case 'split-equal-children':
    split('split-root', ['split-child-a', 'split-child-b']);
    rows.filter(row => row.is_child).forEach(row => { row.amount = -500; });
    break;
  case 'transfer-pair':
    transferPair('transfer-a', 'transfer-peer-a', 'acct-target');
    break;
  case 'import-metadata':
    simple('imported-root', {
      imported_id: 'financial-imported-root',
      imported_payee: 'Imported Merchant',
      reconciled: true,
      schedule: 'schedule-oracle',
    });
    break;
  case 'split-import-metadata':
    split('split-import-root', ['split-import-child'], false, true);
    break;
  case 'mismatched-split':
    split('mismatched-split-root', ['mismatched-split-child'], true);
    break;
  case 'ordered-root':
    simple('ordered-root', { sort_order: 20 });
    break;
  case 'ordinary-payee-no-learning':
    simple('ordinary-payee-root', { payee: 'payee-regular' });
    break;
  case 'same-account-amount':
    simple('manual', { date: '2026-09-21' });
    simple('imported', { date: '2026-09-20', imported_id: 'financial-imported' });
    simple('imported-payee', { date: '2026-09-22', imported_payee: 'Imported Merchant' });
    simple('earlier', { date: '2026-09-19' });
    simple('later', { date: '2026-09-22' });
    simple('equal-a', { date: '2026-09-20', imported_id: 'financial-equal-a' });
    simple('equal-b', { date: '2026-09-20', imported_id: 'financial-equal-b' });
    break;
  case 'equal-import-date':
    simple('equal-a', { date: '2026-09-20', imported_id: 'financial-equal-a' });
    simple('equal-b', { date: '2026-09-20', imported_id: 'financial-equal-b' });
    break;
  case 'two-simple':
    simple('simple-a');
    simple('simple-b');
    break;
  case 'simple-and-split':
    simple('simple-a', { date: '2026-09-19' });
    split('split-root-b', ['split-child-b']);
    break;
  case 'split-and-simple':
    split('split-root-a', ['split-child-a']);
    simple('simple-b', { date: '2026-09-21' });
    break;
  case 'two-splits-two-children':
    split('split-root-a', ['split-child-a']);
    split('split-root-b', ['split-child-b']);
    break;
  case 'zero-child-parent':
    add({ id: 'empty-parent-a', is_parent: true, category: null });
    simple('simple-b');
    break;
  case 'one-child-parent':
    split('one-child-parent-a', ['one-child-a']);
    simple('simple-b');
    break;
  case 'conflicting-split-errors':
    split('parent-malformed-a', ['malformed-child-a'], true);
    split('parent-malformed-b', ['malformed-child-b'], true);
    rows.find(row => row.id === 'malformed-child-b')!.amount = -1200;
    rows.find(row => row.id === 'parent-malformed-b')!.error = {
      type: 'SplitTransactionError', version: 1, difference: 200,
    };
    break;
  case 'transfer-on-budget':
    transferPair('transfer-a', 'transfer-peer-a', 'acct-target');
    simple('simple-b');
    break;
  case 'transfer-off-budget':
    transferPair('transfer-a', 'transfer-peer-a', 'acct-off-a', { offBudgetCategory: true });
    simple('simple-b');
    break;
  case 'two-same-destination-pairs':
    transferPair('transfer-a', 'transfer-peer-a', 'acct-target');
    transferPair('transfer-c', 'transfer-peer-c', 'acct-target');
    break;
  case 'two-different-destination-pairs':
    transferPair('transfer-a', 'transfer-peer-a', 'acct-off-a');
    transferPair('transfer-e', 'transfer-peer-e', 'acct-off-b');
    break;
  case 'reconciled-transfer-pairs':
    transferPair('transfer-a', 'transfer-peer-a', 'acct-target');
    transferPair('transfer-c', 'transfer-peer-c', 'acct-target', { reconciledPeer: true });
    break;
  case 'orphan-transfer':
    simple('transfer-orphan', { transfer_id: 'missing-peer' });
    simple('simple-b');
    break;
  case 'wrong-reciprocal-link':
    transferPair('transfer-a', 'transfer-peer-a', 'acct-target', { reciprocal: false });
    simple('simple-b');
    break;
  case 'valid-plus-invalid-pair':
    transferPair('transfer-a', 'transfer-peer-a', 'acct-off-a');
    transferPair('transfer-invalid', 'transfer-peer-invalid', 'acct-off-a');
    rows.find(row => row.id === 'transfer-peer-invalid')!.amount = 999;
    break;
  case 'split-transfer-graphs':
    split('split-transfer-root-a', ['split-transfer-child-a']);
    split('split-transfer-root-b', ['split-transfer-child-b']);
    rows.push(
      transaction({
        id: 'split-transfer-peer-a',
        account: 'acct-target',
        amount: 1000,
        payee: 'payee-to-main',
        category: null,
        transfer_id: 'split-transfer-child-a',
      }),
      transaction({
        id: 'split-transfer-peer-b',
        account: 'acct-target',
        amount: 1000,
        payee: 'payee-to-main',
        category: null,
        transfer_id: 'split-transfer-child-b',
      }),
    );
    rows.splice(
      rows.findIndex(row => row.id === 'split-transfer-child-a'),
      1,
      transaction({
        id: 'split-transfer-child-a',
        is_child: true,
        parent_id: 'split-transfer-root-a',
        amount: -1000,
        category: null,
        payee: 'payee-to-target',
        transfer_id: 'split-transfer-peer-a',
      }),
    );
    rows.splice(
      rows.findIndex(row => row.id === 'split-transfer-child-b'),
      1,
      transaction({
        id: 'split-transfer-child-b',
        is_child: true,
        parent_id: 'split-transfer-root-b',
        amount: -1000,
        category: null,
        payee: 'payee-to-target',
        transfer_id: 'split-transfer-peer-b',
      }),
    );
    break;
  case 'later-conflict':
    simple('simple-a');
    simple('simple-b');
    break;
  default:
    throw new Error(`No fixture builder for graph ${item.graph}`);
  }

  validateFixture(item, rows);
  return rows;
}

function validateFixture(item: CommandCase, rows: TransactionEntity[]): void {
  const byID = new Map(rows.map(row => [row.id, row]));
  if (byID.size !== rows.length) throw new Error(`${item.id}: duplicate fixture row IDs`);
  if (item.selected.some(id => !byID.has(id))) throw new Error(`${item.id}: selected row is absent`);
  if (item.id === 'D2-import-metadata-root' && byID.get(item.selected[0])?.reconciled !== true) {
    throw new Error(`${item.id}: source must be reconciled so duplicate reset is observable`);
  }
  if (
    item.id === 'D2-duplicate-does-not-request-learning' &&
    byID.get(item.selected[0])?.payee !== 'payee-regular'
  ) {
    throw new Error(`${item.id}: source must use the ordinary seeded payee`);
  }
  const malformedSplit = ['mismatched-split', 'conflicting-split-errors', 'zero-child-parent'].includes(item.graph);
  for (const parent of rows.filter(row => row.is_parent)) {
    const children = rows.filter(row => row.parent_id === parent.id);
    const difference = parent.amount - children.reduce((sum, child) => sum + child.amount, 0);
    if (!malformedSplit && (children.length === 0 || difference !== 0)) {
      throw new Error(`${item.id}: unintended split imbalance for ${parent.id}`);
    }
  }
  if (item.id === 'M2-selected-children-same-parent') {
    const selected = item.selected.map(id => byID.get(id)!);
    if (selected.some(row => !row.is_child) || new Set(selected.map(row => row.parent_id)).size !== 1
        || selected[0].amount !== selected[1].amount) {
      throw new Error(`${item.id}: selected children must share a parent and have merge-eligible amounts`);
    }
  }
  if (['M2-keep-simple-drop-split', 'M2-keep-split-drop-simple'].includes(item.id)) {
    const [keep, drop] = item.selected.map(id => byID.get(id)!);
    if (keep.date >= drop.date || keep.account !== drop.account || keep.amount !== drop.amount) {
      throw new Error(`${item.id}: input dates and amounts must exercise the named keep/drop direction`);
    }
  }
  const malformedTransfer = ['orphan-transfer', 'wrong-reciprocal-link', 'valid-plus-invalid-pair'].includes(item.graph);
  if (!malformedTransfer) {
    for (const row of rows.filter(row => row.transfer_id)) {
      const peer = byID.get(row.transfer_id!);
      if (!peer || peer.transfer_id !== row.id || peer.amount !== -row.amount) {
        throw new Error(`${item.id}: unintended malformed transfer ${row.id}`);
      }
    }
  }
  if (item.graph === 'valid-plus-invalid-pair') {
    const [first, second] = item.selected.map(id => byID.get(id)!);
    const firstPeer = byID.get(first.transfer_id!)!;
    const secondPeer = byID.get(second.transfer_id!)!;
    if (first.account !== second.account || first.amount !== second.amount
        || firstPeer.account !== secondPeer.account || firstPeer.amount === secondPeer.amount) {
      throw new Error(`${item.id}: fixture must reach the invalid paired-amount check`);
    }
  }
}

async function seedCase(item: CommandCase): Promise<SeededCase> {
  const rows = buildFixture(item);
  // Seed with Actual's public TransactionEntity fields through its schema
  // converter; support.ts separately snapshots the resulting physical columns.
  for (const row of rows) await db.insertTransaction(row);
  return { selectedIDs: item.selected };
}

function transaction(
  row: Partial<TransactionEntity> & { id: string },
): TransactionEntity {
  return {
    account: 'acct-main',
    amount: -1000,
    category: 'category-food',
    cleared: true,
    date: '2026-09-20',
    is_child: false,
    is_parent: false,
    notes: 'synthetic command oracle',
    parent_id: null,
    payee: 'payee-regular',
    reconciled: false,
    sort_order: 100,
    ...row,
  } as TransactionEntity;
}

async function runActualUndo(): Promise<void> {
  await undo();
}
