#!/usr/bin/env node

// Checks the committed Reports fixture without an oracle: manifest pins, helper and generator
// hashes, case identity against cases.mjs, and the recorded shape of every case. Regeneration is
// generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';
import { CASES, TIME_ZONE, TODAY } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('Reports');
const SCHEMA_VERSION = 1;
const contractName = 'reports-contract.json';
const manifestName = 'reports-manifest.json';
const helperPaths = [
  'scripts/report-parity/cases.mjs',
  'scripts/report-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const WORLD_TABLES = [
  'accounts', 'payees', 'payee_mapping', 'category_groups', 'categories', 'category_mapping',
  'transactions', 'zero_budgets', 'reflect_budgets', 'preferences',
];
const failures = [];
const note = message => failures.push(message);

const sha256 = data => createHash('sha256').update(data).digest('hex');
const sameJSON = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const isList = value => Array.isArray(value);
const isNumber = value => typeof value === 'number' && Number.isFinite(value);
const isNumberOrNull = value => value === null || isNumber(value);

const contractBytes = readFileSync(join(fixtureDirectory, contractName));
const contract = JSON.parse(contractBytes.toString('utf8'));
const manifest = JSON.parse(readFileSync(join(fixtureDirectory, manifestName), 'utf8'));

// Manifest pins.
if (manifest.schemaVersion !== SCHEMA_VERSION) note(`manifest schemaVersion is ${manifest.schemaVersion}`);
const pin = { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion };
if (!sameJSON(manifest.actual, pin)) note('manifest actual pin does not match config/parity/oracle-pin.json');
if (!sameJSON(contract.oracle, pin)) note('contract oracle pin does not match config/parity/oracle-pin.json');
if (manifest.generator?.sha256 !== sha256(readFileSync(join(dirname(scriptPath), 'generate.mjs')))) {
  note('generate.mjs changed since the manifest was written');
}
for (const helper of manifest.helpers ?? []) {
  if (sha256(readFileSync(join(repositoryRoot, helper.path))) !== helper.sha256) {
    note(`helper ${helper.path} changed since the manifest was written`);
  }
}
if (!sameJSON(helperPaths, (manifest.helpers ?? []).map(helper => helper.path))) {
  note('manifest helper list does not match verify.mjs helper list');
}
if (manifest.seed !== null) note('manifest seed must be null for this deterministic harness');
if (manifest.timeZone !== TIME_ZONE) note(`manifest timeZone is ${manifest.timeZone}`);
if (manifest.caseCount !== CASES.length) note(`manifest caseCount is ${manifest.caseCount}, cases.mjs has ${CASES.length}`);
if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length === 0) note('manifest has no oracle source hashes');
for (const source of manifest.sourceFiles ?? []) {
  if (!/^[0-9a-f]{64}$/.test(source.sha256)) note(`source hash for ${source.path} is malformed`);
}
if (!sameJSON(manifest.oracleOnly, [])) note('manifest oracleOnly must be empty: every case is replayed');
if (manifest.privacy?.syntheticOnly !== true
    || manifest.privacy?.containsServerCredentials !== false
    || manifest.privacy?.containsPersonalFinancialData !== false) {
  note('manifest privacy block is not synthetic-only');
}

const fixture = manifest.fixtures?.[0];
const expectedFixturePath = relative(repositoryRoot, join(fixtureDirectory, contractName));
if (manifest.fixtures?.length !== 1 || fixture.path !== expectedFixturePath) {
  note(`manifest fixture entry is not ${expectedFixturePath}`);
}
if (fixture?.sha256 !== sha256(contractBytes)) note('contract bytes do not match the manifest fixture hash');
if (!sameJSON(fixture?.caseIDs, CASES.map(item => item.id))) note('manifest caseIDs do not match cases.mjs in order');
if (fixture?.caseCount !== CASES.length) note('manifest fixture caseCount does not match cases.mjs');
if (new Set(CASES.map(item => item.id)).size !== CASES.length) note('cases.mjs case IDs are not unique');

// Contract header and the two worlds.
if (contract.schemaVersion !== SCHEMA_VERSION) note(`contract schemaVersion is ${contract.schemaVersion}`);
if (contract.environment?.timeZone !== TIME_ZONE) note('contract environment time zone differs');
if (contract.environment?.today !== TODAY) note('contract environment today differs');
for (const world of ['envelope', 'tracking']) {
  for (const table of WORLD_TABLES) {
    if (!isList(contract.worlds?.[world]?.[table])) note(`worlds.${world}.${table} is missing`);
  }
}
const budgetTable = { envelope: 'zero_budgets', tracking: 'reflect_budgets' };
for (const [world, table] of Object.entries(budgetTable)) {
  if (!(contract.worlds?.[world]?.[table]?.length > 0)) note(`worlds.${world}.${table} has no budget rows`);
}

// Case-by-case shape.
function checkNetWorth(where, record) {
  const expected = record.expected;
  if (!isList(expected.accountIDs) || expected.accountIDs.length === 0) note(`${where}: accountIDs missing`);
  if (!isList(expected.points) || expected.points.length === 0) note(`${where}: points missing`);
  for (const point of expected.points ?? []) {
    if (typeof point.period !== 'string' || !isNumber(point.y)) note(`${where}: malformed point`);
    for (const id of expected.accountIDs ?? []) {
      if (!isNumber(point.balances?.[id])) note(`${where}: ${point.period} has no balance for ${id}`);
    }
  }
  if (!isNumber(expected.netWorth) || !isNumber(expected.totalChange)) note(`${where}: totals missing`);
}
function checkCashFlow(where, record) {
  const expected = record.expected;
  if (!isList(expected.periods) || expected.periods.length === 0) note(`${where}: periods missing`);
  for (const period of expected.periods ?? []) {
    if (typeof period.period !== 'string'
        || ![period.income, period.expenses, period.transfers, period.balance].every(isNumber)) {
      note(`${where}: malformed period`);
    }
  }
  for (const key of ['totalIncome', 'totalExpenses', 'totalTransfers', 'totalChange', 'balance']) {
    if (!isNumber(expected[key])) note(`${where}: ${key} missing`);
  }
}
function checkSpending(where, record) {
  const expected = record.expected;
  if (!isList(expected.intervalData) || expected.intervalData.length !== 28) {
    note(`${where}: intervalData must hold 28 buckets`);
  }
  (expected.intervalData ?? []).forEach((row, index) => {
    if (row.day !== index + 1) note(`${where}: bucket ${index + 1} is day ${row.day}`);
    if (!isNumberOrNull(row.compare) || !isNumber(row.compareTo) || !isNumber(row.average) || !isNumber(row.budget)) {
      note(`${where}: malformed bucket ${row.day}`);
    }
  });
  for (const key of ['totalAssets', 'totalDebts', 'totalTotals']) {
    if (!isNumber(expected[key])) note(`${where}: ${key} missing`);
  }
}
function checkCalendar(where, record) {
  const months = record.expected.months;
  if (!isList(months) || months.length !== 3) note(`${where}: three months expected`);
  for (const month of months ?? []) {
    if (!isList(month.data) || month.data.length % 7 !== 0) note(`${where}: ${month.start} is not whole weeks`);
    if (!isNumber(month.totalIncome) || !isNumber(month.totalExpense)) note(`${where}: ${month.start} totals missing`);
  }
}
const checks = {
  'net-worth': checkNetWorth, 'cash-flow': checkCashFlow, spending: checkSpending, calendar: checkCalendar,
};
if (!isList(contract.cases) || contract.cases.length !== CASES.length) {
  note(`contract has ${contract.cases?.length} cases, cases.mjs has ${CASES.length}`);
} else {
  contract.cases.forEach((record, index) => {
    const planned = CASES[index];
    const where = planned.id;
    if (record.id !== planned.id || record.kind !== planned.kind) {
      note(`case ${index} is ${record.id}/${record.kind}, cases.mjs says ${planned.id}/${planned.kind}`);
      return;
    }
    if (!sameJSON(record.input, planned.input)) note(`${where}: input differs from cases.mjs`);
    if (record.world !== (planned.world ?? 'envelope')) note(`${where}: world is ${record.world}`);
    if (record.today !== (planned.input.today ?? TODAY)) note(`${where}: today is ${record.today}`);
    if (typeof record.expected !== 'object' || record.expected === null) {
      note(`${where}: expected is missing`);
      return;
    }
    checks[planned.kind](where, record);
  });
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`report verify: ${failure}`);
  console.error(`report verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(`Report parity fixture verified: ${CASES.length} cases, ${manifest.oracleOnly.length} oracle-only.`);
