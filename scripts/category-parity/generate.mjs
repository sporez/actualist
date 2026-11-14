#!/usr/bin/env node

// Generates the category fixture from Actual's own handlers at the pinned release.
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
import { CASES, SHEET_MONTHS, TIME_ZONE, TODAY, WORLD } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');
const SCHEMA_VERSION = 1;
const contractName = 'categories-contract.json';
const manifestName = 'categories-manifest.json';
const helperPaths = [
  'scripts/category-parity/cases.mjs',
  'scripts/category-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
// Pinned in the generator: a different Actual source fails before anything is written.
const expectedSourceHashes = {
  'packages/loot-core/src/server/budget/app.ts':
    'dad317c2af3723a7ebb10269c67585b9f81d607f1a43593645bd35d3a6c389d8',
  'packages/loot-core/src/server/budget/base.ts':
    '0e55e0f309adb0cebb015ec92f56d95ebb385ce21093a8f32d3be0adc7e26f6e',
  'packages/loot-core/src/server/budget/actions.ts':
    '5fa3915814c773ee998e6836e5fe7c5a562cad643b310a1ac74faad662ec3294',
  'packages/loot-core/src/server/db/index.ts':
    '4e99b6c8e3b0bcd4c2dfbdd4aa7e93d00875558c1e150eab7d9c703617bafcd7',
  'packages/loot-core/src/server/db/sort.ts':
    '16a8c0e90d4c5d9ac5c9b47256e121f2be93f5beb31aa8685711307912435041',
  'packages/loot-core/src/server/db/mappings.ts':
    '6ec833744859b6e14f9a83a91cbfa99980bfe1b69750c567a146e7b2ff0573b9',
  'packages/loot-core/src/server/models.ts':
    '83ae5d25aeab9c52c72988360e77be2b11a83faa22ca40ee56c93bbf8d9b8cd0',
  'packages/loot-core/src/server/aql/schema/index.ts':
    '0ca5282bb17655bbb27f876c5883a2af7f2fc2801e27ddae79606db833190366',
  'packages/loot-core/src/server/undo.ts':
    '2b664e329d843c8022f935d131b7a88a40f85b3e64904faed50f8aeffd5deafe',
  'packages/desktop-client/src/budget/mutations.ts':
    'd0781dba39ddccd4de2cb5939d0559076741a91f272ad9c9921ca9507f1c01b9',
  'packages/desktop-client/src/budget/queries.ts':
    '2f731199e57259667817f12b60f24df6b9c3cc3960dbb0f1dcf0c4d88c70ef10',
  'packages/desktop-client/src/hooks/useDeleteCategoryFlow.ts':
    '2458ad6402c005cd7e01c04a7508089241b62f83e37ce51a89fb9094223a8063',
};
const MINTED_ID = /^id\d+$/;
const EMBEDDED_MINTED_ID = /\bid\d+\b/;

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('Categories');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-categories-check-'))
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

const runnerRelative = 'packages/loot-core/src/server/budget/__actualist_categories_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-categories-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-categories-run-'));
const planPath = join(workDirectory, 'plan.json');
const outputPath = join(workDirectory, 'records.json');
const runner = readFileSync(join(scriptDirectory, 'oracle-runner.template'), 'utf8')
  .replace('__PLAN_PATH__', JSON.stringify(planPath))
  .replace('__OUTPUT_PATH__', JSON.stringify(outputPath));

let raw;
const started = Date.now();
try {
  writeFileSync(planPath, JSON.stringify({ world: WORLD, today: TODAY, sheetMonths: SHEET_MONTHS, cases: CASES }));
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
  if (record.kind.startsWith('read-')) {
    if (record.stateRows) output.stateRows = record.stateRows;
    output.read = record.read;
    return withNormalizedIDs(output);
  }
  output.handlerCall = record.handlerCall;
  output.handlerResult = record.handlerResult;
  if (record.handlerError !== null) output.handlerError = record.handlerError;
  if (record.mustTransfer !== undefined) output.mustTransfer = record.mustTransfer;
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
  `  "environment": ${JSON.stringify({ timeZone: TIME_ZONE, today: TODAY, sheetMonths: SHEET_MONTHS })},`,
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
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/category-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: null,
  timeZone: TIME_ZONE,
  caseCount: records.length,
  amountUnits: 'integer minor units',
  execution: 'Actual category handlers (category-create, category-update, category-move, category-delete, category-group-create, category-group-update, category-group-move, category-group-delete, must-category-transfer, get-categories) on an offline in-memory SQLite database with a loaded envelope spreadsheet, called as the desktop client calls them with the clock frozen, then one real undo',
  scope: 'synthetic local handler behavior only; no server round trip',
  normalization: [
    'ids Actual mints (id1, ... from the loot-core test uuid mock) are uuid-N by first appearance in the case; setup ids are explicit',
    'writes are the net cell writes of messages: the last value per dataset, row and column, sorted',
    'repeated CRDT messages are kept verbatim, in the order Actual wrote them',
    'names, values and amounts are never normalized',
    'undo is recorded and not replayed by CategoryOracleReplayTests',
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
    for (const difference of drift) console.error(`category parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Category parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated category parity fixture (${oraclePin.tag}, ${records.length} cases, oracle ${oracleSeconds}s).`);
}
