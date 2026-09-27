import MockDate from 'mockdate';
import { afterAll, afterEach, beforeEach, expect, test, vi } from 'vitest';

import * as asyncStorage from '#platform/server/asyncStorage';
import * as db from '#server/db';
import { loadMappings } from '#server/db/mappings';
import { handlers } from '#server/main';
import { runHandler } from '#server/mutators';
import { post } from '#server/post';
import { app as schedulesApp } from '#server/schedules/app';
import { setSyncingMode } from '#server/sync';
import { loadRules } from '#server/transactions/transaction-rules';
import { clearUndo } from '#server/undo';

import {
  accountRow,
  crdtCount,
  crdtMarker,
  crdtMessagesSince,
  domainSnapshot,
  FIXED_DATE_INTEGER,
  FIXED_DAY,
  scheduleRows,
  transactionRows,
  writeOracle,
  type JSONPrimitive,
  type JSONValue,
  type NormalizedMessage,
  type OracleCase,
} from './account-lifecycle-parity-support';

type AccountSeed = {
  id: string;
  name: string;
  offBudget?: boolean;
  closed?: boolean;
  link?: {
    provider: 'goCardless' | 'simpleFin';
    bankID: string;
    remoteAccountID: string;
  };
};

type ClosingTransferResult = {
  operationMessages: NormalizedMessage[];
  afterOperation: Awaited<ReturnType<typeof domainSnapshot>>;
  sourceTransaction: Record<string, JSONPrimitive>;
  destinationTransaction: Record<string, JSONPrimitive>;
};

const cases: OracleCase[] = [];
const postMock = vi.mocked(post);
const tokenMock = vi.mocked(asyncStorage.getItem);

function jsonObject(value: unknown): Record<string, JSONValue> {
  const normalized: unknown = JSON.parse(JSON.stringify(value));
  if (typeof normalized !== 'object' || normalized === null || Array.isArray(normalized)) {
    throw new Error('Oracle case section must normalize to an object');
  }
  return normalized as Record<string, JSONValue>;
}

function recordCase(
  id: string,
  input: unknown,
  assertions: string[],
  observed: unknown,
): void {
  cases.push({
    id,
    input: jsonObject(input),
    assertions,
    observed: jsonObject(observed),
  });
}

function message(
  dataset: string,
  row: string,
  column: string,
  value: JSONPrimitive,
): NormalizedMessage {
  return { dataset, row, column, value };
}

function expectCell(
  messages: NormalizedMessage[],
  expected: NormalizedMessage,
): void {
  expect(messages).toContainEqual(expected);
}

function rowWithID(
  rows: Array<Record<string, JSONPrimitive>>,
  id: string,
): Record<string, JSONPrimitive> {
  const row = rows.find(value => value.id === id);
  if (!row) throw new Error(`Missing synthetic row ${id}`);
  return row;
}

async function seedAccount(seed: AccountSeed): Promise<void> {
  if (seed.link) {
    const existingBank = await db.first<{ id: string }>(
      'SELECT id FROM banks WHERE id = ?',
      [seed.link.bankID],
    );
    if (!existingBank) {
      await db.insertWithUUID('banks', {
        id: seed.link.bankID,
        bank_id: `remote-${seed.link.bankID}`,
        name: `Synthetic ${seed.link.bankID}`,
      });
    }
  }
  await db.insertAccount({
    id: seed.id,
    name: seed.name,
    offbudget: seed.offBudget ? 1 : 0,
    closed: seed.closed ? 1 : 0,
    ...(seed.link
      ? {
          account_id: seed.link.remoteAccountID,
          bank: seed.link.bankID,
          balance_current: 12_345,
          balance_available: 12_000,
          balance_limit: 50_000,
          account_sync_source: seed.link.provider,
          bank_sync_status: 'ok',
          last_sync: 'synthetic-last-sync',
        }
      : {}),
  });
  await db.insertPayee({
    id: `transfer-${seed.id}`,
    name: '',
    transfer_acct: seed.id,
  });
}

async function seedTransaction({
  id,
  account,
  amount,
  payee = null,
  category = null,
  notes = null,
}: {
  id: string;
  account: string;
  amount: number;
  payee?: string | null;
  category?: string | null;
  notes?: string | null;
}): Promise<void> {
  await runHandler(
    handlers['transaction-add'],
    {
      id,
      account,
      amount,
      payee,
      category,
      notes,
      date: FIXED_DAY,
      cleared: true,
    },
    { name: 'transaction-add' },
  );
}

async function seedSplitFamily(account: string): Promise<void> {
  await db.insertTransaction({
    id: 'split-parent',
    account,
    amount: 1_000,
    date: FIXED_DAY,
    is_parent: true,
    cleared: true,
  });
  await db.insertTransaction({
    id: 'split-child-a',
    account,
    amount: 400,
    date: FIXED_DAY,
    is_child: true,
    parent_id: 'split-parent',
    cleared: true,
  });
  await db.insertTransaction({
    id: 'split-child-b',
    account,
    amount: 600,
    date: FIXED_DAY,
    is_child: true,
    parent_id: 'split-parent',
    cleared: true,
  });
}

async function seedHiddenCategory(): Promise<void> {
  await db.insertCategoryGroup({
    id: 'expense-group',
    name: 'Synthetic expenses',
    is_income: 0,
  });
  await db.insertCategory({
    id: 'hidden-category',
    name: 'Synthetic hidden category',
    cat_group: 'expense-group',
    hidden: 1,
    is_income: 0,
  });
}

function normalizedRemoteCalls(): Array<Record<string, JSONValue>> {
  return postMock.mock.calls.map(call => {
    const headers = call[2] as Record<string, string> | undefined;
    return {
      url: String(call[0]),
      body: JSON.parse(JSON.stringify(call[1] ?? null)) as JSONValue,
      tokenHeaderPresent: Boolean(headers?.['X-ACTUAL-TOKEN']),
    };
  });
}

async function runClosingTransfer({
  sourceOffBudget,
  destinationOffBudget,
  balance,
  categoryID,
}: {
  sourceOffBudget: boolean;
  destinationOffBudget: boolean;
  balance: number;
  categoryID?: string;
}): Promise<ClosingTransferResult> {
  await seedAccount({
    id: 'source',
    name: 'Synthetic source',
    offBudget: sourceOffBudget,
  });
  await seedAccount({
    id: 'destination',
    name: 'Synthetic destination',
    offBudget: destinationOffBudget,
  });
  await seedTransaction({ id: 'opening-row', account: 'source', amount: balance });
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-close'],
    {
      id: 'source',
      transferAccountId: 'destination',
      categoryId: categoryID,
    },
    { name: 'account-close' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const afterOperation = await domainSnapshot();
  const closingTransactions = afterOperation.transactions.filter(
    row => row.notes === 'Closing account' && row.tombstone === 0,
  );
  expect(closingTransactions).toHaveLength(2);
  const sourceTransaction = closingTransactions.find(row => row.acct === 'source');
  const destinationTransaction = closingTransactions.find(
    row => row.acct === 'destination',
  );
  expect(sourceTransaction).toBeDefined();
  expect(destinationTransaction).toBeDefined();
  if (!sourceTransaction || !destinationTransaction) {
    throw new Error('Closing transfer did not produce both synthetic legs');
  }

  expect(await accountRow('source')).toMatchObject({ closed: 1, tombstone: 0 });
  expect(sourceTransaction).toMatchObject({
    amount: -balance,
    date: FIXED_DATE_INTEGER,
    notes: 'Closing account',
    cleared: 1,
    reconciled: 0,
    starting_balance_flag: 0,
    schedule: null,
    tombstone: 0,
  });
  expect(destinationTransaction).toMatchObject({
    amount: balance,
    date: FIXED_DATE_INTEGER,
    notes: 'Closing account',
    category: null,
    cleared: 0,
    reconciled: 0,
    starting_balance_flag: 0,
    schedule: null,
    tombstone: 0,
  });
  expect(sourceTransaction.transferred_id).toBe(destinationTransaction.id);
  expect(destinationTransaction.transferred_id).toBe(sourceTransaction.id);
  expect(sourceTransaction.description).toBe('transfer-destination');
  expect(destinationTransaction.description).toBe('transfer-source');
  expectCell(operationMessages, message('accounts', 'source', 'closed', 1));
  expectCell(
    operationMessages,
    message('transactions', String(sourceTransaction.id), 'amount', -balance),
  );
  expectCell(
    operationMessages,
    message(
      'transactions',
      String(destinationTransaction.id),
      'amount',
      balance,
    ),
  );

  return {
    operationMessages,
    afterOperation,
    sourceTransaction,
    destinationTransaction,
  };
}

beforeEach(async () => {
  vi.clearAllMocks();
  await global.emptyDatabase()();
  await loadMappings();
  await loadRules();
  clearUndo();
  setSyncingMode('offline');
  MockDate.set(`${FIXED_DAY}T12:00:00.000Z`);
  tokenMock.mockResolvedValue(null);
  postMock.mockResolvedValue({});
});

afterEach(async () => {
  await schedulesApp.stopServices();
  clearUndo();
  setSyncingMode('disabled');
  MockDate.reset();
});

afterAll(() => {
  writeOracle(cases);
});

test('rename open account and History inverse emit only the name cell', async () => {
  await seedAccount({ id: 'source', name: 'Before' });
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-update'],
    { id: 'source', name: 'After' },
    { name: 'account-update' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const afterOperation = await accountRow('source');
  expect(operationMessages).toEqual([
    message('accounts', 'source', 'name', 'After'),
  ]);
  expect(afterOperation).toMatchObject({ name: 'After', closed: 0, tombstone: 0 });

  const undoMarker = await crdtMarker();
  await runHandler(handlers.undo, undefined, { name: 'undo' });
  const undoMessages = await crdtMessagesSince(undoMarker);
  const afterUndo = await accountRow('source');
  expect(undoMessages).toEqual([
    message('accounts', 'source', 'name', 'Before'),
  ]);
  expect(afterUndo.name).toBe('Before');

  recordCase(
    'rename-open-history',
    { account: { id: 'source', name: 'Before', closed: false }, name: 'After' },
    [
      'account-update emits only accounts.name',
      'History undo restores the previous name on the same account ID',
    ],
    { operationMessages, afterOperation, undoMessages, afterUndo },
  );
});

test('rename closed account preserves lifecycle and unrelated cells', async () => {
  await seedAccount({ id: 'source', name: 'Closed before', closed: true });
  clearUndo();
  const before = await accountRow('source');
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-update'],
    { id: 'source', name: 'Closed after' },
    { name: 'account-update' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const after = await accountRow('source');
  expect(operationMessages).toEqual([
    message('accounts', 'source', 'name', 'Closed after'),
  ]);
  expect(after).toEqual({ ...before, name: 'Closed after' });

  recordCase(
    'rename-closed',
    {
      account: { id: 'source', name: 'Closed before', closed: true },
      name: 'Closed after',
    },
    [
      'closed accounts accept account-update',
      'the exact normalized CRDT delta is accounts.name only',
    ],
    { before, operationMessages, after },
  );
});

test('rename core handler records its unchanged whitespace and duplicate input boundary', async () => {
  await seedAccount({ id: 'source', name: 'Original' });
  await seedAccount({ id: 'peer', name: 'Duplicate' });
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-update'],
    { id: 'source', name: 'Original' },
    { name: 'account-update' },
  );
  await runHandler(
    handlers['account-update'],
    { id: 'source', name: '  Original  ' },
    { name: 'account-update' },
  );
  await runHandler(
    handlers['account-update'],
    { id: 'source', name: 'Duplicate' },
    { name: 'account-update' },
  );
  await runHandler(
    handlers['account-update'],
    { id: 'source', name: 'duplicate' },
    { name: 'account-update' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const after = await domainSnapshot();
  expect(operationMessages).toEqual([
    message('accounts', 'source', 'name', 'Original'),
    message('accounts', 'source', 'name', '  Original  '),
    message('accounts', 'source', 'name', 'Duplicate'),
    message('accounts', 'source', 'name', 'duplicate'),
  ]);
  expect(rowWithID(after.accounts, 'source').name).toBe('duplicate');
  expect(rowWithID(after.accounts, 'peer').name).toBe('Duplicate');

  recordCase(
    'rename-handler-input-boundary',
    {
      source: { id: 'source', name: 'Original' },
      peer: { id: 'peer', name: 'Duplicate' },
      submittedNames: [
        'Original',
        '  Original  ',
        'Duplicate',
        'duplicate',
      ],
    },
    [
      'the core handler emits a name cell even when the value is unchanged',
      'the core handler does not trim outer whitespace',
      'the core handler does not reject exact or case-variant duplicate names',
      'desktop input validation is therefore a separate boundary, not handler behavior',
    ],
    { operationMessages, after },
  );
});

test('reopen, repeated reopen, and History preserve the same identity', async () => {
  await seedAccount({ id: 'source', name: 'Closed', closed: true });
  clearUndo();
  const firstMarker = await crdtMarker();
  await runHandler(
    handlers['account-reopen'],
    { id: 'source' },
    { name: 'account-reopen' },
  );
  const firstMessages = await crdtMessagesSince(firstMarker);
  expect(firstMessages).toEqual([
    message('accounts', 'source', 'closed', 0),
  ]);
  expect(await accountRow('source')).toMatchObject({ id: 'source', closed: 0 });

  const undoMarker = await crdtMarker();
  await runHandler(handlers.undo, undefined, { name: 'undo' });
  const undoMessages = await crdtMessagesSince(undoMarker);
  expect(undoMessages).toEqual([
    message('accounts', 'source', 'closed', 1),
  ]);

  const repeatMarker = await crdtMarker();
  await runHandler(
    handlers['account-reopen'],
    { id: 'source' },
    { name: 'account-reopen' },
  );
  await runHandler(
    handlers['account-reopen'],
    { id: 'source' },
    { name: 'account-reopen' },
  );
  const repeatMessages = await crdtMessagesSince(repeatMarker);
  expect(repeatMessages).toEqual([
    message('accounts', 'source', 'closed', 0),
    message('accounts', 'source', 'closed', 0),
  ]);
  const afterRepeat = await accountRow('source');

  recordCase(
    'reopen-repeat-history',
    { account: { id: 'source', closed: true }, repeatedCalls: 2 },
    [
      'reopen writes accounts.closed = 0 on the same ID',
      'History undo restores closed = 1',
      'the pinned upstream handler emits another closed = 0 cell for a repeated reopen',
    ],
    { firstMessages, undoMessages, repeatMessages, afterRepeat },
  );
});

test('empty close tombstones only the account and History restores it', async () => {
  await seedAccount({ id: 'source', name: 'Empty' });
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-close'],
    { id: 'source' },
    { name: 'account-close' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const afterOperation = await domainSnapshot();
  expect(operationMessages).toEqual([
    message('accounts', 'source', 'tombstone', 1),
  ]);
  expect(rowWithID(afterOperation.accounts, 'source').tombstone).toBe(1);
  expect(rowWithID(afterOperation.payees, 'transfer-source')).toMatchObject({
    tombstone: 0,
    transfer_acct: 'source',
  });

  const undoMarker = await crdtMarker();
  await runHandler(handlers.undo, undefined, { name: 'undo' });
  const undoMessages = await crdtMessagesSince(undoMarker);
  const afterUndo = await domainSnapshot();
  expect(undoMessages).toEqual([
    message('accounts', 'source', 'tombstone', 0),
  ]);
  expect(rowWithID(afterUndo.accounts, 'source').tombstone).toBe(0);

  recordCase(
    'close-empty-history',
    { account: { id: 'source', livePhysicalTransactionCount: 0 } },
    [
      'empty close tombstones the account instead of setting closed',
      'empty close leaves the transfer payee live',
      'History undo resurrects the account',
    ],
    { operationMessages, afterOperation, undoMessages, afterUndo },
  );
});

test('nonempty exact-zero close writes closed without a transfer', async () => {
  await seedAccount({ id: 'source', name: 'Zero' });
  await seedTransaction({ id: 'zero-row', account: 'source', amount: 0 });
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-close'],
    { id: 'source' },
    { name: 'account-close' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const after = await domainSnapshot();
  expect(operationMessages).toEqual([
    message('accounts', 'source', 'closed', 1),
  ]);
  expect(rowWithID(after.accounts, 'source')).toMatchObject({
    closed: 1,
    tombstone: 0,
  });
  expect(after.transactions.filter(row => row.notes === 'Closing account')).toEqual(
    [],
  );

  recordCase(
    'close-zero',
    { account: { id: 'source', physicalRows: [{ id: 'zero-row', amount: 0 }] } },
    [
      'a physical live row prevents empty deletion',
      'exact zero closes with accounts.closed = 1 and creates no transfer',
    ],
    { operationMessages, after },
  );
});

test('positive on-budget close creates signed transfer and History removes it', async () => {
  const result = await runClosingTransfer({
    sourceOffBudget: false,
    destinationOffBudget: false,
    balance: 4_250,
  });
  expect(result.sourceTransaction.category).toBeNull();
  const undoMarker = await crdtMarker();
  await runHandler(handlers.undo, undefined, { name: 'undo' });
  const undoMessages = await crdtMessagesSince(undoMarker);
  const afterUndo = await domainSnapshot();
  expect(rowWithID(afterUndo.accounts, 'source').closed).toBe(0);
  const undoneClosingRows = afterUndo.transactions.filter(
    row => row.notes === 'Closing account',
  );
  expect(undoneClosingRows).toHaveLength(2);
  expect(undoneClosingRows.every(row => row.tombstone === 1)).toBe(true);
  expect(undoMessages.filter(value => value.dataset === 'accounts')).toContainEqual(
    message('accounts', 'source', 'closed', 0),
  );

  recordCase(
    'close-positive-on-to-on-history',
    {
      source: { id: 'source', offBudget: false, balance: 4_250 },
      destination: { id: 'destination', offBudget: false },
    },
    [
      'source closing amount is -balance and destination amount is balance',
      'same-budget-type transfer category is null',
      'History restores open state and tombstones both created transfer legs',
    ],
    { ...result, undoMessages, afterUndo },
  );
});

test('negative on-budget close reverses transfer signs', async () => {
  const result = await runClosingTransfer({
    sourceOffBudget: false,
    destinationOffBudget: false,
    balance: -2_300,
  });
  expect(result.sourceTransaction.amount).toBe(2_300);
  expect(result.destinationTransaction.amount).toBe(-2_300);

  recordCase(
    'close-negative-on-to-on',
    {
      source: { id: 'source', offBudget: false, balance: -2_300 },
      destination: { id: 'destination', offBudget: false },
    },
    [
      'negative balances use the same source = -balance rule',
      'the paired destination keeps the original signed balance',
    ],
    result,
  );
});

test('on-budget to off-budget close preserves the selected hidden category', async () => {
  await seedHiddenCategory();
  const result = await runClosingTransfer({
    sourceOffBudget: false,
    destinationOffBudget: true,
    balance: 3_100,
    categoryID: 'hidden-category',
  });
  expect(result.sourceTransaction.category).toBe('hidden-category');
  expect(result.destinationTransaction.category).toBeNull();
  expectCell(
    result.operationMessages,
    message(
      'transactions',
      String(result.sourceTransaction.id),
      'category',
      'hidden-category',
    ),
  );

  recordCase(
    'close-on-to-off-hidden-category',
    {
      source: { id: 'source', offBudget: false, balance: 3_100 },
      destination: { id: 'destination', offBudget: true },
      category: { id: 'hidden-category', hidden: true },
    },
    [
      'on-budget to off-budget keeps the supplied category on the source leg',
      'a hidden live category is accepted by the real handler path',
      'the paired destination leg remains uncategorized',
    ],
    result,
  );
});

test('off-budget to on-budget close needs no category', async () => {
  const result = await runClosingTransfer({
    sourceOffBudget: true,
    destinationOffBudget: false,
    balance: 1_700,
  });
  expect(result.sourceTransaction.category).toBeNull();
  expect(result.destinationTransaction.category).toBeNull();

  recordCase(
    'close-off-to-on',
    {
      source: { id: 'source', offBudget: true, balance: 1_700 },
      destination: { id: 'destination', offBudget: false },
      category: null,
    },
    [
      'off-budget to on-budget succeeds without a category',
      'both persisted transfer legs are uncategorized',
    ],
    result,
  );
});

test('off-budget to off-budget close clears category semantics', async () => {
  const result = await runClosingTransfer({
    sourceOffBudget: true,
    destinationOffBudget: true,
    balance: 900,
  });
  expect(result.sourceTransaction.category).toBeNull();
  expect(result.destinationTransaction.category).toBeNull();

  recordCase(
    'close-off-to-off',
    {
      source: { id: 'source', offBudget: true, balance: 900 },
      destination: { id: 'destination', offBudget: true },
      category: null,
    },
    [
      'off-budget to off-budget succeeds without a category',
      'same-type transfer cleanup leaves both legs uncategorized',
    ],
    result,
  );
});

test('self-transfer close refuses before any CRDT/domain mutation', async () => {
  await seedAccount({ id: 'source', name: 'Self' });
  await seedTransaction({ id: 'balance-row', account: 'source', amount: 500 });
  clearUndo();
  const before = await domainSnapshot();
  const marker = await crdtMarker();
  const countBefore = await crdtCount();
  await expect(
    runHandler(
      handlers['account-close'],
      { id: 'source', transferAccountId: 'source' },
      { name: 'account-close' },
    ),
  ).rejects.toThrow(/transfer account can not be the account being closed/);
  const operationMessages = await crdtMessagesSince(marker);
  const after = await domainSnapshot();
  expect(operationMessages).toEqual([]);
  expect(await crdtCount()).toBe(countBefore);
  expect(after).toEqual(before);

  recordCase(
    'close-self-transfer-refusal',
    {
      source: { id: 'source', balance: 500 },
      transferAccountId: 'source',
    },
    [
      'self transfer throws the pinned API error',
      'refusal emits zero CRDT cells and leaves selected domain rows unchanged',
    ],
    { operationMessages, before, after },
  );
});

test('split parent is excluded while children contribute to close balance', async () => {
  await seedAccount({ id: 'source', name: 'Split source' });
  await seedAccount({ id: 'destination', name: 'Split destination' });
  await seedSplitFamily('source');
  await seedTransaction({ id: 'ordinary-row', account: 'source', amount: 300 });
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-close'],
    { id: 'source', transferAccountId: 'destination' },
    { name: 'account-close' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const after = await domainSnapshot();
  const sourceClosingRow = after.transactions.find(
    row => row.acct === 'source' && row.notes === 'Closing account',
  );
  expect(sourceClosingRow).toBeDefined();
  expect(sourceClosingRow?.amount).toBe(-1_300);
  expect(after.transactions.filter(row => row.acct === 'source')).toHaveLength(5);

  recordCase(
    'close-split-balance',
    {
      source: {
        id: 'source',
        rows: [
          { id: 'split-parent', amount: 1_000, isParent: true },
          { id: 'split-child-a', amount: 400, isChild: true },
          { id: 'split-child-b', amount: 600, isChild: true },
          { id: 'ordinary-row', amount: 300 },
        ],
      },
      destination: { id: 'destination' },
    },
    [
      'close balance sums live non-parent rows: 400 + 600 + 300',
      'the physical parent still contributes to transaction count',
      'the source closing leg is -1300 rather than double-counting the parent',
    ],
    { operationMessages, after, sourceClosingRow },
  );
});

test('forced simple delete tombstones source rows, transfer payee, and account', async () => {
  await seedAccount({ id: 'source', name: 'Forced simple' });
  await seedTransaction({ id: 'simple-a', account: 'source', amount: 100 });
  await seedTransaction({ id: 'simple-b', account: 'source', amount: -40 });
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-close'],
    { id: 'source', forced: true },
    { name: 'account-close' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const after = await domainSnapshot();
  for (const transactionID of ['simple-a', 'simple-b']) {
    expectCell(
      operationMessages,
      message('transactions', transactionID, 'tombstone', 1),
    );
    expect(rowWithID(after.transactions, transactionID).tombstone).toBe(1);
  }
  expectCell(operationMessages, message('accounts', 'source', 'tombstone', 1));
  expectCell(
    operationMessages,
    message('payees', 'transfer-source', 'tombstone', 1),
  );
  expect(rowWithID(after.accounts, 'source').tombstone).toBe(1);
  expect(rowWithID(after.payees, 'transfer-source').tombstone).toBe(1);

  recordCase(
    'forced-delete-simple',
    { account: { id: 'source', transactionIDs: ['simple-a', 'simple-b'] } },
    [
      'forced close tombstones every source transaction',
      'forced close tombstones the source transfer payee and account',
      'no synthetic balancing transfer is created',
    ],
    { operationMessages, after },
  );
});

test('forced split-transfer graph delete preserves and detaches opposite leg', async () => {
  await seedAccount({ id: 'source', name: 'Graph source' });
  await seedAccount({ id: 'destination', name: 'Graph destination' });
  await seedSplitFamily('source');
  await seedTransaction({
    id: 'source-transfer',
    account: 'source',
    amount: -700,
    payee: 'transfer-destination',
    notes: 'Synthetic existing transfer',
  });
  const seededRows = await transactionRows(['source', 'destination']);
  const sourceTransfer = rowWithID(seededRows, 'source-transfer');
  const counterpartID = String(sourceTransfer.transferred_id);
  expect(counterpartID).not.toBe('null');
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-close'],
    { id: 'source', forced: true },
    { name: 'account-close' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const after = await domainSnapshot();
  for (const sourceID of [
    'split-parent',
    'split-child-a',
    'split-child-b',
    'source-transfer',
  ]) {
    expect(rowWithID(after.transactions, sourceID).tombstone).toBe(1);
    expectCell(
      operationMessages,
      message('transactions', sourceID, 'tombstone', 1),
    );
  }
  const counterpart = rowWithID(after.transactions, counterpartID);
  expect(counterpart).toMatchObject({
    acct: 'destination',
    amount: 700,
    description: null,
    transferred_id: null,
    tombstone: 0,
  });
  expectCell(
    operationMessages,
    message('transactions', counterpartID, 'description', null),
  );
  expectCell(
    operationMessages,
    message('transactions', counterpartID, 'transferred_id', null),
  );
  expect(rowWithID(after.payees, 'transfer-source').tombstone).toBe(1);
  expect(rowWithID(after.accounts, 'source').tombstone).toBe(1);

  recordCase(
    'forced-delete-split-transfer-graph',
    {
      source: {
        id: 'source',
        splitFamily: ['split-parent', 'split-child-a', 'split-child-b'],
        transfer: 'source-transfer',
      },
      destination: { id: 'destination', counterpartID },
    },
    [
      'forced close tombstones split parent, split children, and source transfer',
      'the opposite transfer row survives with amount/date/notes/account intact',
      'the opposite row clears payee and transfer_id only',
      'the source transfer payee and account are tombstoned',
    ],
    { operationMessages, seededRows, after, counterpart },
  );
});

test('SimpleFIN unlink clears local link cells without a remote call', async () => {
  await seedAccount({
    id: 'source',
    name: 'SimpleFIN',
    link: {
      provider: 'simpleFin',
      bankID: 'bank-simplefin',
      remoteAccountID: 'remote-account-simplefin',
    },
  });
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-unlink'],
    { id: 'source' },
    { name: 'account-unlink' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const after = await accountRow('source');
  expect(operationMessages).toEqual([
    message('accounts', 'source', 'account_id', null),
    message('accounts', 'source', 'bank', null),
    message('accounts', 'source', 'balance_current', null),
    message('accounts', 'source', 'balance_available', null),
    message('accounts', 'source', 'balance_limit', null),
    message('accounts', 'source', 'account_sync_source', null),
    message('accounts', 'source', 'bank_sync_status', null),
  ]);
  expect(after).toMatchObject({
    account_id: null,
    bank: null,
    balance_current: null,
    balance_available: null,
    balance_limit: null,
    account_sync_source: null,
    bank_sync_status: null,
    last_sync: 'synthetic-last-sync',
  });
  expect(postMock).not.toHaveBeenCalled();

  recordCase(
    'unlink-simplefin',
    {
      account: {
        id: 'source',
        provider: 'simpleFin',
        linked: true,
        lastSync: 'synthetic-last-sync',
      },
    },
    [
      'SimpleFIN unlink clears the seven pinned local link/balance/status cells',
      'last_sync is preserved',
      'SimpleFIN unlink makes no remote provider call',
    ],
    { operationMessages, after, remoteCalls: normalizedRemoteCalls() },
  );
});

test('GoCardless last bank reference calls mocked remote removal', async () => {
  await seedAccount({
    id: 'source',
    name: 'GoCardless last',
    link: {
      provider: 'goCardless',
      bankID: 'bank-gocardless',
      remoteAccountID: 'remote-account-gocardless',
    },
  });
  tokenMock.mockResolvedValue('synthetic-token');
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-unlink'],
    { id: 'source' },
    { name: 'account-unlink' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  const remoteCalls = normalizedRemoteCalls();
  expect(remoteCalls).toHaveLength(1);
  expect(remoteCalls[0]).toMatchObject({
    body: { requisitionId: 'remote-bank-gocardless' },
    tokenHeaderPresent: true,
  });
  expect(String(remoteCalls[0].url)).toMatch(/\/remove-account$/);
  expect(await accountRow('source')).toMatchObject({ bank: null });

  recordCase(
    'unlink-gocardless-last-reference',
    { account: { id: 'source', provider: 'goCardless' }, bankReferenceCount: 1 },
    [
      'local unlink happens before remote removal',
      'the last bank reference calls the mocked remove-account route once',
      'fixture output records token presence but not token bytes',
    ],
    { operationMessages, after: await accountRow('source'), remoteCalls },
  );
});

test('GoCardless shared bank suppresses remote removal', async () => {
  const link = {
    provider: 'goCardless' as const,
    bankID: 'bank-gocardless',
    remoteAccountID: 'remote-account-a',
  };
  await seedAccount({ id: 'source', name: 'GoCardless A', link });
  await seedAccount({
    id: 'peer',
    name: 'GoCardless B',
    link: { ...link, remoteAccountID: 'remote-account-b' },
  });
  tokenMock.mockResolvedValue('synthetic-token');
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-unlink'],
    { id: 'source' },
    { name: 'account-unlink' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  expect(postMock).not.toHaveBeenCalled();
  expect(await accountRow('source')).toMatchObject({ bank: null });
  expect(await accountRow('peer')).toMatchObject({ bank: 'bank-gocardless' });

  recordCase(
    'unlink-gocardless-shared-bank',
    {
      account: { id: 'source', provider: 'goCardless' },
      peer: { id: 'peer', sameBank: true },
    },
    [
      'source local link cells clear',
      'a remaining shared-bank reference suppresses remote removal',
      'the peer link is unchanged',
    ],
    {
      operationMessages,
      source: await accountRow('source'),
      peer: await accountRow('peer'),
      remoteCalls: normalizedRemoteCalls(),
    },
  );
});

test('GoCardless unlink without token remains a local success', async () => {
  await seedAccount({
    id: 'source',
    name: 'GoCardless no token',
    link: {
      provider: 'goCardless',
      bankID: 'bank-gocardless',
      remoteAccountID: 'remote-account-gocardless',
    },
  });
  tokenMock.mockResolvedValue(null);
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-unlink'],
    { id: 'source' },
    { name: 'account-unlink' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  expect(postMock).not.toHaveBeenCalled();
  const after = await accountRow('source');
  expect(after.bank).toBeNull();

  recordCase(
    'unlink-gocardless-without-token',
    { account: { id: 'source', provider: 'goCardless' }, userTokenPresent: false },
    [
      'GoCardless local link cells clear before token lookup decides remote work',
      'an absent token suppresses remote removal without reverting local unlink',
    ],
    { operationMessages, after, remoteCalls: normalizedRemoteCalls() },
  );
});

test('GoCardless remote failure is swallowed after local unlink', async () => {
  await seedAccount({
    id: 'source',
    name: 'GoCardless remote failure',
    link: {
      provider: 'goCardless',
      bankID: 'bank-gocardless',
      remoteAccountID: 'remote-account-gocardless',
    },
  });
  tokenMock.mockResolvedValue('synthetic-token');
  postMock.mockRejectedValueOnce(new Error('synthetic remote failure'));
  clearUndo();
  const marker = await crdtMarker();
  await expect(
    runHandler(
      handlers['account-unlink'],
      { id: 'source' },
      { name: 'account-unlink' },
    ),
  ).resolves.toBe('ok');
  const operationMessages = await crdtMessagesSince(marker);
  const after = await accountRow('source');
  expect(after.bank).toBeNull();
  expect(postMock).toHaveBeenCalledOnce();

  recordCase(
    'unlink-gocardless-remote-failure',
    {
      account: { id: 'source', provider: 'goCardless' },
      remoteResult: 'synthetic rejection',
    },
    [
      'remote removal is mocked and attempted once',
      'the handler swallows the remote rejection',
      'local unlink remains committed',
    ],
    { operationMessages, after, remoteCalls: normalizedRemoteCalls() },
  );
});

test('close undo excludes provider unlink while restoring closed state', async () => {
  await seedAccount({
    id: 'source',
    name: 'Linked close',
    link: {
      provider: 'simpleFin',
      bankID: 'bank-simplefin',
      remoteAccountID: 'remote-account-simplefin',
    },
  });
  await seedTransaction({ id: 'zero-row', account: 'source', amount: 0 });
  clearUndo();
  const marker = await crdtMarker();
  await runHandler(
    handlers['account-close'],
    { id: 'source' },
    { name: 'account-close' },
  );
  const operationMessages = await crdtMessagesSince(marker);
  expect(operationMessages).toHaveLength(8);
  expectCell(operationMessages, message('accounts', 'source', 'closed', 1));
  expectCell(operationMessages, message('accounts', 'source', 'bank', null));

  const undoMarker = await crdtMarker();
  await runHandler(handlers.undo, undefined, { name: 'undo' });
  const undoMessages = await crdtMessagesSince(undoMarker);
  const afterUndo = await accountRow('source');
  expect(undoMessages).toEqual([
    message('accounts', 'source', 'closed', 0),
  ]);
  expect(afterUndo).toMatchObject({
    closed: 0,
    bank: null,
    account_id: null,
    account_sync_source: null,
    last_sync: 'synthetic-last-sync',
  });

  recordCase(
    'close-unlink-undo-boundary',
    { account: { id: 'source', provider: 'simpleFin', balance: 0 } },
    [
      'close operation emits seven unlink cells followed by closed = 1',
      'History undo emits only closed = 0',
      'the local provider link remains cleared after undo',
    ],
    { operationMessages, undoMessages, afterUndo },
  );
});

test('schedule reference survives close and reopen while posting eligibility changes', async () => {
  schedulesApp.startServices();
  await seedAccount({ id: 'source', name: 'Scheduled account' });
  await seedTransaction({ id: 'zero-row', account: 'source', amount: 0 });
  await runHandler(
    handlers['schedule/create'],
    {
      schedule: {
        id: 'schedule-source',
        name: 'Synthetic schedule',
        posts_transaction: true,
      },
      conditions: [
        { op: 'is', field: 'account', value: 'source' },
        { op: 'is', field: 'amount', value: -775 },
        { op: 'is', field: 'date', value: FIXED_DAY },
      ],
    },
    { name: 'schedule/create' },
  );
  const before = await scheduleRows();
  clearUndo();

  const closeMarker = await crdtMarker();
  await runHandler(
    handlers['account-close'],
    { id: 'source' },
    { name: 'account-close' },
  );
  const closeMessages = await crdtMessagesSince(closeMarker);
  const afterClose = await scheduleRows();
  expect(afterClose).toEqual(before);
  expect(closeMessages).toEqual([
    message('accounts', 'source', 'closed', 1),
  ]);

  const closedServiceMarker = await crdtMarker();
  await runHandler(handlers['schedule/force-run-service'], undefined, {
    name: 'schedule/force-run-service',
  });
  const closedServiceMessages = await crdtMessagesSince(closedServiceMarker);
  const closedScheduledTransactions = (
    await transactionRows(['source'])
  ).filter(row => row.schedule === 'schedule-source' && row.tombstone === 0);
  expect(closedServiceMessages).toEqual([]);
  expect(closedScheduledTransactions).toEqual([]);

  const reopenMarker = await crdtMarker();
  await runHandler(
    handlers['account-reopen'],
    { id: 'source' },
    { name: 'account-reopen' },
  );
  const reopenMessages = await crdtMessagesSince(reopenMarker);
  const afterReopen = await scheduleRows();
  expect(afterReopen).toEqual(before);
  expect(reopenMessages).toEqual([
    message('accounts', 'source', 'closed', 0),
  ]);

  const openServiceMarker = await crdtMarker();
  await runHandler(handlers['schedule/force-run-service'], undefined, {
    name: 'schedule/force-run-service',
  });
  const openServiceMessages = await crdtMessagesSince(openServiceMarker);
  const openScheduledTransactions = (
    await transactionRows(['source'])
  ).filter(row => row.schedule === 'schedule-source' && row.tombstone === 0);
  expect(openScheduledTransactions).toHaveLength(1);
  expect(openScheduledTransactions[0]).toMatchObject({
    acct: 'source',
    amount: -775,
    date: FIXED_DATE_INTEGER,
    schedule: 'schedule-source',
  });
  expect(
    openServiceMessages.some(
      value =>
        value.dataset === 'transactions' &&
        value.row === openScheduledTransactions[0].id,
    ),
  ).toBe(true);

  recordCase(
    'schedule-close-reopen-eligibility',
    {
      account: { id: 'source' },
      schedule: {
        id: 'schedule-source',
        postsTransaction: true,
        amount: -775,
        date: FIXED_DAY,
      },
    },
    [
      'close and reopen emit no schedule/rule/date cells',
      'the schedule account reference remains byte-for-byte unchanged',
      'automatic service posts nothing while the account is closed',
      'automatic service posts the scheduled transaction after reopen',
    ],
    {
      before,
      closeMessages,
      afterClose,
      closedServiceMessages,
      closedScheduledTransactions,
      reopenMessages,
      afterReopen,
      openServiceMessages,
      openScheduledTransactions,
    },
  );
});
