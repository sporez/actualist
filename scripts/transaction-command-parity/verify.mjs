#!/usr/bin/env node

// Checks the committed TransactionCommand fixture without an oracle: manifest
// pins, helper hashes, matrix identity, recorded input and outcome shape.
// Regeneration is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('TransactionCommand');
const SCHEMA_VERSION = 1;
const EXPECTED_CASES = 39;
const contractName = 'transaction-command-contract.json';
const manifestName = 'transaction-command-manifest.json';
const helperPaths = [
  'scripts/transaction-command-parity/matrix.json',
  'scripts/transaction-command-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const REFERENCE_TABLES = [
  'accounts', 'categories', 'categoryGroups', 'categoryMappings',
  'payees', 'payeeMappings', 'rules', 'schedules',
];
const failures = [];
const note = message => failures.push(message);

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function sameJSON(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

const matrix = JSON.parse(readFileSync(join(dirname(scriptPath), 'matrix.json'), 'utf8'));
if (matrix.cases.length !== EXPECTED_CASES) note(`matrix has ${matrix.cases.length} cases, expected ${EXPECTED_CASES}`);
if (new Set(matrix.cases.map(item => item.id)).size !== matrix.cases.length) note('matrix case IDs are not unique');

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
  const actual = sha256(readFileSync(join(repositoryRoot, helper.path)));
  if (actual !== helper.sha256) note(`helper ${helper.path} changed since the manifest was written`);
}
if (!sameJSON(helperPaths, (manifest.helpers ?? []).map(helper => helper.path))) {
  note('manifest helper list does not match verify.mjs helper list');
}
if (manifest.seed !== null) note('manifest seed must be null for this deterministic harness');
if (manifest.amountUnits !== 'integer minor units') note('amount units are not explicit');
if (manifest.caseCount !== EXPECTED_CASES) note(`manifest caseCount is ${manifest.caseCount}`);
if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length === 0) note('manifest has no oracle source hashes');
for (const source of manifest.sourceFiles ?? []) {
  if (!/^[0-9a-f]{64}$/.test(source.sha256)) note(`source hash for ${source.path} is malformed`);
}
if (!sameJSON(manifest.oracleOnly, [])) note('manifest oracleOnly must be empty: every case is replayed');

const fixture = manifest.fixtures?.[0];
const expectedFixturePath = relative(repositoryRoot, join(fixtureDirectory, contractName));
if (manifest.fixtures?.length !== 1 || fixture.path !== expectedFixturePath) {
  note(`manifest fixture entry is not ${expectedFixturePath}`);
}
if (fixture?.sha256 !== sha256(contractBytes)) note('contract bytes do not match the manifest fixture hash');
if (!sameJSON(fixture?.caseIDs, matrix.cases.map(item => item.id))) note('manifest caseIDs do not match the matrix in order');
if (fixture?.caseCount !== matrix.cases.length) note('manifest fixture caseCount does not match the matrix');

// Contract header and shared reference rows.
if (contract.schemaVersion !== SCHEMA_VERSION) note(`contract schemaVersion is ${contract.schemaVersion}`);
if (contract.environment?.timeZone !== 'UTC') note('contract environment is not UTC');
for (const table of REFERENCE_TABLES) {
  if (!Array.isArray(contract.referenceData?.[table])) note(`referenceData.${table} is missing`);
}

// Case-by-case checks against the matrix.
const isTable = value => Array.isArray(value);
if (!Array.isArray(contract.cases) || contract.cases.length !== matrix.cases.length) {
  note(`contract has ${contract.cases?.length} cases, matrix has ${matrix.cases.length}`);
} else {
  contract.cases.forEach((record, index) => {
    const planned = matrix.cases[index];
    const where = planned.id;
    if (record.id !== planned.id) {
      note(`case ${index} is ${record.id}, matrix says ${planned.id}`);
      return;
    }
    for (const field of ['gate', 'graph', 'selected']) {
      if (!sameJSON(record[field], planned[field])) note(`${where}: ${field} differs from the matrix`);
    }
    const inputIDs = (record.input?.transactions ?? []).map(row => row.id);
    if (!isTable(record.input?.transactions)) note(`${where}: seeded input rows are missing`);
    for (const id of record.selected) {
      if (!inputIDs.includes(id)) note(`${where}: selected row ${id} is not in the seeded input`);
    }
    for (const field of [record.afterHandler?.transactions, record.undo?.transactions]) {
      if (!isTable(field)) note(`${where}: a row checkpoint is missing`);
    }
    if (!isTable(record.forwardMessages)) note(`${where}: forward messages are missing`);
    if (!isTable(record.undo?.messages)) note(`${where}: undo messages are missing`);
    if (record.handler?.outcome === 'ok') {
      if (record.handler.result === undefined || record.handler.error !== undefined) note(`${where}: malformed ok outcome`);
      if (planned.gate.startsWith('D') && !isTable(record.handler.result?.added)) {
        note(`${where}: duplicate result lacks the added rows`);
      }
      if (planned.gate.startsWith('M') && !record.selected.includes(record.handler.result)) {
        note(`${where}: merge result is not one of the selected ids`);
      }
    } else if (record.handler?.outcome === 'refused') {
      if (typeof record.handler.error !== 'string' || record.handler.error === '') note(`${where}: refusal lacks its text`);
    } else {
      note(`${where}: handler outcome is ${record.handler?.outcome}`);
    }
    if (!['ok', 'error'].includes(record.undo?.outcome)) note(`${where}: undo outcome is ${record.undo?.outcome}`);
  });
  const learning = contract.cases.find(item => item.id === 'D2-duplicate-does-not-request-learning');
  if (learning?.rules?.learnCategoriesRequested !== false
      || !sameJSON(learning.rules.before, learning.rules.afterHandler)
      || !sameJSON(learning.rules.before, learning.rules.afterUndo)) {
    note('D2-duplicate-does-not-request-learning must record unchanged rules through handler and undo');
  }
}
// Actual-minted ids must not survive normalization.
if (/"id\d+"/.test(contractBytes.toString('utf8'))) note('un-normalized minted id in the contract');

if (failures.length > 0) {
  for (const failure of failures) console.error(`transaction command verify: ${failure}`);
  console.error(`transaction command verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(`Transaction command parity fixture verified: ${matrix.cases.length} cases, ${manifest.oracleOnly.length} oracle-only.`);
