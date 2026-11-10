#!/usr/bin/env node

// Checks the committed FileImport fixture without an oracle: manifest pins, helper
// and source hashes, plan identity, derived-case consistency, the coverage gate
// recorded at generation, and the structural invariants in cases.mjs.
// Regeneration is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../lib/oracle-pin.mjs';
import { buildPlan, expectationFailures, SEED } from './cases.mjs';
import { FROZEN_SOURCES, REGISTRY } from './registry.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('FileImport');
const SCHEMA_VERSION = 1;
const contractName = 'file-import-contract.json';
const manifestName = 'file-import-manifest.json';

const failures = [];
const note = message => failures.push(message);
const sha256 = data => createHash('sha256').update(data).digest('hex');
const sameJSON = (left, right) => JSON.stringify(left) === JSON.stringify(right);

const plan = buildPlan();
if (!sameJSON(plan, buildPlan())) note('buildPlan() is not deterministic for a fixed seed');
if (new Set(plan.cases.map(planCase => planCase.id)).size !== plan.cases.length) note('plan case IDs are not unique');

const contractBytes = readFileSync(join(fixtureDirectory, contractName));
const contract = JSON.parse(contractBytes.toString('utf8'));
const manifest = JSON.parse(readFileSync(join(fixtureDirectory, manifestName), 'utf8'));
const pin = { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion };

if (manifest.schemaVersion !== SCHEMA_VERSION) note(`manifest schemaVersion is ${manifest.schemaVersion}`);
if (!sameJSON(manifest.actual, pin)) note('manifest actual pin does not match config/parity/oracle-pin.json');
if (manifest.generator?.sha256 !== sha256(readFileSync(join(dirname(scriptPath), 'generate.mjs')))) {
  note('generate.mjs changed since the manifest was written');
}
for (const helper of manifest.helpers ?? []) {
  if (sha256(readFileSync(join(repositoryRoot, helper.path))) !== helper.sha256) {
    note(`helper ${helper.path} changed since the manifest was written`);
  }
}
if (manifest.seed !== SEED) note(`manifest seed ${manifest.seed} does not match ${SEED}`);
if (!sameJSON(manifest.sourceFiles, Object.entries(FROZEN_SOURCES).map(([path, hash]) => ({ path, sha256: hash })))) {
  note('manifest source freeze does not match registry.mjs');
}

const fixture = manifest.fixtures?.[0];
if (manifest.fixtures?.length !== 1 || fixture.path !== relative(repositoryRoot, join(fixtureDirectory, contractName))) {
  note('manifest fixture entry is not the contract file');
}
if (fixture?.sha256 !== sha256(contractBytes)) note('contract bytes do not match the manifest fixture hash');

if (contract.schemaVersion !== SCHEMA_VERSION) note(`contract schemaVersion is ${contract.schemaVersion}`);
if (!sameJSON(contract.oracle, pin)) note('contract oracle pin does not match config/parity/oracle-pin.json');
if (contract.seed !== SEED) note(`contract seed ${contract.seed} does not match ${SEED}`);
if (contract.syntheticData?.only !== true) note('contract does not declare synthetic data only');

// Case-by-case checks against the plan. A derived case is recorded exactly when
// the output of the case it derives from is not null, with that output as input.
const recordsByID = new Map((contract.cases ?? []).map(record => [record.id, record]));
const expectedIDs = [];
for (const planCase of plan.cases) {
  const record = recordsByID.get(planCase.id);
  if (planCase.source === 'derived') {
    const source = recordsByID.get(planCase.derivedFrom);
    if (!source) { note(`${planCase.id}: derives from missing case ${planCase.derivedFrom}`); continue; }
    if (source.output === null) {
      if (record) note(`${planCase.id}: recorded although its source output is null`);
      continue;
    }
    if (record && !sameJSON(record.input, { amount: source.output })) note(`${planCase.id}: input is not its source output`);
  }
  expectedIDs.push(planCase.id);
  if (!record) { note(`${planCase.id}: missing from the contract`); continue; }
  for (const field of ['function', 'source', 'description', 'seed', 'derivedFrom']) {
    if (!sameJSON(record[field], planCase[field])) note(`${planCase.id}: ${field} differs from the plan`);
  }
  if (planCase.source !== 'derived' && !sameJSON(record.input, planCase.input)) note(`${planCase.id}: input differs from the plan`);
  for (const failure of expectationFailures(record, planCase)) note(`${planCase.id}: ${failure}`);
}
if (!sameJSON((contract.cases ?? []).map(record => record.id), expectedIDs)) note('contract case IDs differ from the plan in order');
if (!sameJSON(fixture?.caseIDs, expectedIDs)) note('manifest caseIDs do not match the contract');
if (manifest.caseCount !== expectedIDs.length) note(`manifest caseCount ${manifest.caseCount}, expected ${expectedIDs.length}`);

// Per-function sections and the recorded coverage gate.
for (const entry of REGISTRY) {
  const own = (contract.cases ?? []).filter(record => record.function === entry.name);
  if (own.length === 0) note(`${entry.name}: no cases in the contract`);
  const counts = contract.functions?.[entry.name];
  if (counts?.caseCount !== own.length) note(`${entry.name}: contract caseCount ${counts?.caseCount}, actual ${own.length}`);
  if (!sameJSON(counts, manifest.functions?.[entry.name])) note(`${entry.name}: manifest and contract counts differ`);
  const report = manifest.coverage?.[entry.name];
  if (!report) { note(`${entry.name}: no coverage report in the manifest`); continue; }
  if (report.gate !== entry.coverageGate) note(`${entry.name}: recorded gate ${report.gate}, registry says ${entry.coverageGate}`);
  if (entry.coverageGate === 'enforce' && report.uncovered.length > 0) note(`${entry.name}: uncovered blocks under an enforced gate`);
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`file import verify: ${failure}`);
  console.error(`file import verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(`File import parity fixture verified: ${expectedIDs.length} cases, seed ${SEED}.`);
