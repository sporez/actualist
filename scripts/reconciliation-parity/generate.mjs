#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
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
// Sources behind evidence that is not in the reviewed contract list above:
// the Done stamp site (Account.tsx, not exported, so only source-guarded) and
// the loot-core rules engine that produced the D3 rules-run outcome, and the
// loot-core handlers behind the real-execution unlock cases.
const evidenceSourceFiles = [
  'packages/desktop-client/src/components/accounts/Account.tsx',
  'packages/loot-core/src/server/transactions/transaction-rules.ts',
  'packages/loot-core/src/server/rules/rule.ts',
  'packages/loot-core/src/server/rules/action.ts',
  // The unlock-* cases run the query and batch-update handlers on real rows.
  'packages/loot-core/src/server/main.ts',
  'packages/loot-core/src/server/transactions/app.ts',
];
const DONE_STAMP = /await reconciliation\.finishReconciliation\(\s*account\.id,\s*reconcileAmount,\s*\(\) =>\s*this\.lockTransactions\(\),\s*\);\s*const lastReconciled = new Date\(\)\.getTime\(\)\.toString\(\);\s*this\.props\.onUpdateAccount\(\{ \.\.\.account, last_reconciled: lastReconciled \}\);/;

const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), '..', '..');
const helperPath = join(root, 'scripts/parity/lib/oracle-pin.mjs');
const checking = process.argv.includes('--check');

if (!hasOracleRoot()) {
  console.error(
    `Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`,
  );
  process.exit(2);
}

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

const oracleRoot = pinnedOracleRoot();
const defaultOutput = pinnedFixtureDirectory('Reconciliation');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-reconciliation-check-'))
  : resolve(argument('--output') ?? defaultOutput);

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: oracleRoot, encoding: 'utf8', ...options });
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw new Error(`${command} ${args.join(' ')} failed`);
  }
  return result.stdout.trim();
}

const packageVersion = JSON.parse(
  readFileSync(join(oracleRoot, 'packages/desktop-client/package.json'), 'utf8'),
).version;
if (packageVersion !== oraclePin.packageVersion) {
  throw new Error(`Expected @actual-app/web ${oraclePin.packageVersion}, found ${packageVersion}`);
}
for (const path of [...sourceFiles, ...evidenceSourceFiles]) {
  if (!existsSync(join(oracleRoot, path))) throw new Error(`Pinned source is missing: ${path}`);
}

const yarnPath = join(oracleRoot, '.yarn/releases/yarn-4.17.1.cjs');
if (!existsSync(yarnPath)) {
  throw new Error('Install the pinned Actual checkout with Yarn 4.17.1 before generating');
}

// Stage 1 (loot-core): run Actual's real rules engine on the adjustment that
// the rules-run call receives, with a rule that clears its notes, and run the
// unlock call sequence on real rows (the four unlock-* cases).
const coreRunnerRelative = 'packages/loot-core/src/server/transactions/__actualist_reconciliation_rules.test.ts';
const coreRunnerPath = join(oracleRoot, coreRunnerRelative);
const coreOutputPath = join(oracleRoot, '.actualist-reconciliation-rules.json');
if (existsSync(coreRunnerPath)) throw new Error(`Refusing to overwrite ${coreRunnerRelative}`);

const coreRunner = String.raw`import { writeFileSync } from 'node:fs';
import { afterAll, beforeEach, expect, test } from 'vitest';

import { currentDay } from '../../shared/months';
import { q } from '../../shared/query';
import {
  realizeTempTransactions,
  ungroupTransactions,
  updateTransaction,
} from '../../shared/transactions';
import * as db from '../db';
import { handlers } from '../main';
import { runHandler } from '../mutators';
import { insertRule, loadRules, resetState, runRules } from './transaction-rules';

const output: Record<string, unknown> = {};
afterAll(() => {
  const outputPath = process.env.ACTUALIST_RECONCILIATION_RULES_OUTPUT;
  expect(outputPath).toBeTruthy();
  writeFileSync(outputPath!, JSON.stringify(output, null, 2) + '\n');
});

const rule = {
  stage: 'pre',
  conditionsOp: 'and',
  conditions: [{ op: 'contains', field: 'notes', value: 'Reconciliation' }],
  actions: [{ op: 'set', field: 'notes', value: null }],
};

// Ids are database-generated and sort_order is Date.now(); neither is recorded.
const normalize = transaction => JSON.parse(JSON.stringify({
  ...transaction,
  id: '<generated>',
  date: '<current-day>',
  sort_order: undefined,
}));

beforeEach(async () => {
  await global.emptyDatabase()();
  resetState();
});

test('loot-core rules engine output for an adjustment whose rule clears notes', async () => {
  await insertRule(rule);
  await loadRules();
  const [realized] = realizeTempTransactions([
    {
      id: 'temp',
      account: 'checking',
      cleared: true,
      reconciled: false,
      amount: 2500,
      date: currentDay(),
      notes: 'Reconciliation balance adjustment',
    },
  ]);
  const ruleOutput = await runRules(JSON.parse(JSON.stringify(realized)));
  Object.assign(output, { rule, input: normalize(realized), output: normalize(ruleOutput) });
});

// Real execution of the desktop unlockTransaction call sequence
// (packages/desktop-client/src/accounts/reconciliation.ts). That function is not
// importable from loot-core, so the sequence is reproduced here: the grouped query
// goes through the 'query' handler the client's send('query', ...) reaches, then
// ungroupTransactions, updateTransaction and the real transactions-batch-update
// handler run unchanged. Only this call order is harness glue.
const row = (overrides: Record<string, unknown>) => ({
  account: 'checking', date: '2026-09-14', amount: -2500, category: null, payee: null,
  notes: null, cleared: true, reconciled: false, is_parent: false, is_child: false,
  ...overrides,
});
const family = (parentReconciled: boolean) => [
  row({ id: 'parent', amount: -5000, is_parent: true, reconciled: parentReconciled }),
  row({ id: 'child-a', amount: -2000, is_child: true, parent_id: 'parent', reconciled: true }),
  row({ id: 'child-b', amount: -3000, is_child: true, parent_id: 'parent', reconciled: true }),
];
const unlockPlans = [
  { id: 'unlock-split-member', transactionId: 'child-a', rows: family(true) },
  { id: 'unlock-split-parent', transactionId: 'parent', rows: family(true) },
  { id: 'unlock-split-member-unreconciled-parent', transactionId: 'child-a', rows: family(false) },
  { id: 'unlock-simple-row', transactionId: 'simple', rows: [row({ id: 'simple', reconciled: true })] },
];
const reconciledRows = async () =>
  Object.fromEntries(
    (await db.all('SELECT id, reconciled FROM transactions ORDER BY id')).map(
      (entry: any) => [entry.id, entry.reconciled === 1],
    ),
  );
// Grouped form for seeding a replay: each parent carries its children.
const grouped = (rows: any[]) =>
  rows.filter(entry => !entry.is_child).map(entry => ({
    ...entry,
    ...(entry.is_parent
      ? { subtransactions: rows.filter(child => child.parent_id === entry.id) }
      : {}),
  }));

test('unlockTransaction call sequence on real rows', async () => {
  const unlock: unknown[] = [];
  for (const plan of unlockPlans) {
    await global.emptyDatabase()();
    resetState();
    await db.insertAccount({ id: 'checking', name: 'Checking' });
    for (const entry of plan.rows) await db.insertTransaction(entry as any);
    const before = await reconciledRows();

    const query = q('transactions')
      .filter({ id: plan.transactionId })
      .select('*')
      .options({ splits: 'grouped' });
    const { data } = await handlers['query'](query.serialize());
    const transactions = ungroupTransactions(data);
    const transaction = transactions.find(entry => entry.id === plan.transactionId);
    let sent: unknown = null;
    if (transaction) {
      const { diff } = updateTransaction(transactions, { ...transaction, reconciled: false });
      sent = JSON.parse(JSON.stringify(diff.updated));
      await runHandler(handlers['transactions-batch-update'], { updated: diff.updated }, {
        name: 'transactions-batch-update',
      });
    }
    const after = await reconciledRows();
    unlock.push({
      id: plan.id,
      input: {
        transactionId: plan.transactionId,
        rows: grouped(plan.rows),
        groupedQueryResult: transactions.map(entry => ({
          id: entry.id,
          is_parent: entry.is_parent ?? false,
          is_child: entry.is_child ?? false,
          parent_id: entry.parent_id ?? null,
          reconciled: entry.reconciled ?? null,
        })),
      },
      // Recorded as sent: the fields are not projected, so a missing field stays visible.
      value: sent,
      readback: {
        before,
        after,
        changed: Object.keys(after).filter(id => after[id] !== before[id]),
      },
    });
  }
  output.unlock = unlock;
});
`;

let coreRules;
let coreUnlock;
try {
  writeFileSync(coreRunnerPath, coreRunner);
  rmSync(coreOutputPath, { force: true });
  run(process.execPath, [
    yarnPath, 'workspace', '@actual-app/core', 'vitest', '--run',
    'src/server/transactions/__actualist_reconciliation_rules.test.ts', '--reporter=dot',
  ], { env: { ...process.env, ACTUALIST_RECONCILIATION_RULES_OUTPUT: coreOutputPath }, stdio: 'pipe' });
  ({ unlock: coreUnlock, ...coreRules } = JSON.parse(readFileSync(coreOutputPath, 'utf8')));
} finally {
  rmSync(coreRunnerPath, { force: true });
  rmSync(coreOutputPath, { force: true });
}

// Stage 2 (desktop-client): drive the reconciliation flows with scripted AQL
// and rules-run results. The D3 rules-run must receive the adjustment the core
// stage ran, or the test fails.
const runnerRelative = 'packages/desktop-client/src/accounts/__actualist_reconciliation_oracle.test.ts';
const runnerPath = join(oracleRoot, runnerRelative);
const temporaryOutput = join(oracleRoot, '.actualist-reconciliation-oracle.json');
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

const coreRules = ${JSON.stringify(coreRules)};
const copy = (value: unknown): any => JSON.parse(JSON.stringify(value));
const cases: Array<{ id: string; input?: unknown; value: unknown }> = [];
const entities = {
  note: 'Refs are the literal account, payee and category ids the oracle uses. Names are scripted labels for seeding a database; the oracle does not produce them.',
  accounts: [{ ref: 'checking', name: 'Checking' }, { ref: 'savings', name: 'Savings' }],
  payees: [{ ref: 'bank', name: 'Bank' }],
  categories: [{ ref: 'fees', name: 'Fees' }],
};
const adjustmentTemp = {
  id: 'temp',
  account: 'checking',
  cleared: true,
  reconciled: false,
  amount: 2500,
  date: '<current-day>',
  notes: 'Reconciliation balance adjustment',
};
const rulesRunOutcome = {
  account: 'savings',
  amount: 1700,
  date: '2026-09-01',
  cleared: false,
  category: 'fees',
  payee: 'bank',
  notes: 'rule changed',
};
const ruleDeleteOutcome = { tombstone: true };
const splitRulesRunOutcome = {
  amount: 3000,
  is_parent: true,
  children: [
    { id: 'child-a', amount: 1000 },
    { id: 'child-b', amount: 2000 },
  ],
};

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
  parentID: value.parent_id ? '<generated>' : null,
  children: (value.subtransactions ?? []).map((child: any) => selected(child, normalizeDate)),
});
const batchOf = () => mocks.send.mock.calls.find(call => call[0] === 'transactions-batch-update')?.[1];

beforeEach(() => {
  mocks.send.mockReset();
  mocks.aqlQuery.mockReset();
});

test('cleared balance query and result', async () => {
  const scriptedRows = [
    { id: 'cleared-1', account: 'checking', cleared: true, amount: -10000 },
    { id: 'cleared-2', account: 'checking', cleared: true, amount: 1700 },
    { id: 'uncleared', account: 'checking', cleared: false, amount: 500 },
    { id: 'other-account', account: 'savings', cleared: true, amount: 900 },
  ];
  mocks.aqlQuery.mockImplementationOnce(async () => ({
    data: scriptedRows
      .filter(row => row.cleared && row.account === 'checking')
      .reduce((sum, row) => sum + row.amount, 0),
  }));
  const balance = await getClearedBalance('checking');
  const query = mocks.aqlQuery.mock.calls[0][0];
  cases.push({
    id: 'cleared-balance',
    input: { accountRef: 'checking', scriptedRows },
    value: { balance, query: JSON.parse(JSON.stringify(query)) },
  });
});

test('finish locks only a fresh zero difference', async () => {
  const lock = vi.fn();
  mocks.aqlQuery.mockResolvedValueOnce({ data: 4000 });
  await finishReconciliation('checking', 4000, lock);
  const zeroLockCount = lock.mock.calls.length;
  mocks.aqlQuery.mockResolvedValueOnce({ data: 3500 });
  await finishReconciliation('checking', 4000, lock);
  cases.push({
    id: 'finish',
    input: {
      accountRef: 'checking',
      zeroDifference: { reconcileAmount: 4000, clearedBalance: 4000 },
      nonzeroDifference: { reconcileAmount: 4000, clearedBalance: 3500 },
    },
    value: { zeroDifferenceLocks: zeroLockCount, nonzeroDifferenceLocks: lock.mock.calls.length - zeroLockCount },
  });
});

test('adjustment realizes defaults then preserves complete rule output', async () => {
  let realized: any[] = [];
  mocks.send.mockImplementation(async (name: string, payload: any) => {
    if (name === 'rules-run') return { ...payload.transaction, ...rulesRunOutcome };
  });
  await createReconciliationTransaction('checking', 2500, value => { realized = value; });
  const batch = batchOf();

  mocks.send.mockReset();
  mocks.send.mockImplementation(async (name: string, payload: any) => {
    if (name === 'rules-run') {
      return {
        ...payload.transaction,
        amount: splitRulesRunOutcome.amount,
        is_parent: splitRulesRunOutcome.is_parent,
        subtransactions: splitRulesRunOutcome.children.map(child =>
          transaction({ ...child, is_child: true, parent_id: payload.transaction.id }),
        ),
      };
    }
  });
  await createReconciliationTransaction('checking', 3000);
  const splitBatch = batchOf();
  cases.push({
    id: 'adjustment-rule-projection',
    input: {
      accountRef: 'checking',
      diff: 2500,
      realizedTemp: adjustmentTemp,
      rulesRunOutcome,
      splitDiff: 3000,
      splitRulesRunOutcome,
    },
    value: {
      realized: selected(realized[0]),
      added: batch.added.map((value: any) => selected(value, false)),
      deleted: batch.deleted.map((value: any) => selected(value, false)),
      splitAdded: splitBatch.added.map((value: any) => selected(value)),
    },
  });
});

test('rule deletion is sent as deletion rather than addition', async () => {
  mocks.send.mockImplementation(async (name: string, payload: any) =>
    name === 'rules-run' ? { ...payload.transaction, ...ruleDeleteOutcome } : undefined,
  );
  await createReconciliationTransaction('checking', -900);
  const batch = batchOf();
  cases.push({
    id: 'adjustment-rule-delete',
    input: { accountRef: 'checking', diff: -900, rulesRunOutcome: ruleDeleteOutcome },
    value: {
      addedCount: batch.added.length,
      deletedCount: batch.deleted.length,
      deleted: batch.deleted.map((value: any) => selected(value)),
    },
  });
});

test('lock reconciles simple and split family rows', async () => {
  const rows = [
    transaction(),
    transaction({ id: 'parent', amount: -5000, is_parent: true, subtransactions: [
      transaction({ id: 'child-a', amount: -2000, is_child: true, parent_id: 'parent' }),
      transaction({ id: 'child-b', amount: -3000, is_child: true, parent_id: 'parent' }),
    ] }),
  ];
  mocks.aqlQuery.mockResolvedValueOnce({ data: copy(rows) });
  await lockTransactions('checking');
  const batch = batchOf();
  cases.push({
    id: 'lock',
    input: { accountRef: 'checking', rows },
    value: batch.updated
      .map((value: any) => ({ id: value.id, reconciled: value.reconciled }))
      .sort((a: any, b: any) => a.id.localeCompare(b.id)),
  });
});

test('unlock clears reconciled and preserves cleared', async () => {
  const rows = [transaction({ reconciled: true })];
  mocks.aqlQuery.mockResolvedValueOnce({ data: copy(rows) });
  await unlockTransaction('simple');
  const batch = batchOf();
  cases.push({
    id: 'unlock',
    input: { transactionId: 'simple', rows },
    value: batch.updated.map((value: any) => ({ id: value.id, cleared: value.cleared, reconciled: value.reconciled })),
  });
});

test('done with a nonzero difference locks nothing and sends nothing', async () => {
  const lock = vi.fn();
  mocks.aqlQuery.mockResolvedValueOnce({ data: 3500 });
  await finishReconciliation('checking', 4000, lock);
  cases.push({
    id: 'done-nonzero-difference',
    input: { accountRef: 'checking', reconcileAmount: 4000, clearedBalance: 3500 },
    value: { lockCalls: lock.mock.calls.length, sendCalls: mocks.send.mock.calls.length },
  });
});

test('adjustment with a rule that clears notes replays the loot-core rules output', async () => {
  let realized: any[] = [];
  mocks.send.mockImplementation(async (name: string, payload: any) => {
    if (name === 'rules-run') {
      const { id, sort_order, ...actual } = payload.transaction;
      expect({ ...actual, id: '<generated>', date: '<current-day>' }).toEqual(coreRules.input);
      return { ...coreRules.output, id, date: payload.transaction.date };
    }
  });
  await createReconciliationTransaction('checking', 2500, value => { realized = value; });
  const batch = batchOf();
  cases.push({
    id: 'adjustment-rule-clears-notes',
    input: {
      accountRef: 'checking',
      diff: 2500,
      ruleEngine: 'loot-core runRules, recorded by the core stage',
      rule: coreRules.rule,
      ruleEngineInput: coreRules.input,
      ruleEngineOutput: coreRules.output,
    },
    value: {
      realized: selected(realized[0]),
      added: batch.added.map((value: any) => selected(value)),
      deleted: batch.deleted.map((value: any) => selected(value)),
    },
  });
});

afterAll(() => {
  writeFileSync('${temporaryOutput}', JSON.stringify({
    schemaVersion: ${SCHEMA_VERSION},
    oracle: { tag: '${oraclePin.tag}', commit: '${oraclePin.commit}', packageVersion: '${oraclePin.packageVersion}' },
    entities,
    cases,
  }, null, 2) + '\n');
});
`;

let generated;
try {
  writeFileSync(runnerPath, runner);
  run(process.execPath, [
    yarnPath, 'workspace', '@actual-app/web', 'vitest', '--run',
    runnerRelative.replace('packages/desktop-client/', ''), '--reporter=dot',
  ]);
  generated = JSON.parse(readFileSync(temporaryOutput, 'utf8'));
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(temporaryOutput, { force: true });
}
assertPinnedOracle(oracleRoot, 'after generating');

const EXPECTED_CASES = 8;
if (!Array.isArray(generated.cases) || generated.cases.length !== EXPECTED_CASES) {
  throw new Error(`Oracle did not produce ${EXPECTED_CASES} reviewed cases`);
}
// The unlock cases come from the loot-core stage (real rows, real grouped query).
const EXPECTED_UNLOCK_CASES = 4;
if (!Array.isArray(coreUnlock) || coreUnlock.length !== EXPECTED_UNLOCK_CASES) {
  throw new Error(`Core stage did not produce ${EXPECTED_UNLOCK_CASES} unlock cases`);
}
generated.cases.push(...coreUnlock);

// D2 is not run: onDoneReconciling lives on the unexported AccountInternal
// class. Record the Done stamp only after the source guard matches.
const accountSource = readFileSync(join(oracleRoot, evidenceSourceFiles[0]), 'utf8');
if (!DONE_STAMP.test(accountSource)) {
  throw new Error('Account.tsx no longer stamps last_reconciled unconditionally after Done');
}
const doneCase = generated.cases.find(value => value.id === 'done-nonzero-difference');
doneCase.value.lastReconciledStamp = {
  evidence: 'source-guard, not executed',
  file: evidenceSourceFiles[0],
  stampedAfterDoneRegardlessOfDifference: true,
  field: 'last_reconciled',
  format: 'new Date().getTime().toString() milliseconds',
};

const fixtureName = 'reconciliation-contract.json';
const fixtureText = JSON.stringify(generated, null, 2) + '\n';
mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, fixtureName), fixtureText);

const reconciliationSource = readFileSync(join(oracleRoot, sourceFiles[0]), 'utf8');
const accountTransactionsSource = readFileSync(join(oracleRoot, sourceFiles[2]), 'utf8');
if (!accountTransactionsSource.includes('last_reconciled: new Date().getTime().toString()')) {
  throw new Error('Actual no longer stores last_reconciled as a millisecond string');
}
// Oracle cases Actualist does not replay. Each reason is a product or coverage fact, not a divergence.
const oracleOnly = [
  {
    id: 'adjustment-rule-projection',
    reason:
      'expected output comes from a scripted rules-run outcome; no production rules seed reproduces it without a seam (real-rules coverage: adjustment-rule-clears-notes; Phase 4 rules harness).',
  },
  {
    id: 'done-nonzero-difference',
    reason:
      'source-guard only, the oracle client stamp rule is not executed.',
  },
];
const caseIDs = generated.cases.map(testCase => testCase.id);
const oracleOnlyIDs = oracleOnly.map(entry => entry.id);
if (
  new Set(caseIDs).size !== caseIDs.length ||
  new Set(oracleOnlyIDs).size !== oracleOnlyIDs.length ||
  oracleOnly.some(entry => !caseIDs.includes(entry.id) || entry.reason.trim() === '')
) {
  throw new Error('Reconciliation oracle-only entries are invalid');
}

const manifest = {
  schemaVersion: SCHEMA_VERSION,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/reconciliation-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: [{ path: relative(root, helperPath), sha256: sha256(readFileSync(helperPath)) }],
  seed: null,
  amountUnits: 'integer minor units',
  lastReconciledStorage: 'new Date().getTime().toString() milliseconds',
  sourceFiles: sourceFiles.map(path => ({ path, sha256: sha256(readFileSync(join(oracleRoot, path))) })),
  evidenceSourceFiles: evidenceSourceFiles.map(path => ({
    path,
    sha256: sha256(readFileSync(join(oracleRoot, path))),
  })),
  fixture: {
    path: relative(root, join(defaultOutput, fixtureName)),
    sha256: sha256(fixtureText),
    caseCount: generated.cases.length,
    caseIDs,
  },
  oracleOnly,
  caseCount: generated.cases.length,
  contractSourceSha256: sha256(reconciliationSource),
};
writeFileSync(join(outputRoot, 'reconciliation-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

if (checking) {
  const failures = compareWithCommitted(defaultOutput, outputRoot, [fixtureName, 'reconciliation-manifest.json']);
  rmSync(outputRoot, { recursive: true, force: true });
  if (failures.length > 0) {
    for (const failure of failures) console.error(`reconciliation parity drift: ${failure}`);
    process.exit(1);
  }
  console.log(`Reconciliation parity fixture matches a fresh generation (${generated.cases.length} cases).`);
} else {
  console.log(`Generated reconciliation parity fixture (${oraclePin.tag}, ${generated.cases.length} cases).`);
}
