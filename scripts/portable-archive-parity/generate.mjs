#!/usr/bin/env node

// Generates the portable archive fixture from Actual's own export-budget and import-budget
// handlers at the pinned release. Usage and flow: README.md.
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
import { digest } from '../parity/lib/table-digest.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');
const SCHEMA_VERSION = 1;
const TIME_ZONE = 'UTC';
const TODAY = '2026-09-27';
const BUDGET_NAME = 'Portable Archive Oracle';
const actualZipName = 'actual-export.zip';
const actualistZipName = 'actualist-export.zip';
const actualDigestName = 'actual-export-digest.json';
const actualistDigestName = 'actualist-export-digest.json';
const manifestName = 'portable-archive-manifest.json';
const helperPaths = [
  'scripts/portable-archive-parity/oracle-runner.template',
  'scripts/portable-archive-parity/produce-actualist-export.sh',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
  'scripts/parity/lib/table-digest.mjs',
];
// Pinned in the generator: a different Actual source fails before anything is written.
const expectedSourceHashes = {
  'packages/loot-core/src/server/cloud-storage.ts':
    '4a0e41f37fbdbb34b7d9fd6e2f79d2331b4d3662a0e52f5f716fb66ff1858942',
  'packages/loot-core/src/server/budgetfiles/app.ts':
    '5cf6a29a5c8a0f435cd30f70198cda8ff47cf26fe9f23d7a0c492506de93bed9',
  'packages/loot-core/src/server/importers/actual.ts':
    'c4cb45cbeca140b5219b1336438a425ff16401d8917c927364a19f1c911adaa6',
  'packages/loot-core/src/server/db/index.ts':
    '4e99b6c8e3b0bcd4c2dfbdd4aa7e93d00875558c1e150eab7d9c703617bafcd7',
  'packages/loot-core/src/server/schedules/app.ts':
    'c7aaddb94d6293016a6dad16952a5b978abc6cb637b62909078ce92e03e04613',
};

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('PortableArchive');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-portable-archive-check-'))
  : fixtureDirectory;

const sha256 = data => createHash('sha256').update(data).digest('hex');

function run(command, args, cwd, environment) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', env: environment, maxBuffer: 256 * 1024 * 1024 });
  if (result.status !== 0) {
    process.stderr.write((result.stdout ?? '').slice(-20000));
    process.stderr.write((result.stderr ?? '').slice(-20000));
    throw new Error(`${command} ${args.join(' ')} failed with status ${result.status}`);
  }
  return result.stdout.trim();
}

const packageVersion = JSON.parse(readFileSync(join(checkout, 'packages/loot-core/package.json'), 'utf8')).version;
if (packageVersion !== oraclePin.packageVersion) {
  throw new Error(`Expected @actual-app/core ${oraclePin.packageVersion}, found ${packageVersion}`);
}
for (const [path, expectedHash] of Object.entries(expectedSourceHashes)) {
  const sourcePath = join(checkout, path);
  if (!existsSync(sourcePath)) throw new Error(`Pinned source is missing: ${path}`);
  const actualHash = sha256(readFileSync(sourcePath));
  if (actualHash !== expectedHash) throw new Error(`Pinned source hash mismatch for ${path}: ${actualHash}`);
}

// The Actualist export is an input produced by produce-actualist-export.sh. Without it only
// direction A is generated.
const actualistZipPath = join(fixtureDirectory, actualistZipName);
const hasActualistZip = existsSync(actualistZipPath);

const runnerRelative = 'packages/loot-core/src/server/__actualist_portable_archive_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-portable-archive-run-'));
const dataDirectory = join(workDirectory, 'data');
mkdirSync(dataDirectory);
const planPath = join(workDirectory, 'plan.json');
const outputPath = join(workDirectory, 'records.json');
const generatedActualZip = join(workDirectory, actualZipName);
const steps = [
  { op: 'seed-export', label: 'seed', zip: generatedActualZip },
  { op: 'import', label: 'actual', zip: generatedActualZip },
  ...(hasActualistZip ? [{ op: 'import', label: 'actualist', zip: actualistZipPath }] : []),
];
const runner = readFileSync(join(scriptDirectory, 'oracle-runner.template'), 'utf8')
  .replace('__PLAN_PATH__', JSON.stringify(planPath))
  .replace('__OUTPUT_PATH__', JSON.stringify(outputPath));

let actualZip;
let records;
let digests;
let actualistRawDigest = null;
const started = Date.now();
try {
  writeFileSync(planPath, JSON.stringify({ today: TODAY, budgetName: BUDGET_NAME, steps }));
  writeFileSync(runnerPath, runner);
  run('node', ['.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/core', 'vitest', '--run',
    runnerRelative.replace('packages/loot-core/', '')],
  checkout, { ...process.env, ACTUAL_DATA_DIR: dataDirectory, TZ: TIME_ZONE });
  records = JSON.parse(readFileSync(outputPath, 'utf8'));
  actualZip = readFileSync(generatedActualZip);
  // What Actual reads from each ZIP: the imported copy, digested once the budget is closed.
  digests = Object.fromEntries(records.filter(record => record.id).map(record => [
    record.label,
    digest(join(dataDirectory, record.id, 'db.sqlite')),
  ]));
  if (hasActualistZip) {
    // The Actualist ZIP's own database as written, before Actual loads it.
    const unzipped = spawnSync('unzip', ['-p', actualistZipPath, 'db.sqlite'], { maxBuffer: 1 << 30 });
    if (unzipped.status !== 0) throw new Error('unzip of the Actualist export failed');
    const raw = join(workDirectory, 'actualist-raw.sqlite');
    writeFileSync(raw, unzipped.stdout);
    actualistRawDigest = digest(raw);
  }
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(workDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');
const oracleSeconds = ((Date.now() - started) / 1000).toFixed(1);

const balancesOf = label => records.find(record => record.label === label).balances;
const header = {
  schemaVersion: SCHEMA_VERSION,
  oracle: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  syntheticData: { only: true },
};
const json = value => JSON.stringify(value, null, 1) + '\n';
const actualDigestData = Buffer.from(json({
  ...header,
  source: 'Actual export-budget of the seeded world, read back by Actual import-budget',
  digest: digests.actual,
  balances: balancesOf('actual'),
}), 'utf8');
const files = [[actualZipName, actualZip], [actualDigestName, actualDigestData]];
let actualistDigestData = null;
if (hasActualistZip) {
  actualistDigestData = Buffer.from(json({
    ...header,
    source: 'the committed Actualist export, as written (zip) and read by Actual import-budget (afterActualImport)',
    zip: actualistRawDigest,
    afterActualImport: digests.actualist,
    balances: balancesOf('actualist'),
  }), 'utf8');
  files.push([actualistDigestName, actualistDigestData]);
}
mkdirSync(outputRoot, { recursive: true });
for (const [name, data] of files) writeFileSync(join(outputRoot, name), data);

// Manifest paths name the pinned fixture location, never the temporary --check directory.
const logicalPath = name => relative(repositoryRoot, join(fixtureDirectory, name));
const entry = ([name, data]) => ({ path: logicalPath(name), sha256: sha256(data) });
const manifestText = JSON.stringify({
  schemaVersion: SCHEMA_VERSION,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/portable-archive-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  timeZone: TIME_ZONE,
  today: TODAY,
  amountUnits: 'integer minor units',
  execution: 'Actual export-budget handler on a seeded budget in a real data directory with the clock frozen, then import-budget (type actual) of that ZIP and of the committed Actualist export; the imported databases are digested with sqlite3',
  scope: 'synthetic local file behavior only; no server round trip',
  digest: 'live rows of every table (tombstone = 0 where the column exists), all columns, order independent; messages_*, kvcache*, sqlite_* and actualist_* tables only counted',
  // Inputs: the ZIPs the digests were taken from. actualist-export.zip is produced by Actualist,
  // not by Actual (produce-actualist-export.sh).
  inputs: {
    actualExportZip: sha256(actualZip),
    actualistExportZip: hasActualistZip ? sha256(readFileSync(actualistZipPath)) : null,
  },
  sourceFiles: Object.keys(expectedSourceHashes).map(path => ({ path, sha256: sha256(readFileSync(join(checkout, path))) })),
  fixtures: files.map(entry),
  privacy: { syntheticOnly: true, containsServerCredentials: false, containsPersonalFinancialData: false },
}, null, 2) + '\n';
writeFileSync(join(outputRoot, manifestName), manifestText);

if (checking) {
  const names = [...files.map(([name]) => name), manifestName];
  const drift = compareWithCommitted(fixtureDirectory, outputRoot, names);
  rmSync(outputRoot, { recursive: true, force: true });
  if (drift.length > 0) {
    for (const difference of drift) console.error(`portable archive parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`Portable archive parity fixtures match a fresh generation (${names.length} files).`);
} else {
  console.log(`Generated portable archive fixtures (${oraclePin.tag}, ${files.length} files, oracle ${oracleSeconds}s).`);
}
