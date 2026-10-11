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
} from '../parity/lib/oracle-pin.mjs';
import { compareWithCommitted } from '../parity/lib/fixture-diff.mjs';
import { buildPlan, expectationFailures, oracleOnlyEntries, SEED, TODAY, TIME_ZONE } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');
const helperPaths = [
  'scripts/bank-sync-parity/cases.mjs',
  'scripts/bank-sync-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const EXPECTED_TAG = oraclePin.tag;
const EXPECTED_COMMIT = oraclePin.commit;
const EXPECTED_VERSION = oraclePin.packageVersion;
const SCHEMA_VERSION = 1;
const contractName = 'bank-sync-contract.json';
const manifestName = 'bank-sync-manifest.json';
const expectedSourceHashes = {
  'packages/loot-core/src/server/accounts/sync.ts':
    '5561e484d09691308640864ece5e3c3ec07365d68bb0ed4e08f01e18ed364a0f',
  'packages/loot-core/src/server/accounts/title/index.ts':
    '93c4b8ccfa180d9169229188b584f56928f828f40be166d6ff3a94cf87d0a568',
  'packages/loot-core/src/server/accounts/title/lower-case.ts':
    'ee1254d26e85b854ad413237a97fee2baf6901c1fb8a67cd6d2efe293e68798a',
  'packages/loot-core/src/server/accounts/title/specials.ts':
    'e48d6ccb1cd3a8581ee7e8e8f76c432f032d4b50677149b3167445751548736c',
  'packages/loot-core/src/server/accounts/payees.ts':
    '81178670a00320653fce0205d06f1d3a6f7b4062ce656dbb4477c42931e84b7d',
  'packages/loot-core/src/server/transactions/index.ts':
    '2c32a9e4a3f54da01dd54d9a141abaef9f3740daa6900640f804da17db9e6c02',
  'packages/loot-core/src/server/transactions/transfer.ts':
    '309ebae609b20dee6053bc0a84e80e310a0d53fd4aed7c284d7e4379c9305701',
  'packages/loot-core/src/server/transactions/transaction-rules.ts':
    'a6f08970af6f8d190c4c3b1a9ef2fad18c9f7e7211758a38d8bf02b9232c06ea',
  'packages/loot-core/src/server/util/custom-sync-mapping.ts':
    'a0b3da04d1c732c3299dbb386c90e73aa71a02dc6b5984775eded82fa6e3c235',
  'packages/loot-core/src/server/db/index.ts':
    '0b3d3ee68b571523cc8cd3a7044ade50e8afea5941bb54879f45643f92241a71',
  'packages/loot-core/src/shared/transactions.ts':
    '99563d32b2fcefa4a33e512fbdb4c3d9c5ba804e9fc9acd50054f2b58addd5c9',
  'packages/loot-core/src/shared/util.ts':
    'f2ba71c3ba432082239dca0a48a79d8b1328ea4d258dfd4aeebb4ac43665c07d',
  'packages/loot-core/src/shared/months.ts':
    '2bec8ac7beca3a9f4bae07d7da1e12ef140c239d481059bf4b9b97617a8fe0a3',
  'packages/loot-core/src/server/schedules/app.ts':
    '9cc505fba24effd2564871da3db9c781df831a138d04bdfbeaf67f338c2e9dc4',
  'packages/loot-core/src/server/tests/mockSyncServer.ts':
    '4f51d99d9924d816a47b2bb1be9616ca41aa6ed694ea1928a90c45de08fae835',
  'packages/loot-core/src/mocks/setup.ts':
    '1deb435399c7871a57baea5668474ad2e8290d0925f472a1b971a1832ec18b70',
  'packages/loot-core/src/server/rules/action.ts':
    '12cbd130c59634b2f711a7068c05e9de4dcef5dd71efe3601c3d64ad2bb68976',
  'packages/loot-core/src/server/rules/rule.ts':
    '83aed782d93ce41dd406373668b182da05f4896750a0a12341aa8dcc647f44c7',
  'packages/loot-core/src/server/rules/index.ts':
    'cf70324f000f82e027edcc2943115105c93b354abfbfeed3cf1bb749ad9fee39',
};

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${EXPECTED_TAG}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('BankSync');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-bank-sync-check-'))
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
const runnerRelative = 'packages/loot-core/src/server/transactions/__actualist_bank_sync_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-bank-sync-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-bank-sync-run-'));
const planPath = join(workDirectory, 'plan.json');
const contractTempPath = join(workDirectory, 'contract.json');
const template = readFileSync(join(scriptDirectory, 'oracle-runner.template'), 'utf8');
const runner = template
  .replace('__PLAN_PATH__', JSON.stringify(planPath))
  .replace('__CONTRACT_PATH__', JSON.stringify(contractTempPath));

let records;
let worldTables;
try {
  writeFileSync(planPath, JSON.stringify(plan));
  mkdirSync(temporaryDataDirectory, { recursive: true });
  writeFileSync(runnerPath, runner);
  run('node', [
    '.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/core',
    'vitest', '--run', runnerRelative.replace('packages/loot-core/', ''),
  ], checkout, { ...process.env, ACTUAL_DATA_DIR: temporaryDataDirectory, TZ: TIME_ZONE });
  ({ records, worldTables } = JSON.parse(readFileSync(contractTempPath, 'utf8')));
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
  for (const failure of failures) console.error(`bank sync expectation: ${failure}`);
  const keptPath = join(tmpdir(), 'actualist-bank-sync-failed-contract.json');
  writeFileSync(keptPath, JSON.stringify(records, null, 1));
  console.error(`Synthetic records from the failed run kept at ${keptPath}; no fixture was written.`);
  process.exit(1);
}

// Manifest paths name the pinned fixture location, never the temporary --check directory.
const logicalPath = name => relative(repositoryRoot, join(fixtureDirectory, name));
const caseIDs = records.map(record => record.id);
const generatedCount = records.filter(record => record.source === 'generated').length;
const namedCount = records.length - generatedCount;
const oracleOnly = oracleOnlyEntries(plan);

const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify({ tag: EXPECTED_TAG, commit: EXPECTED_COMMIT, packageVersion: EXPECTED_VERSION })},`,
  `  "syntheticData": ${JSON.stringify({ only: true })},`,
  `  "environment": ${JSON.stringify({ today: TODAY, timeZone: TIME_ZONE })},`,
  `  "world": ${JSON.stringify(plan.world)},`,
  `  "worldTables": ${JSON.stringify(worldTables)},`,
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
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/bank-sync-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: SEED,
  today: TODAY,
  timeZone: TIME_ZONE,
  generatedCaseCount: generatedCount,
  namedCaseCount: namedCount,
  caseCount: records.length,
  amountUnits: 'integer minor units in reconcile calls and recorded rows; provider downloads carry SimpleFIN decimal strings',
  execution: 'Actual reconcileTransactions (isBankSyncAccount false for file imports, true for a direct provider call) and simpleFinBatchSync over a mocked provider response (the full bank-sync path including the first-sync Starting Balance row), on an offline in-memory SQLite database; rules are inserted with insertRule and loaded with loadRules; schedules are created with createSchedule',
  scope: 'synthetic local reconcile only; no server round trip',
  callKinds: { csv: 'reconcileTransactions, isBankSyncAccount false', bank: 'reconcileTransactions, isBankSyncAccount true', simplefin: 'simpleFinBatchSync, mocked provider response' },
  normalization: [
    'ids Actual mints (new payees, new rows, transfer legs) are uuid-N by first appearance in result then after-tables, per case; setup ids are explicit',
    'rows of each dumped table are sorted by primary key; _ts and sort_order columns are dropped (sort_order derives from the fake clock)',
    'transactions are dumped from v_transactions_internal with public field names, including deleted rows and split children, with dates as ISO days',
    'the input dump is the starter schema after setup, before the call; the after dump is the same tables after the call',
    'result is the reconcile result (added, updated, updatedPreview) or the simpleFinBatchSync result array; updatedPreview.existing.amount is upstream\'s decimal amount',
    'amounts in recorded rows are never normalized',
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
  oracleOnly,
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
    for (const difference of drift) console.error(`bank sync parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Bank sync parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated bank sync parity fixture (${oraclePin.tag}, ${namedCount} named, ${generatedCount} generated).`);
}
