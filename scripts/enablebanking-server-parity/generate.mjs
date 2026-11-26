#!/usr/bin/env node

// Generates the Enable Banking server fixture: each scenario's raw Enable
// Banking payloads go through Actual's own sync-server routes at the pinned
// release, and the HTTP response the server writes is recorded. `--check`
// regenerates into a temporary directory and diffs against the committed
// fixture.
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
import { buildScenarios, SCHEMA_VERSION, TODAY } from './scenarios.mjs';
import { contractName, expectationFailures, helperPaths, manifestName, sourceHashes } from './shape.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = dirname(scriptPath);
const repositoryRoot = resolve(scriptDirectory, '..', '..');

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const fixtureDirectory = pinnedFixtureDirectory('EnableBankingServer');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-enablebanking-check-'))
  : fixtureDirectory;

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

const packageVersion = JSON.parse(
  readFileSync(join(checkout, 'packages/sync-server/package.json'), 'utf8'),
).version;
if (packageVersion !== oraclePin.packageVersion) {
  throw new Error(`Expected @actual-app/sync-server ${oraclePin.packageVersion}, found ${packageVersion}`);
}
for (const [path, expectedHash] of Object.entries(sourceHashes)) {
  const sourcePath = join(checkout, path);
  if (!existsSync(sourcePath)) throw new Error(`Pinned source is missing: ${path}`);
  const actualHash = sha256(readFileSync(sourcePath));
  if (actualHash !== expectedHash) throw new Error(`Pinned source hash mismatch for ${path}: ${actualHash}`);
}

const plan = { today: TODAY, scenarios: buildScenarios() };
const packageRoot = join(checkout, 'packages/sync-server');
const runnerRelative = 'src/app-enablebanking/tests/__actualist_enablebanking_oracle.spec.ts';
const runnerPath = join(packageRoot, runnerRelative);
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const workDirectory = mkdtempSync(join(tmpdir(), 'actualist-enablebanking-run-'));
const planPath = join(workDirectory, 'plan.json');
const contractTempPath = join(workDirectory, 'contract.json');
// Upstream's config runs a global setup that migrates an account database on
// disk; these routes never open it, so the run uses a config without it.
const configPath = join(workDirectory, 'vitest.config.mjs');
const template = readFileSync(join(scriptDirectory, 'oracle-runner.template'), 'utf8');
const runner = template
  .replace('__PLAN_PATH__', JSON.stringify(planPath))
  .replace('__CONTRACT_PATH__', JSON.stringify(contractTempPath));

let records;
try {
  writeFileSync(planPath, JSON.stringify(plan));
  writeFileSync(configPath, "export default { test: { globals: true, coverage: { enabled: false }, fileParallelism: false } };\n");
  writeFileSync(runnerPath, runner);
  const result = spawnSync('node', [
    '../../.yarn/releases/yarn-4.17.1.cjs', 'vitest', '--run',
    '--root', packageRoot, '--config', configPath, runnerRelative,
  ], {
    cwd: packageRoot,
    encoding: 'utf8',
    env: { ...process.env, NODE_ENV: 'test', TZ: 'UTC' },
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    process.stderr.write((result.stdout ?? '').slice(-20000));
    process.stderr.write((result.stderr ?? '').slice(-20000));
    throw new Error(`vitest failed with status ${result.status}`);
  }
  records = JSON.parse(readFileSync(contractTempPath, 'utf8'));
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(workDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');

if (!Array.isArray(records) || records.length !== plan.scenarios.length) {
  throw new Error(`Oracle returned ${records?.length} scenarios; the plan has ${plan.scenarios.length}`);
}
const failures = [];
records.forEach((record, index) => {
  if (record.id !== plan.scenarios[index].id) throw new Error(`Scenario order mismatch at ${index}: ${record.id}`);
  for (const failure of expectationFailures(record)) failures.push(`${record.id}: ${failure}`);
});
if (failures.length > 0) {
  for (const failure of failures) console.error(`enable banking expectation: ${failure}`);
  process.exit(1);
}

const contractText = [
  '{',
  `  "schemaVersion": ${SCHEMA_VERSION},`,
  `  "oracle": ${JSON.stringify({ tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion })},`,
  `  "syntheticData": ${JSON.stringify({ only: true })},`,
  `  "environment": ${JSON.stringify({ today: TODAY })},`,
  '  "scenarios": [',
  records.map(record => `    ${JSON.stringify(record)}`).join(',\n'),
  '  ]',
  '}',
].join('\n') + '\n';
const contractData = Buffer.from(contractText, 'utf8');
mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, contractName), contractData);

const manifest = {
  schemaVersion: SCHEMA_VERSION,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    path: relative(repositoryRoot, scriptPath),
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  sourceFiles: Object.entries(sourceHashes).map(([path, hash]) => ({ path, sha256: hash })),
  today: TODAY,
  scenarioCount: records.length,
  fixtures: [{
    path: relative(repositoryRoot, join(fixtureDirectory, contractName)),
    sha256: sha256(contractData),
    caseIDs: records.map(record => record.id),
    caseCount: records.length,
  }],
};
writeFileSync(join(outputRoot, manifestName), JSON.stringify(manifest, null, 2) + '\n');

if (checking) {
  const differences = compareWithCommitted(fixtureDirectory, outputRoot, [contractName, manifestName]);
  rmSync(outputRoot, { force: true, recursive: true });
  if (differences.length > 0) {
    for (const difference of differences) console.error(`enable banking --check: ${difference}`);
    process.exit(1);
  }
  console.log(`Enable Banking server fixture matches the oracle: ${records.length} scenarios.`);
} else {
  console.log(`Wrote ${records.length} scenarios to ${relative(repositoryRoot, outputRoot)}.`);
}
