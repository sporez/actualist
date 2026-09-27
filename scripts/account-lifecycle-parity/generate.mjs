#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const EXPECTED_TAG = 'v26.9.0';
const EXPECTED_COMMIT = '59fe126f637d858c061e1eeedbef5436c8f2225a';
const EXPECTED_VERSION = '26.9.0';
const EXPECTED_NODE_MAJOR = 24;
const EXPECTED_YARN_VERSION = '4.17.1';
const SCHEMA_VERSION = 1;

const scriptPath = fileURLToPath(import.meta.url);
const scriptRoot = dirname(scriptPath);
const repositoryRoot = resolve(scriptRoot, '..', '..');
const checkoutArgument = argument('--actual-checkout');
if (!checkoutArgument) usage();
const checkout = resolve(checkoutArgument);
const outputRoot = resolve(
  argument('--output') ??
    join(
      repositoryRoot,
      'ActualistTests/Fixtures/ActualCore26_9_0/AccountLifecycle',
    ),
);

const harnessFiles = [
  'account-lifecycle-parity.test.ts',
  'account-lifecycle-parity-support.ts',
];
const sourceFiles = [
  'packages/loot-core/package.json',
  'packages/loot-core/src/mocks/setup.ts',
  'packages/loot-core/src/server/accounts/app.ts',
  'packages/loot-core/src/server/db/index.ts',
  'packages/loot-core/src/server/db/mappings.ts',
  'packages/loot-core/src/server/sql/init.sql',
  'packages/loot-core/src/server/mutators.ts',
  'packages/loot-core/src/server/schedules/app.ts',
  'packages/loot-core/src/server/sync/index.ts',
  'packages/loot-core/src/server/transactions/app.ts',
  'packages/loot-core/src/server/transactions/index.ts',
  'packages/loot-core/src/server/transactions/transfer.ts',
  'packages/loot-core/src/server/undo.ts',
  'packages/desktop-client/src/components/modals/CloseAccountModal.tsx',
  'packages/desktop-client/src/components/util/accountValidation.ts',
];
const expectedCaseIDs = [
  'rename-open-history',
  'rename-closed',
  'rename-handler-input-boundary',
  'reopen-repeat-history',
  'close-empty-history',
  'close-zero',
  'close-positive-on-to-on-history',
  'close-negative-on-to-on',
  'close-on-to-off-hidden-category',
  'close-off-to-on',
  'close-off-to-off',
  'close-self-transfer-refusal',
  'close-split-balance',
  'forced-delete-simple',
  'forced-delete-split-transfer-graph',
  'unlink-simplefin',
  'unlink-gocardless-last-reference',
  'unlink-gocardless-shared-bank',
  'unlink-gocardless-without-token',
  'unlink-gocardless-remote-failure',
  'close-unlink-undo-boundary',
  'schedule-close-reopen-eligibility',
];

const overlayRoot = join(
  checkout,
  'packages/loot-core/src/server/accounts',
);
const rawOutput = join(checkout, '.actualist-account-lifecycle-oracle.json');
const vitestOutput = join(
  checkout,
  '.actualist-account-lifecycle-vitest.json',
);
const stagingOutput = `${outputRoot}.staging-${process.pid}`;

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

function usage() {
  console.error(
    'Usage: node scripts/account-lifecycle-parity/generate.mjs --actual-checkout <isolated-path> [--output <path>]',
  );
  process.exit(2);
}

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? checkout,
    encoding: 'utf8',
    env: options.env ?? process.env,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw new Error(
      `${command} ${args.join(' ')} failed with status ${String(result.status)}`,
    );
  }
  return result.stdout.trim();
}

function hashedFiles(paths, root) {
  return paths.map(path => ({
    path,
    sha256: sha256(readFileSync(join(root, path))),
  }));
}

function assertObject(value, label) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function validateRawFixture(parsed) {
  assertObject(parsed, 'raw fixture');
  if (parsed.schemaVersion !== SCHEMA_VERSION) {
    throw new Error(`Expected raw schema ${SCHEMA_VERSION}`);
  }
  if (parsed.syntheticDataOnly !== true) {
    throw new Error('Oracle did not declare syntheticDataOnly');
  }
  if (!Array.isArray(parsed.cases)) {
    throw new Error('Oracle cases must be an array');
  }
  const actualCaseIDs = parsed.cases.map(value => {
    const item = assertObject(value, 'case');
    if (typeof item.id !== 'string') throw new Error('Case id must be a string');
    if (!assertObject(item.input, `${item.id}.input`)) {
      throw new Error(`${item.id}.input is invalid`);
    }
    if (!Array.isArray(item.assertions) || item.assertions.length === 0) {
      throw new Error(`${item.id}.assertions must be nonempty`);
    }
    assertObject(item.observed, `${item.id}.observed`);
    return item.id;
  });
  if (new Set(actualCaseIDs).size !== actualCaseIDs.length) {
    throw new Error('Oracle emitted duplicate case IDs');
  }
  if (JSON.stringify(actualCaseIDs) !== JSON.stringify(expectedCaseIDs)) {
    throw new Error(
      `Oracle case order mismatch. Expected ${expectedCaseIDs.join(', ')}, received ${actualCaseIDs.join(', ')}`,
    );
  }
}

function validateVitestReport(parsed) {
  const report = assertObject(parsed, 'Vitest JSON report');
  if (report.success !== true) throw new Error('Vitest report is not successful');
  if (report.numFailedTests !== 0) {
    throw new Error(`Vitest reported ${String(report.numFailedTests)} failures`);
  }
  if (report.numPassedTests !== expectedCaseIDs.length) {
    throw new Error(
      `Expected ${expectedCaseIDs.length} passing cases, found ${String(report.numPassedTests)}`,
    );
  }
  if (report.numPendingTests !== 0 || report.numTodoTests !== 0) {
    throw new Error('Vitest report contains skipped or todo cases');
  }
}

function validateManifestShape(manifest) {
  if (manifest.schemaVersion !== SCHEMA_VERSION) {
    throw new Error('Manifest schema version mismatch');
  }
  if (!/^v24\./.test(manifest.toolchain.node)) {
    throw new Error('Manifest Node provenance is not v24');
  }
  if (manifest.toolchain.yarn !== EXPECTED_YARN_VERSION) {
    throw new Error('Manifest Yarn provenance mismatch');
  }
  if (manifest.fixture.caseCount !== expectedCaseIDs.length) {
    throw new Error('Manifest case count mismatch');
  }
  if (
    JSON.stringify(manifest.fixture.caseIDs) !== JSON.stringify(expectedCaseIDs)
  ) {
    throw new Error('Manifest case IDs mismatch');
  }
  for (const file of [...manifest.harnessFiles, ...manifest.sourceFiles]) {
    if (!/^[0-9a-f]{64}$/.test(file.sha256)) {
      throw new Error(`Invalid SHA-256 for ${file.path}`);
    }
  }
}

if (!existsSync(join(checkout, '.git'))) {
  throw new Error(`Actual checkout is not a git worktree: ${checkout}`);
}
if (Number(process.versions.node.split('.')[0]) !== EXPECTED_NODE_MAJOR) {
  throw new Error(
    `Expected Node ${EXPECTED_NODE_MAJOR}.x, found ${process.version}`,
  );
}

const commit = run('git', ['rev-parse', 'HEAD']);
if (commit !== EXPECTED_COMMIT) {
  throw new Error(`Expected ${EXPECTED_COMMIT}, found ${commit}`);
}
const tag = run('git', ['describe', '--tags', '--exact-match', 'HEAD']);
if (tag !== EXPECTED_TAG) throw new Error(`Expected ${EXPECTED_TAG}, found ${tag}`);
const trackedStatus = run('git', ['status', '--short', '--untracked-files=no']);
if (trackedStatus !== '') {
  throw new Error('Actual oracle checkout has tracked changes; refusing to overlay');
}

const packageVersion = JSON.parse(
  readFileSync(join(checkout, 'packages/loot-core/package.json'), 'utf8'),
).version;
if (packageVersion !== EXPECTED_VERSION) {
  throw new Error(
    `Expected @actual-app/core ${EXPECTED_VERSION}, found ${String(packageVersion)}`,
  );
}
for (const path of sourceFiles) {
  if (!existsSync(join(checkout, path))) {
    throw new Error(`Pinned source is missing: ${path}`);
  }
}
for (const file of harnessFiles) {
  if (!existsSync(join(scriptRoot, 'harness', file))) {
    throw new Error(`Harness source is missing: ${file}`);
  }
  const target = join(overlayRoot, file);
  if (existsSync(target)) {
    throw new Error(`Refusing to overwrite upstream overlay: ${target}`);
  }
}
for (const temporaryPath of [rawOutput, vitestOutput, stagingOutput]) {
  if (existsSync(temporaryPath)) {
    throw new Error(`Refusing to overwrite existing path: ${temporaryPath}`);
  }
}
if (existsSync(outputRoot)) {
  throw new Error(`Refusing to replace existing fixture directory: ${outputRoot}`);
}

const yarnPath = join(checkout, '.yarn/releases/yarn-4.17.1.cjs');
if (!existsSync(yarnPath)) {
  throw new Error(`Pinned Yarn release is missing: ${yarnPath}`);
}
const yarnVersion = run('node', [yarnPath, '--version']);
if (yarnVersion !== EXPECTED_YARN_VERSION) {
  throw new Error(
    `Expected Yarn ${EXPECTED_YARN_VERSION}, found ${yarnVersion}`,
  );
}

const testArgv = [
  '.yarn/releases/yarn-4.17.1.cjs',
  'workspace',
  '@actual-app/core',
  'run',
  'test:node',
  'src/server/accounts/account-lifecycle-parity.test.ts',
  '--reporter=json',
  '--outputFile=.actualist-account-lifecycle-vitest.json',
];

try {
  for (const file of harnessFiles) {
    cpSync(join(scriptRoot, 'harness', file), join(overlayRoot, file), {
      errorOnExist: true,
    });
  }

  run('node', testArgv, {
    env: {
      ...process.env,
      ACTUALIST_ACCOUNT_LIFECYCLE_ORACLE_OUTPUT: rawOutput,
    },
  });

  if (!existsSync(rawOutput)) {
    throw new Error('Harness completed without writing the raw oracle output');
  }
  if (!existsSync(vitestOutput)) {
    throw new Error('Vitest completed without writing its JSON report');
  }

  const rawBytes = readFileSync(rawOutput);
  const parsedRaw = JSON.parse(rawBytes.toString('utf8'));
  validateRawFixture(parsedRaw);
  validateVitestReport(JSON.parse(readFileSync(vitestOutput, 'utf8')));

  mkdirSync(stagingOutput, { recursive: false });
  const fixtureName = 'account-lifecycle-oracle.json';
  const stagedFixture = join(stagingOutput, fixtureName);
  writeFileSync(stagedFixture, rawBytes);

  const manifest = {
    schemaVersion: SCHEMA_VERSION,
    generatedAt: new Date().toISOString(),
    actual: { tag, commit, packageVersion },
    toolchain: { node: process.version, yarn: yarnVersion },
    generation: {
      workingDirectory: '<isolated-actual-checkout>',
      argv: ['node', ...testArgv],
      environment: {
        ACTUALIST_ACCOUNT_LIFECYCLE_ORACLE_OUTPUT:
          '<isolated-actual-checkout>/.actualist-account-lifecycle-oracle.json',
      },
    },
    generator: {
      path: 'scripts/account-lifecycle-parity/generate.mjs',
      sha256: sha256(readFileSync(scriptPath)),
      manifestSchemaPath:
        'scripts/account-lifecycle-parity/manifest.schema.json',
      manifestSchemaSha256: sha256(
        readFileSync(join(scriptRoot, 'manifest.schema.json')),
      ),
    },
    harnessFiles: hashedFiles(harnessFiles, join(scriptRoot, 'harness')).map(
      file => ({ ...file, path: `scripts/account-lifecycle-parity/harness/${file.path}` }),
    ),
    sourceFiles: hashedFiles(sourceFiles, checkout),
    fixture: {
      path: relative(repositoryRoot, join(outputRoot, fixtureName)),
      sha256: sha256(rawBytes),
      caseCount: parsedRaw.cases.length,
      caseIDs: parsedRaw.cases.map(value => value.id),
    },
    cases: parsedRaw.cases.map((value, index) => ({
      id: value.id,
      input: value.input,
      assertions: value.assertions,
      outputPointer: `${fixtureName}#/cases/${index}`,
    })),
  };
  validateManifestShape(manifest);
  writeFileSync(
    join(stagingOutput, 'manifest.json'),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );

  mkdirSync(dirname(outputRoot), { recursive: true });
  renameSync(stagingOutput, outputRoot);
  console.log(
    `Generated ${expectedCaseIDs.length} account lifecycle parity cases from ${EXPECTED_TAG}.`,
  );
} finally {
  for (const file of harnessFiles) {
    rmSync(join(overlayRoot, file), { force: true });
  }
  rmSync(rawOutput, { force: true });
  rmSync(vitestOutput, { force: true });
  rmSync(stagingOutput, { recursive: true, force: true });
}
