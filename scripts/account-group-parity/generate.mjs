#!/usr/bin/env node

// Generates the account group fixture from Actual's own handlers at the pinned release.
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
const contractName = 'account-groups-contract.json';
const manifestName = 'account-groups-manifest.json';
const helperPaths = [
  'scripts/account-group-parity/cases.mjs',
  'scripts/account-group-parity/oracle-runner.template',
  'scripts/account-group-parity/tree-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
// Pinned in the generator: a different Actual source fails before anything is written.
const expectedSourceHashes = {
  'packages/loot-core/src/server/account-groups/app.ts':
    '5bb7c51820cd55adc4b23006ca4b912f2bcfc6d7663daa0cf899c57a66fd4ded',
  'packages/loot-core/src/server/db/index.ts':
    '4e99b6c8e3b0bcd4c2dfbdd4aa7e93d00875558c1e150eab7d9c703617bafcd7',
  'packages/loot-core/src/server/db/sort.ts':
    '16a8c0e90d4c5d9ac5c9b47256e121f2be93f5beb31aa8685711307912435041',
  'packages/loot-core/src/server/accounts/app.ts':
    'd2303dee45557d54ce21daa7ecfab49cba4440b334dd5abe1e1318ef5fb79e1d',
  'packages/loot-core/src/server/models.ts':
    '83ae5d25aeab9c52c72988360e77be2b11a83faa22ca40ee56c93bbf8d9b8cd0',
  'packages/loot-core/src/server/aql/schema/index.ts':
    '0ca5282bb17655bbb27f876c5883a2af7f2fc2801e27ddae79606db833190366',
  'packages/desktop-client/src/account-groups/mutations.ts':
    '949ad938c72fbfda85fc43c65500b805c9de98bbda98bab1760bd84f835b7725',
  'packages/desktop-client/src/accounts/mutations.ts':
    '5beb4df24b74049e4bd66ce39252d01dd7feb6317dda6d9a60ee042cf6077b9b',
  'packages/desktop-client/src/accounts/queries.ts':
    'aa5c375948a3571e553a77cb90ab32991dbe487051ea461ec3a1a4d10d03490f',
  'packages/desktop-client/src/components/modals/AccountGroupsModal/AccountGroupsModal.tsx':
    '7733210b14ad5728851f9684caef7a57e886c5c47da324c7ee7e9ea05aac7c5a',
  'packages/desktop-client/src/components/modals/AccountGroupsModal/AccountGroupRow.tsx':
    '9ea35cd80c3968123cb4e6acd9b330f7c061ee6b5a5513ee186dd4c901a72084',
  'packages/desktop-client/src/components/sidebar/redesign/useSidebarAccountTree.ts':
    '8097e8ff45bfa23b106699ec4db9cf8a37e462f6ff64c507ee5be2df7c8e394a',
};
const MINTED_ID = /^id\d+$/;
const EMBEDDED_MINTED_ID = /\bid\d+\b/;

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('AccountGroups');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-account-groups-check-'))
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

const lootRunnerRelative = 'packages/loot-core/src/server/account-groups/__actualist_account_groups_oracle.test.ts';
const treeRunnerRelative = 'packages/desktop-client/src/components/sidebar/redesign/__actualist_account_groups_tree_oracle.test.ts';
const lootRunnerPath = join(checkout, lootRunnerRelative);
const treeRunnerPath = join(checkout, treeRunnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-account-groups-oracle-data');
for (const [path, relativePath] of [[lootRunnerPath, lootRunnerRelative], [treeRunnerPath, treeRunnerRelative]]) {
  if (existsSync(path)) throw new Error(`Refusing to overwrite ${relativePath}`);
}

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-account-groups-run-'));
const planPath = join(workDirectory, 'plan.json');
const outputPath = join(workDirectory, 'records.json');
const treeInputPath = join(workDirectory, 'tree-input.json');
const treeOutputPath = join(workDirectory, 'tree-output.json');
const fill = (name, replacements) => Object.entries(replacements).reduce(
  (text, [token, value]) => text.replace(token, JSON.stringify(value)),
  readFileSync(join(scriptDirectory, name), 'utf8'),
);
const lootRunner = fill('oracle-runner.template', { __PLAN_PATH__: planPath, __OUTPUT_PATH__: outputPath });
const treeRunner = fill('tree-runner.template', { __INPUT_PATH__: treeInputPath, __OUTPUT_PATH__: treeOutputPath });
const yarn = ['.yarn/releases/yarn-4.17.1.cjs', 'workspace'];

let raw;
let treeReads;
const started = Date.now();
try {
  writeFileSync(planPath, JSON.stringify({ world: WORLD, today: TODAY, cases: CASES }));
  mkdirSync(temporaryDataDirectory, { recursive: true });
  // Run 1, loot-core: the handlers.
  writeFileSync(lootRunnerPath, lootRunner);
  run('node', [...yarn, '@actual-app/core', 'vitest', '--run', lootRunnerRelative.replace('packages/loot-core/', '')],
    checkout, { ...process.env, ACTUAL_DATA_DIR: temporaryDataDirectory, TZ: TIME_ZONE });
  raw = JSON.parse(readFileSync(outputPath, 'utf8'));

  // Run 2, desktop-client: the sidebar tree builder over what run 1 read.
  const treeInputs = raw.filter(record => record.treeInput).map(record => ({ id: record.id, ...record.treeInput }));
  writeFileSync(treeInputPath, JSON.stringify(treeInputs));
  writeFileSync(treeRunnerPath, treeRunner);
  run('node', [...yarn, '@actual-app/web', 'vitest', '--run', treeRunnerRelative.replace('packages/desktop-client/', ''), '--reporter=dot'],
    checkout, { ...process.env, TZ: TIME_ZONE });
  treeReads = new Map(JSON.parse(readFileSync(treeOutputPath, 'utf8')).map(entry => [entry.id, entry.read]));
} finally {
  rmSync(lootRunnerPath, { force: true });
  rmSync(treeRunnerPath, { force: true });
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
  if (record.kind.startsWith('read-')) {
    if (record.treeInput) {
      // failedCount is a bank-sync status count; no world account has a failed sync.
      const tree = treeReads.get(record.id);
      if (tree.failedCounts.onBudget !== 0 || tree.failedCounts.offBudget !== 0) {
        throw new Error(`${record.id}: unexpected failed sync accounts`);
      }
      const { failedCounts: _failed, accountCounts: _counts, ...read } = tree;
      output.read = read;
    } else {
      output.read = record.read;
    }
    return withNormalizedIDs(output);
  }
  output.handlerCall = record.handlerCall;
  output.handlerResult = record.handlerResult;
  if (record.handlerError !== null) output.handlerError = record.handlerError;
  output.messages = record.messages;
  output.writes = netWrites(record.messages);
  output.rows = record.rows;
  output.order = record.order;
  output.undo = record.undo;
  return withNormalizedIDs(output);
});

const caseIDs = records.map(record => record.id);
const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify({ tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion })},`,
  `  "syntheticData": ${JSON.stringify({ only: true })},`,
  `  "environment": ${JSON.stringify({ timeZone: TIME_ZONE, today: TODAY })},`,
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
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/account-group-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: null,
  timeZone: TIME_ZONE,
  caseCount: records.length,
  amountUnits: 'integer minor units',
  execution: 'Actual account group handlers (account-group-create, account-group-update, account-group-move, account-group-delete, account-update, account-groups-get, accounts-get) on an offline in-memory SQLite database, called as the desktop client calls them with the clock frozen, then one real undo; the sidebar tree comes from the desktop client selectors and buildAccountSide in a second vitest run',
  scope: 'synthetic local handler behavior only; no server round trip',
  normalization: [
    'ids Actual mints (id1, ... from the loot-core test uuid mock) are uuid-N by first appearance in the case; setup ids are explicit',
    'writes are the net cell writes of messages: the last value per dataset, row and column, sorted',
    'repeated CRDT messages are kept verbatim, in the order Actual wrote them',
    'names, values and amounts are never normalized',
    'undo is recorded and not replayed by AccountGroupOracleReplayTests',
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
    for (const difference of drift) console.error(`account group parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Account group parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated account group parity fixture (${oraclePin.tag}, ${records.length} cases, oracle ${oracleSeconds}s).`);
}
