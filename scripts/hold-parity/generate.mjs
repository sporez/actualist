#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertPinnedOracle,
  hasOracleRoot,
  oraclePin,
  ORACLE_ROOT_VARIABLE,
  pinnedFixtureDirectory,
  pinnedOracleRoot,
} from '../parity/lib/oracle-pin.mjs';
import { compareWithCommitted } from '../parity/lib/fixture-diff.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const helperPaths = ['scripts/parity/lib/oracle-pin.mjs', 'scripts/parity/lib/fixture-diff.mjs'];
const EXPECTED_TAG = oraclePin.tag;
const EXPECTED_COMMIT = oraclePin.commit;
const EXPECTED_VERSION = oraclePin.packageVersion;
const SCHEMA_VERSION = 1;
const EXPECTED_CASE_COUNT = 16;
const contractName = 'hold-contract.json';
const manifestName = 'hold-manifest.json';
const expectedSourceHashes = {
  'packages/loot-core/src/server/budget/actions.ts':
    '5fa3915814c773ee998e6836e5fe7c5a562cad643b310a1ac74faad662ec3294',
  'packages/loot-core/src/server/budget/app.ts':
    '873e61d76d8023410a6a831d1e3e83c0002f9fd987077904afed867b4eb2fc0c',
  'packages/loot-core/src/server/budget/base.ts':
    'c70cc2d5386bc4628bae805b3a82f860b22747413c795cea7f6a87b8c930838b',
  'packages/loot-core/src/server/budget/envelope.ts':
    'bbd07cf2a56f03b5c14d61a50f0cba764f08370895a4c5c2a9cea825626ccdcd',
  'packages/loot-core/src/server/db/index.ts':
    '0b3d3ee68b571523cc8cd3a7044ade50e8afea5941bb54879f45643f92241a71',
  'packages/loot-core/src/server/mutators.ts':
    'f24756558fd2aadc3cbff1fd23514b5908ef6b319c1ad7d8eefeb5ee649f538f',
  'packages/loot-core/src/server/sync/index.ts':
    'f597760aed699ff0f696b2ec433c1d59588e7f2dd53f4aa6518713dfd76c99b8',
  'packages/loot-core/src/platform/server/sqlite/index.ts':
    '2fecae0cd47dd260be771d3a48b8ef5ec48378418c5f8667b8c14d6c95f9dc92',
  'packages/loot-core/src/platform/server/sqlite/index.electron.ts':
    '8fee26e68d2a07d028947d7b54380d03ad088f2d8ff3b606dd34798c84031ab7',
  'packages/desktop-client/src/components/budget/envelope/budgetsummary/ToBudgetMenu.tsx':
    '7c17f3efa6129d2619d6bc3d7b3e320798d63fd1dda4d5049ecb6c5cdc02ca07',
  'packages/desktop-client/src/budget/mutations.ts':
    'e044f65a62975b7cc36c9b2bdd0e3351dd4b07dd3d90548d285769eb759008e2',
};

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${EXPECTED_TAG}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-hold-check-'))
  : resolve(argument('--output') ?? pinnedFixtureDirectory('Holds'));

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function run(command, args, cwd = checkout, environment = process.env) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', env: environment });
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw new Error(`${command} ${args.join(' ')} failed with status ${result.status}`);
  }
  return result.stdout.trim();
}

const packageVersion = JSON.parse(
  readFileSync(join(checkout, 'packages/loot-core/package.json'), 'utf8'),
).version;
if (packageVersion !== EXPECTED_VERSION) {
  throw new Error(`Expected @actual-app/core ${EXPECTED_VERSION}, found ${packageVersion}`);
}

for (const [path, expectedHash] of Object.entries(expectedSourceHashes)) {
  const sourcePath = join(checkout, path);
  if (!existsSync(sourcePath)) throw new Error(`Pinned source is missing: ${path}`);
  const actualHash = sha256(readFileSync(sourcePath));
  if (actualHash !== expectedHash) {
    throw new Error(`Pinned source hash mismatch for ${path}: ${actualHash}`);
  }
}

const runnerRelative = 'packages/loot-core/src/server/budget/__actualist_hold_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryContract = join(checkout, '.actualist-hold-oracle.json');
const temporaryDataDirectory = join(checkout, '.actualist-hold-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

// Each case records its seeded inputs, the handler calls the UI would make, the
// CRDT cells Actual wrote (without timestamps), and every month's sheet state
// after each step, so a Swift replay can seed the same inputs and compare outputs.
const runner = String.raw`// @ts-strict-ignore
import { writeFileSync } from 'node:fs';
import { Timestamp } from '@actual-app/crdt';
import { expect, test } from 'vitest';

import * as budget from '#server/budget/base';
import * as db from '#server/db';
import { handlers } from '#server/main';
import { runHandler } from '#server/mutators';
import * as sheet from '#server/sheet';
import { applyMessages, setSyncingMode } from '#server/sync';
import * as monthUtils from '#shared/months';

const months = [
  '2026-06', '2026-07', '2026-08', '2026-09', '2026-10', '2026-11', '2026-12', '2027-01', '2027-02',
];
const DEFAULT_SETUP = {
  budgetType: 'envelope',
  juneIncome: 0,
  julyIncome: 200000,
  julyGroceriesBudget: 50000,
  julyManualBuffer: 0,
  julyIncomeCarryover: false,
  augustIncome: 0,
  augustIncomeCarryover: false,
};
const STATE_CELLS = [
  ['toBudget', 'to-budget'],
  ['availableFunds', 'available-funds'],
  ['fromLastMonth', 'from-last-month'],
  ['totalIncome', 'total-income'],
  ['totalBudgeted', 'total-budgeted'],
  ['manualHeldAmount', 'buffered'],
  ['automaticHeldAmount', 'buffered-auto'],
  ['heldAmount', 'buffered-selected'],
  ['groceriesBudgeted', 'budget-groceries'],
  ['groceriesSpent', 'sum-amount-groceries'],
  ['groceriesLeftover', 'leftover-groceries'],
  ['salaryCarryover', 'carryover-salary'],
];
const cases = [];

function readCell(sheetName, name) {
  try {
    const value = sheet.getCell(sheetName, name).value;
    return typeof value === 'number' || typeof value === 'boolean' ? value : null;
  } catch {
    return null;
  }
}

function monthStates() {
  return months.map(month => {
    const sheetName = monthUtils.sheetForMonth(month);
    const state = { month };
    for (const [key, cell] of STATE_CELLS) {
      state[key] = readCell(sheetName, cell);
    }
    return state;
  });
}

function stateOf(states, month) {
  return states.find(state => state.month === month);
}

function finalState(results, month) {
  return stateOf(results[results.length - 1].stateAfter, month);
}

// Null means Actual created no such cell for that month; the hold fields must always exist.
const CORE_STATE_KEYS = [
  'toBudget', 'availableFunds', 'fromLastMonth', 'totalIncome', 'totalBudgeted',
  'manualHeldAmount', 'automaticHeldAmount', 'heldAmount',
];
function expectNoNullState(states) {
  for (const state of states) {
    for (const key of CORE_STATE_KEYS) {
      expect(state[key], state.month + ' ' + key).not.toBeNull();
    }
  }
}

async function resetDatabase() {
  if (sheet.get()) {
    await sheet.waitOnSpreadsheet();
    sheet.unloadSpreadsheet();
  }
  setSyncingMode('disabled');
  await global.emptyDatabase()();
}

async function setupBudget(overrides = {}) {
  const setup = { ...DEFAULT_SETUP, ...overrides };
  await resetDatabase();
  await db.insertAccount({ id: 'checking', name: 'Synthetic Checking', offbudget: 0 });
  await db.insertCategoryGroup({ id: 'income-group', name: 'Synthetic Income', is_income: 1 });
  await db.insertCategory({
    id: 'salary', name: 'Synthetic Salary', cat_group: 'income-group', is_income: 1,
  });
  await db.insertCategoryGroup({ id: 'expense-group', name: 'Synthetic Expenses', is_income: 0 });
  await db.insertCategory({
    id: 'groceries', name: 'Synthetic Groceries', cat_group: 'expense-group', is_income: 0,
  });
  for (const [id, date, amount] of [
    ['income-june', '2026-06-01', setup.juneIncome],
    ['income-july', '2026-07-01', setup.julyIncome],
    ['income-august', '2026-08-01', setup.augustIncome],
  ]) {
    if (amount !== 0) {
      await db.insertTransaction({
        id, account: 'checking', date, amount, category: 'salary', cleared: true,
      });
    }
  }
  if (setup.budgetType !== 'envelope') {
    db.runQuery(
      "INSERT OR REPLACE INTO preferences (id, value) VALUES ('budgetType', '" + setup.budgetType + "')",
    );
  }
  if (setup.julyGroceriesBudget !== 0) {
    await db.insert('zero_budgets', {
      id: '202607-groceries', month: 202607, category: 'groceries',
      amount: setup.julyGroceriesBudget, carryover: 0,
    });
  }
  if (setup.julyIncomeCarryover) {
    await db.insert('zero_budgets', {
      id: '202607-salary', month: 202607, category: 'salary', amount: 0, carryover: 1,
    });
  }
  if (setup.augustIncomeCarryover) {
    await db.insert('zero_budgets', {
      id: '202608-salary', month: 202608, category: 'salary', amount: 0, carryover: 1,
    });
  }
  if (setup.julyManualBuffer !== 0) {
    await db.insert('zero_budget_months', { id: '2026-07', buffered: setup.julyManualBuffer });
  }

  await sheet.loadSpreadsheet(db);
  if (setup.budgetType !== 'envelope') {
    sheet.get().meta().budgetType = setup.budgetType;
  }
  await budget.createBudget(months);
  await sheet.waitOnSpreadsheet();
  db.runQuery('DELETE FROM messages_crdt');
  setSyncingMode('offline');
  return setup;
}

function lastMessageID() {
  return db.firstSync('SELECT COALESCE(MAX(id), 0) AS id FROM messages_crdt')?.id ?? 0;
}

// Timestamps are wall-clock plus a random client ID, so produced cells omit them.
async function cellsAfter(id) {
  const rows = await db.all(
    'SELECT dataset, row, column, value FROM messages_crdt WHERE id > ? ORDER BY id',
    [id],
  );
  return rows.map(row => ({
    dataset: row.dataset,
    row: row.row,
    column: row.column,
    serializedValue: row.value,
  }));
}

async function runStep(handler, args) {
  const beforeID = lastMessageID();
  let returned;
  let error = null;
  try {
    returned = await runHandler(handlers[handler], args, { name: handler });
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  }
  await sheet.waitOnSpreadsheet();
  return {
    handler,
    args,
    returned: returned ?? null,
    error,
    cells: await cellsAfter(beforeID),
    stateAfter: monthStates(),
  };
}

// ToBudgetMenu sends reset-income-carryover when Hold is chosen; the hold form then sends the amount.
function uiHold(month, amount) {
  return [
    { handler: 'budget/reset-income-carryover', args: { month } },
    { handler: 'budget/hold-for-next-month', args: { month, amount } },
  ];
}

async function runCase({ id, description, setup: overrides = {}, steps, uiReachable = true }) {
  const setup = await setupBudget(overrides);
  const before = monthStates();
  const results = [];
  for (const step of steps) {
    results.push(await runStep(step.handler, step.args));
  }
  if (setup.budgetType === 'envelope') {
    expectNoNullState(before);
    for (const result of results) expectNoNullState(result.stateAfter);
  }
  cases.push({ id, description, uiReachable, setup, before, steps: results });
  return results;
}

function encodeValue(value) {
  if (value === null) return '0:';
  return typeof value === 'number' ? 'N:' + value : 'S:' + value;
}

test('Actual ${EXPECTED_VERSION} hold contract', async () => {
  const partial = await runCase({
    id: 'hold-partial-then-repeat-adds',
    description: 'Holds of 40000 then 20000 in July accumulate in the manual hold.',
    steps: [...uiHold('2026-07', 40000), ...uiHold('2026-07', 20000)],
  });
  expect(partial[1].returned).toBe(true);
  expect(finalState(partial, '2026-07')).toMatchObject({
    toBudget: 90000, manualHeldAmount: 60000, heldAmount: 60000,
  });

  const all = await runCase({
    id: 'hold-full-available-to-budget',
    description: 'Holding the whole July To Budget leaves nothing to budget.',
    steps: uiHold('2026-07', 150000),
  });
  expect(all[1].returned).toBe(true);
  expect(finalState(all, '2026-07')).toMatchObject({ toBudget: 0, heldAmount: 150000 });

  const clamped = await runCase({
    id: 'hold-more-than-available-clamps',
    description: 'A hold larger than July To Budget is clamped to To Budget.',
    steps: uiHold('2026-07', 200000),
  });
  expect(finalState(clamped, '2026-07')).toMatchObject({ toBudget: 0, heldAmount: 150000 });

  const repeatClamped = await runCase({
    id: 'hold-repeat-clamps-to-remaining-to-budget',
    description: 'A second hold in July is clamped to the To Budget left after the first.',
    steps: [...uiHold('2026-07', 100000), ...uiHold('2026-07', 200000)],
  });
  expect(finalState(repeatClamped, '2026-07')).toMatchObject({
    toBudget: 0, manualHeldAmount: 150000, heldAmount: 150000,
  });

  const released = await runCase({
    id: 'release-hold-restores-to-budget',
    description: 'Resetting the manual hold returns the held amount to July To Budget.',
    steps: [...uiHold('2026-07', 40000), { handler: 'budget/reset-hold', args: { month: '2026-07' } }],
  });
  expect(released[2].returned).toBe(null);
  expect(finalState(released, '2026-07')).toMatchObject({
    toBudget: 150000, manualHeldAmount: 0, heldAmount: 0,
  });

  const releaseWithoutRow = await runCase({
    id: 'release-without-stored-hold-row-writes-zero-hold',
    description: 'A direct reset-hold with no stored hold row writes a zero manual hold. The menu offers reset only when a manual hold is set.',
    steps: [{ handler: 'budget/reset-hold', args: { month: '2026-07' } }],
    uiReachable: false,
  });
  expect(releaseWithoutRow[0].cells.some(
    cell => cell.dataset === 'zero_budget_months' && cell.column === 'buffered',
  )).toBe(true);
  expect(finalState(releaseWithoutRow, '2026-07')).toMatchObject({ toBudget: 150000, heldAmount: 0 });

  const restarted = await runCase({
    id: 'hold-after-release-starts-from-zero',
    description: 'After a release, a new hold starts from a zero manual hold.',
    steps: [
      ...uiHold('2026-07', 40000),
      { handler: 'budget/reset-hold', args: { month: '2026-07' } },
      ...uiHold('2026-07', 20000),
    ],
  });
  expect(finalState(restarted, '2026-07')).toMatchObject({
    toBudget: 130000, manualHeldAmount: 20000, heldAmount: 20000,
  });

  const rolled = await runCase({
    id: 'hold-rolls-into-next-month-available',
    description: 'Money held in July returns as August from-last-month and To Budget.',
    steps: uiHold('2026-07', 40000),
  });
  expect(finalState(rolled, '2026-07')).toMatchObject({ toBudget: 110000, heldAmount: 40000 });
  expect(finalState(rolled, '2026-08')).toMatchObject({
    fromLastMonth: 150000, toBudget: 150000, heldAmount: 0,
  });

  const yearEnd = await runCase({
    id: 'hold-across-year-boundary-rolls-into-january',
    description: 'A December hold returns through the 2026-12 to 2027-01 sheet link.',
    steps: uiHold('2026-12', 40000),
  });
  expect(finalState(yearEnd, '2026-12')).toMatchObject({ toBudget: 110000, heldAmount: 40000 });
  expect(finalState(yearEnd, '2027-01')).toMatchObject({
    fromLastMonth: 150000, toBudget: 150000, heldAmount: 0,
  });

  const zeroToBudget = await runCase({
    id: 'hold-noop-when-to-budget-is-zero',
    description: 'With no July To Budget, a direct hold call returns false and writes no hold cells. The menu hides Hold when To Budget is not positive.',
    setup: { julyIncome: 0, julyGroceriesBudget: 0 },
    steps: uiHold('2026-07', 10000),
    uiReachable: false,
  });
  expect(zeroToBudget[1].returned).toBe(false);
  expect(zeroToBudget[1].cells).toEqual([]);
  expect(finalState(zeroToBudget, '2026-07')).toMatchObject({ toBudget: 0, heldAmount: 0 });

  const negativeToBudget = await runCase({
    id: 'hold-noop-when-to-budget-is-negative',
    description: 'With negative July To Budget, a direct hold call returns false and writes no hold cells. The menu hides Hold when To Budget is not positive.',
    setup: { julyIncome: 100000, julyGroceriesBudget: 150000 },
    steps: uiHold('2026-07', 10000),
    uiReachable: false,
  });
  expect(negativeToBudget[1].returned).toBe(false);
  expect(negativeToBudget[1].cells).toEqual([]);
  expect(finalState(negativeToBudget, '2026-07')).toMatchObject({ toBudget: -50000, heldAmount: 0 });

  const releasedAutomatic = await runCase({
    id: 'release-manual-hold-reveals-automatic-income-hold',
    description: 'Releasing a manual hold reveals the income-carryover hold, which the next reset clears.',
    setup: {
      julyIncome: 100000,
      julyGroceriesBudget: 0,
      julyManualBuffer: 20000,
      julyIncomeCarryover: true,
      augustIncomeCarryover: true,
      augustIncome: 25000,
    },
    steps: [
      { handler: 'budget/reset-hold', args: { month: '2026-07' } },
      { handler: 'budget/reset-income-carryover', args: { month: '2026-07' } },
    ],
  });
  expect(stateOf(releasedAutomatic[0].stateAfter, '2026-07')).toMatchObject({
    manualHeldAmount: 0, automaticHeldAmount: 100000, heldAmount: 100000, toBudget: 0,
  });
  expect(finalState(releasedAutomatic, '2026-07')).toMatchObject({
    manualHeldAmount: 0, automaticHeldAmount: 0, heldAmount: 0, toBudget: 100000,
  });
  expect(finalState(releasedAutomatic, '2026-08')).toMatchObject({
    automaticHeldAmount: 25000, heldAmount: 25000,
  });

  const replacedAutomatic = await runCase({
    id: 'hold-handler-replaces-automatic-income-hold-when-called-directly',
    description: 'Calling the hold handler without the menu reset replaces an active automatic hold with the manual amount.',
    setup: { juneIncome: 50000, julyIncome: 100000, julyGroceriesBudget: 0, julyIncomeCarryover: true },
    steps: [{ handler: 'budget/hold-for-next-month', args: { month: '2026-07', amount: 30000 } }],
    uiReachable: false,
  });
  expect(replacedAutomatic[0].returned).toBe(true);
  expect(finalState(replacedAutomatic, '2026-07')).toMatchObject({
    manualHeldAmount: 30000, automaticHeldAmount: 100000, heldAmount: 30000, toBudget: 120000,
  });

  await runCase({
    id: 'hold-in-tracking-budget-is-not-offered',
    description: 'Tracking budgets have no Hold menu item. The handler result is recorded as the direct-call outcome.',
    setup: { budgetType: 'tracking' },
    steps: uiHold('2026-07', 40000),
    uiReachable: false,
  });

  const future = await runCase({
    id: 'hold-in-future-month-creates-stored-row',
    description: 'A hold in January 2027 with no stored month row creates the row.',
    steps: uiHold('2027-01', 1000),
  });
  expect(future[1].cells.some(
    cell => cell.dataset === 'zero_budget_months' && cell.row === '2027-01',
  )).toBe(true);
  expect(finalState(future, '2027-01')).toMatchObject({
    fromLastMonth: 150000, manualHeldAmount: 1000, heldAmount: 1000, toBudget: 149000,
  });

  const replaySetup = await setupBudget();
  const replayBefore = monthStates();
  const replayCells = [
    {
      timestamp: Timestamp.parse('2026-09-26T12:00:00.000Z-0000-61637475616c6973'),
      dataset: 'zero_budget_months', row: '2026-07', column: 'buffered', value: 45000,
    },
    {
      timestamp: Timestamp.parse('2026-09-26T12:00:00.000Z-0001-61637475616c6973'),
      dataset: 'zero_budgets', row: '202607-salary', column: 'month', value: 202607,
    },
    {
      timestamp: Timestamp.parse('2026-09-26T12:00:00.000Z-0002-61637475616c6973'),
      dataset: 'zero_budgets', row: '202607-salary', column: 'category', value: 'salary',
    },
    {
      timestamp: Timestamp.parse('2026-09-26T12:00:00.000Z-0003-61637475616c6973'),
      dataset: 'zero_budgets', row: '202607-salary', column: 'carryover', value: 0,
    },
  ];
  await applyMessages(replayCells);
  await sheet.waitOnSpreadsheet();
  const replayAfter = monthStates();
  expect(stateOf(replayAfter, '2026-07')).toMatchObject({
    toBudget: 105000, manualHeldAmount: 45000, heldAmount: 45000,
  });
  cases.push({
    id: 'actualist-compatible-crdt-replays-into-actual-peer',
    description: 'Actualist-shaped CRDT cells for a manual hold and income carryover reset apply to Actual core.',
    uiReachable: true,
    setup: replaySetup,
    before: replayBefore,
    steps: [{
      kind: 'apply-messages',
      cells: replayCells.map(cell => ({
        timestamp: cell.timestamp.toString(),
        dataset: cell.dataset,
        row: cell.row,
        column: cell.column,
        serializedValue: encodeValue(cell.value),
      })),
      stateAfter: replayAfter,
    }],
  });

  expect(cases.length).toBe(${EXPECTED_CASE_COUNT});
  writeFileSync('${temporaryContract}', JSON.stringify({
    schemaVersion: ${SCHEMA_VERSION},
    oracle: { tag: '${EXPECTED_TAG}', commit: '${EXPECTED_COMMIT}', packageVersion: '${EXPECTED_VERSION}' },
    syntheticData: {
      only: true,
      accountIDs: ['checking'],
      categoryIDs: ['salary', 'groceries'],
      months,
    },
    cases,
  }, null, 2) + '\n');
});
`;

let contractData;
try {
  mkdirSync(temporaryDataDirectory, { recursive: true });
  writeFileSync(runnerPath, runner);
  run('node', [
    '.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/core',
    'vitest', '--run', runnerRelative.replace('packages/loot-core/', ''),
  ], checkout, { ...process.env, ACTUAL_DATA_DIR: temporaryDataDirectory });
  contractData = readFileSync(temporaryContract);
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(temporaryContract, { force: true });
  rmSync(temporaryDataDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');

const contract = JSON.parse(contractData.toString('utf8'));
if (!Array.isArray(contract.cases) || contract.cases.length !== EXPECTED_CASE_COUNT) {
  throw new Error(`Oracle did not produce ${EXPECTED_CASE_COUNT} reviewed hold cases`);
}

// Oracle cases Actualist does not replay. Each reason is a coverage fact, not a divergence.
const oracleOnly = [
  {
    id: 'hold-handler-replaces-automatic-income-hold-when-called-directly',
    reason:
      "not reachable from either app's UI; Actualist refuses at the API (disable the automatic hold first) while Actual replaces the hold (README difference 2).",
  },
  {
    id: 'hold-in-tracking-budget-is-not-offered',
    reason:
      "not reachable from either app's UI; Actualist refuses at the API as an unsupported action while Actual writes reflect_budgets (README difference 4).",
  },
];
const caseIDs = contract.cases.map(testCase => testCase.id);
const oracleOnlyIDs = oracleOnly.map(entry => entry.id);
if (
  new Set(caseIDs).size !== caseIDs.length ||
  new Set(oracleOnlyIDs).size !== oracleOnlyIDs.length ||
  oracleOnly.some(entry => !caseIDs.includes(entry.id) || entry.reason.trim() === '')
) {
  throw new Error('Hold oracle-only entries are invalid');
}

// Manifest paths name the pinned fixture location, never the temporary --check directory.
const fixtureDirectory = pinnedFixtureDirectory('Holds');
const logicalPath = name => relative(repositoryRoot, join(fixtureDirectory, name));
mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, contractName), contractData);

const manifestText = JSON.stringify({
  schemaVersion: SCHEMA_VERSION,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/hold-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: null,
  amountUnits: 'integer minor units',
  execution: 'Actual core handlers through runHandler and applyMessages with offline CRDT persistence',
  scope: 'synthetic local SQLite and CRDT replay only; no live server roundtrip',
  caseCount: contract.cases.length,
  sourceFiles: Object.entries(expectedSourceHashes).map(([path, expectedHash]) => ({
    path,
    sha256: expectedHash,
  })),
  fixtures: [{
    path: logicalPath(contractName),
    sha256: sha256(contractData),
    caseCount: contract.cases.length,
    caseIDs,
  }],
  oracleOnly,
  privacy: {
    syntheticOnly: true,
    containsServerCredentials: false,
    containsPersonalFinancialData: false,
  },
}, null, 2) + '\n';
writeFileSync(join(outputRoot, manifestName), manifestText);

if (checking) {
  const failures = compareWithCommitted(fixtureDirectory, outputRoot, [contractName, manifestName]);
  rmSync(outputRoot, { recursive: true, force: true });
  if (failures.length > 0) {
    for (const failure of failures) console.error(`hold parity drift: ${failure}`);
    process.exit(1);
  }
  console.log(`Hold parity fixtures match a fresh generation (${contract.cases.length} cases).`);
} else {
  console.log(`Generated hold parity fixture (${oraclePin.tag}, ${contract.cases.length} cases).`);
}
