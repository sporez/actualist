#!/usr/bin/env node

// Checks the committed TransactionQuery fixture and Splits/grouped-query-cases.json
// without an oracle: manifest pins, helper hashes, plan identity, record shape,
// the grouped-query projection, and the plan's structural checks. Regeneration
// is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';
import {
  buildPlan,
  expectationFailures,
  FAMILIES,
  groupedQueryProjection,
  oracleOnlyEntries,
  ORACLE_ONLY_FIELDS,
  SEED,
  TIME_ZONE,
  WORLDS,
} from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('TransactionQuery');
const groupedDirectory = pinnedFixtureDirectory('Splits');
const SCHEMA_VERSION = 1;
const contractName = 'transaction-query-contract.json';
const manifestName = 'transaction-query-manifest.json';
const groupedName = 'grouped-query-cases.json';
const helperPaths = [
  'scripts/transaction-query-parity/cases.mjs',
  'scripts/transaction-query-parity/oracle-runner.template',
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

const pinRecord = { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion };
const plan = buildPlan();
if (!sameJSON(plan, buildPlan())) note('buildPlan() is not deterministic');
if (new Set(plan.cases.map(planCase => planCase.id)).size !== plan.cases.length) note('plan case IDs are not unique');

const contractBytes = readFileSync(join(fixtureDirectory, contractName));
const contract = JSON.parse(contractBytes.toString('utf8'));
const groupedBytes = readFileSync(join(groupedDirectory, groupedName));
const grouped = JSON.parse(groupedBytes.toString('utf8'));
const manifest = JSON.parse(readFileSync(join(fixtureDirectory, manifestName), 'utf8'));
const familyCounts = Object.fromEntries(
  FAMILIES.map(family => [family, plan.cases.filter(planCase => planCase.family === family).length]),
);
const splitCases = plan.cases.filter(planCase => planCase.family === 'splitmodes');

// Manifest pins.
if (manifest.schemaVersion !== SCHEMA_VERSION) note(`manifest schemaVersion is ${manifest.schemaVersion}`);
if (!sameJSON(manifest.actual, pinRecord)) note('manifest actual pin does not match config/parity/oracle-pin.json');
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
if (manifest.seed !== SEED) note(`manifest seed ${manifest.seed} does not match ${SEED}`);
if (manifest.timeZone !== TIME_ZONE) note(`manifest timeZone ${manifest.timeZone} does not match ${TIME_ZONE}`);
if (manifest.caseCount !== plan.cases.length) note(`manifest caseCount ${manifest.caseCount}, plan ${plan.cases.length}`);
if (!sameJSON(manifest.familyCounts, familyCounts)) note('manifest familyCounts do not match the plan');
for (const source of manifest.sourceFiles ?? []) {
  if (!/^[0-9a-f]{64}$/.test(source.sha256)) note(`source hash for ${source.path} is malformed`);
}
if (!sameJSON(manifest.oracleOnly, oracleOnlyEntries(plan))) note('manifest oracleOnly list does not match the plan');
if (!sameJSON(manifest.oracleOnlyFields, ORACLE_ONLY_FIELDS)) note('manifest oracleOnlyFields do not match cases.mjs');

const [contractEntry, groupedEntry] = manifest.fixtures ?? [];
if (manifest.fixtures?.length !== 2) note('manifest must list the contract and the grouped-query fixture');
const contractPath = relative(repositoryRoot, join(fixtureDirectory, contractName));
if (contractEntry?.path !== contractPath) note(`manifest fixture entry is not ${contractPath}`);
if (contractEntry?.sha256 !== sha256(contractBytes)) note('contract bytes do not match the manifest fixture hash');
if (!sameJSON(contractEntry?.caseIDs, plan.cases.map(planCase => planCase.id))) {
  note('manifest caseIDs do not match the plan in order');
}
if (contractEntry?.caseCount !== plan.cases.length) note('manifest fixture caseCount does not match the plan');
const groupedPath = relative(repositoryRoot, join(groupedDirectory, groupedName));
if (groupedEntry?.path !== groupedPath) note(`manifest grouped entry is not ${groupedPath}`);
if (groupedEntry?.sha256 !== sha256(groupedBytes)) note('grouped-query bytes do not match the manifest hash');
if (!sameJSON(groupedEntry?.caseIDs, splitCases.map(planCase => planCase.id))) {
  note('manifest grouped caseIDs do not match the plan');
}

// Contract header and worlds.
if (contract.schemaVersion !== SCHEMA_VERSION) note(`contract schemaVersion is ${contract.schemaVersion}`);
if (!sameJSON(contract.oracle, pinRecord)) note('contract oracle pin does not match config/parity/oracle-pin.json');
if (!sameJSON(contract.syntheticData, { only: true, timeZone: TIME_ZONE })) {
  note('contract syntheticData is not the expected synthetic shape');
}
const usedWorlds = [...new Set(plan.cases.map(planCase => planCase.world))];
if (!sameJSON(Object.keys(contract.worlds).sort(), [...usedWorlds].sort())) note('contract worlds differ from the worlds the plan uses');
for (const name of usedWorlds) {
  const dumped = contract.worlds[name];
  const planned = WORLDS[name];
  if (!dumped) continue;
  const ids = rows => rows.map(row => row.id).sort();
  if (!sameJSON(ids(dumped.transactions), ids(planned.transactions))) note(`world ${name}: transaction ids differ from the plan`);
  if (!sameJSON(ids(dumped.accounts), ids(planned.accounts))) note(`world ${name}: account ids differ from the plan`);
  for (const planned_ of planned.transactions) {
    const stored = dumped.transactions.find(row => row.id === planned_.id);
    if (!stored) continue;
    if (stored.amount !== planned_.amount || stored.date !== planned_.date) note(`world ${name}: ${planned_.id} amount or date differs from the plan`);
  }
}

// Cases.
const MINTED = /00000000-0000-4000-8000-\d{12}/;
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
    for (const field of ['gate', 'family', 'source', 'description', 'seed', 'oracleOnly', 'world', 'kind']) {
      if (!sameJSON(record[field], planCase[field])) note(`${where}: ${field} differs from the plan`);
    }
    if (MINTED.test(JSON.stringify(record))) note(`${where}: a minted uuid survived normalization`);
    if (planCase.kind === 'condition' && !sameJSON(record.condition, planCase.condition)) note(`${where}: condition differs from the plan`);
    if (planCase.kind === 'filter-create') {
      if (!sameJSON(record.baseline, planCase.baseline) || !sameJSON(record.candidate, planCase.candidate)) note(`${where}: payloads differ from the plan`);
    }
    if (planCase.kind === 'split-modes' && !sameJSON(record.order, planCase.order)) note(`${where}: order differs from the plan`);
    for (const failure of expectationFailures(record, planCase)) note(`${where}: ${failure}`);
  });
  // The grouped-query file is exactly the projection of the recorded split-mode cases.
  const expectedGrouped = contract.cases
    .filter(record => record.family === 'splitmodes')
    .map(record => groupedQueryProjection(record, plan.cases.find(planCase => planCase.id === record.id)));
  if (!sameJSON(grouped.cases, expectedGrouped)) note('grouped-query-cases.json is not the projection of the recorded split-mode cases');
}
if (!sameJSON(grouped.oracle, pinRecord)) note('grouped-query-cases.json oracle pin does not match config/parity/oracle-pin.json');

if (failures.length > 0) {
  for (const failure of failures) console.error(`transaction query verify: ${failure}`);
  console.error(`transaction query verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(
  `Transaction query parity fixture verified: ${plan.cases.length} cases (` +
    `${Object.entries(familyCounts).map(([family, count]) => `${family} ${count}`).join(', ')}), ` +
    `${oracleOnlyEntries(plan).length} oracle-only cases, ${usedWorlds.length} worlds, ${groupedEntry?.caseIDs?.length} grouped-query cases.`,
);
