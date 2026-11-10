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
} from '../lib/oracle-pin.mjs';
import { compareWithCommitted } from '../lib/fixture-diff.mjs';
import { buildPlan, expectationFailures, SEED } from './cases.mjs';
import { FROZEN_SOURCES, REGISTRY, registryFiles } from './registry.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..', '..');
const helperPaths = [
  'scripts/parity/file-import-oracle/cases.mjs',
  'scripts/parity/file-import-oracle/registry.mjs',
  'scripts/parity/file-import-oracle/oracle-runner.test.ts',
  'scripts/parity/file-import-oracle/oracle.vitest.config.mjs',
  'scripts/parity/file-import-oracle/readonly-oracle.sb',
  'scripts/parity/sync-merkle/cases.mjs',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];
const SCHEMA_VERSION = 1;
const contractName = 'file-import-contract.json';
const manifestName = 'file-import-manifest.json';

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('FileImport');
const outputRoot = checking ? mkdtempSync(join(tmpdir(), 'actualist-file-import-check-')) : fixtureDirectory;

const sha256 = data => createHash('sha256').update(data).digest('hex');

// Source freeze: every registry file is frozen, and every frozen file matches.
const unfrozen = registryFiles().filter(file => !(file in FROZEN_SOURCES));
if (unfrozen.length > 0) throw new Error(`Registry reads files with no frozen hash: ${unfrozen.join(', ')}`);
const packageVersion = JSON.parse(readFileSync(join(checkout, 'packages/loot-core/package.json'), 'utf8')).version;
if (packageVersion !== oraclePin.packageVersion) {
  throw new Error(`Expected @actual-app/core ${oraclePin.packageVersion}, found ${packageVersion}`);
}
for (const [path, expectedHash] of Object.entries(FROZEN_SOURCES)) {
  const sourcePath = join(checkout, path);
  if (!existsSync(sourcePath)) throw new Error(`Pinned source is missing: ${path}`);
  const actualHash = sha256(readFileSync(sourcePath));
  if (actualHash !== expectedHash) throw new Error(`Pinned source hash mismatch for ${path}: ${actualHash}`);
}

const plan = buildPlan();
const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-file-import-run-'));
const planPath = join(workDirectory, 'plan.json');
const resultPath = join(workDirectory, 'result.json');
let result;
try {
  writeFileSync(planPath, JSON.stringify(plan));
  // vitest only reads the checkout: the sandbox profile denies writes below it, and
  // the Vite cache lives in the work directory.
  const run = spawnSync('/usr/bin/sandbox-exec', [
    '-D', `PROTECTED_CHECKOUT=${checkout}`,
    '-f', join(scriptDirectory, 'readonly-oracle.sb'),
    process.execPath, join(checkout, 'node_modules/vitest/vitest.mjs'), 'run',
    '--configLoader', 'native',
    '--config', join(scriptDirectory, 'oracle.vitest.config.mjs'),
  ], {
    cwd: workDirectory,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: {
      ...process.env,
      TZ: 'UTC',
      ACTUALIST_FILE_IMPORT_ORACLE_ROOT: checkout,
      ACTUALIST_FILE_IMPORT_ORACLE_HARNESS: scriptDirectory,
      ACTUALIST_FILE_IMPORT_ORACLE_CACHE: join(workDirectory, 'vite-cache'),
      ACTUALIST_FILE_IMPORT_ORACLE_PLAN: planPath,
      ACTUALIST_FILE_IMPORT_ORACLE_RESULT: resultPath,
    },
  });
  if (run.status !== 0) {
    process.stderr.write((run.stdout ?? '').slice(-20000));
    process.stderr.write((run.stderr ?? '').slice(-20000));
    throw new Error(`oracle run failed with status ${run.status}`);
  }
  result = JSON.parse(readFileSync(resultPath, 'utf8'));
} finally {
  rmSync(workDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');

const { records, coverage } = result;
const planned = new Map(plan.cases.map(planCase => [planCase.id, planCase]));
const failures = [];
const seen = new Set();
for (const record of records) {
  const planCase = planned.get(record.id);
  if (!planCase) { failures.push(`${record.id}: not in the plan`); continue; }
  seen.add(record.id);
  for (const failure of expectationFailures(record, planCase)) failures.push(`${record.id}: ${failure}`);
}
for (const planCase of plan.cases) {
  if (!seen.has(planCase.id) && planCase.source !== 'derived') failures.push(`${planCase.id}: no record`);
}

// Coverage gate: print every uncovered block; an `enforce` function fails the run.
for (const entry of REGISTRY) {
  const report = coverage[entry.name];
  const label = `${entry.name} [${entry.coverageGate}]`;
  if (report.uncovered.length === 0) {
    console.log(`coverage ${label}: every block reached`);
    continue;
  }
  console.log(`coverage ${label}: ${report.uncovered.length} uncovered block(s)`);
  for (const block of report.uncovered) {
    console.log(`  lines ${block.startLine}-${block.endLine}: ${block.snippet}`);
  }
  if (entry.coverageGate === 'enforce') failures.push(`${entry.name}: uncovered blocks under an enforced coverage gate`);
}
if (failures.length > 0) {
  for (const failure of failures) console.error(`file import expectation: ${failure}`);
  console.error('No fixture was written.');
  process.exit(1);
}

const logicalPath = name => relative(repositoryRoot, join(fixtureDirectory, name));
const functionCounts = {};
for (const entry of REGISTRY) {
  const own = records.filter(record => record.function === entry.name);
  functionCounts[entry.name] = {
    caseCount: own.length,
    namedCaseCount: own.filter(record => record.source === 'named').length,
    generatedCaseCount: own.filter(record => record.source === 'generated').length,
    derivedCaseCount: own.filter(record => record.source === 'derived').length,
  };
}
const pin = { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion };
const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify(pin)},`,
  `  "syntheticData": ${JSON.stringify({ only: true })},`,
  `  "seed": ${SEED},`,
  `  "functions": ${JSON.stringify(functionCounts)},`,
  '  "cases": [',
  records.map(record => `    ${JSON.stringify(record)}`).join(',\n'),
  '  ]',
  '}',
].join('\n') + '\n';
const contractData = Buffer.from(contractText, 'utf8');
mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, contractName), contractData);
writeFileSync(join(outputRoot, manifestName), JSON.stringify({
  schemaVersion: SCHEMA_VERSION,
  actual: pin,
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/parity/file-import-oracle/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: SEED,
  functions: functionCounts,
  caseCount: records.length,
  execution: 'Each registered function is extracted from its frozen Actual source file, evaluated in an isolated vm context with its real dependencies, and called for every case under vitest in a sandbox that denies writes to the checkout; V8 precise coverage records the blocks reached',
  coverage,
  normalization: [
    '{ "$js": tag } stands for a JS value JSON cannot carry: undefined, NaN, -0, Infinity, -Infinity, or threw (with message)',
    'a derived case takes its input from the output of the case named in derivedFrom, and exists only when that output is not null',
    'coverage lists maximal runs of source text with a zero V8 block count, after type stripping that keeps every character in place; lines are 1-based lines of the frozen source file',
  ],
  sourceFiles: Object.entries(FROZEN_SOURCES).map(([path, hash]) => ({ path, sha256: hash })),
  fixtures: [{
    path: logicalPath(contractName),
    sha256: sha256(contractData),
    caseCount: records.length,
    caseIDs: records.map(record => record.id),
  }],
  privacy: { syntheticOnly: true, containsServerCredentials: false, containsPersonalFinancialData: false },
}, null, 2) + '\n');

if (checking) {
  const drift = compareWithCommitted(fixtureDirectory, outputRoot, [contractName, manifestName]);
  rmSync(outputRoot, { recursive: true, force: true });
  if (drift.length > 0) {
    for (const difference of drift) console.error(`file import parity drift: ${difference}`);
    process.exit(1);
  }
  console.log(`File import parity fixtures match a fresh generation (${records.length} cases).`);
} else {
  console.log(`Generated file import parity fixture (${oraclePin.tag}, ${records.length} cases).`);
}
