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
const helperPath = join(repositoryRoot, 'scripts/parity/lib/oracle-pin.mjs');
const EXPECTED_TAG = oraclePin.tag;
const EXPECTED_COMMIT = oraclePin.commit;
const EXPECTED_VERSION = oraclePin.packageVersion;
const SCHEMA_VERSION = 1;
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
const temporaryDatabase = join(checkout, '.actualist-hold-baseline.sqlite');
const temporaryDataDirectory = join(checkout, '.actualist-hold-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const runner = String.raw`// @ts-strict-ignore
import { writeFileSync } from 'node:fs';
import { Timestamp } from '@actual-app/crdt';
import { expect, test } from 'vitest';

import * as sqlite from '#platform/server/sqlite';
import * as actions from '#server/budget/actions';
import * as budget from '#server/budget/base';
import * as db from '#server/db';
import { handlers } from '#server/main';
import { runHandler } from '#server/mutators';
import * as sheet from '#server/sheet';
import { applyMessages, setSyncingMode } from '#server/sync';
import * as monthUtils from '#shared/months';

type Cell = {
  timestamp: string;
  dataset: string;
  row: string;
  column: string;
  serializedValue: string;
};

const months = ['2026-06', '2026-07', '2026-08', '2027-01', '2027-02'];
const cases: Array<{ id: string; value: unknown }> = [];

async function resetDatabase() {
  if (sheet.get()) {
    await sheet.waitOnSpreadsheet();
    sheet.unloadSpreadsheet();
  }
  setSyncingMode('disabled');
  await global.emptyDatabase()();
}

async function setupBudget({
  incomeAmount = 200_000,
  expenseBudget = 50_000,
  manualBuffer = 0,
  julyCarryover = false,
  augustCarryover = false,
  augustIncome = 0,
} = {}) {
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
  await db.insertTransaction({
    id: 'income-july', account: 'checking', date: '2026-07-01',
    amount: incomeAmount, category: 'salary', cleared: true,
  });
  if (augustIncome !== 0) {
    await db.insertTransaction({
      id: 'income-august', account: 'checking', date: '2026-08-01',
      amount: augustIncome, category: 'salary', cleared: true,
    });
  }
  if (expenseBudget !== 0) {
    await db.insert('zero_budgets', {
      id: '202607-groceries', month: 202607, category: 'groceries',
      amount: expenseBudget, carryover: 0,
    });
  }
  if (julyCarryover) {
    await db.insert('zero_budgets', {
      id: '202607-salary', month: 202607, category: 'salary', amount: 0, carryover: 1,
    });
  }
  if (augustCarryover) {
    await db.insert('zero_budgets', {
      id: '202608-salary', month: 202608, category: 'salary', amount: 0, carryover: 1,
    });
  }
  if (manualBuffer !== 0) {
    await db.insert('zero_budget_months', { id: '2026-07', buffered: manualBuffer });
  }

  await sheet.loadSpreadsheet(db);
  await budget.createBudget(months);
  await sheet.waitOnSpreadsheet();
  db.runQuery('DELETE FROM messages_crdt');
  setSyncingMode('offline');
}

async function state(month: string) {
  const sheetName = monthUtils.sheetForMonth(month);
  return {
    month,
    toBudget: await actions.getSheetValue(sheetName, 'to-budget'),
    manualHeldAmount: await actions.getSheetValue(sheetName, 'buffered'),
    automaticHeldAmount: await actions.getSheetValue(sheetName, 'buffered-auto'),
    heldAmount: await actions.getSheetValue(sheetName, 'buffered-selected'),
  };
}

function lastMessageID() {
  return db.firstSync<{ id: number }>(
    'SELECT COALESCE(MAX(id), 0) AS id FROM messages_crdt',
  )?.id ?? 0;
}

async function cellsAfter(id: number): Promise<Cell[]> {
  const rows = await db.all<{
    timestamp: string; dataset: string; row: string; column: string; value: string;
  }>('SELECT timestamp, dataset, row, column, value FROM messages_crdt WHERE id > ? ORDER BY id', [id]);
  return rows.map(row => ({
    timestamp: row.timestamp,
    dataset: row.dataset,
    row: row.row,
    column: row.column,
    serializedValue: row.value,
  }));
}

async function runAction(name: string, args: Record<string, unknown>) {
  const beforeID = lastMessageID();
  const result = await runHandler(handlers[name], args, { name });
  await sheet.waitOnSpreadsheet();
  return { result, cells: await cellsAfter(beforeID) };
}

async function pwaHold(month: string, amount: number) {
  const before = await state(month);
  // ToBudgetMenu dispatches this reset when the Hold flow is opened, while the
  // Hold form later invokes the hold handler with the submitted amount.
  const reset = await runAction('budget/reset-income-carryover', { month });
  const hold = await runAction('budget/hold-for-next-month', { month, amount });
  return {
    requestedAmount: amount,
    before,
    actions: [
      { name: 'budget/reset-income-carryover', ...reset },
      { name: 'budget/hold-for-next-month', ...hold },
    ],
    cells: [...reset.cells, ...hold.cells],
    after: await state(month),
  };
}

test('Actual ${EXPECTED_VERSION} hold contract', async () => {
  await setupBudget();
  const baseline = await state('2026-07');
  expect(baseline).toEqual({
    month: '2026-07', toBudget: 150_000, manualHeldAmount: 0,
    automaticHeldAmount: 0, heldAmount: 0,
  });
  const exported = await sqlite.exportDatabase(db.getDatabase());
  writeFileSync(
    '${temporaryDatabase}',
    typeof exported === 'string' ? Buffer.from(exported, 'binary') : exported,
  );

  const partial = await pwaHold('2026-07', 40_000);
  const repeated = await pwaHold('2026-07', 20_000);
  expect(partial.after).toMatchObject({ toBudget: 110_000, heldAmount: 40_000 });
  expect(repeated.after).toMatchObject({ toBudget: 90_000, heldAmount: 60_000 });
  cases.push({ id: 'partial-and-repeated-hold', value: { steps: [partial, repeated] } });

  await setupBudget();
  const all = await pwaHold('2026-07', 150_000);
  expect(all.after).toMatchObject({ toBudget: 0, heldAmount: 150_000 });
  cases.push({ id: 'all-available-hold', value: all });

  await setupBudget();
  const clamped = await pwaHold('2026-07', 200_000);
  expect(clamped.after).toMatchObject({ toBudget: 0, heldAmount: 150_000 });
  cases.push({ id: 'oversized-hold-clamps-to-available', value: clamped });

  await setupBudget({
    incomeAmount: 100_000, expenseBudget: 0, manualBuffer: 20_000,
    julyCarryover: true, augustCarryover: true, augustIncome: 25_000,
  });
  const mixedBefore = await state('2026-07');
  const resetManual = await runAction('budget/reset-hold', { month: '2026-07' });
  const afterManualReset = await state('2026-07');
  const resetAutomatic = await runAction('budget/reset-income-carryover', { month: '2026-07' });
  const afterAutomaticReset = await state('2026-07');
  const futureAfterReset = await state('2026-08');
  expect(mixedBefore).toMatchObject({ manualHeldAmount: 20_000, automaticHeldAmount: 100_000, heldAmount: 20_000 });
  expect(afterManualReset).toMatchObject({ manualHeldAmount: 0, automaticHeldAmount: 100_000, heldAmount: 100_000 });
  expect(afterAutomaticReset).toMatchObject({ manualHeldAmount: 0, automaticHeldAmount: 0, heldAmount: 0 });
  expect(futureAfterReset).toMatchObject({ automaticHeldAmount: 25_000, heldAmount: 25_000 });
  cases.push({
    id: 'manual-reset-reveals-auto-then-selected-auto-reset-preserves-future',
    value: {
      before: mixedBefore,
      resetManual: { ...resetManual, after: afterManualReset },
      resetAutomatic: { ...resetAutomatic, after: afterAutomaticReset },
      futureAfterReset,
    },
  });

  await setupBudget();
  const beforeStoredRows = db.firstSync<{ count: number }>(
    "SELECT COUNT(*) AS count FROM zero_budget_months WHERE id = '2027-01'",
  )?.count ?? -1;
  const future = await pwaHold('2027-01', 1_000);
  expect(beforeStoredRows).toBe(0);
  expect(future.after).toMatchObject({ manualHeldAmount: 1_000, heldAmount: 1_000 });
  cases.push({ id: 'future-created-sheet-without-stored-month-row', value: { beforeStoredRows, ...future } });

  await setupBudget();
  const actualistCells = [
    {
      timestamp: Timestamp.parse('2026-09-26T12:00:00.000Z-0000-61637475616c6973'),
      dataset: 'zero_budget_months', row: '2026-07', column: 'buffered', value: 45_000,
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
  await applyMessages(actualistCells);
  await sheet.waitOnSpreadsheet();
  const replayAfter = await state('2026-07');
  expect(replayAfter).toMatchObject({ toBudget: 105_000, manualHeldAmount: 45_000, heldAmount: 45_000 });
  cases.push({
    id: 'actualist-compatible-crdt-replays-into-second-actual-peer',
    value: {
      cells: actualistCells.map(cell => ({
        timestamp: cell.timestamp.toString(), dataset: cell.dataset, row: cell.row,
        column: cell.column,
        serializedValue: cell.value === null
          ? '0:'
          : typeof cell.value === 'number'
            ? 'N:' + cell.value
            : 'S:' + cell.value,
      })),
      after: replayAfter,
    },
  });

  const sourceCells = cases.flatMap(entry => {
    const json = JSON.stringify(entry.value);
    return json.includes('serializedValue') ? [entry.id] : [];
  });
  expect(sourceCells.length).toBe(cases.length);
  writeFileSync('${temporaryContract}', JSON.stringify({
    schemaVersion: ${SCHEMA_VERSION},
    oracle: { tag: '${EXPECTED_TAG}', commit: '${EXPECTED_COMMIT}', packageVersion: '${EXPECTED_VERSION}' },
    syntheticData: {
      only: true,
      accountIDs: ['checking'],
      categoryIDs: ['salary', 'groceries'],
      months,
    },
    baseline: {
      databaseFile: 'hold-baseline.sqlite',
      month: '2026-07',
      state: baseline,
    },
    cases,
  }, null, 2) + '\n');
});
`;

let contractData;
let databaseData;
try {
  mkdirSync(temporaryDataDirectory, { recursive: true });
  writeFileSync(runnerPath, runner);
  run('node', [
    '.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/core',
    'vitest', '--run', runnerRelative.replace('packages/loot-core/', ''),
  ], checkout, { ...process.env, ACTUAL_DATA_DIR: temporaryDataDirectory });
  contractData = readFileSync(temporaryContract);
  databaseData = readFileSync(temporaryDatabase);
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(temporaryContract, { force: true });
  rmSync(temporaryDatabase, { force: true });
  rmSync(temporaryDataDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');

const contract = JSON.parse(contractData.toString('utf8'));
if (!Array.isArray(contract.cases) || contract.cases.length !== 6) {
  throw new Error('Oracle did not produce six reviewed hold cases');
}
if (databaseData.subarray(0, 16).toString('utf8') !== 'SQLite format 3\u0000') {
  throw new Error('Oracle did not produce a SQLite baseline database');
}

// Manifest paths name the pinned fixture location, never the temporary --check directory.
const fixtureDirectory = pinnedFixtureDirectory('Holds');
const logicalPath = name => relative(repositoryRoot, join(fixtureDirectory, name));
const contractName = 'hold-contract.json';
const databaseName = 'hold-baseline.sqlite';
mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, contractName), contractData);
writeFileSync(join(outputRoot, databaseName), databaseData);

const manifestText = JSON.stringify({
  schemaVersion: SCHEMA_VERSION,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/hold-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: [{ path: relative(repositoryRoot, helperPath), sha256: sha256(readFileSync(helperPath)) }],
  seed: null,
  amountUnits: 'integer minor units',
  execution: 'Actual core handlers through runHandler/runMutator with offline CRDT persistence',
  scope: 'synthetic local SQLite and CRDT replay only; no live server roundtrip',
  sourceFiles: Object.entries(expectedSourceHashes).map(([path, expectedHash]) => ({
    path,
    sha256: expectedHash,
  })),
  artifacts: [
    {
      path: logicalPath(contractName),
      sha256: sha256(contractData),
      caseCount: contract.cases.length,
    },
    {
      path: logicalPath(databaseName),
      sha256: sha256(databaseData),
    },
  ],
  privacy: {
    syntheticOnly: true,
    containsServerCredentials: false,
    containsPersonalFinancialData: false,
  },
}, null, 2) + '\n';
writeFileSync(join(outputRoot, 'hold-manifest.json'), manifestText);

if (checking) {
  const failures = compareWithCommitted(fixtureDirectory, outputRoot, [contractName, databaseName, 'hold-manifest.json']);
  rmSync(outputRoot, { recursive: true, force: true });
  if (failures.length > 0) {
    for (const failure of failures) console.error(`hold parity drift: ${failure}`);
    process.exit(1);
  }
  console.log(`Hold parity fixtures match a fresh generation (${contract.cases.length} cases).`);
} else {
  console.log(`Generated hold parity fixture (${oraclePin.tag}, ${contract.cases.length} cases).`);
}
