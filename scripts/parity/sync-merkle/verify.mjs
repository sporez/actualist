#!/usr/bin/env node

// Checks the committed SyncMerkle fixture without an oracle: manifest pins, helper
// hashes, plan identity, recorded setup, run shape, and the structural invariants
// in cases.mjs. Regeneration is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../lib/oracle-pin.mjs';
import { buildPlan, expectationFailures, SEED, TIME_ZONE } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('SyncMerkle');
const SCHEMA_VERSION = 1;
const contractName = 'sync-merkle-contract.json';
const manifestName = 'sync-merkle-manifest.json';
const helperPaths = [
  'scripts/parity/sync-merkle/cases.mjs',
  'scripts/parity/sync-merkle/oracle-runner.template',
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
const pin = { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion };
if (manifest.schemaVersion !== SCHEMA_VERSION) note(`manifest schemaVersion is ${manifest.schemaVersion}`);
if (!sameJSON(manifest.actual, pin)) note('manifest actual pin does not match config/parity/oracle-pin.json');
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
if (manifest.timeZone !== TIME_ZONE) note(`manifest timeZone ${manifest.timeZone} does not match ${TIME_ZONE}`);
if (manifest.caseCount !== plan.cases.length) note(`manifest caseCount ${manifest.caseCount}, plan ${plan.cases.length}`);
if (manifest.namedCaseCount !== namedCount) note(`manifest namedCaseCount ${manifest.namedCaseCount}, plan ${namedCount}`);
if (manifest.generatedCaseCount !== generatedCount) {
  note(`manifest generatedCaseCount ${manifest.generatedCaseCount}, plan ${generatedCount}`);
}
for (const source of manifest.sourceFiles ?? []) {
  if (!/^[0-9a-f]{64}$/.test(source.sha256)) note(`source hash for ${source.path} is malformed`);
}

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
if (!sameJSON(contract.oracle, pin)) note('contract oracle pin does not match config/parity/oracle-pin.json');
if (!sameJSON(contract.environment, { timeZone: TIME_ZONE })) note('contract environment does not match the plan');
if (!sameJSON(contract.message, {
  dataset: plan.dataset,
  column: plan.column,
  clientNode: plan.clientNode,
  groupId: plan.groupId,
  fileId: plan.fileId,
})) {
  note('contract message header does not match the plan');
}

// Case-by-case checks against the plan.
if (!Array.isArray(contract.cases) || contract.cases.length !== plan.cases.length) {
  note(`contract has ${contract.cases?.length} cases, plan has ${plan.cases.length}`);
} else {
  contract.cases.forEach((record, index) => {
    const planCase = plan.cases[index];
    if (record.id !== planCase.id) {
      note(`case ${index} is ${record.id}, plan says ${planCase.id}`);
      return;
    }
    for (const field of ['source', 'description', 'seed', 'tags', 'now', 'setup', 'during']) {
      if (!sameJSON(record[field], planCase[field])) note(`${planCase.id}: ${field} differs from the plan`);
    }
    for (const failure of expectationFailures(record, planCase)) note(`${planCase.id}: ${failure}`);
  });
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`sync merkle verify: ${failure}`);
  console.error(`sync merkle verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(
  `Sync merkle parity fixture verified: ${plan.cases.length} cases (${namedCount} named, ${generatedCount} generated), seed ${SEED}.`,
);
