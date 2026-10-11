#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';

const SCHEMA_VERSION = 1;
const CASE_IDS = [
  'hold-partial-then-repeat-adds',
  'hold-full-available-to-budget',
  'hold-more-than-available-clamps',
  'hold-repeat-clamps-to-remaining-to-budget',
  'release-hold-restores-to-budget',
  'release-without-stored-hold-row-writes-zero-hold',
  'hold-after-release-starts-from-zero',
  'hold-rolls-into-next-month-available',
  'hold-across-year-boundary-rolls-into-january',
  'hold-noop-when-to-budget-is-zero',
  'hold-noop-when-to-budget-is-negative',
  'release-manual-hold-reveals-automatic-income-hold',
  'hold-handler-replaces-automatic-income-hold-when-called-directly',
  'hold-in-tracking-budget-is-not-offered',
  'hold-in-future-month-creates-stored-row',
  'actualist-compatible-crdt-replays-into-actual-peer',
];
const REQUIRED_SOURCES = [
  'packages/loot-core/src/server/budget/actions.ts',
  'packages/loot-core/src/server/budget/envelope.ts',
  'packages/loot-core/src/server/budget/base.ts',
  'packages/loot-core/src/server/budget/app.ts',
];

const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), '..', '..');
const fixtureRoot = pinnedFixtureDirectory('Holds');
const manifestPath = join(fixtureRoot, 'hold-manifest.json');

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function fail(message) {
  console.error(`hold parity fixture error: ${message}`);
  console.error(
    'Regenerate with ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/hold-parity/generate.mjs.',
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
if (manifest.seed !== null) fail('manifest seed must be null for this deterministic harness');
if (manifest.amountUnits !== 'integer minor units') fail('amount units are not explicit');

const generatorPath = join(root, 'scripts/hold-parity/generate.mjs');
if (sha256(readFileSync(generatorPath)) !== manifest.generator?.sha256) fail('generator hash mismatch');
if (!Array.isArray(manifest.helpers) || manifest.helpers.length === 0) {
  fail('manifest does not record the helper scripts it depends on');
}
for (const helper of manifest.helpers) {
  let data;
  try {
    data = readFileSync(resolve(root, helper.path ?? ''));
  } catch (error) {
    fail(`cannot read helper ${helper.path}: ${error.message}`);
  }
  if (sha256(data) !== helper.sha256) fail(`helper hash mismatch: ${helper.path}`);
}

if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length === 0) {
  fail('source hash list is empty');
}
for (const source of manifest.sourceFiles) {
  if (typeof source.path !== 'string' || !/^[a-f0-9]{64}$/.test(source.sha256 ?? '')) {
    fail(`invalid source entry: ${JSON.stringify(source)}`);
  }
}
for (const required of REQUIRED_SOURCES) {
  if (!manifest.sourceFiles.some(source => source.path === required)) {
    fail(`source hash list does not include ${required}`);
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
if (!Array.isArray(contract.cases) || contract.cases.length !== CASE_IDS.length) {
  fail(`fixture must contain ${CASE_IDS.length} cases, found ${contract.cases?.length}`);
}
if (fixture.caseCount !== contract.cases.length || manifest.caseCount !== contract.cases.length) {
  fail('manifest case count does not match the fixture');
}
const ids = contract.cases.map(entry => entry.id);
if (new Set(ids).size !== ids.length) fail('duplicate fixture case ids');
for (const id of CASE_IDS) {
  if (!ids.includes(id)) fail(`missing reviewed case: ${id}`);
}
for (const entry of contract.cases) {
  if (!Array.isArray(entry.steps) || entry.steps.length === 0) fail(`case ${entry.id} has no steps`);
  if (!Array.isArray(entry.before) || entry.before.length === 0) fail(`case ${entry.id} has no baseline state`);
}
console.log(`Hold parity fixture verified (${manifest.actual.tag}, ${contract.cases.length} cases).`);
