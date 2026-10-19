#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertPinnedOracle,
  hasOracleRoot,
  oraclePin,
  ORACLE_ROOT_VARIABLE,
  pinnedFixtureDirectory,
  pinnedOracleRoot,
} from '../lib/oracle-pin.mjs';
import { compareWithCommitted } from '../lib/fixture-diff.mjs';
import { buildPlan, expectationFailures, SEED, TIME_ZONE } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..', '..');
const helperPaths = [
  'scripts/parity/sync-merkle/cases.mjs',
  'scripts/parity/sync-merkle/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const EXPECTED_TAG = oraclePin.tag;
const EXPECTED_COMMIT = oraclePin.commit;
const EXPECTED_VERSION = oraclePin.packageVersion;
const SCHEMA_VERSION = 1;
const contractName = 'sync-merkle-contract.json';
const manifestName = 'sync-merkle-manifest.json';
const expectedSourceHashes = {
  'packages/loot-core/src/server/sync/index.ts':
    'f597760aed699ff0f696b2ec433c1d59588e7f2dd53f4aa6518713dfd76c99b8',
  'packages/loot-core/src/server/sync/encoder.ts':
    '8ee36e5dd1002dcb0523cb4f8db03a4a7aacd8a757a1a3ddb43dc94614700076',
  'packages/loot-core/src/server/tests/mockSyncServer.ts':
    '4f51d99d9924d816a47b2bb1be9616ca41aa6ed694ea1928a90c45de08fae835',
  'packages/loot-core/src/server/__mocks__/post.ts':
    '2e8212fb58f5c8cf372acceac63ac77e4b3e9d890bc6e4168ffd71129c4b1717',
  'packages/loot-core/src/mocks/setup.ts':
    '1deb435399c7871a57baea5668474ad2e8290d0925f472a1b971a1832ec18b70',
  'packages/loot-core/src/server/prefs.ts':
    '4def4d5f7276ceda300fc239d3018e025613262368c6cfb0ac1606166d856850',
  'packages/crdt/src/crdt/merkle.ts':
    'b6be49084d47bdc2d9b349ccf35dc7a14e9a1d0bbffabdb309edfb9864eb09bd',
  'packages/crdt/src/crdt/timestamp.ts':
    '90d6c01ffeba8d25d5720cb3b1805f2c04e8a5535b9ba209416d44120fc885be',
};

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${EXPECTED_TAG}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('SyncMerkle');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-sync-merkle-check-'))
  : resolve(argument('--output') ?? fixtureDirectory);

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function run(command, args, cwd, environment) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    env: environment,
    maxBuffer: 256 * 1024 * 1024,
  });
  if (result.status !== 0) {
    process.stderr.write((result.stdout ?? '').slice(-20000));
    process.stderr.write((result.stderr ?? '').slice(-20000));
    throw new Error(`${command} ${args.join(' ')} failed with status ${result.status}`);
  }
  return result.stdout.trim();
}

const packageVersion = JSON.parse(
  readFileSync(join(checkout, 'packages/loot-core/package.json'), 'utf8'),
).version;
if (packageVersion !== EXPECTED_VERSION) {
  throw new Error(`Expected @actual-app/core ${EXPECTED_VERSION}, found ${packageVersion}`);
}
for (const [path, expectedHash] of Object.entries(expectedSourceHashes)) {
  const sourcePath = join(checkout, path);
  if (!existsSync(sourcePath)) throw new Error(`Pinned source is missing: ${path}`);
  const actualHash = sha256(readFileSync(sourcePath));
  if (actualHash !== expectedHash) {
    throw new Error(`Pinned source hash mismatch for ${path}: ${actualHash}`);
  }
}

const plan = buildPlan();
const runnerRelative = 'packages/loot-core/src/server/sync/__actualist_sync_merkle_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-sync-merkle-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-sync-merkle-run-'));
const planPath = join(workDirectory, 'plan.json');
const contractTempPath = join(workDirectory, 'contract.json');
const template = readFileSync(join(scriptDirectory, 'oracle-runner.template'), 'utf8');
const runner = template
  .replace('__PLAN_PATH__', JSON.stringify(planPath))
  .replace('__CONTRACT_PATH__', JSON.stringify(contractTempPath));

let records;
try {
  writeFileSync(planPath, JSON.stringify(plan));
  mkdirSync(temporaryDataDirectory, { recursive: true });
  writeFileSync(runnerPath, runner);
  run('node', [
    '.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/core',
    'vitest', '--run', runnerRelative.replace('packages/loot-core/', ''),
  ], checkout, { ...process.env, ACTUAL_DATA_DIR: temporaryDataDirectory, TZ: TIME_ZONE });
  ({ records } = JSON.parse(readFileSync(contractTempPath, 'utf8')));
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(temporaryDataDirectory, { force: true, recursive: true });
  rmSync(workDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');

if (!Array.isArray(records) || records.length !== plan.cases.length) {
  throw new Error(`Oracle returned ${records?.length} cases; the plan has ${plan.cases.length}`);
}
const failures = [];
records.forEach((record, index) => {
  const planned = plan.cases[index];
  if (record.id !== planned.id) throw new Error(`Case order mismatch at ${index}: ${record.id}`);
  for (const failure of expectationFailures(record, planned)) {
    failures.push(`${record.id}: ${failure}`);
  }
});
if (failures.length > 0) {
  for (const failure of failures) console.error(`sync merkle expectation: ${failure}`);
  console.error('No fixture was written.');
  process.exit(1);
}

// Manifest paths name the pinned fixture location, never the temporary --check directory.
const logicalPath = name => relative(repositoryRoot, join(fixtureDirectory, name));
const caseIDs = records.map(record => record.id);
const generatedCount = records.filter(record => record.source === 'generated').length;
const namedCount = records.length - generatedCount;
const outcomes = {};
for (const record of records) outcomes[record.result.outcome] = (outcomes[record.result.outcome] ?? 0) + 1;

const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify({ tag: EXPECTED_TAG, commit: EXPECTED_COMMIT, packageVersion: EXPECTED_VERSION })},`,
  `  "syntheticData": ${JSON.stringify({ only: true })},`,
  `  "environment": ${JSON.stringify({ timeZone: TIME_ZONE })},`,
  `  "message": ${JSON.stringify({ dataset: plan.dataset, column: plan.column, clientNode: plan.clientNode, groupId: plan.groupId, fileId: plan.fileId })},`,
  '  "cases": [',
  records.map(record => `    ${JSON.stringify(record)}`).join(',\n'),
  '  ]',
  '}',
].join('\n') + '\n';
const contractData = Buffer.from(contractText, 'utf8');
mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, contractName), contractData);

const manifestText = JSON.stringify({
  schemaVersion: SCHEMA_VERSION,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/parity/sync-merkle/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: SEED,
  timeZone: TIME_ZONE,
  generatedCaseCount: generatedCount,
  namedCaseCount: namedCount,
  caseCount: records.length,
  execution: 'Actual fullSync (packages/loot-core/src/server/sync/index.ts) on an in-memory SQLite client database against the upstream mockSyncServer /sync/sync handler, with the Date clock frozen; setup messages are applied with applyMessages and pushed to the mock server with the sync encoder; mid-sync events run when the Nth /sync/sync request arrives, before the mock server processes it',
  scope: 'synthetic payee-name messages only; no real server, no encryption',
  outcomes,
  normalization: [
    'every recorded list (sentTimestamps, receivedTimestamps, serverTimestamps, clientTimestamps, clientPayees, serverMessagesFromClientCommits) is { count, sha256, items? }; items (the sorted entries) is present only when count <= 20',
    'sha256 is the lowercase hex SHA-256 of the UTF-8 string made by sorting the entries with the default JS string sort and joining them with a newline (no trailing newline); the empty list hashes the empty string',
    'a timestamp list entry is the timestamp string; a clientPayees entry is id + tab + name',
    'sentCount is dropped: it equals sentTimestamps.count',
    'requests are in arrival order; since is the request since field',
    'mintedCommits are the timestamps Timestamp.send() produced for planned client commits that actually ran (an event keyed to a request that never happened mints nothing)',
    'serverTimestamps holds real messages only; a phantom merkle entry has no message',
    'out-of-sync is a SyncError with reason out-of-sync; any other thrown or returned error is error:<message>',
  ],
  sourceFiles: Object.entries(expectedSourceHashes).map(([path, expectedHash]) => ({
    path,
    sha256: expectedHash,
  })),
  fixtures: [{
    path: logicalPath(contractName),
    sha256: sha256(contractData),
    caseCount: records.length,
    caseIDs,
  }],
  privacy: {
    syntheticOnly: true,
    containsServerCredentials: false,
    containsPersonalFinancialData: false,
  },
}, null, 2) + '\n';
writeFileSync(join(outputRoot, manifestName), manifestText);

if (checking) {
  const drift = compareWithCommitted(fixtureDirectory, outputRoot, [contractName, manifestName]);
  rmSync(outputRoot, { recursive: true, force: true });
  if (drift.length > 0) {
    for (const difference of drift) console.error(`sync merkle parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Sync merkle parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated sync merkle parity fixture (${oraclePin.tag}, ${namedCount} named, ${generatedCount} generated).`);
}
