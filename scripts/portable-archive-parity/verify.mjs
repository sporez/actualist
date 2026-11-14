#!/usr/bin/env node

// Checks the committed PortableArchive fixture without an oracle: manifest pins, generator and
// helper hashes, fixture and input ZIP hashes, and the shape of both digests. Regeneration is
// generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('PortableArchive');
const SCHEMA_VERSION = 1;
const helperPaths = [
  'scripts/portable-archive-parity/oracle-runner.template',
  'scripts/portable-archive-parity/produce-actualist-export.sh',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
  'scripts/parity/lib/table-digest.mjs',
];
const failures = [];
const note = message => failures.push(message);
const sha256 = data => createHash('sha256').update(data).digest('hex');
const sameJSON = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const read = name => readFileSync(join(fixtureDirectory, name));

const manifest = JSON.parse(read('portable-archive-manifest.json').toString('utf8'));
if (manifest.schemaVersion !== SCHEMA_VERSION) note(`manifest schemaVersion is ${manifest.schemaVersion}`);
const pin = { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion };
if (!sameJSON(manifest.actual, pin)) note('manifest actual pin does not match config/parity/oracle-pin.json');
if (manifest.generator?.sha256 !== sha256(readFileSync(join(dirname(scriptPath), 'generate.mjs')))) {
  note('generate.mjs changed since the manifest was written');
}
for (const helper of manifest.helpers ?? []) {
  if (sha256(readFileSync(join(repositoryRoot, helper.path))) !== helper.sha256) {
    note(`helper ${helper.path} changed since the manifest was written`);
  }
}
if (!sameJSON(helperPaths, (manifest.helpers ?? []).map(helper => helper.path))) {
  note('manifest helper list does not match verify.mjs helper list');
}
if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length === 0) note('manifest has no oracle source hashes');
if (manifest.privacy?.syntheticOnly !== true
    || manifest.privacy?.containsServerCredentials !== false
    || manifest.privacy?.containsPersonalFinancialData !== false) {
  note('manifest privacy block is not synthetic-only');
}

// Generated files and the input ZIPs.
const names = ['actual-export.zip', 'actual-export-digest.json', 'actualist-export-digest.json'];
const recorded = new Map((manifest.fixtures ?? []).map(entry => [entry.path, entry.sha256]));
for (const name of names) {
  const path = relative(repositoryRoot, join(fixtureDirectory, name));
  if (recorded.get(path) !== sha256(read(name))) note(`${name} does not match the manifest hash`);
}
if (manifest.inputs?.actualExportZip !== sha256(read('actual-export.zip'))) note('actual-export.zip does not match manifest inputs');
if (manifest.inputs?.actualistExportZip !== sha256(read('actualist-export.zip'))) {
  note('actualist-export.zip changed since the digests were generated; run generate.mjs');
}

// Digest shape.
const actual = JSON.parse(read('actual-export-digest.json').toString('utf8'));
const actualist = JSON.parse(read('actualist-export-digest.json').toString('utf8'));
const digests = {
  'actual-export-digest.json digest': actual.digest,
  'actualist-export-digest.json zip': actualist.zip,
  'actualist-export-digest.json afterActualImport': actualist.afterActualImport,
};
for (const [name, value] of Object.entries(digests)) {
  const tables = Object.entries(value?.tables ?? {});
  if (tables.length === 0) note(`${name}: no tables`);
  for (const [table, entry] of tables) {
    if (entry.count !== entry.lines.length) note(`${name}: ${table} count differs from its lines`);
    if (sha256(entry.lines.join('\n')) !== entry.hash) note(`${name}: ${table} hash differs from its lines`);
  }
}
for (const file of [actual, actualist]) {
  if (!sameJSON(file.oracle, pin)) note('digest oracle pin does not match config/parity/oracle-pin.json');
  if (!Array.isArray(file.balances) || file.balances.length === 0) note('digest has no balances');
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`portable archive parity: ${failure}`);
  process.exit(1);
}
console.log('Portable archive parity fixture hashes match.');
