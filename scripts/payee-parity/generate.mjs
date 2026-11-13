#!/usr/bin/env node

// Generates the payee fixture from Actual's own handlers at the pinned release.
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
import { CASES, TIME_ZONE, WORLD } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');
const SCHEMA_VERSION = 1;
const contractName = 'payees-contract.json';
const manifestName = 'payees-manifest.json';
const helperPaths = [
  'scripts/payee-parity/cases.mjs',
  'scripts/payee-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
// Pinned in the generator: a different Actual source fails before anything is written.
const expectedSourceHashes = {
  'packages/loot-core/src/server/payees/app.ts':
    'a981c54f585e900db7897f3c5165f43125bb8498a79a02a5c83636260c398f7a',
  'packages/loot-core/src/server/db/index.ts':
    '4e99b6c8e3b0bcd4c2dfbdd4aa7e93d00875558c1e150eab7d9c703617bafcd7',
  'packages/loot-core/src/server/models.ts':
    '83ae5d25aeab9c52c72988360e77be2b11a83faa22ca40ee56c93bbf8d9b8cd0',
  'packages/loot-core/src/server/preferences/app.ts':
    'aa89bc608f81ee6a1498d5e5d89d6c7cc4c57d6ff02be78d29f8cecf43c68ce2',
  'packages/loot-core/src/server/undo.ts':
    '2b664e329d843c8022f935d131b7a88a40f85b3e64904faed50f8aeffd5deafe',
  'packages/loot-core/src/shared/normalisation.ts':
    'a3eb2322f8cce7ecf06a4c87aae444cf34ad4838140a76afd014af84dc047dfb',
  'packages/loot-core/src/server/schedules/app.ts':
    'c7aaddb94d6293016a6dad16952a5b978abc6cb637b62909078ce92e03e04613',
  'packages/loot-core/src/server/transactions/transaction-rules.ts':
    '4a8cb6f400859e2614c3a74c2ccdd18835e0bf31f78b5e253a99567505497988',
  'packages/desktop-client/src/payees/mutations.ts':
    'fc50e7abe312bdf6b9244feae3f9795c2482c724979f04eb7beb9b09d1157e87',
  'packages/desktop-client/src/components/autocomplete/PayeeAutocomplete.tsx':
    '01aebf5063ede285d10712e8f3bbfb0641f46e09b6d38f164d39f556c373c63d',
  'packages/desktop-client/src/components/mobile/payees/MobilePayeeEditPage.tsx':
    '590302163c03890e35999b25ae8abb7689421c0398bd8b2cb8989da43c2213c9',
  'packages/desktop-client/src/components/mobile/payees/MobilePayeesPage.tsx':
    'af151f905c9db39f01fd49caa5421aaa3ac1572ee8834efc50cad7d8404b675e',
  'packages/desktop-client/src/components/payees/ManagePayees.tsx':
    '8139b3f70745dcccc477095e53a8a01bee002ca088591740741c7134fde25ac3',
  'packages/desktop-client/src/components/payees/CategoryLearning.tsx':
    'cbac98e8e027c6f645244692a20e7546ecc39a5997b06b14866caa2d9fc2057a',
  'packages/desktop-client/src/prefs/prefsSlice.ts':
    '1bd2bae3f44ed3883b020c183718ef1cd2e63c6989b8c51e6172e926edc38bd6',
};
const MINTED_ID = /^id\d+$/;
const EMBEDDED_MINTED_ID = /\bid\d+\b/;

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('Payees');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-payees-check-'))
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

const runnerRelative = 'packages/loot-core/src/server/payees/__actualist_payees_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-payees-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-payees-run-'));
const planPath = join(workDirectory, 'plan.json');
const outputPath = join(workDirectory, 'records.json');
const runner = readFileSync(join(scriptDirectory, 'oracle-runner.template'), 'utf8')
  .replace('__PLAN_PATH__', JSON.stringify(planPath))
  .replace('__OUTPUT_PATH__', JSON.stringify(outputPath));

let raw;
const started = Date.now();
try {
  writeFileSync(planPath, JSON.stringify({ world: WORLD, cases: CASES }));
  mkdirSync(temporaryDataDirectory, { recursive: true });
  writeFileSync(runnerPath, runner);
  run('node', [
    '.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/core',
    'vitest', '--run', runnerRelative.replace('packages/loot-core/', ''),
  ], checkout, { ...process.env, ACTUAL_DATA_DIR: temporaryDataDirectory, TZ: TIME_ZONE });
  raw = JSON.parse(readFileSync(outputPath, 'utf8'));
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(temporaryDataDirectory, { force: true, recursive: true });
  rmSync(workDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');
const oracleSeconds = ((Date.now() - started) / 1000).toFixed(1);

if (!Array.isArray(raw) || raw.length !== CASES.length) {
  throw new Error(`Oracle returned ${raw?.length} cases; the plan has ${CASES.length}`);
}
raw.forEach((record, index) => {
  if (record.id !== CASES[index].id) throw new Error(`Case order mismatch at ${index}: ${record.id}`);
});

// Actual's test setup mints ids as id1, id2, ... and restarts the counter per case. A
// string that is exactly such an id becomes uuid-N by first appearance in the case's
// serialized form; setup ids are explicit and no other value (names included) is
// rewritten. A minted id inside longer text would escape this rule, so it fails.
function withNormalizedIDs(value) {
  const names = new Map();
  const walk = node => {
    if (typeof node === 'string') {
      if (MINTED_ID.test(node)) {
        if (!names.has(node)) names.set(node, `uuid-${names.size + 1}`);
        return names.get(node);
      }
      if (EMBEDDED_MINTED_ID.test(node)) throw new Error(`Minted id inside text: ${node}`);
      return node;
    }
    if (Array.isArray(node)) return node.map(walk);
    if (node !== null && typeof node === 'object') {
      return Object.fromEntries(Object.entries(node).map(([key, child]) => [key, walk(child)]));
    }
    return node;
  };
  return walk(value);
}

// The net cell writes of a message list: the last value per (dataset, row, column).
function netWrites(messages) {
  const last = new Map();
  for (const message of messages) {
    last.set(JSON.stringify([message.dataset, message.row, message.column]), message.value);
  }
  return [...last.entries()]
    .map(([key, value]) => {
      const [dataset, row, column] = JSON.parse(key);
      return { dataset, row, column, value };
    })
    .sort((a, b) => (
      a.dataset < b.dataset ? -1 : a.dataset > b.dataset ? 1
        : a.row < b.row ? -1 : a.row > b.row ? 1
          : a.column < b.column ? -1 : a.column > b.column ? 1 : 0
    ));
}

// The seed world is identical for every case; its dump is recorded once.
const world = raw[0].world;
const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);
for (const record of raw) {
  if (!same(record.world, world)) throw new Error(`${record.id}: seeded world differs from the first case`);
}

const records = raw.map(record => {
  const output = { id: record.id, kind: record.kind, input: record.input };
  if (record.kind === 'read') {
    output.read = record.read;
    return withNormalizedIDs(output);
  }
  output.preferencesSeed = record.preferencesSeed;
  if (record.selectedExisting) output.selectedExisting = record.selectedExisting;
  output.handlerCall = record.handlerCall;
  output.handlerResult = record.handlerResult;
  if (record.handlerError !== null) output.handlerError = record.handlerError;
  output.messages = record.messages;
  output.writes = netWrites(record.messages);
  output.rows = record.rows;
  output.undo = record.undo;
  return withNormalizedIDs(output);
});

const caseIDs = records.map(record => record.id);
const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify({ tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion })},`,
  `  "syntheticData": ${JSON.stringify({ only: true })},`,
  `  "environment": ${JSON.stringify({ timeZone: TIME_ZONE })},`,
  `  "world": ${JSON.stringify(world)},`,
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
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/payee-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: null,
  timeZone: TIME_ZONE,
  caseCount: records.length,
  amountUnits: 'integer minor units',
  execution: 'Actual payee handlers (payee-create, payees-batch-change, payees-merge, preferences/save) on an offline in-memory SQLite database, called as the desktop client calls them, then one real undo',
  scope: 'synthetic local handler behavior only; no server round trip',
  normalization: [
    'ids Actual mints (id1, ... from the loot-core test uuid mock) are uuid-N by first appearance in the case; setup ids are explicit',
    'writes are the net cell writes of messages: the last value per dataset, row and column, sorted',
    'repeated CRDT messages are kept verbatim, in the order Actual wrote them',
    'names, values and amounts are never normalized',
    'undo is recorded and not replayed by PayeeOracleReplayTests',
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
    for (const difference of drift) console.error(`payee parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Payee parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated payee parity fixture (${oraclePin.tag}, ${records.length} cases, oracle ${oracleSeconds}s).`);
}
