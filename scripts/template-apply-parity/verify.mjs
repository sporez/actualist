#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';

const SCHEMA_VERSION = 1;
const FAMILIES = ['fixed', 'priority', 'schedule', 'average-copy', 'percent', 'remainder', 'goal-by', 'limit-refill'];
const FUNDING_STATES = ['above', 'below', 'exact', 'zero', 'negative'];
const GENERATED_PER_COMBINATION = 3;
const NAMED_CASE_IDS = [
  'tapply-named-ended-schedule',
  'tapply-named-deleted-category',
  'tapply-named-priority-clamp',
  'tapply-named-average-missing-months',
  'tapply-named-yearly-sinking-fund',
  'tapply-named-schedule-by-id',
  'tapply-named-stale-note-goal-def',
  'tapply-named-tracking-budget',
  'tapply-named-jpy-currency',
  'tapply-named-leap-year-periodic',
  'tapply-named-year-boundary-by',
  'tapply-named-overwrite-existing-budget',
  'tapply-named-apply-skips-budgeted',
  'tapply-named-no-templates',
  'tapply-named-orphan-goal-reset',
];
const REQUIRED_SOURCES = [
  'packages/loot-core/src/server/budget/goal-template.ts',
  'packages/loot-core/src/server/budget/category-template-context.ts',
  'packages/loot-core/src/server/budget/envelope.ts',
  'packages/loot-core/src/server/budget/tracking.ts',
];
const HELPERS = ['scripts/parity/lib/oracle-pin.mjs', 'scripts/parity/lib/fixture-diff.mjs'];
const HARNESS = 'scripts/template-apply-parity/harness/template-apply-parity.test.ts';

const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), '..', '..');
const fixtureRoot = pinnedFixtureDirectory('TemplateApply');
const manifestPath = join(fixtureRoot, 'template-apply-manifest.json');

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function fail(message) {
  console.error(`template apply parity fixture error: ${message}`);
  console.error(
    'Regenerate with ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/template-apply-parity/generate.mjs.',
  );
  process.exit(1);
}

let manifest;
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
} catch (error) {
  fail(`cannot read ${relative(root, manifestPath)}: ${error.message}`);
}
if (manifest.schemaVersion !== SCHEMA_VERSION) fail('unexpected manifest schema');
for (const [key, value] of [
  ['tag', oraclePin.tag],
  ['commit', oraclePin.commit],
  ['packageVersion', oraclePin.packageVersion],
]) {
  if (manifest.actual?.[key] !== value) fail(`unexpected Actual ${key}`);
}
if (!Number.isInteger(manifest.seed)) fail('manifest does not record an integer seed');
if (manifest.amountUnits === undefined || !manifest.amountUnits.startsWith('integer minor units')) {
  fail('amount units are not explicit');
}

const generatorPath = join(root, 'scripts/template-apply-parity/generate.mjs');
if (sha256(readFileSync(generatorPath)) !== manifest.generator?.sha256) fail('generator hash mismatch');
if (sha256(readFileSync(join(root, HARNESS))) !== manifest.harness?.sha256) fail('harness hash mismatch');
if (manifest.harness?.path !== HARNESS) fail('manifest harness path mismatch');
for (const helper of HELPERS) {
  const recorded = manifest.helpers?.find(entry => entry.path === helper);
  if (!recorded) fail(`manifest does not record helper ${helper}`);
  if (sha256(readFileSync(join(root, helper))) !== recorded.sha256) fail(`helper hash mismatch: ${helper}`);
}

if (!Array.isArray(manifest.upstreamSources) || manifest.upstreamSources.length === 0) {
  fail('upstream source hash list is empty');
}
for (const source of manifest.upstreamSources) {
  if (typeof source.path !== 'string' || !/^[a-f0-9]{64}$/.test(source.sha256 ?? '')) {
    fail(`invalid upstream source entry: ${JSON.stringify(source)}`);
  }
}
for (const required of REQUIRED_SOURCES) {
  if (!manifest.upstreamSources.some(source => source.path === required)) {
    fail(`upstream source hash list does not include ${required}`);
  }
}

if (!Array.isArray(manifest.fixtures) || manifest.fixtures.length !== 1) {
  fail('manifest must list exactly one fixture');
}
const [fixture] = manifest.fixtures;
const fixturePath = resolve(root, fixture.path ?? '');
if (!fixturePath.startsWith(fixtureRoot + '/')) fail('fixture path escapes pinned directory');
const data = readFileSync(fixturePath);
if (sha256(data) !== fixture.sha256) fail('fixture hash mismatch');

const contract = JSON.parse(data.toString('utf8'));
if (contract.schemaVersion !== SCHEMA_VERSION) fail('unexpected fixture schema');
for (const [key, value] of [
  ['tag', oraclePin.tag],
  ['commit', oraclePin.commit],
  ['packageVersion', oraclePin.packageVersion],
]) {
  if (contract.oracle?.[key] !== value) fail(`fixture oracle ${key} mismatch`);
}
if (contract.syntheticData?.only !== true) fail('fixture is not marked synthetic-only');

const expectedCaseCount = NAMED_CASE_IDS.length + FAMILIES.length * FUNDING_STATES.length * GENERATED_PER_COMBINATION;
if (!Array.isArray(contract.cases) || contract.cases.length !== expectedCaseCount) {
  fail(`fixture must contain ${expectedCaseCount} cases, found ${contract.cases?.length}`);
}
if (fixture.caseCount !== contract.cases.length || manifest.caseCount !== contract.cases.length) {
  fail('manifest case count does not match the fixture');
}

const ids = contract.cases.map(entry => entry.id);
if (new Set(ids).size !== ids.length) fail('duplicate fixture case ids');
if (JSON.stringify(fixture.caseIDs) !== JSON.stringify(ids)) fail('manifest caseIDs do not match fixture order');
for (const id of NAMED_CASE_IDS) {
  if (!ids.includes(id)) fail(`missing named case: ${id}`);
}
if (JSON.stringify(manifest.coverage?.namedCaseIDs) !== JSON.stringify(NAMED_CASE_IDS)) {
  fail('manifest named case IDs do not match the reviewed list');
}

const seen = new Set();
for (const entry of contract.cases) {
  if (!entry.operation || !['apply', 'overwrite'].includes(entry.operation.kind)) {
    fail(`case ${entry.id} has no operation kind`);
  }
  if (!FUNDING_STATES.includes(entry.funding?.state)) fail(`case ${entry.id} has no funding state`);
  if (!entry.input || !entry.before || !entry.expected) fail(`case ${entry.id} is missing input, before, or expected`);
  if (entry.id.startsWith('tapply-generated-')) {
    if (!FAMILIES.includes(entry.family)) fail(`case ${entry.id} has an unknown family`);
    seen.add(`${entry.family}/${entry.funding.state}`);
  }
}
for (const family of FAMILIES) {
  for (const state of FUNDING_STATES) {
    if (!seen.has(`${family}/${state}`)) fail(`no generated case for ${family}/${state}`);
  }
}

console.log(`Template apply parity fixture verified (${manifest.actual.tag}, ${contract.cases.length} cases).`);
