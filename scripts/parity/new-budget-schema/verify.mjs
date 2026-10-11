#!/usr/bin/env node
// Checks the committed NewBudget fixture without an oracle checkout or network:
// the pin, fixture and harness file hashes, the recorded oracle source list, and
// the table and migration counts. `run.sh drift` regenerates from the oracle.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import {
  oraclePin,
  pinnedFixtureDirectory,
  repositoryRoot,
} from '../lib/oracle-pin.mjs';

// Keep in step with ORACLE_SOURCES in manifest.py.
const NAMED_ORACLE_SOURCES = [
  'packages/loot-core/src/server/budgetfiles/app.ts',
  'packages/loot-core/src/server/budget/base.ts',
  'packages/loot-core/src/server/update.ts',
  'packages/loot-core/src/server/migrate/migrations.ts',
  'packages/loot-core/default-db.sqlite',
];
const MIGRATION_PREFIX = 'packages/loot-core/migrations/';
const FIXTURE_FILES = ['starter-schema.json', 'migrations.txt'];

const fixtureDirectory = pinnedFixtureDirectory('NewBudget');
const manifestPath = join(fixtureDirectory, 'newbudget-manifest.json');
const failures = [];

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function repositoryFile(path) {
  return join(repositoryRoot, path);
}

if (!existsSync(manifestPath)) {
  console.error(
    `NewBudget manifest is missing: ${relative(repositoryRoot, manifestPath)}`,
  );
  process.exit(1);
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

for (const field of ['tag', 'commit', 'packageVersion']) {
  if (manifest.actual?.[field] !== oraclePin[field]) {
    failures.push(
      `manifest actual.${field} is ${String(manifest.actual?.[field])}, pin is ${oraclePin[field]}`,
    );
  }
}
if (manifest.seed !== null) failures.push('manifest seed must be null');

const fixtureNames = (manifest.fixtureFiles ?? []).map(item => item.path);
if (JSON.stringify(fixtureNames) !== JSON.stringify(FIXTURE_FILES)) {
  failures.push(`manifest fixtureFiles are ${JSON.stringify(fixtureNames)}`);
}
for (const file of manifest.fixtureFiles ?? []) {
  const path = join(fixtureDirectory, file.path);
  if (!existsSync(path)) {
    failures.push(`fixture file is missing: ${file.path}`);
  } else if (sha256(path) !== file.sha256) {
    failures.push(`fixture file differs from the manifest: ${file.path}; run drift`);
  }
}

const sourcePaths = (manifest.oracleSources ?? []).map(item => item.path);
for (const path of NAMED_ORACLE_SOURCES) {
  if (!sourcePaths.includes(path)) failures.push(`oracle source is not recorded: ${path}`);
}
if (new Set(sourcePaths).size !== sourcePaths.length) {
  failures.push('oracle source list has duplicate paths');
}
const migrationSources = sourcePaths.filter(path => path.startsWith(MIGRATION_PREFIX));
if (migrationSources.length === 0) failures.push('no migration sources are recorded');
if (sourcePaths.length !== NAMED_ORACLE_SOURCES.length + migrationSources.length) {
  failures.push('oracle source list has entries outside the named sources and migrations');
}

if (!Array.isArray(manifest.harnessFiles) || manifest.harnessFiles.length === 0) {
  failures.push('manifest records no harness files');
}
for (const file of manifest.harnessFiles ?? []) {
  if (!existsSync(repositoryFile(file.path))) {
    failures.push(`harness file is missing: ${file.path}`);
  } else if (sha256(repositoryFile(file.path)) !== file.sha256) {
    failures.push(`harness file differs from the manifest: ${file.path}; run generate and drift`);
  }
}

const starter = JSON.parse(readFileSync(join(fixtureDirectory, 'starter-schema.json'), 'utf8'));
const migrationIDs = readFileSync(join(fixtureDirectory, 'migrations.txt'), 'utf8')
  .split('\n')
  .filter(Boolean);
if (manifest.counts?.tables !== Object.keys(starter).length) {
  failures.push(`manifest counts.tables is ${String(manifest.counts?.tables)}, fixture has ${Object.keys(starter).length}`);
}
if (manifest.counts?.migrations !== migrationIDs.length) {
  failures.push(`manifest counts.migrations is ${String(manifest.counts?.migrations)}, fixture has ${migrationIDs.length}`);
}

if (failures.length > 0) {
  console.error('NewBudget fixture verification failed:');
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(
  `NewBudget fixture verified (${manifest.actual.tag}, ${Object.keys(starter).length} tables, ${migrationIDs.length} migrations).`,
);
