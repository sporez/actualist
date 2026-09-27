#!/usr/bin/env node

import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import {
  closeSync,
  cpSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const EXPECTED_TAG = 'v26.9.0';
const EXPECTED_COMMIT = '59fe126f637d858c061e1eeedbef5436c8f2225a';
const EXPECTED_VERSION = '26.9.0';
const EXPECTED_NODE_MAJOR = 24;
const EXPECTED_YARN_VERSION = '4.17.1';
const EXPECTED_BETTER_SQLITE3_VERSION = '12.11.1';
const SCHEMA_VERSION = 1;
const ORACLE_TIMEOUT_MILLISECONDS = 180_000;
const TERMINATION_GRACE_MILLISECONDS = 5_000;
const TERMINATION_CONFIRM_MILLISECONDS = 1_000;

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
const vitestOutputName = `.actualist-account-lifecycle-vitest-${randomUUID()}.json`;
const vitestOutput = join(
  checkout,
  vitestOutputName,
);
const ownershipRecord = join(
  checkout,
  '.actualist-account-lifecycle-process.json',
);
const stagingOutput = `${outputRoot}.staging-${process.pid}`;
let ownedOracleProcessGroupMayRemain = false;

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
    timeout: options.timeout ?? 10_000,
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

function delay(milliseconds) {
  return new Promise(resolveDelay => setTimeout(resolveDelay, milliseconds));
}

function processGroupExists(processGroupID) {
  try {
    process.kill(-processGroupID, 0);
    return true;
  } catch (error) {
    if (error?.code === 'ESRCH') return false;
    throw error;
  }
}

function signalProcessGroup(processGroupID, signal) {
  try {
    process.kill(-processGroupID, signal);
  } catch (error) {
    if (error?.code !== 'ESRCH') throw error;
  }
}

async function runOracle(command, args, options) {
  if (process.platform === 'win32') {
    throw new Error(
      'Account lifecycle oracle execution requires POSIX process-group ownership',
    );
  }

  await new Promise((resolveRun, rejectRun) => {
    let child;
    let processGroupID;
    let stdout = '';
    let stderr = '';
    let didSettle = false;
    let isTerminating = false;
    let timeoutHandle;
    const handledSignals = ['SIGINT', 'SIGTERM', 'SIGHUP'];
    const signalExitCodes = { SIGINT: 130, SIGTERM: 143, SIGHUP: 129 };

    function childIsActive() {
      return Boolean(
        child && child.exitCode === null && child.signalCode === null,
      );
    }

    function removeParentHandlers() {
      for (const signal of handledSignals) {
        process.removeListener(signal, parentSignalHandlers.get(signal));
      }
      process.removeListener('exit', handleParentExit);
    }

    function settle(error) {
      if (didSettle) return;
      didSettle = true;
      if (timeoutHandle) clearTimeout(timeoutHandle);
      removeParentHandlers();
      if (error) {
        process.stderr.write(stdout);
        process.stderr.write(stderr);
        rejectRun(error);
      } else {
        resolveRun();
      }
    }

    async function terminateOwnedProcessGroup(reason) {
      if (isTerminating || didSettle) return;
      isTerminating = true;
      if (timeoutHandle) clearTimeout(timeoutHandle);
      try {
        if (processGroupID && childIsActive()) {
          signalProcessGroup(processGroupID, 'SIGTERM');
        }
        await delay(TERMINATION_GRACE_MILLISECONDS);
        if (
          processGroupID &&
          childIsActive() &&
          processGroupExists(processGroupID)
        ) {
          signalProcessGroup(processGroupID, 'SIGKILL');
          await delay(TERMINATION_CONFIRM_MILLISECONDS);
        }
        if (
          processGroupID &&
          (childIsActive() || processGroupExists(processGroupID))
        ) {
          ownedOracleProcessGroupMayRemain = true;
        }
        settle(
          new Error(
            `${reason}; ${ownedOracleProcessGroupMayRemain ? `owned process group ${String(processGroupID)} may remain and temporary files were retained` : `owned process group ${String(processGroupID)} was terminated`}`,
          ),
        );
      } catch (error) {
        ownedOracleProcessGroupMayRemain = true;
        settle(
          new Error(
            `${reason}; could not terminate owned process group ${String(processGroupID)} and temporary files were retained: ${error instanceof Error ? error.message : String(error)}`,
          ),
        );
      }
    }

    const parentSignalHandlers = new Map(
      handledSignals.map(signal => [
        signal,
        () => {
          process.exitCode = signalExitCodes[signal];
          void terminateOwnedProcessGroup(
            `Generator was interrupted by ${signal}`,
          );
        },
      ]),
    );
    function handleParentExit() {
      if (processGroupID && childIsActive()) {
        try {
          signalProcessGroup(processGroupID, 'SIGTERM');
        } catch {
          // The durable ownership record is retained for coordinator recovery.
        }
      }
    }
    for (const signal of handledSignals) {
      process.once(signal, parentSignalHandlers.get(signal));
    }
    process.once('exit', handleParentExit);

    try {
      child = spawn(command, args, {
        cwd: options.cwd ?? checkout,
        detached: true,
        env: options.env,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      processGroupID = child.pid;
    } catch (error) {
      settle(error);
      return;
    }

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      stdout += chunk;
    });
    child.stderr.on('data', chunk => {
      stderr += chunk;
    });
    child.once('error', error => settle(error));
    child.once('close', (status, signal) => {
      if (isTerminating || didSettle) return;
      let processGroupRemains = false;
      try {
        processGroupRemains = Boolean(
          processGroupID && processGroupExists(processGroupID),
        );
      } catch (error) {
        ownedOracleProcessGroupMayRemain = true;
        settle(
          new Error(
            `Could not confirm exit of oracle process group ${String(processGroupID)}; temporary files were retained: ${error instanceof Error ? error.message : String(error)}`,
          ),
        );
        return;
      }
      if (processGroupRemains) {
        ownedOracleProcessGroupMayRemain = true;
        settle(
          new Error(
            `Oracle child ${String(processGroupID)} exited but its owned process group remains; temporary files were retained`,
          ),
        );
        return;
      }
      if (status !== 0) {
        settle(
          new Error(
            `${command} ${args.join(' ')} failed with status ${String(status)}${signal ? ` (${signal})` : ''}`,
          ),
        );
        return;
      }
      settle();
    });

    if (!processGroupID) {
      settle(new Error('Oracle child did not report a process ID'));
      return;
    }
    try {
      const ownershipFile = openSync(ownershipRecord, 'wx');
      try {
        writeFileSync(
          ownershipFile,
          `${JSON.stringify(
            {
              schemaVersion: 1,
              pid: processGroupID,
              processGroupID,
              createdAt: new Date().toISOString(),
            },
            null,
            2,
          )}\n`,
        );
        fsyncSync(ownershipFile);
      } finally {
        closeSync(ownershipFile);
      }
    } catch (error) {
      void terminateOwnedProcessGroup(
        `Could not record oracle process-group ownership: ${error instanceof Error ? error.message : String(error)}`,
      );
      return;
    }
    timeoutHandle = setTimeout(
      () =>
        void terminateOwnedProcessGroup(
          `Oracle child ${String(processGroupID)} exceeded ${String(ORACLE_TIMEOUT_MILLISECONDS)}ms`,
        ),
      ORACLE_TIMEOUT_MILLISECONDS,
    );
  });
}

function hashedFiles(paths, root) {
  return paths.map(path => ({
    path,
    sha256: sha256(readFileSync(join(root, path))),
  }));
}

function hashedPath(path) {
  const manifestPath = relative(checkout, path);
  if (
    manifestPath === '' ||
    manifestPath === '..' ||
    manifestPath.startsWith(`..${sep}`)
  ) {
    throw new Error(`Provenance path is outside the isolated checkout: ${path}`);
  }
  return {
    path: manifestPath,
    sha256: sha256(readFileSync(path)),
  };
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
  if (
    manifest.generation.environment.TZ !== 'UTC' ||
    manifest.generation.executionCeilingMilliseconds !==
      ORACLE_TIMEOUT_MILLISECONDS ||
    manifest.generation.terminationGraceMilliseconds !==
      TERMINATION_GRACE_MILLISECONDS
  ) {
    throw new Error('Manifest execution provenance mismatch');
  }
  if (
    manifest.dependencies.nativeSQLite.packageName !== 'better-sqlite3' ||
    manifest.dependencies.nativeSQLite.version !==
      EXPECTED_BETTER_SQLITE3_VERSION
  ) {
    throw new Error('Manifest native SQLite provenance mismatch');
  }
  if (manifest.fixture.caseCount !== expectedCaseIDs.length) {
    throw new Error('Manifest case count mismatch');
  }
  if (
    JSON.stringify(manifest.fixture.caseIDs) !== JSON.stringify(expectedCaseIDs)
  ) {
    throw new Error('Manifest case IDs mismatch');
  }
  const dependencyFiles = [
    manifest.dependencies.lockfile,
    manifest.dependencies.yarnConfiguration,
    manifest.dependencies.installState,
    manifest.dependencies.nativeSQLite.packageManifest,
    manifest.dependencies.nativeSQLite.resolvedEntry,
    manifest.dependencies.nativeSQLite.binary,
  ];
  const expectedDependencyPaths = [
    'yarn.lock',
    '.yarnrc.yml',
    'node_modules/.yarn-state.yml',
    'node_modules/better-sqlite3/package.json',
    'node_modules/better-sqlite3/lib/index.js',
  ];
  if (
    JSON.stringify(dependencyFiles.slice(0, -1).map(file => file.path)) !==
      JSON.stringify(expectedDependencyPaths) ||
    !/^node_modules\/better-sqlite3\/.+\/better_sqlite3\.node$/.test(
      dependencyFiles.at(-1).path,
    )
  ) {
    throw new Error('Manifest dependency paths mismatch');
  }
  for (const file of [
    ...manifest.harnessFiles,
    ...manifest.sourceFiles,
    ...dependencyFiles,
  ]) {
    if (!/^[0-9a-f]{64}$/.test(file.sha256)) {
      throw new Error(`Invalid SHA-256 for ${file.path}`);
    }
  }
}

if (!existsSync(join(checkout, '.git'))) {
  throw new Error(`Actual checkout is not a git worktree: ${checkout}`);
}
if (process.platform === 'win32') {
  throw new Error(
    'Account lifecycle oracle execution requires POSIX process-group ownership',
  );
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
for (const temporaryPath of [
  rawOutput,
  vitestOutput,
  ownershipRecord,
  stagingOutput,
]) {
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

const dependencyPaths = {
  lockfile: join(checkout, 'yarn.lock'),
  yarnConfiguration: join(checkout, '.yarnrc.yml'),
  installState: join(checkout, 'node_modules/.yarn-state.yml'),
  nativePackageRoot: join(checkout, 'node_modules/better-sqlite3'),
};
for (const [label, path] of Object.entries(dependencyPaths)) {
  if (!existsSync(path)) {
    throw new Error(`Dependency provenance is missing ${label}: ${path}`);
  }
}

const nativePackageManifestPath = join(
  dependencyPaths.nativePackageRoot,
  'package.json',
);
const nativePackage = JSON.parse(
  readFileSync(nativePackageManifestPath, 'utf8'),
);
if (
  nativePackage.name !== 'better-sqlite3' ||
  nativePackage.version !== EXPECTED_BETTER_SQLITE3_VERSION
) {
  throw new Error(
    `Expected better-sqlite3 ${EXPECTED_BETTER_SQLITE3_VERSION}, found ${String(nativePackage.name)} ${String(nativePackage.version)}`,
  );
}
const nativeEntryPath = join(
  dependencyPaths.nativePackageRoot,
  nativePackage.main ?? 'lib/index.js',
);
const coreRequire = createRequire(
  join(checkout, 'packages/loot-core/package.json'),
);
const resolvedNativeEntry = coreRequire.resolve('better-sqlite3');
if (
  !existsSync(nativeEntryPath) ||
  realpathSync(nativeEntryPath) !== realpathSync(resolvedNativeEntry)
) {
  throw new Error(
    'The @actual-app/core resolver does not select the recorded better-sqlite3 install',
  );
}
const nativePackageRequire = createRequire(nativeEntryPath);
const resolveNativeBinding = nativePackageRequire('bindings');
const resolvedNativeBinaryPath = resolveNativeBinding({
  bindings: 'better_sqlite3.node',
  module_root: dependencyPaths.nativePackageRoot,
  path: true,
});
if (
  typeof resolvedNativeBinaryPath !== 'string' ||
  !existsSync(resolvedNativeBinaryPath)
) {
  throw new Error('bindings did not resolve an available native SQLite binary');
}
const nativePackageRealPath = realpathSync(dependencyPaths.nativePackageRoot);
const nativeBinaryRealPath = realpathSync(resolvedNativeBinaryPath);
const nativeBinaryRelativePath = relative(
  nativePackageRealPath,
  nativeBinaryRealPath,
);
if (
  nativeBinaryRelativePath === '..' ||
  nativeBinaryRelativePath.startsWith(`..${sep}`)
) {
  throw new Error(
    `Resolved native SQLite binary is outside better-sqlite3: ${resolvedNativeBinaryPath}`,
  );
}
const nativeBinaryPath = join(
  dependencyPaths.nativePackageRoot,
  nativeBinaryRelativePath,
);
const dependencyProvenance = {
  lockfile: hashedPath(dependencyPaths.lockfile),
  yarnConfiguration: hashedPath(dependencyPaths.yarnConfiguration),
  installState: hashedPath(dependencyPaths.installState),
  nativeSQLite: {
    packageName: nativePackage.name,
    version: nativePackage.version,
    platform: process.platform,
    architecture: process.arch,
    packageManifest: hashedPath(nativePackageManifestPath),
    resolvedEntry: hashedPath(nativeEntryPath),
    binary: hashedPath(nativeBinaryPath),
  },
};

const testArgv = [
  '.yarn/releases/yarn-4.17.1.cjs',
  'workspace',
  '@actual-app/core',
  'run',
  'test:node',
  'src/server/accounts/account-lifecycle-parity.test.ts',
  '--bail=1',
  '--reporter=json',
  `--outputFile=${vitestOutput}`,
];

try {
  for (const file of harnessFiles) {
    cpSync(join(scriptRoot, 'harness', file), join(overlayRoot, file), {
      errorOnExist: true,
    });
  }

  await runOracle('node', testArgv, {
    env: {
      ...process.env,
      ACTUALIST_ACCOUNT_LIFECYCLE_ORACLE_OUTPUT: rawOutput,
      TZ: 'UTC',
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
      argv: [
        'node',
        ...testArgv.map(value =>
          value === `--outputFile=${vitestOutput}`
            ? '--outputFile=<isolated-actual-checkout>/.actualist-account-lifecycle-vitest-<invocation-id>.json'
            : value,
        ),
      ],
      environment: {
        ACTUALIST_ACCOUNT_LIFECYCLE_ORACLE_OUTPUT:
          '<isolated-actual-checkout>/.actualist-account-lifecycle-oracle.json',
        TZ: 'UTC',
      },
      executionCeilingMilliseconds: ORACLE_TIMEOUT_MILLISECONDS,
      terminationGraceMilliseconds: TERMINATION_GRACE_MILLISECONDS,
      processOwnership: 'detached POSIX process group',
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
    dependencies: dependencyProvenance,
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
  if (ownedOracleProcessGroupMayRemain) {
    console.error(
      [
        'Oracle process-group exit could not be confirmed; refusing to remove temporary overlays or outputs:',
        ...harnessFiles.map(file => `  ${join(overlayRoot, file)}`),
        `  ${rawOutput}`,
        `  ${vitestOutput}`,
        `  ${ownershipRecord}`,
        `  ${stagingOutput}`,
      ].join('\n'),
    );
  } else {
    for (const file of harnessFiles) {
      rmSync(join(overlayRoot, file), { force: true });
    }
    rmSync(rawOutput, { force: true });
    rmSync(vitestOutput, { force: true });
    rmSync(ownershipRecord, { force: true });
    rmSync(stagingOutput, { recursive: true, force: true });
  }
}
