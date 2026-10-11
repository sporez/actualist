#!/usr/bin/env node

// Generates the transaction duplicate/merge fixture from Actual's own handlers
// at the pinned release. Usage and flow: README.md.
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

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');
const SCHEMA_VERSION = 1;
const TIME_ZONE = 'UTC';
// mocks/setup.ts freezes Date.now() at this value, so it is the sort_order
// Actual gives a row that carries none.
const FROZEN_NOW = 123456789;
const contractName = 'transaction-command-contract.json';
const manifestName = 'transaction-command-manifest.json';
const helperPaths = [
  'scripts/transaction-command-parity/matrix.json',
  'scripts/transaction-command-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
// Hashed from the oracle checkout at generation; the pin makes them exact.
const sourceFiles = [
  'packages/loot-core/src/server/transactions/app.ts',
  'packages/loot-core/src/server/transactions/merge.ts',
  'packages/loot-core/src/server/transactions/transfer.ts',
  'packages/loot-core/src/server/undo.ts',
  'packages/loot-core/src/server/db/index.ts',
  'packages/loot-core/src/server/mutators.ts',
  'packages/loot-core/src/shared/transactions.ts',
  'packages/loot-core/src/mocks/setup.ts',
];
const REFERENCE_TABLES = [
  'accounts', 'categories', 'categoryGroups', 'categoryMappings',
  'payees', 'payeeMappings', 'rules', 'schedules',
];
const LEARNING_CASE = 'D2-duplicate-does-not-request-learning';
const MINTED_ID = /^id\d+$/;
const EMBEDDED_MINTED_ID = /\bid\d+\b/;

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('TransactionCommand');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-transaction-command-check-'))
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
for (const path of sourceFiles) {
  if (!existsSync(join(checkout, path))) throw new Error(`Pinned source is missing: ${path}`);
}

const matrix = JSON.parse(readFileSync(join(scriptDirectory, 'matrix.json'), 'utf8'));
const runnerRelative = 'packages/loot-core/src/server/transactions/__actualist_transaction_command_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-transaction-command-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-transaction-command-run-'));
const planPath = join(workDirectory, 'plan.json');
const outputPath = join(workDirectory, 'records.json');
const runner = readFileSync(join(scriptDirectory, 'oracle-runner.template'), 'utf8')
  .replace('__PLAN_PATH__', JSON.stringify(planPath))
  .replace('__OUTPUT_PATH__', JSON.stringify(outputPath));

let raw;
const started = Date.now();
try {
  writeFileSync(planPath, JSON.stringify(matrix));
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

if (!Array.isArray(raw) || raw.length !== matrix.cases.length) {
  throw new Error(`Oracle returned ${raw?.length} cases; the matrix has ${matrix.cases.length}`);
}
raw.forEach((record, index) => {
  if (record.id !== matrix.cases[index].id) throw new Error(`Case order mismatch at ${index}: ${record.id}`);
});

// Actual's test setup mints ids as id1, id2, ... and restarts the counter per
// case. A string that is exactly such an id becomes uuid-N by first appearance in
// the case's serialized form; setup ids are explicit and no other value is
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

// Reference rows (accounts, categories, payees, schedules, mappings, rules) are
// seeded identically for every case. Record them once; a case lists only the
// tables a checkpoint changed.
const referenceData = Object.fromEntries(REFERENCE_TABLES.map(table => [table, raw[0].referencesBefore[table]]));
const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);
function changedTables(snapshot) {
  const changed = {};
  for (const table of REFERENCE_TABLES) {
    if (!same(snapshot[table], referenceData[table])) changed[table] = snapshot[table];
  }
  return changed;
}

const records = raw.map(record => {
  if (!same(record.referencesBefore, raw[0].referencesBefore)) {
    throw new Error(`${record.id}: seeded reference rows differ from the first case`);
  }
  const afterHandlerChanges = changedTables(record.referencesAfterHandler);
  const afterUndoChanges = changedTables(record.referencesAfterUndo);
  const output = {
    id: record.id,
    gate: record.gate,
    graph: record.graph,
    selected: record.selected,
    input: { transactions: record.before },
    handler: record.handlerError === null
      ? { outcome: 'ok', result: record.handlerResult }
      : { outcome: 'refused', error: record.handlerError },
    afterHandler: { transactions: record.after },
    forwardMessages: record.forwardMessages,
    undo: record.undoError === null
      ? { outcome: 'ok', messages: record.undoMessages, transactions: record.afterUndo }
      : { outcome: 'error', error: record.undoError, messages: record.undoMessages, transactions: record.afterUndo },
  };
  if (record.conflict !== null) output.conflict = record.conflict;
  if (Object.keys(afterHandlerChanges).length > 0 || Object.keys(afterUndoChanges).length > 0) {
    output.referenceChanges = { afterHandler: afterHandlerChanges, afterUndo: afterUndoChanges };
  }
  if (record.id === LEARNING_CASE) {
    output.rules = {
      learnCategoriesRequested: false,
      before: record.referencesBefore.rules,
      afterHandler: record.referencesAfterHandler.rules,
      afterUndo: record.referencesAfterUndo.rules,
    };
  }
  return withNormalizedIDs(output);
});

const caseIDs = records.map(record => record.id);
const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify({ tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion })},`,
  `  "syntheticData": ${JSON.stringify({ only: true })},`,
  `  "environment": ${JSON.stringify({ timeZone: TIME_ZONE, frozenNow: FROZEN_NOW })},`,
  `  "referenceData": ${JSON.stringify(referenceData)},`,
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
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/transaction-command-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: null,
  timeZone: TIME_ZONE,
  caseCount: records.length,
  amountUnits: 'integer minor units',
  execution: 'Actual transactions-batch-update (duplicate: the added rows the desktop client builds) and transactions-merge handlers on an offline in-memory SQLite database, then one real undo',
  scope: 'synthetic local handler behavior only; no server round trip',
  normalization: [
    'ids Actual mints (id1, id2, ... from the loot-core test uuid mock) are uuid-N by first appearance in the case; setup ids are explicit',
    `sort_order ${FROZEN_NOW} is the frozen Date.now() Actual gives a row without one; it is not a comparable value`,
    'repeated CRDT messages are kept verbatim, in the order Actual wrote them',
    'reference rows are recorded once; a case lists only the tables a checkpoint changed',
    'amounts and dates are never normalized',
  ],
  sourceFiles: sourceFiles.map(path => ({ path, sha256: sha256(readFileSync(join(checkout, path))) })),
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
    for (const difference of drift) console.error(`transaction command parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Transaction command parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated transaction command parity fixture (${oraclePin.tag}, ${records.length} cases, oracle ${oracleSeconds}s).`);
}
