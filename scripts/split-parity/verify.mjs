#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const EXPECTED = {
  schemaVersion: 1,
  tag: 'v26.8.1',
  commit: '063df03763ca772b51f6264752b88ddec22cfb8a',
  packageVersion: '26.8.1',
};
const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), '..', '..');
const fixtureRoot = join(root, 'ActualistTests/Fixtures/ActualCore26_8_1/Splits');
const manifestPath = join(fixtureRoot, 'manifest.json');

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function fail(message) {
  console.error(`split parity fixture error: ${message}`);
  console.error(
    'Regenerate with scripts/split-parity/generate.mjs --actual-checkout <pinned-actual-v26.8.1>.',
  );
  process.exit(1);
}

let manifest;
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
} catch (error) {
  fail(`cannot read ${relative(root, manifestPath)}: ${error.message}`);
}

if (manifest.schemaVersion !== EXPECTED.schemaVersion) {
  fail(`manifest schema ${manifest.schemaVersion} is not ${EXPECTED.schemaVersion}`);
}
for (const [key, expected] of Object.entries({
  tag: EXPECTED.tag,
  commit: EXPECTED.commit,
  packageVersion: EXPECTED.packageVersion,
})) {
  if (manifest.actual?.[key] !== expected) {
    fail(`manifest Actual ${key} ${manifest.actual?.[key]} is not ${expected}`);
  }
}
if (manifest.amountUnits !== 'integer minor units') {
  fail('amount units are not explicit integer minor units');
}
if (manifest.rounding !== 'JavaScript Math.round: ties toward positive infinity') {
  fail('rounding convention changed without an oracle schema update');
}

const generatorPath = join(root, 'scripts/split-parity/generate.mjs');
if (sha256(readFileSync(generatorPath)) !== manifest.generator?.sha256) {
  fail('generator hash differs from the reviewed manifest');
}

if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length < 10) {
  fail('authoritative source hash list is incomplete');
}
const sourcePaths = new Set();
for (const source of manifest.sourceFiles) {
  if (
    typeof source.path !== 'string'
    || !source.path.startsWith('packages/loot-core/src/')
    || !/^[a-f0-9]{64}$/.test(source.sha256 ?? '')
    || sourcePaths.has(source.path)
  ) {
    fail(`invalid or duplicate source entry: ${JSON.stringify(source)}`);
  }
  sourcePaths.add(source.path);
}
for (const required of [
  'packages/loot-core/src/shared/transactions.ts',
  'packages/loot-core/src/server/rules/rule.ts',
  'packages/loot-core/src/server/rules/action.ts',
  'packages/loot-core/src/server/aql/schema/executors.ts',
  'packages/loot-core/src/server/transactions/transfer.ts',
]) {
  if (!sourcePaths.has(required)) fail(`missing required source hash: ${required}`);
}

if (!Array.isArray(manifest.fixtures) || manifest.fixtures.length !== 2) {
  fail('expected exactly the reviewed family and split-rule fixtures');
}
for (const fixture of manifest.fixtures) {
  const path = resolve(root, fixture.path ?? '');
  if (!path.startsWith(fixtureRoot + '/')) {
    fail(`fixture path escapes the pinned fixture directory: ${fixture.path}`);
  }
  let data;
  let parsed;
  try {
    data = readFileSync(path);
    parsed = JSON.parse(data.toString('utf8'));
  } catch (error) {
    fail(`cannot read fixture ${fixture.path}: ${error.message}`);
  }
  if (sha256(data) !== fixture.sha256) fail(`hash mismatch for ${fixture.path}`);
  if (parsed.schemaVersion !== EXPECTED.schemaVersion) {
    fail(`schema mismatch for ${fixture.path}`);
  }
  if (
    parsed.oracle?.commit !== EXPECTED.commit
    || parsed.oracle?.packageVersion !== EXPECTED.packageVersion
  ) {
    fail(`oracle identity mismatch for ${fixture.path}`);
  }
  if (!Array.isArray(parsed.cases) || parsed.cases.length !== fixture.caseCount) {
    fail(`case count mismatch for ${fixture.path}`);
  }
  const ids = new Set(parsed.cases.map(value => value.id));
  if (ids.size !== parsed.cases.length || ids.has(undefined)) {
    fail(`case ids are missing or duplicated in ${fixture.path}`);
  }
}

console.log(
  `Split parity fixtures verified (${manifest.actual.tag}, ${manifest.fixtures.reduce((sum, item) => sum + item.caseCount, 0)} cases).`,
);
