#!/usr/bin/env node

// Generates the undo fixture from Actual's own handlers at the pinned release.
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
import { CASES, PAYEE_UNDO_OMITTED, PAYEE_UNDO_REPLAYED, SHEET_MONTHS, TIME_ZONE, TODAY, WORLD } from './cases.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');
const SCHEMA_VERSION = 1;
const contractName = 'undo-contract.json';
const manifestName = 'undo-manifest.json';
const helperPaths = [
  'scripts/undo-parity/cases.mjs',
  'scripts/undo-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
// Pinned in the generator: a different Actual source fails before anything is written.
const expectedSourceHashes = {
  'packages/loot-core/src/server/undo.ts':
    '2b664e329d843c8022f935d131b7a88a40f85b3e64904faed50f8aeffd5deafe',
  'packages/loot-core/src/server/mutators.ts':
    'f24756558fd2aadc3cbff1fd23514b5908ef6b319c1ad7d8eefeb5ee649f538f',
  'packages/loot-core/src/server/budget/actions.ts':
    '5fa3915814c773ee998e6836e5fe7c5a562cad643b310a1ac74faad662ec3294',
  'packages/loot-core/src/server/budget/app.ts':
    'dad317c2af3723a7ebb10269c67585b9f81d607f1a43593645bd35d3a6c389d8',
  'packages/loot-core/src/server/db/index.ts':
    '4e99b6c8e3b0bcd4c2dfbdd4aa7e93d00875558c1e150eab7d9c703617bafcd7',
  'packages/loot-core/src/server/transactions/app.ts':
    '6fbfa6064e60e2817fa9870a8e1762a69ee10d1b87893f40ab49dd683cac767c',
  'packages/loot-core/src/server/transactions/index.ts':
    '2c32a9e4a3f54da01dd54d9a141abaef9f3740daa6900640f804da17db9e6c02',
  'packages/loot-core/src/server/transactions/transfer.ts':
    '309ebae609b20dee6053bc0a84e80e310a0d53fd4aed7c284d7e4379c9305701',
  'packages/loot-core/src/server/payees/app.ts':
    'a981c54f585e900db7897f3c5165f43125bb8498a79a02a5c83636260c398f7a',
  'packages/loot-core/src/shared/transactions.ts':
    '99563d32b2fcefa4a33e512fbdb4c3d9c5ba804e9fc9acd50054f2b58addd5c9',
  'packages/loot-core/src/shared/util.ts':
    '976e0d398a1074dfc7f4909e17be73754396ab189f961c7f1341eda19620bdbe',
  'packages/desktop-client/src/budget/mutations.ts':
    'd0781dba39ddccd4de2cb5939d0559076741a91f272ad9c9921ca9507f1c01b9',
  'packages/desktop-client/src/payees/mutations.ts':
    'fc50e7abe312bdf6b9244feae3f9795c2482c724979f04eb7beb9b09d1157e87',
  'packages/desktop-client/src/components/autocomplete/PayeeAutocomplete.tsx':
    '01aebf5063ede285d10712e8f3bbfb0641f46e09b6d38f164d39f556c373c63d',
  'packages/desktop-client/src/components/mobile/budget/BudgetCell.tsx':
    '1365f98d4fb150e663eeb54aa133e307cdbf0f8d5ac7caef0da3f324ab5530f8',
  'packages/desktop-client/src/components/mobile/budget/ExpenseCategoryListItem.tsx':
    '6ff7c9e752dd2bf92bdf6ca3b9aa6ca122a4f5bf11e1d3b82bfae686e67e8d9d',
  'packages/desktop-client/src/components/mobile/transactions/TransactionEdit.tsx':
    'cef43b37b9fa7a0195545354b90a155fc80cbfedbab41af59b512573dc676553',
  'packages/desktop-client/src/components/mobile/transactions/TransactionList.tsx':
    'e45714eeb60a0c95744b03872f9fde1c1c5b15743b4d2313cea3ac0c22b8e6fc',
  'packages/desktop-client/src/hooks/useTransactionBatchActions.ts':
    'c29e148adeeb315e6cf6c14f64f2a267fb67d9198e1cd10da1689c05070895b5',
};
const MINTED_ID = /^id\d+$/;
const EMBEDDED_MINTED_ID = /\bid\d+\b/;

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('Undo');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-undo-check-'))
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

const runnerRelative = 'packages/loot-core/src/server/budget/__actualist_undo_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-undo-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-undo-run-'));
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
  output.handlerCall = record.handlerCall;
  output.handlerResults = record.handlerResults;
  if (record.handlerError !== null) output.handlerError = record.handlerError;
  output.messages = record.messages;
  output.writes = netWrites(record.messages);
  output.undoCalls = record.undoCalls;
  if (record.undoErrors.length > 0) output.undoErrors = record.undoErrors;
  output.undoMessages = record.undoMessages;
  output.undoWrites = netWrites(record.undoMessages);
  output.rowsBefore = record.rowsBefore;
  output.rowsAfterAction = record.rowsAfterAction;
  output.rowsAfterUndo = record.rowsAfterUndo;
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
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/undo-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: null,
  timeZone: TIME_ZONE,
  caseCount: records.length,
  amountUnits: 'integer minor units',
  execution: "Actual handlers (budget/budget-amount, budget/transfer-category, transactions-batch-update, payee-create) on an offline in-memory SQLite database with a loaded envelope spreadsheet, called as the mobile client calls them with the clock frozen, then loot-core's undo() once per undoable call",
  scope: 'synthetic local handler behavior only; no server round trip',
  normalization: [
    'ids Actual mints (id1, ... from the loot-core test uuid mock) are uuid-N by first appearance in the case; setup ids are explicit',
    'writes are the net cell writes of messages: the last value per dataset, row and column, sorted',
    'repeated CRDT messages are kept verbatim, in the order Actual wrote them',
    'names, values and amounts are never normalized',
    'handlerCall is the ordered list of calls the UI sends; undoCalls is how many undo() calls the case needs (an edit that creates a payee is two undo steps)',
    'minted ids are normalized across the whole case, world and undo included',
  ],
  sourceFiles: Object.keys(expectedSourceHashes).map(path => ({ path, sha256: sha256(readFileSync(join(checkout, path))) })),
  fixtures: [{
    path: logicalPath(contractName),
    sha256: sha256(contractData),
    caseCount: records.length,
    caseIDs,
  }],
  oracleOnly: [],
  // The Payees fixture records an undo() per case. UndoOracleReplayTests replays those below
  // through the store's one-step payee undo; the rest are listed with why they are not.
  payeeUndo: {
    fixture: 'Payees',
    replayed: PAYEE_UNDO_REPLAYED,
    oracleOnly: PAYEE_UNDO_OMITTED,
  },
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
    for (const difference of drift) console.error(`undo parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Undo parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated undo parity fixture (${oraclePin.tag}, ${records.length} cases, oracle ${oracleSeconds}s).`);
}
