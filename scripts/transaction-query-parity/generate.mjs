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
import {
  buildPlan,
  expectationFailures,
  groupedQueryProjection,
  oracleOnlyEntries,
  ORACLE_ONLY_FIELDS,
  SEED,
  TIME_ZONE,
} from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');
const helperPaths = [
  'scripts/transaction-query-parity/cases.mjs',
  'scripts/transaction-query-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const EXPECTED_TAG = oraclePin.tag;
const EXPECTED_COMMIT = oraclePin.commit;
const EXPECTED_VERSION = oraclePin.packageVersion;
const SCHEMA_VERSION = 1;
const contractName = 'transaction-query-contract.json';
const manifestName = 'transaction-query-manifest.json';
const groupedName = 'grouped-query-cases.json';
const expectedSourceHashes = {
  'packages/loot-core/src/server/filters/app.ts':
    '3d7eb3bb3e838016c7dfa4c977f2373475d530b14964c78e54602b350731f1cc',
  'packages/loot-core/src/server/rules/condition.ts':
    '18eb813e695d4d2312f6417cd134a966f8914d0954176a3329efae01ac55506f',
  'packages/loot-core/src/server/transactions/transaction-rules.ts':
    'a6f08970af6f8d190c4c3b1a9ef2fad18c9f7e7211758a38d8bf02b9232c06ea',
  'packages/loot-core/src/server/aql/schema/executors.ts':
    'f8869a70b722beec361f1309e7a92f9b982b480314ae63c3b97ae161be93d375',
  'packages/loot-core/src/server/aql/schema/index.ts':
    '0ca5282bb17655bbb27f876c5883a2af7f2fc2801e27ddae79606db833190366',
  'packages/loot-core/src/server/db/mappings.ts':
    '6ec833744859b6e14f9a83a91cbfa99980bfe1b69750c567a146e7b2ff0573b9',
  'packages/loot-core/src/server/sync/serialization.ts':
    '0fef74e9f988e02a2d2098ba89f481f87d0717e53f20077399f2a90c62f339bf',
  'packages/loot-core/src/mocks/setup.ts':
    '1deb435399c7871a57baea5668474ad2e8290d0925f472a1b971a1832ec18b70',
  'packages/loot-core/vitest.config.ts':
    '9e003d80211596a03ac02b1d923629d5481faf9e54de02a292893390fca8245f',
  'packages/desktop-client/src/components/filters/FiltersMenu.tsx':
    '86751580a3b20231897f02f3475fd6977c7a6bc992dd68d4541780cf5e0997a6',
  'packages/desktop-client/src/components/filters/SavedFilterMenuButton.tsx':
    '4453bea5de864579101213d2c27df3567a52d1b0002c752641a538928390379e',
  'packages/desktop-client/src/queries/index.ts':
    'eff3ee339452006b13a4335848b7db0dc3364f5ad54776d8477340afa1b3c922',
  'packages/desktop-client/src/components/accounts/Account.tsx':
    '43e3f7311e7cc34e3c07c685e2bcbb8d090df4f269b3b3c1025e75007b81f970',
};

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${EXPECTED_TAG}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('TransactionQuery');
const groupedDirectory = pinnedFixtureDirectory('Splits');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-transaction-query-check-'))
  : resolve(argument('--output') ?? fixtureDirectory);
const groupedOutputRoot = checking || argument('--output') ? outputRoot : groupedDirectory;

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
const runnerRelative = 'packages/loot-core/src/server/transactions/__actualist_transaction_query_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-transaction-query-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-transaction-query-run-'));
const planPath = join(workDirectory, 'plan.json');
const contractTempPath = join(workDirectory, 'contract.json');
const template = readFileSync(join(scriptDirectory, 'oracle-runner.template'), 'utf8');
const runner = template
  .replace('__PLAN_PATH__', JSON.stringify(planPath))
  .replace('__CONTRACT_PATH__', JSON.stringify(contractTempPath));

let output;
const started = Date.now();
try {
  writeFileSync(planPath, JSON.stringify(plan));
  mkdirSync(temporaryDataDirectory, { recursive: true });
  writeFileSync(runnerPath, runner);
  run('node', [
    '.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/core',
    'vitest', '--run', runnerRelative.replace('packages/loot-core/', ''),
  ], checkout, { ...process.env, ACTUAL_DATA_DIR: temporaryDataDirectory, TZ: TIME_ZONE });
  output = JSON.parse(readFileSync(contractTempPath, 'utf8'));
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(temporaryDataDirectory, { force: true, recursive: true });
  rmSync(workDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');
const oracleSeconds = Math.round((Date.now() - started) / 1000);

const { worlds, records } = output;
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
  for (const failure of failures) console.error(`transaction query expectation: ${failure}`);
  const keptPath = join(tmpdir(), 'actualist-transaction-query-failed-contract.json');
  writeFileSync(keptPath, JSON.stringify(output, null, 1));
  console.error(`Synthetic records from the failed run kept at ${keptPath}; no fixture was written.`);
  process.exit(1);
}

// Manifest paths name the pinned fixture location, never the temporary --check directory.
const logicalPath = (directory, name) => relative(repositoryRoot, join(directory, name));
const caseIDs = records.map(record => record.id);
const oracleOnly = oracleOnlyEntries(plan);
const oraclePinRecord = { tag: EXPECTED_TAG, commit: EXPECTED_COMMIT, packageVersion: EXPECTED_VERSION };

const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify(oraclePinRecord)},`,
  `  "syntheticData": ${JSON.stringify({ only: true, timeZone: TIME_ZONE })},`,
  `  "worlds": {\n${Object.entries(worlds).map(([name, world]) => `    ${JSON.stringify(name)}: ${JSON.stringify(world)}`).join(',\n')}\n  },`,
  '  "cases": [',
  records.map(record => `    ${JSON.stringify(record)}`).join(',\n'),
  '  ]',
  '}',
].join('\n') + '\n';
const contractData = Buffer.from(contractText, 'utf8');
mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, contractName), contractData);

// Splits/grouped-query-cases.json: the Actualist-facing projection of the
// split-modes family, consumed by TransactionSplitQueryTests.
const groupedCases = records
  .map((record, index) => ({ record, planCase: plan.cases[index] }))
  .filter(({ planCase }) => planCase.family === 'splitmodes')
  .map(({ record, planCase }) => groupedQueryProjection(record, planCase));
const groupedText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify(oraclePinRecord)},`,
  '  "amountUnits": "integer minor units",',
  '  "notes": "Generated by scripts/transaction-query-parity/generate.mjs from real Actual queries over the synthetic rows of the splitmodes family; do not edit by hand.",',
  '  "cases": [',
  groupedCases.map(projected => `    ${JSON.stringify(projected)}`).join(',\n'),
  '  ]',
  '}',
].join('\n') + '\n';
const groupedData = Buffer.from(groupedText, 'utf8');
mkdirSync(groupedOutputRoot, { recursive: true });
writeFileSync(join(groupedOutputRoot, groupedName), groupedData);

const manifestText = JSON.stringify({
  schemaVersion: SCHEMA_VERSION,
  actual: oraclePinRecord,
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/transaction-query-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: SEED,
  timeZone: TIME_ZONE,
  familyCounts: Object.fromEntries(['condition', 'family', 'filter', 'splitmodes'].map(family => [family, records.filter(record => record.family === family).length])),
  caseCount: records.length,
  amountUnits: 'integer minor units; seeded dates are integer YYYYMMDD, conditions carry ISO day strings',
  execution: 'Actual filter handlers (filter-create, make-filters-from-conditions) and aqlQuery over an offline in-memory SQLite budget seeded from the plan worlds, in a vitest run with TZ pinned',
  scope: 'synthetic local data only; no server round trip',
  normalization: [
    'filter ids minted by uuid v4 are mocked with a counter reset per case and renamed uuid-<n> by first appearance within a case',
    'physical, grouped-root, displayed, context and unmatched id lists of the condition and family cases are sorted; the split-mode cases keep the executor order under an explicit desktop-client orderBy',
    'CRDT messages keep insertion order and drop the clock; table dumps are ordered by id',
    'amounts and dates are never normalized',
  ],
  sourceFiles: Object.entries(expectedSourceHashes).map(([path, expectedHash]) => ({
    path,
    sha256: expectedHash,
  })),
  fixtures: [
    {
      path: logicalPath(fixtureDirectory, contractName),
      sha256: sha256(contractData),
      caseCount: records.length,
      caseIDs,
    },
    {
      path: logicalPath(groupedDirectory, groupedName),
      sha256: sha256(groupedData),
      caseCount: groupedCases.length,
      caseIDs: groupedCases.map(projected => projected.id),
    },
  ],
  oracleOnly,
  oracleOnlyFields: ORACLE_ONLY_FIELDS,
  privacy: {
    syntheticOnly: true,
    containsServerCredentials: false,
    containsPersonalFinancialData: false,
  },
}, null, 2) + '\n';
writeFileSync(join(outputRoot, manifestName), manifestText);

if (checking) {
  const drift = compareWithCommitted(fixtureDirectory, outputRoot, [contractName, manifestName])
    .concat(compareWithCommitted(groupedDirectory, outputRoot, [groupedName]));
  rmSync(outputRoot, { recursive: true, force: true });
  if (drift.length > 0) {
    for (const difference of drift) console.error(`transaction query parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Transaction query parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated transaction query parity fixture (${oraclePin.tag}, ${records.length} cases, oracle ${oracleSeconds}s).`);
}
