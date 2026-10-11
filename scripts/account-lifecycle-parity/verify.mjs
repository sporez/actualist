#!/usr/bin/env node
// Checks the committed account lifecycle fixture without an oracle checkout or
// network: pin, fixture and manifest hashes, case list, and the recorded hashes
// of the generator, its schema, and the harness files.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import {
  oraclePin,
  pinnedFixtureDirectory,
  repositoryRoot,
} from '../parity/lib/oracle-pin.mjs';

const fixtureDirectory = pinnedFixtureDirectory('AccountLifecycle');
const manifestPath = join(fixtureDirectory, 'account-lifecycle-manifest.json');
const fixturePath = join(fixtureDirectory, 'account-lifecycle-oracle.json');
const failures = [];

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function repositoryFile(path) {
  return join(repositoryRoot, path);
}

if (!existsSync(manifestPath) || !existsSync(fixturePath)) {
  console.error(
    `Account lifecycle fixture files are missing under ${relative(repositoryRoot, fixtureDirectory)}`,
  );
  process.exit(1);
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const caseIDs = fixture.cases.map(item => item.id);

for (const field of ['tag', 'commit', 'packageVersion']) {
  if (manifest.actual?.[field] !== oraclePin[field]) {
    failures.push(
      `manifest actual.${field} is ${String(manifest.actual?.[field])}, pin is ${oraclePin[field]}`,
    );
  }
}
if (manifest.seed !== null) failures.push('manifest seed must be null');
if (fixture.syntheticDataOnly !== true) {
  failures.push('fixture does not declare syntheticDataOnly');
}

const committedFixturePath = relative(
  repositoryRoot,
  join(fixtureDirectory, 'account-lifecycle-oracle.json'),
);
if (manifest.fixture?.path !== committedFixturePath) {
  failures.push(`manifest fixture.path is ${String(manifest.fixture?.path)}`);
}
if (manifest.fixture?.sha256 !== sha256(fixturePath)) {
  failures.push('fixture sha256 differs from the manifest');
}
if (manifest.fixture?.caseCount !== caseIDs.length) {
  failures.push(`manifest caseCount is ${String(manifest.fixture?.caseCount)}, fixture has ${caseIDs.length}`);
}
if (JSON.stringify(manifest.fixture?.caseIDs) !== JSON.stringify(caseIDs)) {
  failures.push('manifest fixture.caseIDs differ from the fixture case order');
}
if (JSON.stringify(manifest.cases?.map(item => item.id)) !== JSON.stringify(caseIDs)) {
  failures.push('manifest cases differ from the fixture case order');
}

const generatorPath = manifest.generator?.path;
if (!generatorPath || sha256(repositoryFile(generatorPath)) !== manifest.generator.sha256) {
  failures.push(`generator ${String(generatorPath)} differs from the manifest sha256; regenerate`);
}
if (
  sha256(repositoryFile(manifest.generator.manifestSchemaPath)) !==
  manifest.generator.manifestSchemaSha256
) {
  failures.push('manifest schema differs from the recorded sha256; regenerate');
}

if (!Array.isArray(manifest.harnessFiles) || manifest.harnessFiles.length === 0) {
  failures.push('manifest records no harness files');
}
for (const file of manifest.harnessFiles ?? []) {
  if (!existsSync(repositoryFile(file.path))) {
    failures.push(`harness file is missing: ${file.path}`);
  } else if (sha256(repositoryFile(file.path)) !== file.sha256) {
    failures.push(`harness file differs from the manifest: ${file.path}; regenerate`);
  }
}

if (!Array.isArray(manifest.sourceFiles) || manifest.sourceFiles.length === 0) {
  failures.push('manifest records no oracle source files');
}

if (failures.length > 0) {
  console.error('Account lifecycle fixture verification failed:');
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(
  `Account lifecycle fixture verified (${manifest.actual.tag}, ${caseIDs.length} cases).`,
);
