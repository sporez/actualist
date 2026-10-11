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
import { buildPlan, expectationFailures, oracleOnlyEntries, SEED, TODAY, CURRENCY } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');
const helperPaths = [
  'scripts/budget-month-parity/cases.mjs',
  'scripts/budget-month-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const EXPECTED_TAG = oraclePin.tag;
const EXPECTED_COMMIT = oraclePin.commit;
const EXPECTED_VERSION = oraclePin.packageVersion;
const SCHEMA_VERSION = 1;
const contractName = 'budget-month-contract.json';
const manifestName = 'budget-month-manifest.json';
const expectedSourceHashes = {
  'packages/loot-core/src/server/budget/actions.ts':
    '5fa3915814c773ee998e6836e5fe7c5a562cad643b310a1ac74faad662ec3294',
  'packages/loot-core/src/server/budget/app.ts':
    '873e61d76d8023410a6a831d1e3e83c0002f9fd987077904afed867b4eb2fc0c',
  'packages/loot-core/src/server/budget/base.ts':
    'c70cc2d5386bc4628bae805b3a82f860b22747413c795cea7f6a87b8c930838b',
  'packages/loot-core/src/server/budget/envelope.ts':
    'bbd07cf2a56f03b5c14d61a50f0cba764f08370895a4c5c2a9cea825626ccdcd',
  'packages/loot-core/src/server/budget/tracking.ts':
    '630feb46acc09301759216838389dd8eb6af53fba22e454d1ef9c6c14e323ad9',
  'packages/loot-core/src/server/budget/util.ts':
    '8c905d864f676d1ab1a5f16abdcc5da4f4e3f47d119906c65c84f0398c44f185',
  'packages/loot-core/src/server/db/index.ts':
    '0b3d3ee68b571523cc8cd3a7044ade50e8afea5941bb54879f45643f92241a71',
  'packages/loot-core/src/server/mutators.ts':
    'f24756558fd2aadc3cbff1fd23514b5908ef6b319c1ad7d8eefeb5ee649f538f',
  'packages/loot-core/src/server/sync/index.ts':
    'f597760aed699ff0f696b2ec433c1d59588e7f2dd53f4aa6518713dfd76c99b8',
  'packages/loot-core/src/platform/server/sqlite/index.ts':
    '2fecae0cd47dd260be771d3a48b8ef5ec48378418c5f8667b8c14d6c95f9dc92',
  'packages/loot-core/src/platform/server/sqlite/index.electron.ts':
    '8fee26e68d2a07d028947d7b54380d03ad088f2d8ff3b606dd34798c84031ab7',
  'packages/loot-core/src/shared/months.ts':
    '2bec8ac7beca3a9f4bae07d7da1e12ef140c239d481059bf4b9b97617a8fe0a3',
  'packages/loot-core/src/mocks/setup.ts':
    '1deb435399c7871a57baea5668474ad2e8290d0925f472a1b971a1832ec18b70',
  'packages/desktop-client/src/components/budget/envelope/budgetsummary/ToBudgetMenu.tsx':
    '7c17f3efa6129d2619d6bc3d7b3e320798d63fd1dda4d5049ecb6c5cdc02ca07',
  'packages/desktop-client/src/components/budget/envelope/BalanceMenu.tsx':
    '684e0b9b08311e38af54a0f09e220176a352112d8e9c82d88af9455823a0af66',
  'packages/desktop-client/src/budget/mutations.ts':
    'e044f65a62975b7cc36c9b2bdd0e3351dd4b07dd3d90548d285769eb759008e2',
};

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${EXPECTED_TAG}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('BudgetMonth');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-budget-month-check-'))
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
const runnerRelative = 'packages/loot-core/src/server/budget/__actualist_budget_month_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-budget-month-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-budget-month-run-'));
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
  ], checkout, { ...process.env, ACTUAL_DATA_DIR: temporaryDataDirectory });
  records = JSON.parse(readFileSync(contractTempPath, 'utf8'));
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
  for (const failure of failures) console.error(`budget-month expectation: ${failure}`);
  const keptPath = join(tmpdir(), 'actualist-budget-month-failed-contract.json');
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
  `  "syntheticData": ${JSON.stringify({ only: true, accountIDs: ['checking', 'savings'], currencyCode: CURRENCY })},`,
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
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/budget-month-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: SEED,
  today: TODAY,
  generatedCaseCount: generatedCount,
  namedCaseCount: namedCount,
  caseCount: records.length,
  amountUnits: 'integer minor units',
  execution: 'Actual core handlers through runHandler on an offline in-memory SQLite database with the spreadsheet loaded; CRDT cells read from messages_crdt after each step',
  scope: 'synthetic local spreadsheet and CRDT output only; no server round trip',
  normalization: [
    'message timestamps and message ids are dropped',
    'cells of one step are sorted by dataset, row and column; writes to the same cell keep their write order',
    'sheet state is read after each step for the months at or after the step affectedFrom month',
    'a missing cell is recorded as null; the harness never substitutes a zero',
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
    for (const difference of drift) console.error(`budget-month parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Budget-month parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated budget-month parity fixture (${oraclePin.tag}, ${namedCount} named, ${generatedCount} generated).`);
}
