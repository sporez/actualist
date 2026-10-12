#!/usr/bin/env node

// Generates the transaction creation fixture (the CRDT messages Actual writes
// when it creates transactions) from Actual's own handlers at the pinned release. Usage and flow: README.md.
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
const contractName = 'transactions-contract.json';
const manifestName = 'transactions-manifest.json';
const helperPaths = [
  'scripts/transactions-parity/matrix.json',
  'scripts/transactions-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
// Hashed from the oracle checkout at generation; the pin makes them exact.
const sourceFiles = [
  'packages/loot-core/src/server/transactions/app.ts',
  'packages/loot-core/src/server/transactions/index.ts',
  'packages/loot-core/src/server/transactions/transfer.ts',
  'packages/loot-core/src/server/accounts/app.ts',
  'packages/loot-core/src/server/accounts/sync.ts',
  'packages/loot-core/src/server/accounts/payees.ts',
  'packages/loot-core/src/server/payees/app.ts',
  'packages/loot-core/src/server/db/index.ts',
  'packages/loot-core/src/server/mutators.ts',
  'packages/loot-core/src/mocks/setup.ts',
];
const MINTED_ID = /^id\d+$/;
const SORT_ORDER_TOKEN = '<sort-order>';

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('Transactions');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-transactions-check-'))
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
const runnerRelative = 'packages/loot-core/src/server/transactions/__actualist_transactions_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryDataDirectory = join(checkout, '.actualist-transactions-oracle-data');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-transactions-run-'));
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
// case. Each minted id is renamed by the role it plays in the case, so the fixture
// never depends on mint order; setup ids are explicit and untouched. A role with
// two candidates fails generation.
function roleNames(kind, messages, accountMessages) {
  const roles = new Map();
  const claim = (id, role) => {
    if (roles.has(id)) return;
    if ([...roles.values()].includes(role)) throw new Error(`${kind}: two minted ids want the role ${role}`);
    roles.set(id, role);
  };
  for (const message of accountMessages) if (MINTED_ID.test(message.row)) claim(message.row, 'acct-new');
  for (const message of messages) {
    if (!MINTED_ID.test(message.row)) continue;
    if (message.dataset === 'payees' || message.dataset === 'payee_mapping') claim(message.row, 'payee-new');
    else if (message.dataset === 'transactions') {
      claim(message.row, kind === 'manual' || kind === 'transfer' ? 'txn-paired' : 'txn-new');
    }
  }
  return roles;
}

function normalizeRecord(record) {
  let messages = record.messages;
  if (record.kind === 'starting-balance') {
    // Account creation belongs to account-lifecycle: drop the account row and its
    // transfer payee, keep the Starting Balance payee and the opening transaction.
    const transferPayees = new Set(messages.filter(m => m.dataset === 'payees' && m.column === 'transfer_acct').map(m => m.row));
    messages = messages.filter(m => m.dataset !== 'accounts'
      && !((m.dataset === 'payees' || m.dataset === 'payee_mapping') && transferPayees.has(m.row)));
  }
  const roles = roleNames(record.kind, messages, record.messages.filter(m => m.dataset === 'accounts'));
  const rename = value => (typeof value === 'string' && roles.has(value) ? roles.get(value) : value);
  const expected = messages.map(message => {
    const row = rename(message.row);
    const value = message.column === 'sort_order' && message.value !== null ? SORT_ORDER_TOKEN : rename(message.value);
    if (typeof value === 'string' && /\bid\d+\b/.test(value) && !roles.has(value)) {
      throw new Error(`${record.id}: un-renamed minted id in ${message.dataset}.${message.column}: ${value}`);
    }
    return { dataset: message.dataset, row, column: message.column, value };
  });
  const output = {
    id: record.id,
    kind: record.kind,
    input: matrixByID.get(record.id),
    expected,
  };
  if (record.date !== undefined) output.input = { ...output.input, date: record.date };
  if (record.importResult !== undefined) output.importResult = record.importResult;
  return output;
}

const matrixByID = new Map(matrix.cases.map(item => [item.id, item]));
const records = raw.map(record => {
  if (record.error !== null) throw new Error(`${record.id}: Actual refused: ${record.error}`);
  if (record.messages.length === 0) throw new Error(`${record.id}: Actual wrote no messages`);
  return normalizeRecord(record);
});

const caseIDs = records.map(record => record.id);
const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify({ tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion })},`,
  `  "syntheticData": ${JSON.stringify({ only: true })},`,
  `  "environment": ${JSON.stringify({ timeZone: TIME_ZONE, frozenNow: FROZEN_NOW, sortOrderToken: SORT_ORDER_TOKEN })},`,
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
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/transactions-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: null,
  timeZone: TIME_ZONE,
  caseCount: records.length,
  amountUnits: 'integer minor units',
  execution: 'Actual payee-create + transactions-batch-update (added), transactions-import and account-create (with a starting balance) handlers on an offline in-memory SQLite database; the CRDT messages each wrote, in write order',
  scope: 'synthetic local handler behavior only; no server round trip',
  normalization: [
    `sort_order is recorded as ${SORT_ORDER_TOKEN} when Actual writes it: its value is the frozen Date.now() ${FROZEN_NOW}, and Actualist orders rows with its own base; only the cell's presence is compared`,
    'the new transaction in a manual or transfer case is the explicit id txn-new; every other minted id is named by its role (txn-paired, txn-new, payee-new)',
    'starting-balance cases drop the account row and its transfer payee (account-lifecycle owns them) and keep the Starting Balance payee and the opening transaction',
    'CRDT messages are kept verbatim, in the order Actual wrote them; the replay compares them as a multiset',
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
    for (const difference of drift) console.error(`transactions parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Transactions parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated transactions parity fixture (${oraclePin.tag}, ${records.length} cases, oracle ${oracleSeconds}s).`);
}
