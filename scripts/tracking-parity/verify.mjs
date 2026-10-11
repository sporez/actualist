#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';

const SCHEMA_VERSION = 1;
const SOURCE_PATH = 'packages/loot-core/src/server/budget/tracking.ts';
const CASE_COUNT = 36;

const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), '..', '..');
const fixtureRoot = pinnedFixtureDirectory('Tracking');
const manifestPath = join(fixtureRoot, 'tracking-manifest.json');

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function fail(message) {
  console.error(`tracking parity fixture error: ${message}`);
  console.error(
    'Regenerate with ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/tracking-parity/generate.mjs.',
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

const generatorPath = join(root, 'scripts/tracking-parity/generate.mjs');
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

if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length !== 1) {
  fail('source hash list is incomplete');
}
const [source] = manifest.sourceFiles;
if (source.path !== SOURCE_PATH || !/^[a-f0-9]{64}$/.test(source.sha256 ?? '')) {
  fail(`invalid source entry: ${JSON.stringify(source)}`);
}

const fixturePath = resolve(root, manifest.fixtures?.[0]?.path ?? '');
if (!fixturePath.startsWith(fixtureRoot + '/')) fail('fixture path escapes pinned directory');
const data = readFileSync(fixturePath);
if (sha256(data) !== manifest.fixtures[0].sha256) fail('fixture hash mismatch');

const contract = JSON.parse(data.toString('utf8'));
if (contract.commit !== oraclePin.commit || contract.source !== SOURCE_PATH) {
  fail('fixture oracle identity mismatch');
}
if (contract.sha256 !== source.sha256) fail('fixture source hash does not match the recorded source');
if (!Array.isArray(contract.cases) || contract.cases.length !== CASE_COUNT) {
  fail(`fixture must contain ${CASE_COUNT} cases, found ${contract.cases?.length}`);
}
if (manifest.caseCount !== contract.cases.length || manifest.fixtures[0].caseCount !== contract.cases.length) {
  fail('manifest case count does not match the fixture');
}
console.log(`Tracking parity fixture verified (${manifest.actual.tag}, ${contract.cases.length} cases).`);
