#!/usr/bin/env node

// Checks the committed Schedules fixture without an oracle: manifest pins,
// helper hashes, plan identity, record shape, and the plan's sanity checks.
// Regeneration is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';
import {
  buildPlan,
  expectationFailures,
  oracleOnlyEntries,
  ORACLE_ONLY_FIELDS,
  SEED,
  TIME_ZONE,
  TODAY,
} from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('Schedules');
const SCHEMA_VERSION = 1;
const contractName = 'schedules-contract.json';
const manifestName = 'schedules-manifest.json';
const helperPaths = [
  'scripts/schedule-parity/cases.mjs',
  'scripts/schedule-parity/oracle-runner.template',
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
const familyCounts = Object.fromEntries(
  ['recurrence', 'status', 'stateful'].map(family => [
    family,
    plan.cases.filter(planCase => planCase.family === family).length,
  ]),
);

// Manifest pins.
if (manifest.schemaVersion !== SCHEMA_VERSION) note(`manifest schemaVersion is ${manifest.schemaVersion}`);
if (!sameJSON(manifest.actual, {
  tag: oraclePin.tag,
  commit: oraclePin.commit,
  packageVersion: oraclePin.packageVersion,
})) {
  note('manifest actual pin does not match config/parity/oracle-pin.json');
}
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
if (manifest.today !== TODAY) note(`manifest today ${manifest.today} does not match ${TODAY}`);
if (manifest.timeZone !== TIME_ZONE) note(`manifest timeZone ${manifest.timeZone} does not match ${TIME_ZONE}`);
if (manifest.caseCount !== plan.cases.length) note(`manifest caseCount ${manifest.caseCount}, plan ${plan.cases.length}`);
if (manifest.namedCaseCount !== namedCount) note(`manifest namedCaseCount ${manifest.namedCaseCount}, plan ${namedCount}`);
if (manifest.generatedCaseCount !== generatedCount) {
  note(`manifest generatedCaseCount ${manifest.generatedCaseCount}, plan ${generatedCount}`);
}
if (!sameJSON(manifest.familyCounts, familyCounts)) note('manifest familyCounts do not match the plan');
for (const source of manifest.sourceFiles ?? []) {
  if (!/^[0-9a-f]{64}$/.test(source.sha256)) note(`source hash for ${source.path} is malformed`);
}
if (!sameJSON(manifest.oracleOnly, oracleOnlyEntries(plan))) note('manifest oracleOnly list does not match the plan');
if (!sameJSON(manifest.oracleOnlyFields, ORACLE_ONLY_FIELDS)) note('manifest oracleOnlyFields do not match cases.mjs');

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
if (!sameJSON(contract.syntheticData, { only: true, timeZone: TIME_ZONE, today: TODAY })) {
  note('contract syntheticData is not the expected synthetic shape');
}

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const STATUSES = ['completed', 'paid', 'due', 'upcoming', 'missed', 'scheduled'];

function checkRecurrence(record, planCase, where) {
  if (!sameJSON(record.condition, planCase.condition)) note(`${where}: condition differs from the plan`);
  if (!sameJSON(record.queries.map(query => query.from), planCase.froms)) note(`${where}: query froms differ`);
  for (const query of record.queries) {
    for (const field of ['nextDate', 'nextDateNoSkipWeekend', 'nextDateAfter']) {
      const outcome = query[field];
      if (!outcome || !('value' in outcome) || !('error' in outcome)) note(`${where} ${query.from}: ${field} lacks value/error`);
      else if (outcome.value !== null && !DAY.test(outcome.value)) note(`${where} ${query.from}: ${field} is not a day`);
    }
    for (const list of [query.occurrences.raw, query.occurrences.adjusted]) {
      if (!list.every(day => DAY.test(day))) note(`${where} ${query.from}: occurrence is not a day`);
    }
    if (query.occurrences.raw.length !== query.occurrences.adjusted.length) {
      note(`${where} ${query.from}: raw and adjusted lengths differ`);
    }
  }
}

function checkStatus(record, planCase, where) {
  for (const field of ['today', 'upcomingLength']) {
    if (record[field] !== planCase[field]) note(`${where}: ${field} differs from the plan`);
  }
  if (record.rows.length !== planCase.rows.length) {
    note(`${where}: ${record.rows.length} rows, plan has ${planCase.rows.length}`);
    return;
  }
  record.rows.forEach((row, index) => {
    const planned = planCase.rows[index];
    for (const field of ['nextDate', 'completed', 'hasTrans']) {
      if (row[field] !== planned[field]) note(`${where} row ${index}: ${field} differs from the plan`);
    }
    if (row.error === null && !STATUSES.includes(row.status)) note(`${where} row ${index}: unknown status ${row.status}`);
  });
}

function checkStateful(record, planCase, where) {
  if (!sameJSON(record.setup, planCase.setup)) note(`${where}: setup differs from the plan`);
  if (record.steps.length !== planCase.steps.length) {
    note(`${where}: ${record.steps.length} steps, plan has ${planCase.steps.length}`);
    return;
  }
  const snapshots = [record.before, ...record.steps.map(step => step.after)];
  for (const snapshot of snapshots) {
    for (const section of ['schedules', 'nextDates', 'paths', 'rules', 'transactions', 'effective', 'preview']) {
      if (!Array.isArray(snapshot[section])) note(`${where}: snapshot lacks ${section}`);
    }
    if (snapshot.effective.length !== planCase.setup.schedules.length) note(`${where}: effective rows differ from the setup`);
    for (const row of snapshot.effective) {
      if (!STATUSES.includes(row.status)) note(`${where}: unknown status ${row.status}`);
    }
    const stale = JSON.stringify(snapshot).match(/"[A-Za-z_]*_ts"/);
    if (stale) note(`${where}: a timestamp column survived normalization (${stale[0]})`);
    if (/\bid\d+\b/.test(JSON.stringify(snapshot))) note(`${where}: a mock id survived normalization`);
  }
  record.steps.forEach((step, index) => {
    const planned = planCase.steps[index];
    for (const field of ['op', 'today']) {
      if (step[field] !== planned[field]) note(`${where} step ${index}: ${field} differs from the plan`);
    }
    if (!sameJSON(step.args, planned)) note(`${where} step ${index}: args differ from the plan`);
    if (step.error !== null && typeof step.error !== 'string') note(`${where} step ${index}: error is not text`);
  });
}

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
    for (const field of ['family', 'source', 'description', 'seed', 'oracleOnly']) {
      if (!sameJSON(record[field], planCase[field])) note(`${where}: ${field} differs from the plan`);
    }
    if (planCase.family === 'recurrence') checkRecurrence(record, planCase, where);
    else if (planCase.family === 'status') checkStatus(record, planCase, where);
    else checkStateful(record, planCase, where);
    for (const failure of expectationFailures(record, planCase)) note(`${where}: ${failure}`);
  });
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`schedules verify: ${failure}`);
  console.error(`schedules verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(
  `Schedules parity fixture verified: ${plan.cases.length} cases (${namedCount} named, ${generatedCount} generated; ` +
    `${Object.entries(familyCounts).map(([family, count]) => `${family} ${count}`).join(', ')}), ` +
    `${oracleOnlyEntries(plan).length} oracle-only cases, ${ORACLE_ONLY_FIELDS.length} oracle-only fields, seed ${SEED}.`,
);
