#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const expected = {
  schemaVersion: 1,
  tag: 'v26.9.0',
  commit: '59fe126f637d858c061e1eeedbef5436c8f2225a',
  packageVersion: '26.9.0',
};
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const fixtureRoot = join(root, 'ActualistTests/Fixtures/ActualCore26_9_0/Reconciliation');
const manifestPath = join(fixtureRoot, 'reconciliation-manifest.json');

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function fail(message) {
  console.error(`reconciliation parity fixture error: ${message}`);
  console.error('Regenerate with scripts/reconciliation-parity/generate.mjs --actual-checkout <pinned-actual-v26.9.0>.');
  process.exit(1);
}

let manifest;
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
} catch (error) {
  fail(`cannot read ${relative(root, manifestPath)}: ${error.message}`);
}
if (manifest.schemaVersion !== expected.schemaVersion) fail('unexpected manifest schema');
for (const key of ['tag', 'commit', 'packageVersion']) {
  if (manifest.actual?.[key] !== expected[key]) fail(`unexpected Actual ${key}`);
}
if (manifest.amountUnits !== 'integer minor units') fail('amount units are not explicit');
if (manifest.lastReconciledStorage !== 'new Date().getTime().toString() milliseconds') {
  fail('last_reconciled storage contract changed');
}
const generatorPath = join(root, 'scripts/reconciliation-parity/generate.mjs');
if (sha256(readFileSync(generatorPath)) !== manifest.generator?.sha256) fail('generator hash mismatch');
if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length !== 9) {
  fail('source hash list is incomplete');
}
for (const source of manifest.sourceFiles) {
  if (typeof source.path !== 'string' || !/^[a-f0-9]{64}$/.test(source.sha256 ?? '')) {
    fail(`invalid source entry: ${JSON.stringify(source)}`);
  }
}
const fixturePath = resolve(root, manifest.fixture?.path ?? '');
if (!fixturePath.startsWith(fixtureRoot + '/')) fail('fixture path escapes pinned directory');
const data = readFileSync(fixturePath);
if (sha256(data) !== manifest.fixture?.sha256) fail('fixture hash mismatch');
const fixture = JSON.parse(data.toString('utf8'));
if (fixture.schemaVersion !== expected.schemaVersion || fixture.oracle?.commit !== expected.commit) {
  fail('fixture oracle identity mismatch');
}
if (!Array.isArray(fixture.cases) || fixture.cases.length !== manifest.fixture?.caseCount) {
  fail('fixture case count mismatch');
}
const caseIDs = new Set(fixture.cases.map(value => value.id));
for (const id of [
  'cleared-balance', 'finish', 'adjustment-rule-projection',
  'adjustment-rule-delete', 'lock', 'unlock',
]) {
  if (!caseIDs.has(id)) fail(`missing reviewed case: ${id}`);
}
if (caseIDs.size !== fixture.cases.length) fail('duplicate fixture case ids');
console.log(`Reconciliation parity fixture verified (${manifest.actual.tag}, ${fixture.cases.length} cases).`);
