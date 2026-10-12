#!/usr/bin/env node

// Checks the committed Transactions fixture without an oracle: manifest pins,
// helper hashes, matrix identity, and the recorded message shape.
// Regeneration is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('Transactions');
const SCHEMA_VERSION = 1;
const contractName = 'transactions-contract.json';
const manifestName = 'transactions-manifest.json';
const helperPaths = [
  'scripts/transactions-parity/matrix.json',
  'scripts/transactions-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
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
if (new Set(matrix.cases.map(item => item.id)).size !== matrix.cases.length) note('matrix case IDs are not unique');

const contractBytes = readFileSync(join(fixtureDirectory, contractName));
const contract = JSON.parse(contractBytes.toString('utf8'));
const manifest = JSON.parse(readFileSync(join(fixtureDirectory, manifestName), 'utf8'));

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
if (manifest.amountUnits !== 'integer minor units') note('amount units are not explicit');
if (manifest.caseCount !== matrix.cases.length) note(`manifest caseCount is ${manifest.caseCount}`);
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

if (contract.schemaVersion !== SCHEMA_VERSION) note(`contract schemaVersion is ${contract.schemaVersion}`);
if (contract.environment?.timeZone !== 'UTC') note('contract environment is not UTC');
if (!Array.isArray(contract.cases) || contract.cases.length !== matrix.cases.length) {
  note(`contract has ${contract.cases?.length} cases, matrix has ${matrix.cases.length}`);
} else {
  contract.cases.forEach((record, index) => {
    const planned = matrix.cases[index];
    if (record.id !== planned.id) return note(`case ${index} is ${record.id}, matrix says ${planned.id}`);
    if (record.kind !== planned.kind) note(`${planned.id}: kind differs from the matrix`);
    if (!Array.isArray(record.expected) || record.expected.length === 0) return note(`${planned.id}: no expected messages`);
    for (const message of record.expected) {
      const complete = ['dataset', 'row', 'column'].every(key => typeof message[key] === 'string' && message[key] !== '')
        && 'value' in message
        && (message.value === null || ['string', 'number'].includes(typeof message.value));
      if (!complete) note(`${planned.id}: malformed message ${JSON.stringify(message)}`);
    }
  });
}
if (/"id\d+"/.test(contractBytes.toString('utf8'))) note('un-normalized minted id in the contract');

if (failures.length > 0) {
  for (const failure of failures) console.error(`transactions verify: ${failure}`);
  console.error(`transactions verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(`Transactions parity fixture verified: ${matrix.cases.length} cases, ${manifest.oracleOnly.length} oracle-only.`);
