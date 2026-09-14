#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const EXPECTED_TAG = 'v26.9.0';
const EXPECTED_COMMIT = '59fe126f637d858c061e1eeedbef5436c8f2225a';
const EXPECTED_VERSION = '26.9.0';
const SCHEMA_VERSION = 1;
const sourceFiles = [
  'packages/desktop-client/src/accounts/reconciliation.ts',
  'packages/desktop-client/src/components/mobile/accounts/ReconcilingBanner.tsx',
  'packages/desktop-client/src/components/mobile/accounts/AccountTransactions.tsx',
  'packages/desktop-client/src/components/modals/AccountReconcileModal.tsx',
  'packages/desktop-client/src/components/accounts/Reconcile.test.tsx',
  'packages/loot-core/migrations/1740506588539_add_last_reconciled_at.sql',
  'packages/loot-core/src/shared/transactions.ts',
  'packages/loot-core/src/server/aql/schema/index.ts',
  'packages/loot-core/src/server/aql/schema/executors.ts',
];

const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), '..', '..');
const outputRoot = resolve(
  argument('--output') ?? join(root, 'ActualistTests/Fixtures/ActualCore26_9_0/Reconciliation'),
);
const checkoutArgument = argument('--actual-checkout');
if (!checkoutArgument) usage();
const checkout = resolve(checkoutArgument);

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

function usage() {
  console.error(
    'Usage: scripts/reconciliation-parity/generate.mjs --actual-checkout <path> [--output <path>]',
  );
  process.exit(2);
}

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function run(command, args, cwd = checkout) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw new Error(`${command} ${args.join(' ')} failed`);
  }
  return result.stdout.trim();
}

if (!existsSync(join(checkout, '.git'))) {
  throw new Error(`Actual checkout is not a git worktree: ${checkout}`);
}
const commit = run('git', ['rev-parse', 'HEAD']);
if (commit !== EXPECTED_COMMIT) throw new Error(`Expected ${EXPECTED_COMMIT}, found ${commit}`);
const tag = run('git', ['describe', '--tags', '--exact-match', 'HEAD']);
if (tag !== EXPECTED_TAG) throw new Error(`Expected ${EXPECTED_TAG}, found ${tag}`);
const packageVersion = JSON.parse(
  readFileSync(join(checkout, 'packages/desktop-client/package.json'), 'utf8'),
).version;
if (packageVersion !== EXPECTED_VERSION) {
  throw new Error(`Expected @actual-app/web ${EXPECTED_VERSION}, found ${packageVersion}`);
}
for (const path of sourceFiles) {
  if (!existsSync(join(checkout, path))) throw new Error(`Pinned source is missing: ${path}`);
}

const runnerRelative = 'packages/desktop-client/src/accounts/__actualist_reconciliation_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const temporaryOutput = join(checkout, '.actualist-reconciliation-oracle.json');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

const runner = String.raw`import { writeFileSync } from 'node:fs';
import { afterAll, beforeEach, expect, test, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ send: vi.fn(), aqlQuery: vi.fn() }));
vi.mock('@actual-app/core/platform/client/connection', () => ({ send: mocks.send }));
vi.mock('#queries/aqlQuery', () => ({ aqlQuery: mocks.aqlQuery }));
vi.mock('i18next', () => ({ t: (value: string) => value }));

import {
  createReconciliationTransaction,
  finishReconciliation,
  getClearedBalance,
  lockTransactions,
  unlockTransaction,
} from './reconciliation';

const cases: Array<{ id: string; value: unknown }> = [];
const transaction = (overrides = {}) => ({
  id: 'simple', account: 'checking', date: '2026-09-14', amount: -2500,
  category: null, payee: null, notes: null, cleared: true, reconciled: false,
  is_parent: false, is_child: false, ...overrides,
});
const selected = (value: any, normalizeDate = true): any => ({
  id: ['child-a', 'child-b'].includes(value.id) ? value.id : value.id ? '<generated>' : null,
  account: value.account ?? null,
  date: value.date ? (normalizeDate ? '<current-day>' : value.date) : null,
  amount: value.amount ?? null, category: value.category ?? null, payee: value.payee ?? null,
  notes: value.notes ?? null, cleared: value.cleared ?? null,
  reconciled: value.reconciled ?? null, tombstone: value.tombstone ?? false,
  isParent: value.is_parent ?? false, isChild: value.is_child ?? false,
  parentID: value.parent_id ?? null,
  children: (value.subtransactions ?? []).map((child: any) => selected(child, normalizeDate)),
});

beforeEach(() => {
  mocks.send.mockReset();
  mocks.aqlQuery.mockReset();
});

test('cleared balance query and result', async () => {
  mocks.aqlQuery.mockResolvedValueOnce({ data: -8300 });
  const balance = await getClearedBalance('checking');
  expect(balance).toBe(-8300);
  const query = mocks.aqlQuery.mock.calls[0][0];
  cases.push({ id: 'cleared-balance', value: { balance, query: JSON.parse(JSON.stringify(query)) } });
});

test('finish locks only a fresh zero difference', async () => {
  const lock = vi.fn();
  mocks.aqlQuery.mockResolvedValueOnce({ data: 4000 });
  await finishReconciliation('checking', 4000, lock);
  const zeroLockCount = lock.mock.calls.length;
  mocks.aqlQuery.mockResolvedValueOnce({ data: 3500 });
  await finishReconciliation('checking', 4000, lock);
  cases.push({ id: 'finish', value: { zeroDifferenceLocks: zeroLockCount, nonzeroDifferenceLocks: lock.mock.calls.length - zeroLockCount } });
});

test('adjustment realizes defaults then preserves complete rule output', async () => {
  let realized: any[] = [];
  mocks.send.mockImplementation(async (name: string, payload: any) => {
    if (name === 'rules-run') {
      return {
        ...payload.transaction,
        account: 'savings', amount: 1700, date: '2026-09-01', cleared: false,
        category: 'fees', payee: 'bank', notes: 'rule changed',
      };
    }
  });
  await createReconciliationTransaction('checking', 2500, value => { realized = value; });
  const batch = mocks.send.mock.calls.find(call => call[0] === 'transactions-batch-update')?.[1];
  cases.push({ id: 'adjustment-rule-projection', value: {
    realized: selected(realized[0]),
    added: batch.added.map((value: any) => selected(value, false)),
    deleted: batch.deleted.map((value: any) => selected(value, false)),
  } });

  mocks.send.mockReset();
  mocks.send.mockImplementation(async (name: string, payload: any) => {
    if (name === 'rules-run') {
      return {
        ...payload.transaction,
        amount: 3000,
        is_parent: true,
        subtransactions: [
          transaction({ id: 'child-a', amount: 1000, is_child: true, parent_id: payload.transaction.id }),
          transaction({ id: 'child-b', amount: 2000, is_child: true, parent_id: payload.transaction.id }),
        ],
      };
    }
  });
  await createReconciliationTransaction('checking', 3000);
  const splitBatch = mocks.send.mock.calls.find(call => call[0] === 'transactions-batch-update')?.[1];
  const projectionCase = cases.find(value => value.id === 'adjustment-rule-projection');
  (projectionCase?.value as any).splitAdded = splitBatch.added.map((value: any) => selected(value));
});

test('rule deletion is sent as deletion rather than addition', async () => {
  mocks.send.mockImplementation(async (name: string, payload: any) =>
    name === 'rules-run' ? { ...payload.transaction, tombstone: true } : undefined,
  );
  await createReconciliationTransaction('checking', -900);
  const batch = mocks.send.mock.calls.find(call => call[0] === 'transactions-batch-update')?.[1];
  cases.push({ id: 'adjustment-rule-delete', value: {
    addedCount: batch.added.length, deletedCount: batch.deleted.length,
    deleted: batch.deleted.map(selected),
  } });
});

test('lock reconciles simple and split family rows', async () => {
  mocks.aqlQuery.mockResolvedValueOnce({ data: [
    transaction(),
    transaction({ id: 'parent', amount: -5000, is_parent: true, subtransactions: [
      transaction({ id: 'child-a', amount: -2000, is_child: true, parent_id: 'parent' }),
      transaction({ id: 'child-b', amount: -3000, is_child: true, parent_id: 'parent' }),
    ] }),
  ] });
  await lockTransactions('checking');
  const batch = mocks.send.mock.calls.find(call => call[0] === 'transactions-batch-update')?.[1];
  cases.push({ id: 'lock', value: batch.updated.map((value: any) => ({ id: value.id, reconciled: value.reconciled })).sort((a: any, b: any) => a.id.localeCompare(b.id)) });
});

test('unlock clears reconciled and preserves cleared', async () => {
  mocks.aqlQuery.mockResolvedValueOnce({ data: [transaction({ reconciled: true })] });
  await unlockTransaction('simple');
  const batch = mocks.send.mock.calls.find(call => call[0] === 'transactions-batch-update')?.[1];
  cases.push({ id: 'unlock', value: batch.updated.map((value: any) => ({ id: value.id, cleared: value.cleared, reconciled: value.reconciled })) });
});

afterAll(() => {
  writeFileSync('${temporaryOutput}', JSON.stringify({
    schemaVersion: ${SCHEMA_VERSION},
    oracle: { tag: '${EXPECTED_TAG}', commit: '${EXPECTED_COMMIT}', packageVersion: '${EXPECTED_VERSION}' },
    cases,
  }, null, 2) + '\n');
});
`;

try {
  writeFileSync(runnerPath, runner);
  run('node', [
    '.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/web',
    'vitest', '--run', runnerRelative.replace('packages/desktop-client/', ''),
  ]);
  const generated = readFileSync(temporaryOutput);
  const parsed = JSON.parse(generated.toString('utf8'));
  if (!Array.isArray(parsed.cases) || parsed.cases.length !== 6) {
    throw new Error('Oracle did not produce six reviewed cases');
  }
  mkdirSync(outputRoot, { recursive: true });
  const fixturePath = join(outputRoot, 'reconciliation-contract.json');
  writeFileSync(fixturePath, generated);

  const reconciliationSource = readFileSync(join(checkout, sourceFiles[0]), 'utf8');
  const accountTransactionsSource = readFileSync(join(checkout, sourceFiles[2]), 'utf8');
  if (!accountTransactionsSource.includes('last_reconciled: new Date().getTime().toString()')) {
    throw new Error('Actual no longer stores last_reconciled as a millisecond string');
  }
  const manifest = {
    schemaVersion: SCHEMA_VERSION,
    actual: { tag, commit, packageVersion },
    generator: {
      command: 'scripts/reconciliation-parity/generate.mjs --actual-checkout <actual-v26.9.0>',
      sha256: sha256(readFileSync(scriptPath)),
    },
    amountUnits: 'integer minor units',
    lastReconciledStorage: 'new Date().getTime().toString() milliseconds',
    sourceFiles: sourceFiles.map(path => ({ path, sha256: sha256(readFileSync(join(checkout, path))) })),
    fixture: {
      path: relative(root, fixturePath),
      sha256: sha256(generated),
      caseCount: parsed.cases.length,
    },
    contractSourceSha256: sha256(reconciliationSource),
  };
  writeFileSync(join(outputRoot, 'reconciliation-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  console.log(`Generated reconciliation parity fixture (${tag}, ${parsed.cases.length} cases).`);
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(temporaryOutput, { force: true });
}
