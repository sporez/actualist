#!/usr/bin/env node

// Checks the committed BankSync fixture without an oracle: manifest pins, helper
// hashes, plan identity, recorded setup and rule rows, run shape, and the
// author's structural expectations. Regeneration is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';
import {
  buildPlan,
  expectationFailures,
  oracleOnlyEntries,
  SEED,
  TIME_ZONE,
  TODAY,
} from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('BankSync');
const SCHEMA_VERSION = 1;
const contractName = 'bank-sync-contract.json';
const manifestName = 'bank-sync-manifest.json';
const helperPaths = [
  'scripts/bank-sync-parity/cases.mjs',
  'scripts/bank-sync-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const INPUT_TABLES = ['rules', 'schedules', 'transactions'];
const AFTER_TABLES = ['accounts', 'payees', 'transactions', 'rules'];

const failures = [];
const note = message => failures.push(message);

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function sameJSON(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

const plan = buildPlan();
if (!sameJSON(plan, buildPlan())) note('buildPlan() is not deterministic for a fixed seed');
if (new Set(plan.cases.map(planCase => planCase.id)).size !== plan.cases.length) {
  note('plan case IDs are not unique');
}

const contractBytes = readFileSync(join(fixtureDirectory, contractName));
const contract = JSON.parse(contractBytes.toString('utf8'));
const manifest = JSON.parse(readFileSync(join(fixtureDirectory, manifestName), 'utf8'));
const generatedCount = plan.cases.filter(planCase => planCase.source === 'generated').length;
const namedCount = plan.cases.length - generatedCount;

// Manifest pins.
if (manifest.schemaVersion !== SCHEMA_VERSION) note(`manifest schemaVersion is ${manifest.schemaVersion}`);
if (!sameJSON(manifest.actual, {
  tag: oraclePin.tag,
  commit: oraclePin.commit,
  packageVersion: oraclePin.packageVersion,
})) {
  note('manifest actual pin does not match config/parity/oracle-pin.json');
}
const generatorHash = sha256(readFileSync(join(dirname(scriptPath), 'generate.mjs')));
if (manifest.generator?.sha256 !== generatorHash) note('generate.mjs changed since the manifest was written');
for (const helper of manifest.helpers ?? []) {
  const actual = sha256(readFileSync(join(repositoryRoot, helper.path)));
  if (actual !== helper.sha256) note(`helper ${helper.path} changed since the manifest was written`);
}
if (!sameJSON(helperPaths, (manifest.helpers ?? []).map(helper => helper.path))) {
  note('manifest helper list does not match verify.mjs helper list');
}
if (manifest.seed !== SEED) note(`manifest seed ${manifest.seed} does not match ${SEED}`);
if (manifest.today !== TODAY) note(`manifest today ${manifest.today} does not match ${TODAY}`);
if (manifest.timeZone !== TIME_ZONE) note(`manifest timeZone ${manifest.timeZone} does not match ${TIME_ZONE}`);
if (manifest.caseCount !== plan.cases.length) note(`manifest caseCount ${manifest.caseCount}, plan ${plan.cases.length}`);
if (manifest.namedCaseCount !== namedCount) note(`manifest namedCaseCount ${manifest.namedCaseCount}, plan ${namedCount}`);
if (manifest.generatedCaseCount !== generatedCount) {
  note(`manifest generatedCaseCount ${manifest.generatedCaseCount}, plan ${generatedCount}`);
}
for (const source of manifest.sourceFiles ?? []) {
  if (!/^[0-9a-f]{64}$/.test(source.sha256)) note(`source hash for ${source.path} is malformed`);
}
if (!sameJSON(manifest.oracleOnly, oracleOnlyEntries(plan))) note('manifest oracleOnly list does not match the plan');

const fixture = manifest.fixtures?.[0];
const expectedFixturePath = relative(repositoryRoot, join(fixtureDirectory, contractName));
if (manifest.fixtures?.length !== 1 || fixture.path !== expectedFixturePath) {
  note(`manifest fixture entry is not ${expectedFixturePath}`);
}
if (fixture?.sha256 !== sha256(contractBytes)) note('contract bytes do not match the manifest fixture hash');
if (!sameJSON(fixture?.caseIDs, plan.cases.map(planCase => planCase.id))) {
  note('manifest caseIDs do not match the plan in order');
}
if (fixture?.caseCount !== plan.cases.length) note('manifest fixture caseCount does not match the plan');

// Contract header.
if (contract.schemaVersion !== SCHEMA_VERSION) note(`contract schemaVersion is ${contract.schemaVersion}`);
if (!sameJSON(contract.oracle, {
  tag: oraclePin.tag,
  commit: oraclePin.commit,
  packageVersion: oraclePin.packageVersion,
})) {
  note('contract oracle pin does not match config/parity/oracle-pin.json');
}
if (!sameJSON(contract.environment, { today: TODAY, timeZone: TIME_ZONE })) {
  note('contract environment does not match the plan');
}

if (!sameJSON(contract.world, plan.world)) note('contract world does not match the plan');
for (const table of ['accounts', 'category_groups', 'categories', 'category_mapping', 'payees', 'payee_mapping']) {
  if (!Array.isArray(contract.worldTables?.[table])) note(`contract worldTables.${table} is missing`);
}
for (const [table, planned] of [['accounts', plan.world.accounts], ['categories', plan.world.categories], ['payees', plan.world.payees]]) {
  const have = (contract.worldTables?.[table] ?? []).map(row => row.id);
  for (const row of planned) if (!have.includes(row.id)) note(`contract worldTables.${table} lacks ${row.id}`);
}

// Case-by-case checks against the plan.
if (!Array.isArray(contract.cases) || contract.cases.length !== plan.cases.length) {
  note(`contract has ${contract.cases?.length} cases, plan has ${plan.cases.length}`);
} else {
  contract.cases.forEach((record, index) => {
    const planCase = plan.cases[index];
    const where = planCase.id;
    if (record.id !== planCase.id) {
      note(`case ${index} is ${record.id}, plan says ${planCase.id}`);
      return;
    }
    for (const field of ['source', 'description', 'seed', 'oracleOnly', 'tags', 'setup', 'rules', 'call']) {
      if (!sameJSON(record[field], planCase[field])) note(`${where}: ${field} differs from the plan`);
    }
    // The dumped tables are the starter-schema input; they must agree with the setup.
    for (const table of INPUT_TABLES) {
      if (!Array.isArray(record.input?.[table])) note(`${where}: input table ${table} is missing`);
    }
    for (const table of AFTER_TABLES) {
      if (!Array.isArray(record.after?.[table])) note(`${where}: after table ${table} is missing`);
    }
    const ids = table => (record.input?.[table] ?? []).map(row => row.id).sort();
    for (const [table, planned] of [
      ['transactions', planCase.setup.transactions],
    ]) {
      const missing = planned.map(row => row.id).filter(id => !ids(table).includes(id));
      if (missing.length > 0) note(`${where}: input.${table} lacks ${missing.join(', ')}`);
    }
    const ruleRowIDs = ids('rules');
    const scheduleRuleIDs = planCase.setup.schedules.map(schedule => schedule.ruleID);
    for (const planned of [...planCase.rules.map(entry => entry.id), ...scheduleRuleIDs]) {
      if (!ruleRowIDs.includes(planned)) note(`${where}: input.rules lacks ${planned}`);
    }
    // Every deleted-in-setup row is a tombstone in the input dump.
    for (const planned of planCase.setup.transactions.filter(transaction => transaction.tombstone)) {
      const dumped = (record.input?.transactions ?? []).find(transaction => transaction.id === planned.id);
      if (dumped && Number(dumped.tombstone) !== 1) note(`${where}: ${planned.id} is not a tombstone in the input dump`);
    }
    if (record.error === null && record.call.kind !== 'simplefin') {
      for (const field of ['added', 'updated', 'updatedPreview']) {
        if (!Array.isArray(record.result?.[field])) note(`${where}: result.${field} is missing`);
      }
    }
    for (const failure of expectationFailures(record, planCase)) note(`${where}: ${failure}`);
  });
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`bank sync verify: ${failure}`);
  console.error(`bank sync verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(
  `Bank sync parity fixture verified: ${plan.cases.length} cases (${namedCount} named, ${generatedCount} generated), ` +
    `${oracleOnlyEntries(plan).length} oracle-only, seed ${SEED}.`,
);
