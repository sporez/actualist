#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';

const expected = {
  schemaVersion: 1,
  tag: oraclePin.tag,
  commit: oraclePin.commit,
  packageVersion: oraclePin.packageVersion,
};
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const fixtureRoot = pinnedFixtureDirectory('Reconciliation');
const manifestPath = join(fixtureRoot, 'reconciliation-manifest.json');

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function fail(message) {
  console.error(`reconciliation parity fixture error: ${message}`);
  console.error(
    'Regenerate with ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/reconciliation-parity/generate.mjs.',
  );
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
if (manifest.seed !== null) fail('manifest seed must be null for this deterministic harness');
if (manifest.amountUnits !== 'integer minor units') fail('amount units are not explicit');
if (manifest.lastReconciledStorage !== 'new Date().getTime().toString() milliseconds') {
  fail('last_reconciled storage contract changed');
}
const generatorPath = join(root, 'scripts/reconciliation-parity/generate.mjs');
if (sha256(readFileSync(generatorPath)) !== manifest.generator?.sha256) fail('generator hash mismatch');
if (!Array.isArray(manifest.helpers) || manifest.helpers.length === 0) {
  fail('manifest does not record the helper scripts it depends on');
}
for (const helper of manifest.helpers) {
  const helperPath = resolve(root, helper.path ?? '');
  let data;
  try {
    data = readFileSync(helperPath);
  } catch (error) {
    fail(`cannot read helper ${helper.path}: ${error.message}`);
  }
  if (sha256(data) !== helper.sha256) fail(`helper hash mismatch: ${helper.path}`);
}
if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length !== 9) {
  fail('source hash list is incomplete');
}
for (const source of manifest.sourceFiles) {
  if (typeof source.path !== 'string' || !/^[a-f0-9]{64}$/.test(source.sha256 ?? '')) {
    fail(`invalid source entry: ${JSON.stringify(source)}`);
  }
}
if (!Array.isArray(manifest.evidenceSourceFiles) || manifest.evidenceSourceFiles.length !== 6) {
  fail('evidence source hash list is incomplete');
}
for (const source of manifest.evidenceSourceFiles) {
  if (typeof source.path !== 'string' || !/^[a-f0-9]{64}$/.test(source.sha256 ?? '')) {
    fail(`invalid evidence source entry: ${JSON.stringify(source)}`);
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
if (manifest.caseCount !== fixture.cases.length) fail('manifest caseCount is not the fixture case count');
const caseIDs = new Set(fixture.cases.map(value => value.id));
for (const id of [
  'cleared-balance', 'finish', 'adjustment-rule-projection',
  'adjustment-rule-delete', 'lock', 'unlock',
  'done-nonzero-difference', 'adjustment-rule-clears-notes', 'unlock-split-member',
  'unlock-split-parent', 'unlock-split-member-unreconciled-parent', 'unlock-simple-row',
]) {
  if (!caseIDs.has(id)) fail(`missing reviewed case: ${id}`);
}
if (caseIDs.size !== fixture.cases.length) fail('duplicate fixture case ids');
for (const value of fixture.cases) {
  if (value.input === null || typeof value.input !== 'object') {
    fail(`case ${value.id} does not record its input`);
  }
}
// Oracle uuid-mock ids and uuid-v4 values must not survive normalization.
if (/"(id|parentID|parent_id)":\s*"(temp)?id\d+"|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/.test(data.toString('utf8'))) {
  fail('un-normalized generated id in the reconciliation fixture');
}
const done = fixture.cases.find(value => value.id === 'done-nonzero-difference');
if (done?.value?.lastReconciledStamp?.evidence !== 'source-guard, not executed') {
  fail('done-nonzero-difference must label its Done stamp as source-guard evidence');
}
const rulesCase = fixture.cases.find(value => value.id === 'adjustment-rule-clears-notes');
if (!rulesCase?.input?.ruleEngineOutput || !('notes' in rulesCase.input.ruleEngineOutput)) {
  fail('adjustment-rule-clears-notes must record the loot-core rules output');
}
// The unlock cases ran on real rows: the read-back must agree with what was sent.
for (const id of ['unlock-split-member', 'unlock-split-parent', 'unlock-split-member-unreconciled-parent', 'unlock-simple-row']) {
  const unlock = fixture.cases.find(value => value.id === id);
  const readback = unlock?.readback;
  if (!readback?.before || !readback?.after || !Array.isArray(readback.changed)) {
    fail(`${id} must record the read-back of every row's reconciled flag`);
  }
  const ids = Object.keys(readback.before);
  if (JSON.stringify(ids) !== JSON.stringify(Object.keys(readback.after))) fail(`${id} read-back rows differ`);
  const changed = ids.filter(rowID => readback.before[rowID] !== readback.after[rowID]);
  if (JSON.stringify(changed) !== JSON.stringify(readback.changed)) fail(`${id} changed list disagrees with the read-back`);
  for (const entry of unlock.value ?? []) {
    if (readback.after[entry.id] !== false) fail(`${id} sent an unlock for ${entry.id} that did not stick`);
  }
  if (!Array.isArray(unlock.input?.groupedQueryResult) || unlock.input.groupedQueryResult.length === 0) {
    fail(`${id} must record the real grouped query result`);
  }
}
console.log(`Reconciliation parity fixture verified (${manifest.actual.tag}, ${fixture.cases.length} cases).`);
