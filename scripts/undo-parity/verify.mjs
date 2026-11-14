#!/usr/bin/env node

// Checks the committed Undo fixture without an oracle: manifest pins, helper and generator
// hashes, case identity against cases.mjs, the recorded shape of every case, and that the
// Payees undo lists partition the Payees fixture. Regeneration is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';
import { CASES, PAYEE_UNDO_OMITTED, PAYEE_UNDO_REPLAYED, TIME_ZONE } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('Undo');
const SCHEMA_VERSION = 1;
const contractName = 'undo-contract.json';
const manifestName = 'undo-manifest.json';
const helperPaths = [
  'scripts/undo-parity/cases.mjs',
  'scripts/undo-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const WORLD_TABLES = [
  'accounts', 'category_groups', 'categories', 'category_mapping', 'payees', 'payee_mapping',
  'transactions', 'zero_budgets', 'zero_budget_months',
];
const ROW_TABLES = ['transactions', 'zero_budgets', 'payees', 'payee_mapping'];
const ROW_CHECKPOINTS = ['rowsBefore', 'rowsAfterAction', 'rowsAfterUndo'];
const failures = [];
const note = message => failures.push(message);

const sha256 = data => createHash('sha256').update(data).digest('hex');
const sameJSON = (left, right) => JSON.stringify(left) === JSON.stringify(right);

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

// The Payees undo lists partition the Payees fixture's cases.
const payeeManifest = JSON.parse(readFileSync(join(pinnedFixtureDirectory('Payees'), 'payees-manifest.json'), 'utf8'));
const payeeCaseIDs = payeeManifest.fixtures?.[0]?.caseIDs ?? [];
const payeeOmittedIDs = PAYEE_UNDO_OMITTED.map(entry => entry.id);
if (!sameJSON(manifest.payeeUndo, { fixture: 'Payees', replayed: PAYEE_UNDO_REPLAYED, oracleOnly: PAYEE_UNDO_OMITTED })) {
  note('manifest payeeUndo does not match cases.mjs');
}
if (!sameJSON([...PAYEE_UNDO_REPLAYED, ...payeeOmittedIDs].sort(), [...payeeCaseIDs].sort())) {
  note('payee undo replayed and omitted ids do not partition the Payees fixture case ids');
}
if (PAYEE_UNDO_OMITTED.some(entry => !entry.reason?.trim())) note('a payee undo omission has no reason');
const payeeContract = JSON.parse(readFileSync(join(pinnedFixtureDirectory('Payees'), 'payees-contract.json'), 'utf8'));
for (const record of payeeContract.cases) {
  if (!PAYEE_UNDO_REPLAYED.includes(record.id)) continue;
  if (record.undo === null || record.undo.error !== null || record.handlerCall === null) {
    note(`payee case ${record.id} is replayed but Actual recorded no clean undo`);
  }
}

// Contract header and shared world.
if (contract.schemaVersion !== SCHEMA_VERSION) note(`contract schemaVersion is ${contract.schemaVersion}`);
if (contract.environment?.timeZone !== TIME_ZONE) note('contract environment time zone differs');
for (const table of WORLD_TABLES) {
  if (!Array.isArray(contract.world?.[table])) note(`world.${table} is missing`);
}

// Case-by-case shape.
const isList = value => Array.isArray(value);
const messageShape = message => ['dataset', 'row', 'column'].every(key => typeof message?.[key] === 'string') && 'value' in message;
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
    if (!isList(record.handlerCall) || record.handlerCall.length === 0
        || !record.handlerCall.every(call => typeof call?.method === 'string')) {
      note(`${where}: handlerCall is malformed`);
    }
    if (!isList(record.messages) || !record.messages.every(messageShape)) note(`${where}: messages are malformed`);
    if (!isList(record.writes) || !record.writes.every(messageShape)) note(`${where}: writes are malformed`);
    if (!isList(record.undoMessages) || !record.undoMessages.every(messageShape)) note(`${where}: undoMessages are malformed`);
    if (!isList(record.undoWrites) || !record.undoWrites.every(messageShape)) note(`${where}: undoWrites are malformed`);
    if (!Number.isInteger(record.undoCalls) || record.undoCalls < 1) note(`${where}: undoCalls is missing`);
    for (const checkpoint of ROW_CHECKPOINTS) {
      for (const table of ROW_TABLES) {
        if (!isList(record[checkpoint]?.[table])) note(`${where}: ${checkpoint}.${table} is missing`);
      }
    }
  });
}
if (/"id\d+"/.test(contractBytes.toString('utf8'))) note('un-normalized minted id in the contract');

if (failures.length > 0) {
  for (const failure of failures) console.error(`undo verify: ${failure}`);
  console.error(`undo verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(`Undo parity fixture verified: ${CASES.length} cases, ${PAYEE_UNDO_REPLAYED.length} payee undos replayed, ${PAYEE_UNDO_OMITTED.length} omitted.`);
