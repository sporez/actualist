#!/usr/bin/env node

// Generates the Reports fixture from Actual's own report spreadsheets at the pinned release.
// Usage and flow: README.md.
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
import { CASES, TIME_ZONE, TODAY, WORLD } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');
const SCHEMA_VERSION = 1;
const contractName = 'reports-contract.json';
const manifestName = 'reports-manifest.json';
const helperPaths = [
  'scripts/report-parity/cases.mjs',
  'scripts/report-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
// Pinned in the generator: a different Actual source fails before anything is written.
const expectedSourceHashes = {
  'packages/desktop-client/src/components/reports/spreadsheets/net-worth-spreadsheet.ts':
    '712fe9b49e1b5a85b0ba2c45a474c5285f5da050d7e58a0348272bd50b86c4dd',
  'packages/desktop-client/src/components/reports/spreadsheets/cash-flow-spreadsheet.tsx':
    '4313ade40e83d7e1412a291b741cc2de57d8bb699afc5c271741894d3e4d8fcd',
  'packages/desktop-client/src/components/reports/spreadsheets/spending-spreadsheet.ts':
    '2b9afa135c5cd678287d8842647ea02d9e9f39693d7396394d50715ad04ec239',
  'packages/desktop-client/src/components/reports/spreadsheets/calendar-spreadsheet.ts':
    'bf873e73f92ab6ff7ca9c14940c0fd701791ae0a9be499ba9950969432b1de7f',
  'packages/desktop-client/src/components/reports/spreadsheets/makeQuery.ts':
    '97b13db65d4668fcab66edea41b010d60ac2c78a28cb0614feb8522adc790a33',
  'packages/desktop-client/src/components/reports/spreadsheets/budgetDataQuery.ts':
    '2a8a2557717a7558a316f69f2bca15c2b9828a2e37c4a6fbb822468ca54c50f2',
  'packages/desktop-client/src/components/reports/util.ts':
    '3b4e921eddcd303fd8d59343e74ed5b74fa607d8d66647799202835ca55f0f2a',
  'packages/desktop-client/src/components/reports/spendingAverageRange.ts':
    'fc9e8e153d144895298fc25aa42ec959f9646da6dd1b2aae6747a92e8b79c467',
  'packages/desktop-client/src/components/reports/ReportOptions.ts':
    '91764a80e5f847db4ea307530ed41f4bfc84db0afde56153f9abee5ec75f87c3',
  'packages/loot-core/src/server/aql/schema/index.ts':
    '0ca5282bb17655bbb27f876c5883a2af7f2fc2801e27ddae79606db833190366',
  'packages/loot-core/src/server/aql/views.ts':
    '8eaef3aa83330cee6eab6a7d53bb0f4c0b54976aaf98a995344d8a32e35f2663',
  'packages/loot-core/src/server/aql/exec.ts':
    '2302ee46e8c5103fceef81e1b7069bf5fad97d9ea17c705fa42cdf416195e120',
  'packages/loot-core/src/server/aql/compiler.ts':
    '6448895f96f1d01bf861aad524d7828b6f751fe5f824b7d88ba2039860dcdfc3',
  'packages/loot-core/src/shared/months.ts':
    '2bec8ac7beca3a9f4bae07d7da1e12ef140c239d481059bf4b9b97617a8fe0a3',
  'packages/loot-core/src/server/db/index.ts':
    '4e99b6c8e3b0bcd4c2dfbdd4aa7e93d00875558c1e150eab7d9c703617bafcd7',
  'packages/loot-core/src/server/transactions/transaction-rules.ts':
    '4a8cb6f400859e2614c3a74c2ccdd18835e0bf31f78b5e253a99567505497988',
  'packages/loot-core/vitest.config.ts':
    '849cf638625cadad9b2b4c3b962eb19c58e398c4236198d94cdb1162921a77ed',
};

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('Reports');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-reports-check-'))
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
if (packageVersion !== oraclePin.packageVersion) {
  throw new Error(`Expected @actual-app/core ${oraclePin.packageVersion}, found ${packageVersion}`);
}
for (const [path, expectedHash] of Object.entries(expectedSourceHashes)) {
  const sourcePath = join(checkout, path);
  if (!existsSync(sourcePath)) throw new Error(`Pinned source is missing: ${path}`);
  const actualHash = sha256(readFileSync(sourcePath));
  if (actualHash !== expectedHash) {
    throw new Error(`Pinned source hash mismatch for ${path}: ${actualHash}`);
  }
}

// The runner sits in loot-core's src so '../../desktop-client/src/...' reaches the spreadsheets.
const runnerRelative = 'packages/loot-core/src/__actualist_reports_oracle.test.ts';
const configRelative = 'packages/loot-core/vitest.actualist-reports.config.mts';
const runnerPath = join(checkout, runnerRelative);
const configPath = join(checkout, configRelative);
for (const [path, relativePath] of [[runnerPath, runnerRelative], [configPath, configRelative]]) {
  if (existsSync(path)) throw new Error(`Refusing to overwrite ${relativePath}`);
}
// cash-flow-spreadsheet.tsx is JSX, which loot-core's own vitest config does not compile.
const vitestConfig = `import { peggyLoader } from '@actual-app/vite-plugin-peggy';
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { globals: true, setupFiles: ['./src/mocks/setup.ts'], environment: 'node' },
  ssr: { resolve: { conditions: ['electron', 'module', 'node', 'development'] } },
  resolve: { conditions: ['electron', 'module', 'browser', 'development'] },
  plugins: [peggyLoader(), react()],
});
`;

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-reports-run-'));
const planPath = join(workDirectory, 'plan.json');
const outputPath = join(workDirectory, 'records.json');
const runner = Object.entries({ __PLAN_PATH__: planPath, __OUTPUT_PATH__: outputPath }).reduce(
  (text, [token, value]) => text.replace(token, JSON.stringify(value)),
  readFileSync(join(scriptDirectory, 'oracle-runner.template'), 'utf8'),
);
const yarn = ['.yarn/releases/yarn-4.17.1.cjs', 'workspace'];

let raw;
const started = Date.now();
try {
  writeFileSync(planPath, JSON.stringify({ world: WORLD, today: TODAY, cases: CASES }));
  writeFileSync(runnerPath, runner);
  writeFileSync(configPath, vitestConfig);
  run('node', [
    ...yarn, '@actual-app/core', 'vitest', '--run', '-c', 'vitest.actualist-reports.config.mts',
    runnerRelative.replace('packages/loot-core/', ''),
  ], checkout, { ...process.env, TZ: TIME_ZONE });
  raw = JSON.parse(readFileSync(outputPath, 'utf8'));
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(configPath, { force: true });
  rmSync(workDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');
const oracleSeconds = ((Date.now() - started) / 1000).toFixed(1);

const records = raw.records;
if (!Array.isArray(records) || records.length !== CASES.length) {
  throw new Error(`Oracle returned ${records?.length} cases; the plan has ${CASES.length}`);
}
records.forEach((record, index) => {
  if (record.id !== CASES[index].id) throw new Error(`Case order mismatch at ${index}: ${record.id}`);
});

const caseIDs = records.map(record => record.id);
const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify({ tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion })},`,
  `  "syntheticData": ${JSON.stringify({ only: true })},`,
  `  "environment": ${JSON.stringify({ timeZone: TIME_ZONE, today: TODAY })},`,
  `  "worlds": ${JSON.stringify(raw.worlds)},`,
  '  "cases": [',
  records.map(record => `    ${JSON.stringify(record)}`).join(',\n'),
  '  ]',
  '}',
].join('\n') + '\n';
const contractData = Buffer.from(contractText, 'utf8');
mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, contractName), contractData);

// Manifest paths name the pinned fixture location, never the temporary --check directory.
const logicalPath = name => relative(repositoryRoot, join(fixtureDirectory, name));
const manifestText = JSON.stringify({
  schemaVersion: SCHEMA_VERSION,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/report-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: null,
  timeZone: TIME_ZONE,
  caseCount: records.length,
  amountUnits: 'integer minor units (budget values are fractional as Actual returns them)',
  execution: 'Actual desktop client report spreadsheets (createSpreadsheet, cashFlowByDate, createSpendingSpreadsheet, calendarSpreadsheet) in loot-core vitest on an offline in-memory SQLite database, with the client send forwarded to the in-process handlers and the clock frozen',
  scope: 'synthetic local report behavior only; Actualist-only outputs and the Actual reports Actualist lacks are not generated (README.md)',
  normalization: [
    'dates the spreadsheets return as Date objects are recorded as yyyy-MM-dd or yyyy-MM text',
    'net worth and cash flow points carry the period they cover, derived with the same months.ts range functions the spreadsheet uses',
    'cash flow labels (JSX) and net worth display strings are dropped',
    'amounts, names and values are never normalized',
  ],
  sourceFiles: Object.keys(expectedSourceHashes).map(path => ({ path, sha256: sha256(readFileSync(join(checkout, path))) })),
  fixtures: [{
    path: logicalPath(contractName),
    sha256: sha256(contractData),
    caseCount: records.length,
    caseIDs,
  }],
  oracleOnly: [],
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
    for (const difference of drift) console.error(`report parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Report parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated report parity fixture (${oraclePin.tag}, ${records.length} cases, oracle ${oracleSeconds}s).`);
}
