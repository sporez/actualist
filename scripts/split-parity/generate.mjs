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

function ruleResult(actions, transaction = baseParent) {
  const rule = new Rule({
    conditionsOp: 'and',
    conditions: [{ op: 'is', field: 'imported_payee', value: 'actualist-oracle' }],
    actions,
  });
  return selectedFamily(rule.apply({
    ...transaction,
    imported_payee: 'actualist-oracle',
  }));
}

const inheritedChild = makeChild(baseParent, {
  id: 'child-inherited',
  amount: -4000,
  sort_order: -1,
});
const overriddenChild = makeChild(baseParent, {
  id: 'child-overrides',
  amount: 1000,
  category: null,
  payee: null,
  notes: 'child note',
  sort_order: -2,
});

const exactParent = recalculateSplit({
  ...baseParent,
  is_parent: true,
  payee: null,
  subtransactions: [
    makeChild(baseParent, { id: 'child-1', amount: -6000, sort_order: -1 }),
    makeChild(baseParent, { id: 'child-2', amount: -4000, sort_order: -2 }),
  ],
});
const mismatchedParent = recalculateSplit({
  ...exactParent,
  subtransactions: [
    makeChild(baseParent, { id: 'child-1', amount: -4000, sort_order: -1 }),
    makeChild(baseParent, { id: 'child-2', amount: -5000, sort_order: -2 }),
  ],
});
const mixedSignParent = recalculateSplit({
  ...exactParent,
  subtransactions: [
    makeChild(baseParent, { id: 'child-1', amount: -11000, sort_order: -1 }),
    makeChild(baseParent, { id: 'child-2', amount: 1000, sort_order: -2 }),
    makeChild(baseParent, { id: 'child-3', amount: 0, sort_order: -3 }),
  ],
});

const splitConversion = splitTransaction([baseParent], baseParent.id, parent => [
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

const updateConversion = updateTransaction([baseParent], {
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
});

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
];
const parentPayeeUpdate = updateTransaction(updateSource, {
  ...exactParent,
  payee: 'tea',
});
const childDelete = deleteTransaction(updateSource, 'child-1');
const oneChildSource = [
  exactParent,
  makeChild(exactParent, {
    id: 'only-child',
    amount: -10000,
    category: 'utilities',
    sort_order: -1,
  }),
];
const finalChildDelete = deleteTransaction(oneChildSource, 'only-child');
const detachChildren = makeAsNonChildTransactions(
  [updateSource[1]],
  updateSource,
);

const familyTransformations = {
  schemaVersion: ${FIXTURE_SCHEMA_VERSION},
  oracle,
  amountUnits: 'integer minor units',
  cases: [
    {
      id: 'make-child-inheritance-and-null-overrides',
      expected: [selected(inheritedChild), selected(overriddenChild)],
    },
    {
      id: 'recalculate-exact-mismatch-and-mixed-sign',
      expected: {
        exact: selectedFamily(exactParent),
        mismatch: selectedFamily(mismatchedParent),
        mixedSign: selectedFamily(mixedSignParent),
      },
    },
    {
      id: 'low-level-split-conversion-nulls-parent-payee-and-starts-with-error',
      expected: familyFromRows(splitConversion.data),
    },
    {
      id: 'update-conversion-materializes-exact-family',
      expected: {
        result: familyFromRows(updateConversion.data),
        diff: updateConversion.diff,
      },
    },
    {
      id: 'parent-payee-update-preserves-child-override',
      expected: {
        result: familyFromRows(parentPayeeUpdate.data),
        diff: parentPayeeUpdate.diff,
      },
    },
    {
      id: 'child-delete-recalculates-parent-error',
      expected: {
        result: familyFromRows(childDelete.data),
        diff: childDelete.diff,
      },
    },
    {
      id: 'final-child-delete-collapses-parent',
      expected: {
        result: familyFromRows(finalChildDelete.data),
        diff: finalChildDelete.diff,
      },
    },
    {
      id: 'detach-child-preserves-nonchild-fields',
      expected: detachChildren,
    },
  ],
};

const splitRuleCases = {
  schemaVersion: ${FIXTURE_SCHEMA_VERSION},
  oracle,
  amountUnits: 'integer minor units',
  rounding: 'JavaScript Math.round: ties toward positive infinity',
  cases: [
    {
      id: 'index-zero-whole-transaction-and-one-based-children',
      actions: [
        { op: 'append-notes', value: ' whole', options: { splitIndex: 0 } },
        { op: 'set-split-amount', value: -4000, options: { splitIndex: 1, method: 'fixed-amount' } },
        { op: 'set', field: 'category', value: 'groceries', options: { splitIndex: 1 } },
        { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
        { op: 'set', field: 'category', value: null, options: { splitIndex: 2 } },
      ],
      expected: ruleResult([
        { op: 'append-notes', value: ' whole', options: { splitIndex: 0 } },
        { op: 'set-split-amount', value: -4000, options: { splitIndex: 1, method: 'fixed-amount' } },
        { op: 'set', field: 'category', value: 'groceries', options: { splitIndex: 1 } },
        { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
        { op: 'set', field: 'category', value: null, options: { splitIndex: 2 } },
      ]),
    },
    {
      id: 'negative-half-percent-rounding',
      parentAmount: -5,
      expected: ruleResult(
        [
          { op: 'set-split-amount', value: 50, options: { splitIndex: 1, method: 'fixed-percent' } },
          { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
        ],
        { ...baseParent, amount: -5 },
      ),
    },
    {
      id: 'positive-half-percent-rounding',
      parentAmount: 5,
      expected: ruleResult(
        [
          { op: 'set-split-amount', value: 50, options: { splitIndex: 1, method: 'fixed-percent' } },
          { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
        ],
        { ...baseParent, amount: 5 },
      ),
    },
    {
      id: 'multiple-negative-remainders-adjust-highest-index',
      parentAmount: -5,
      expected: ruleResult(
        [
          { op: 'set-split-amount', value: 0, options: { splitIndex: 1, method: 'remainder' } },
          { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
        ],
        { ...baseParent, amount: -5 },
      ),
    },
    {
      id: 'fixed-before-percent-before-remainder',
      parentAmount: 50,
      expected: ruleResult(
        [
          { op: 'set-split-amount', value: 100, options: { splitIndex: 1, method: 'fixed-amount' } },
          { op: 'set-split-amount', value: 50, options: { splitIndex: 2, method: 'fixed-percent' } },
          { op: 'set-split-amount', value: 0, options: { splitIndex: 3, method: 'remainder' } },
        ],
        { ...baseParent, amount: 50 },
      ),
    },
    {
      id: 'formula-and-remainder',
      parentAmount: 100000,
      expected: ruleResult(
        [
          { op: 'set-split-amount', value: 0, options: { splitIndex: 1, method: 'formula', formula: '=300' } },
          { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
        ],
        { ...baseParent, amount: 100000 },
      ),
    },
    {
      id: 'effective-child-input-is-not-split',
      expected: ruleResult(
        [
          { op: 'set-split-amount', value: -4000, options: { splitIndex: 1, method: 'fixed-amount' } },
          { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'remainder' } },
        ],
        makeChild(baseParent, { id: 'existing-child', amount: -10000 }),
      ),
    },
  ],
};

const childAmountUpdate = updateTransaction(updateSource, {
  ...updateSource[1],
  amount: -7000,
});
const parentDateAccountCleared = updateTransaction(updateSource, {
  ...exactParent,
  date: '2026-08-20',
  account: 'savings',
  cleared: false,
});
const addedChild = addSplitTransaction(updateSource, 'parent-1');

const mutationCases = {
  schemaVersion: ${FIXTURE_SCHEMA_VERSION},
  oracle,
  amountUnits: 'integer minor units',
  cases: [
    {
      id: 'add-child-appends-zero-remainder',
      expected: familyFromRows(addedChild.data),
    },
    {
      id: 'child-amount-update-recalculates-error',
      expected: {
        result: familyFromRows(childAmountUpdate.data),
        diff: childAmountUpdate.diff,
      },
    },
    {
      id: 'parent-date-account-cleared-propagate',
      expected: {
        result: familyFromRows(parentDateAccountCleared.data),
        diff: parentDateAccountCleared.diff,
      },
    },
    {
      id: 'update-conversion-materializes-exact-family',
      expected: {
        result: familyFromRows(updateConversion.data),
        diff: updateConversion.diff,
      },
    },
    {
      id: 'parent-payee-update-preserves-child-override',
      expected: {
        result: familyFromRows(parentPayeeUpdate.data),
        diff: parentPayeeUpdate.diff,
      },
    },
    {
      id: 'child-delete-recalculates-parent-error',
      expected: {
        result: familyFromRows(childDelete.data),
        diff: childDelete.diff,
      },
    },
    {
      id: 'final-child-delete-collapses-parent',
      expected: {
        result: familyFromRows(finalChildDelete.data),
        diff: finalChildDelete.diff,
      },
    },
    {
      id: 'detach-child-preserves-nonchild-fields',
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
  ['family-transformations.json', generated.familyTransformations],
  ['split-rule-cases.json', generated.splitRuleCases],
  ['mutation-cases.json', generated.mutationCases],
];
for (const [name, value] of fixtures) {
  writeFileSync(join(outputDirectory, name), JSON.stringify(value, null, 2) + '\n');
}
const fixtureEntries = fixtures.map(([name]) => {
  const path = join(defaultOutput, name);
  const value = JSON.parse(readFileSync(join(outputDirectory, name), 'utf8'));
  return {
    path: relative(repositoryRoot, path),
    sha256: sha256(readFileSync(join(outputDirectory, name))),
    caseCount: value.cases.length,
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
