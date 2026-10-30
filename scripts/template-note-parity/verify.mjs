#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), '..', '..');
const fixtureRoot = pinnedFixtureDirectory('TemplateNotes');
const manifestPath = join(fixtureRoot, 'template-note-manifest.json');
const sha256 = data => createHash('sha256').update(data).digest('hex');

function fail(message) {
  console.error(`template note parity fixture error: ${message}`);
  console.error('Regenerate with ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/template-note-parity/generate.mjs.');
  process.exit(1);
}

let manifest;
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
} catch (error) {
  fail(`cannot read ${relative(root, manifestPath)}: ${error.message}`);
}
if (manifest.schemaVersion !== 1) fail('unexpected manifest schema');
for (const key of ['tag', 'commit', 'packageVersion']) {
  if (manifest.actual?.[key] !== oraclePin[key]) fail(`unexpected Actual ${key}`);
}
if (sha256(readFileSync(join(root, 'scripts/template-note-parity/generate.mjs'))) !== manifest.generator?.sha256) {
  fail('generator hash mismatch');
}
for (const file of [manifest.harness, ...(manifest.helpers ?? [])]) {
  if (sha256(readFileSync(resolve(root, file?.path ?? ''))) !== file?.sha256) fail(`hash mismatch: ${file?.path}`);
}
if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length === 0) fail('source hash list is incomplete');

const fixture = manifest.fixtures?.[0];
const fixturePath = resolve(root, fixture?.path ?? '');
if (!fixturePath.startsWith(fixtureRoot + '/')) fail('fixture path escapes pinned directory');
const data = readFileSync(fixturePath);
if (sha256(data) !== fixture.sha256) fail('fixture hash mismatch');

const contract = JSON.parse(data.toString('utf8'));
if (contract.oracle?.commit !== oraclePin.commit) fail('fixture oracle identity mismatch');
if (!Array.isArray(contract.cases) || contract.cases.length === 0) fail('fixture has no cases');
if (new Set(contract.cases.map(testCase => testCase.id)).size !== contract.cases.length) fail('duplicate case ids');
if (manifest.caseCount !== contract.cases.length || fixture.caseCount !== contract.cases.length) {
  fail('manifest case count does not match the fixture');
}
const stale = contract.cases.filter(testCase => testCase.stale).length;
console.log(`Template note parity fixture verified (${manifest.actual.tag}, ${contract.cases.length} cases, ${stale} stale).`);
