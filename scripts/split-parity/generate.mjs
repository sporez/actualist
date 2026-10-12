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

const FIXTURE_SCHEMA_VERSION = 1;
const ID_NORMALIZATION = 'Ids the oracle generates (uuid mock id<N>, or tempid<N> under a temp parent) become <generated-{parent|child|row}-N>, numbered per case in first-encounter order. Explicit ids are kept.';
const GENERATED_ID = /^(temp)?id\d+$/;
const ID_KEYS = new Set(['id', 'parentID', 'parent_id']);

const sourceFiles = [
  'packages/loot-core/src/shared/transactions.ts',
  'packages/loot-core/src/shared/transactions.test.ts',
  'packages/loot-core/src/server/aql/schema/index.ts',
  'packages/loot-core/src/server/aql/schema/executors.ts',
  'packages/loot-core/src/server/transactions/index.ts',
  'packages/loot-core/src/server/transactions/transfer.ts',
  'packages/loot-core/src/server/transactions/transaction-rules.ts',
  'packages/loot-core/src/server/transactions/transaction-rules.test.ts',
  'packages/loot-core/src/server/transactions/__snapshots__/transaction-rules.test.ts.snap',
  'packages/loot-core/src/server/tools/app.ts',
  'packages/loot-core/src/server/rules/rule.ts',
  'packages/loot-core/src/server/rules/action.ts',
  'packages/loot-core/src/server/rules/index.test.ts',
];

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const helperPath = join(repositoryRoot, 'scripts/parity/lib/oracle-pin.mjs');
const defaultOutput = pinnedFixtureDirectory('Splits');
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
const outputDirectory = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-split-check-'))
  : resolve(argument('--output') ?? defaultOutput);

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: oracleRoot,
    encoding: 'utf8',
    ...options,
  });
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw new Error(`${command} ${args.join(' ')} failed`);
  }
  return result.stdout.trim();
}

const packageJSON = JSON.parse(
  readFileSync(join(oracleRoot, 'packages/loot-core/package.json'), 'utf8'),
);
if (packageJSON.version !== oraclePin.packageVersion) {
  throw new Error(`Expected @actual-app/core ${oraclePin.packageVersion}, found ${packageJSON.version}`);
}
for (const path of sourceFiles) {
  if (!existsSync(join(oracleRoot, path))) {
    throw new Error(`Pinned Actual source is missing: ${path}`);
  }
}

const runnerRelativePath = 'packages/loot-core/src/__actualist_split_oracle.test.ts';
const runnerPath = join(oracleRoot, runnerRelativePath);
const temporaryOutput = join(oracleRoot, '.actualist-split-oracle-output.json');
if (existsSync(runnerPath)) {
  throw new Error(`Refusing to overwrite existing oracle runner: ${runnerPath}`);
}

// Every case records `input`: the arguments the oracle received, copied before
// the call so an in-place mutation by the oracle cannot change the record.
const runner = String.raw`import { writeFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';

import { Rule } from './server/rules/rule';
import {
  addSplitTransaction,
  deleteTransaction,
  makeAsNonChildTransactions,
  makeChild,
  recalculateSplit,
  splitTransaction,
  updateTransaction,
} from './shared/transactions';

const oracle = {
  tag: '${oraclePin.tag}',
  commit: '${oraclePin.commit}',
  packageVersion: '${oraclePin.packageVersion}',
};

const copy = value => JSON.parse(JSON.stringify(value));

const baseParent = {
  id: 'parent-1',
  amount: -10000,
  account: 'checking',
  date: '2026-08-15',
  category: 'groceries',
  payee: 'coffee',
  notes: 'parent note',
  cleared: true,
  reconciled: false,
  starting_balance_flag: false,
  sort_order: 100,
};

// Stored rows carry every cell. A key the oracle's diff would see as undefined-versus-null
// is an artifact of a sparse fixture, so update inputs are densified.
function dense(transaction) {
  const row = {
    notes: null,
    is_parent: false,
    is_child: false,
    parent_id: null,
    error: null,
    ...transaction,
  };
  if (row.subtransactions) {
    row.subtransactions = row.subtransactions.map(dense);
  }
  return row;
}

function selected(transaction) {
  return {
    id: transaction.id ?? null,
    amount: transaction.amount ?? null,
    account: transaction.account ?? null,
    date: transaction.date ?? null,
    category: transaction.category ?? null,
    payee: transaction.payee ?? null,
    notes: transaction.notes ?? null,
    cleared: transaction.cleared ?? null,
    reconciled: transaction.reconciled ?? null,
    startingBalance: transaction.starting_balance_flag ?? null,
    sortOrder: transaction.sort_order ?? null,
    isParent: transaction.is_parent ?? false,
    isChild: transaction.is_child ?? false,
    parentID: transaction.parent_id ?? null,
    error: transaction.error ?? null,
    deleted: transaction._deleted ?? false,
  };
}

function selectedFamily(transaction) {
  return {
    parent: selected(transaction),
    children: (transaction.subtransactions ?? []).map(selected),
  };
}

function familyFromRows(rows, parentID = 'parent-1') {
  const parent = rows.find(row => row.id === parentID);
  return {
    rows: rows.map(selected),
    family: parent
      ? selectedFamily({
          ...parent,
          subtransactions: rows.filter(row => row.parent_id === parentID),
        })
      : null,
  };
}

const ruleConditions = [{ op: 'is', field: 'imported_payee', value: 'actualist-oracle' }];

function ruleCase(id, actions, transaction, extra = {}) {
  const input = {
    transaction: { ...copy(transaction), imported_payee: 'actualist-oracle' },
    conditionsOp: 'and',
    conditions: ruleConditions,
    actions,
  };
  const rule = new Rule({
    conditionsOp: 'and',
    conditions: copy(ruleConditions),
    actions: copy(actions),
  });
  return {
    id,
    ...extra,
    input,
    expected: selectedFamily(rule.apply(copy(input.transaction))),
  };
}

const inheritedData = { id: 'child-inherited', amount: -4000, sort_order: -1 };
const overriddenData = {
  id: 'child-overrides',
  amount: 1000,
  category: null,
  payee: null,
  notes: 'child note',
  sort_order: -2,
};
const inheritedChild = makeChild(baseParent, copy(inheritedData));
const overriddenChild = makeChild(baseParent, copy(overriddenData));

const exactInput = {
  ...copy(baseParent),
  is_parent: true,
  payee: null,
  subtransactions: [
    makeChild(baseParent, { id: 'child-1', amount: -6000, sort_order: -1 }),
    makeChild(baseParent, { id: 'child-2', amount: -4000, sort_order: -2 }),
  ],
};
const exactParent = recalculateSplit(copy(exactInput));
const mismatchInput = {
  ...copy(exactParent),
  subtransactions: [
    makeChild(baseParent, { id: 'child-1', amount: -4000, sort_order: -1 }),
    makeChild(baseParent, { id: 'child-2', amount: -5000, sort_order: -2 }),
  ],
};
const mismatchedParent = recalculateSplit(copy(mismatchInput));
const mixedInput = {
  ...copy(exactParent),
  subtransactions: [
    makeChild(baseParent, { id: 'child-1', amount: -11000, sort_order: -1 }),
    makeChild(baseParent, { id: 'child-2', amount: 1000, sort_order: -2 }),
    makeChild(baseParent, { id: 'child-3', amount: 0, sort_order: -3 }),
  ],
};
const mixedSignParent = recalculateSplit(copy(mixedInput));

// Records the children the callback creates, so the input is exactly what the
// oracle's split conversion received.
function splitWith(createChildren) {
  const input = {
    operation: 'splitTransaction',
    transactions: [baseParent],
    id: baseParent.id,
    children: null,
  };
  const result = splitTransaction([copy(baseParent)], baseParent.id, parent => {
    const children = createChildren(parent);
    input.children = copy(children);
    return children;
  });
  return { input, result };
}

const splitConversion = splitWith(parent => [
  makeChild(parent, {
    id: 'child-1',
    amount: -6000,
    category: 'groceries',
    sort_order: -1,
  }),
  makeChild(parent, {
    id: 'child-2',
    amount: -4000,
    category: null,
    payee: null,
    notes: 'override',
    sort_order: -2,
  }),
]);
const zeroSortOrderSplit = splitWith(parent => [
  makeChild(parent, {
    id: 'child-1',
    amount: -10000,
    category: 'groceries',
    sort_order: 0,
  }),
]);

const updateConversionInput = {
  id: baseParent.id,
  subtransactions: [
    {
      id: 'child-1',
      amount: -6000,
      category: 'groceries',
      sort_order: -1,
    },
    {
      id: 'child-2',
      amount: -4000,
      category: null,
      payee: null,
      notes: 'override',
      sort_order: -2,
    },
  ],
};
const denseBaseParent = dense(baseParent);
const updateConversion = updateTransaction(copy([denseBaseParent]), copy(updateConversionInput));
const updateConversionOperation = {
  operation: 'updateTransaction',
  transactions: [denseBaseParent],
  transaction: updateConversionInput,
};

const updateSource = [
  exactParent,
  makeChild(exactParent, {
    id: 'child-1',
    amount: -6000,
    payee: 'coffee',
    notes: 'inherited payee',
    sort_order: -1,
  }),
  makeChild(exactParent, {
    id: 'child-2',
    amount: -4000,
    payee: 'market',
    notes: 'override payee',
    sort_order: -2,
  }),
].map(dense);
const parentPayeeInput = dense({ ...copy(exactParent), payee: 'tea' });
const parentPayeeUpdate = updateTransaction(copy(updateSource), copy(parentPayeeInput));
const parentPayeeOperation = {
  operation: 'updateTransaction',
  transactions: updateSource,
  transaction: parentPayeeInput,
};
const childDelete = deleteTransaction(copy(updateSource), 'child-1');
const childDeleteOperation = {
  operation: 'deleteTransaction',
  transactions: updateSource,
  id: 'child-1',
};
const oneChildSource = [
  exactParent,
  makeChild(exactParent, {
    id: 'only-child',
    amount: -10000,
    category: 'utilities',
    sort_order: -1,
  }),
];
const finalChildDelete = deleteTransaction(copy(oneChildSource), 'only-child');
const finalChildDeleteOperation = {
  operation: 'deleteTransaction',
  transactions: oneChildSource,
  id: 'only-child',
};
const detachChildren = makeAsNonChildTransactions(copy([updateSource[1]]), copy(updateSource));
const detachOperation = {
  operation: 'makeAsNonChildTransactions',
  transactions: [updateSource[1]],
  allTransactions: updateSource,
};

const familyTransformations = {
  schemaVersion: ${FIXTURE_SCHEMA_VERSION},
  oracle,
  amountUnits: 'integer minor units',
  idNormalization: '${ID_NORMALIZATION}',
  cases: [
    {
      id: 'make-child-inheritance-and-null-overrides',
      input: {
        operation: 'makeChild',
        parent: baseParent,
        data: [inheritedData, overriddenData],
      },
      expected: [selected(inheritedChild), selected(overriddenChild)],
    },
    {
      id: 'recalculate-exact-mismatch-and-mixed-sign',
      input: {
        operation: 'recalculateSplit',
        exact: exactInput,
        mismatch: mismatchInput,
        mixedSign: mixedInput,
      },
      expected: {
        exact: selectedFamily(exactParent),
        mismatch: selectedFamily(mismatchedParent),
        mixedSign: selectedFamily(mixedSignParent),
      },
    },
    {
      id: 'low-level-split-conversion-nulls-parent-payee-and-starts-with-error',
      input: splitConversion.input,
      expected: familyFromRows(splitConversion.result.data),
    },
    {
      id: 'split-conversion-zero-sort-order',
      input: zeroSortOrderSplit.input,
      expected: familyFromRows(zeroSortOrderSplit.result.data),
    },
    {
      id: 'update-conversion-materializes-exact-family',
      input: updateConversionOperation,
      expected: {
        result: familyFromRows(updateConversion.data),
        diff: updateConversion.diff,
      },
    },
    {
      id: 'parent-payee-update-preserves-child-override',
      input: parentPayeeOperation,
      expected: {
        result: familyFromRows(parentPayeeUpdate.data),
        diff: parentPayeeUpdate.diff,
      },
    },
    {
      id: 'child-delete-recalculates-parent-error',
      input: childDeleteOperation,
      expected: {
        result: familyFromRows(childDelete.data),
        diff: childDelete.diff,
      },
    },
    {
      id: 'final-child-delete-collapses-parent',
      input: finalChildDeleteOperation,
      expected: {
        result: familyFromRows(finalChildDelete.data),
        diff: finalChildDelete.diff,
      },
    },
    {
      id: 'detach-child-preserves-nonchild-fields',
      input: detachOperation,
      expected: detachChildren,
    },
  ],
};

const RULE_ACTIONS_WHOLE = [
  { op: 'append-notes', value: ' whole', options: { splitIndex: 0 } },
  { op: 'set-split-amount', value: -4000, options: { splitIndex: 1, method: 'fixed-amount' } },
  { op: 'set', field: 'category', value: 'groceries', options: { splitIndex: 1 } },
  { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
  { op: 'set', field: 'category', value: null, options: { splitIndex: 2 } },
];

const splitRuleCases = {
  schemaVersion: ${FIXTURE_SCHEMA_VERSION},
  oracle,
  amountUnits: 'integer minor units',
  rounding: 'JavaScript Math.round: ties toward positive infinity',
  idNormalization: '${ID_NORMALIZATION}',
  cases: [
    ruleCase(
      'index-zero-whole-transaction-and-one-based-children',
      RULE_ACTIONS_WHOLE,
      baseParent,
      { actions: RULE_ACTIONS_WHOLE },
    ),
    ruleCase(
      'negative-half-percent-rounding',
      [
        { op: 'set-split-amount', value: 50, options: { splitIndex: 1, method: 'fixed-percent' } },
        { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
      ],
      { ...baseParent, amount: -5 },
      { parentAmount: -5 },
    ),
    ruleCase(
      'positive-half-percent-rounding',
      [
        { op: 'set-split-amount', value: 50, options: { splitIndex: 1, method: 'fixed-percent' } },
        { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
      ],
      { ...baseParent, amount: 5 },
      { parentAmount: 5 },
    ),
    ruleCase(
      'multiple-negative-remainders-adjust-highest-index',
      [
        { op: 'set-split-amount', value: 0, options: { splitIndex: 1, method: 'remainder' } },
        { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
      ],
      { ...baseParent, amount: -5 },
      { parentAmount: -5 },
    ),
    ruleCase(
      'fixed-before-percent-before-remainder',
      [
        { op: 'set-split-amount', value: 100, options: { splitIndex: 1, method: 'fixed-amount' } },
        { op: 'set-split-amount', value: 50, options: { splitIndex: 2, method: 'fixed-percent' } },
        { op: 'set-split-amount', value: 0, options: { splitIndex: 3, method: 'remainder' } },
      ],
      { ...baseParent, amount: 50 },
      { parentAmount: 50 },
    ),
    ruleCase(
      'formula-and-remainder',
      [
        { op: 'set-split-amount', value: 0, options: { splitIndex: 1, method: 'formula', formula: '=300' } },
        { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
      ],
      { ...baseParent, amount: 100000 },
      { parentAmount: 100000 },
    ),
    ruleCase(
      'effective-child-input-is-not-split',
      [
        { op: 'set-split-amount', value: -4000, options: { splitIndex: 1, method: 'fixed-amount' } },
        { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
      ],
      makeChild(baseParent, { id: 'existing-child', amount: -10000 }),
    ),
  ],
};

const childAmountInput = { ...copy(updateSource[1]), amount: -7000 };
const childAmountUpdate = updateTransaction(copy(updateSource), copy(childAmountInput));
const childAmountOperation = {
  operation: 'updateTransaction',
  transactions: updateSource,
  transaction: childAmountInput,
};
const childZeroAmountInput = { ...copy(updateSource[2]), amount: 0 };
const childZeroAmountUpdate = updateTransaction(copy(updateSource), copy(childZeroAmountInput));
const childZeroAmountOperation = {
  operation: 'updateTransaction',
  transactions: updateSource,
  transaction: childZeroAmountInput,
};
const parentDateInput = dense({
  ...copy(exactParent),
  date: '2026-08-20',
  account: 'savings',
  cleared: false,
});
const parentDateAccountCleared = updateTransaction(copy(updateSource), copy(parentDateInput));
const parentDateOperation = {
  operation: 'updateTransaction',
  transactions: updateSource,
  transaction: parentDateInput,
};
const addedChild = addSplitTransaction(copy(updateSource), 'parent-1');
const addedChildOperation = {
  operation: 'addSplitTransaction',
  transactions: updateSource,
  id: 'parent-1',
};

const mutationCases = {
  schemaVersion: ${FIXTURE_SCHEMA_VERSION},
  oracle,
  amountUnits: 'integer minor units',
  idNormalization: '${ID_NORMALIZATION}',
  cases: [
    {
      id: 'add-child-appends-zero-remainder',
      input: addedChildOperation,
      expected: familyFromRows(addedChild.data),
    },
    {
      id: 'child-amount-update-recalculates-error',
      input: childAmountOperation,
      expected: {
        result: familyFromRows(childAmountUpdate.data),
        diff: childAmountUpdate.diff,
      },
    },
    {
      id: 'child-amount-changed-to-zero',
      input: childZeroAmountOperation,
      expected: {
        result: familyFromRows(childZeroAmountUpdate.data),
        diff: childZeroAmountUpdate.diff,
      },
    },
    {
      id: 'parent-date-account-cleared-propagate',
      input: parentDateOperation,
      expected: {
        result: familyFromRows(parentDateAccountCleared.data),
        diff: parentDateAccountCleared.diff,
      },
    },
    {
      id: 'update-conversion-materializes-exact-family',
      input: updateConversionOperation,
      expected: {
        result: familyFromRows(updateConversion.data),
        diff: updateConversion.diff,
      },
    },
    {
      id: 'parent-payee-update-preserves-child-override',
      input: parentPayeeOperation,
      expected: {
        result: familyFromRows(parentPayeeUpdate.data),
        diff: parentPayeeUpdate.diff,
      },
    },
    {
      id: 'child-delete-recalculates-parent-error',
      input: childDeleteOperation,
      expected: {
        result: familyFromRows(childDelete.data),
        diff: childDelete.diff,
      },
    },
    {
      id: 'final-child-delete-collapses-parent',
      input: finalChildDeleteOperation,
      expected: {
        result: familyFromRows(finalChildDelete.data),
        diff: finalChildDelete.diff,
      },
    },
    {
      id: 'detach-child-preserves-nonchild-fields',
      input: detachOperation,
      expected: detachChildren,
    },
  ],
};

describe('Actualist split oracle export', () => {
  test('writes deterministic vectors', () => {
    const outputPath = process.env.ACTUALIST_SPLIT_ORACLE_OUTPUT;
    expect(outputPath).toBeTruthy();
    writeFileSync(
      outputPath!,
      JSON.stringify({ familyTransformations, splitRuleCases, mutationCases }, null, 2) + '\n',
    );
  });
});
`;

// The oracle generates ids with its uuid mock (id<N>). Replace them per case
// with role-based placeholders so the fixture does not depend on call order.
function normalizeGeneratedIDs(caseValue) {
  const placeholders = new Map();
  const counts = { parent: 0, child: 0, row: 0 };
  const placeholderFor = (id, role) => {
    if (!placeholders.has(id)) {
      counts[role] += 1;
      placeholders.set(id, `<generated-${role}-${counts[role]}>`);
    }
    return placeholders.get(id);
  };
  const walk = value => {
    if (Array.isArray(value)) return value.map(walk);
    if (value === null || typeof value !== 'object') return value;
    const role = value.isParent === true || value.is_parent === true
      ? 'parent'
      : value.isChild === true || value.is_child === true
        ? 'child'
        : 'row';
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => {
        if (ID_KEYS.has(key) && typeof item === 'string' && GENERATED_ID.test(item)) {
          return [key, placeholderFor(item, key === 'id' ? role : 'parent')];
        }
        return [key, walk(item)];
      }),
    );
  };
  return walk(caseValue);
}

function normalizeFixture(fixture) {
  return { ...fixture, cases: fixture.cases.map(normalizeGeneratedIDs) };
}

mkdirSync(outputDirectory, { recursive: true });
let generated;
try {
  writeFileSync(runnerPath, runner);
  rmSync(temporaryOutput, { force: true });
  const yarnPath = join(oracleRoot, '.yarn/releases/yarn-4.17.1.cjs');
  if (!existsSync(yarnPath)) {
    throw new Error('Install the pinned Actual checkout with Yarn 4.17.1 before generating');
  }
  run(
    process.execPath,
    [
      yarnPath,
      'workspace',
      '@actual-app/core',
      'vitest',
      '--run',
      'src/__actualist_split_oracle.test.ts',
      '--reporter=dot',
    ],
    {
      env: { ...process.env, ACTUALIST_SPLIT_ORACLE_OUTPUT: temporaryOutput },
      stdio: 'pipe',
    },
  );
  generated = JSON.parse(readFileSync(temporaryOutput, 'utf8'));
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(temporaryOutput, { force: true });
}
assertPinnedOracle(oracleRoot, 'after generating');

const fixtures = [
  ['family-transformations.json', normalizeFixture(generated.familyTransformations)],
  ['split-rule-cases.json', normalizeFixture(generated.splitRuleCases)],
  ['mutation-cases.json', normalizeFixture(generated.mutationCases)],
];
for (const [name, value] of fixtures) {
  writeFileSync(join(outputDirectory, name), JSON.stringify(value, null, 2) + '\n');
}
// Oracle cases Actualist does not replay, per fixture file. Each reason is a product or coverage fact.
const splitOracleOnly = {
  'family-transformations.json': [
    {
      id: 'detach-child-preserves-nonchild-fields',
      reason: 'no production path (makeAsNonChildTransactions has no Actualist counterpart).',
    },
  ],
  'split-rule-cases.json': [],
  'mutation-cases.json': [
    {
      id: 'detach-child-preserves-nonchild-fields',
      reason: 'no production path (makeAsNonChildTransactions has no Actualist counterpart).',
    },
  ],
};
const fixtureEntries = fixtures.map(([name, value]) => {
  const path = join(defaultOutput, name);
  const caseIDs = value.cases.map(testCase => testCase.id);
  const oracleOnly = splitOracleOnly[name];
  const oracleOnlyIDs = oracleOnly.map(entry => entry.id);
  if (
    new Set(caseIDs).size !== caseIDs.length ||
    new Set(oracleOnlyIDs).size !== oracleOnlyIDs.length ||
    oracleOnly.some(entry => !caseIDs.includes(entry.id) || entry.reason.trim() === '')
  ) {
    throw new Error(`Split oracle-only entries are invalid for ${name}`);
  }
  return {
    path: relative(repositoryRoot, path),
    sha256: sha256(readFileSync(join(outputDirectory, name))),
    caseCount: value.cases.length,
    caseIDs,
    oracleOnly,
  };
});

const manifest = {
  schemaVersion: FIXTURE_SCHEMA_VERSION,
  actual: {
    tag: oraclePin.tag,
    commit: oraclePin.commit,
    packageVersion: oraclePin.packageVersion,
  },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/split-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: [
    {
      path: relative(repositoryRoot, helperPath),
      sha256: sha256(readFileSync(helperPath)),
    },
  ],
  seed: null,
  caseCount: fixtureEntries.reduce((sum, entry) => sum + entry.caseCount, 0),
  amountUnits: 'integer minor units',
  rounding: 'JavaScript Math.round: ties toward positive infinity',
  sourceFiles: sourceFiles.map(path => ({
    path,
    sha256: sha256(readFileSync(join(oracleRoot, path))),
  })),
  fixtures: fixtureEntries,
};
writeFileSync(join(outputDirectory, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

if (checking) {
  const failures = compareWithCommitted(defaultOutput, outputDirectory, [
    ...fixtures.map(([name]) => name),
    'manifest.json',
  ]);
  rmSync(outputDirectory, { recursive: true, force: true });
  if (failures.length > 0) {
    for (const failure of failures) console.error(`split parity drift: ${failure}`);
    process.exit(1);
  }
  console.log(`Split parity fixtures match a fresh generation (${manifest.caseCount} cases).`);
} else {
  console.log(`Generated ${fixtures.length} fixtures in ${relative(repositoryRoot, outputDirectory)}`);
}
