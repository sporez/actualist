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
  'scripts/rule-parity/cases.mjs',
  'scripts/rule-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const EXPECTED_TAG = oraclePin.tag;
const EXPECTED_COMMIT = oraclePin.commit;
const EXPECTED_VERSION = oraclePin.packageVersion;
const SCHEMA_VERSION = 1;
const contractName = 'rules-contract.json';
const manifestName = 'rules-manifest.json';
const expectedSourceHashes = {
  'packages/loot-core/src/server/transactions/transaction-rules.ts':
    'a6f08970af6f8d190c4c3b1a9ef2fad18c9f7e7211758a38d8bf02b9232c06ea',
  'packages/loot-core/src/server/rules/action.ts':
    '12cbd130c59634b2f711a7068c05e9de4dcef5dd71efe3601c3d64ad2bb68976',
  'packages/loot-core/src/server/rules/balanceOfFormula.ts':
    '6b29e6ea1c872984ba2bcc024eb9f17deae6d6c101d0ebb5590692623306e073',
  'packages/loot-core/src/server/rules/condition.ts':
    '18eb813e695d4d2312f6417cd134a966f8914d0954176a3329efae01ac55506f',
  'packages/loot-core/src/server/rules/handlebars-helpers.ts':
    '894aee77943f57c03a865fc5919d09c4e38172b964d03cac858edb56842e30b1',
  'packages/loot-core/src/server/rules/index.ts':
    'cf70324f000f82e027edcc2943115105c93b354abfbfeed3cf1bb749ad9fee39',
  'packages/loot-core/src/server/rules/rule-indexer.ts':
    '1383b98cc4221d1b7f30ec0c3fcd71541b5815a7d8cee90fdaf00ca493ae29b5',
  'packages/loot-core/src/server/rules/rule-utils.ts':
    '975ac1ac4e1ef8a31a0e17bcd8f80b7af8ae4ece2a02583ee25dbab72bf64d6d',
  'packages/loot-core/src/server/rules/rule.ts':
    '83aed782d93ce41dd406373668b182da05f4896750a0a12341aa8dcc647f44c7',
  'packages/loot-core/src/shared/rules.ts':
    'c15da6a851c58e8d4578ceccd6dd121ef85de3c69e9b280c91b97d3d067232df',
  'packages/loot-core/src/shared/months.ts':
    '2bec8ac7beca3a9f4bae07d7da1e12ef140c239d481059bf4b9b97617a8fe0a3',
  'packages/loot-core/src/shared/transactions.ts':
    '99563d32b2fcefa4a33e512fbdb4c3d9c5ba804e9fc9acd50054f2b58addd5c9',
  'packages/loot-core/src/shared/schedules.ts':
    '7019c15bffddf1c2d510c135fb5b01ac3220922325a1522d2f398c1ad1f4d1e2',
  'packages/loot-core/src/shared/formulas/customFunctions.ts':
    '7ef1b4bff4d5efae961b96fcdf308f5e7745748339ca9d9a700d05d63bfa8558',
  'packages/loot-core/src/server/schedules/app.ts':
    '9cc505fba24effd2564871da3db9c781df831a138d04bdfbeaf67f338c2e9dc4',
  'packages/loot-core/src/server/db/index.ts':
    '0b3d3ee68b571523cc8cd3a7044ade50e8afea5941bb54879f45643f92241a71',
  'packages/loot-core/src/server/formulas/bootstrap.ts':
    'bc7feb5b58602efac7778d286dd5972e6620112cd94ab6f20dbf60115d5daf59',
  'packages/loot-core/src/mocks/setup.ts':
    '1deb435399c7871a57baea5668474ad2e8290d0925f472a1b971a1832ec18b70',
};

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${EXPECTED_TAG}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('Rules');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-rules-check-'))
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
const runnerRelative = 'packages/loot-core/src/server/transactions/__actualist_rules_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-rules-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-rules-run-'));
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
  for (const failure of failures) console.error(`rules expectation: ${failure}`);
  const keptPath = join(tmpdir(), 'actualist-rules-failed-contract.json');
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
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/rule-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: SEED,
  today: TODAY,
  timeZone: TIME_ZONE,
  generatedCaseCount: generatedCount,
  namedCaseCount: namedCount,
  caseCount: records.length,
  amountUnits: 'integer minor units',
  execution: 'Actual transaction-rules runRules on an offline in-memory SQLite database; rules are inserted with insertRule and loaded with loadRules; schedules are created with createSchedule',
  scope: 'synthetic local rule evaluation only; no server round trip',
  normalization: [
    'ids Actual mints (new payees, split children) are uuid-N in creation order per case; setup ids are explicit',
    'rows of each dumped table are sorted by primary key and _ts columns are dropped',
    'the joined lookups _account, _account_name and _category_name are dropped from each output transaction',
    'amounts are never normalized',
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
    for (const difference of drift) console.error(`rules parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Rules parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated rules parity fixture (${oraclePin.tag}, ${namedCount} named, ${generatedCount} generated).`);
}
