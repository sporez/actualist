#!/usr/bin/env node

// Checks the committed BudgetMonth fixture without an oracle: manifest pins,
// helper hashes, plan identity, step and setup equality, state shape, and the
// author's expectations against the recorded values. Regeneration is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';
import {
  buildPlan,
  CURRENCY,
  expectationFailures,
  oracleOnlyEntries,
  SEED,
  TODAY,
} from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('BudgetMonth');
const SCHEMA_VERSION = 1;
const contractName = 'budget-month-contract.json';
const manifestName = 'budget-month-manifest.json';
const helperPaths = [
  'scripts/budget-month-parity/cases.mjs',
  'scripts/budget-month-parity/oracle-runner.template',
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

function nonIntegerNumbers(node, path = '$', found = []) {
  if (typeof node === 'number' && !Number.isInteger(node)) {
    found.push(path);
  } else if (Array.isArray(node)) {
    node.forEach((value, index) => nonIntegerNumbers(value, `${path}[${index}]`, found));
  } else if (node !== null && typeof node === 'object') {
    for (const [key, value] of Object.entries(node)) nonIntegerNumbers(value, `${path}.${key}`, found);
  }
  return found;
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
if (!sameJSON(contract.syntheticData, { only: true, accountIDs: ['checking', 'savings'], currencyCode: CURRENCY })) {
  note('contract syntheticData is not the expected synthetic shape');
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
    for (const field of ['source', 'description', 'seed', 'oracleOnly', 'setup', 'sheetMonths']) {
      if (!sameJSON(record[field], planCase[field])) note(`${where}: ${field} differs from the plan`);
    }
    const months = planCase.sheetMonths;
    if (!sameJSON(record.before.map(state => state.month), months)) note(`${where}: before months differ`);
    if (!sameJSON(record.expected.map(state => state.month), months)) note(`${where}: expected months differ`);
    if (record.steps.length !== planCase.steps.length) {
      note(`${where}: ${record.steps.length} recorded steps, ${planCase.steps.length} planned`);
    }
    record.steps.forEach((step, stepIndex) => {
      const planned = planCase.steps[stepIndex];
      if (!planned) return;
      for (const field of ['handler', 'affectedFrom', 'args']) {
        if (!sameJSON(step[field], planned[field])) note(`${where} step ${stepIndex}: ${field} differs from the plan`);
      }
      if (!('returned' in step) || !Array.isArray(step.cells) || !Array.isArray(step.stateAfter)) {
        note(`${where} step ${stepIndex}: missing returned, cells or stateAfter`);
      }
      if (step.error !== null && typeof step.error !== 'string') note(`${where} step ${stepIndex}: error is not text`);
      for (const cell of step.cells ?? []) {
        for (const field of ['dataset', 'row', 'column', 'serializedValue']) {
          if (typeof cell[field] !== 'string') note(`${where} step ${stepIndex}: cell ${field} is not text`);
        }
      }
      const affected = months.filter(month => month >= planned.affectedFrom);
      if (!sameJSON(step.stateAfter.map(state => state.month), affected)) {
        note(`${where} step ${stepIndex}: stateAfter months are not the months from ${planned.affectedFrom}`);
      }
    });
    const nonInteger = nonIntegerNumbers({ before: record.before, expected: record.expected, steps: record.steps });
    if (nonInteger.length > 0) note(`${where}: non-integer values at ${nonInteger.slice(0, 3).join(', ')}`);
    for (const failure of expectationFailures(record, planCase)) note(`${where}: ${failure}`);
  });
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`budget-month verify: ${failure}`);
  console.error(`budget-month verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(
  `Budget-month parity fixture verified: ${plan.cases.length} cases (${namedCount} named, ${generatedCount} generated), ` +
    `${oracleOnlyEntries(plan).length} oracle-only, seed ${SEED}.`,
);
