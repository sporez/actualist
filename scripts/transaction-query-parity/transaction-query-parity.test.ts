import { expect, test, vi } from 'vitest';

import { aqlQuery } from '#server/aql';
import * as db from '#server/db';
import { loadMappings } from '#server/db/mappings';
import { handlers } from '#server/main';
import { runHandler } from '#server/mutators';
import { setSyncingMode } from '#server/sync';
import { q } from '#shared/query';

import {
  crdtMarker,
  crdtMessagesSince,
  flattenQueryIDs,
  normalizeError,
  normalizeQueryRows,
  OracleRecorder,
  queryRootIDs,
  rawFilterRows,
  rawQueryFixture,
  toJSON,
  type JSONValue,
  type OracleCaseDefinition,
} from './transaction-query-parity-support';

const uuidState = vi.hoisted(() => ({ next: 1 }));
vi.mock('uuid', async importOriginal => {
  const original = await importOriginal<typeof import('uuid')>();
  return {
    ...original,
    v4: () =>
      `00000000-0000-4000-8000-${String(uuidState.next++).padStart(12, '0')}`,
  };
});

type Condition = {
  field: 'account' | 'category' | 'date' | 'payee';
  op: string;
  options?: Record<string, boolean>;
  type: 'date' | 'id';
  value: JSONValue;
};

type Q1Case = {
  condition: Condition;
  expectedPhysicalIDs: string[];
  id: string;
};

type Q2Case = {
  baselineConditions: Condition[];
  baselineJoin: 'and' | 'or';
  candidateConditions: Condition[];
  candidateJoin: 'and' | 'or';
  candidateName: string;
  expectedClassification: 'created' | 'duplicate-condition' | 'duplicate-name';
  id: string;
};

const transactionRoot: Record<string, string> = {
  'tx-after': 'tx-after',
  'tx-before': 'tx-before',
  'tx-child-context': 'tx-parent',
  'tx-child-target': 'tx-parent',
  'tx-exact': 'tx-exact',
  'tx-null': 'tx-null',
  'tx-parent': 'tx-parent',
};

const q1Cases: Q1Case[] = [
  q1('q1-date-is-day', date('is', '2026-09-20'), [
    'tx-parent',
    'tx-child-target',
    'tx-child-context',
    'tx-exact',
  ]),
  q1('q1-date-isapprox-day', date('isapprox', '2026-09-20'), [
    'tx-before',
    'tx-parent',
    'tx-child-target',
    'tx-child-context',
    'tx-exact',
    'tx-after',
  ]),
  q1('q1-date-gt-exclusive-lower', date('gt', '2026-09-20'), [
    'tx-after',
    'tx-null',
  ]),
  q1('q1-date-gte-inclusive-lower', date('gte', '2026-09-20'), [
    'tx-parent',
    'tx-child-target',
    'tx-child-context',
    'tx-exact',
    'tx-after',
    'tx-null',
  ]),
  q1('q1-date-lt-exclusive-upper', date('lt', '2026-09-20'), [
    'tx-before',
  ]),
  q1('q1-date-lte-inclusive-upper', date('lte', '2026-09-20'), [
    'tx-before',
    'tx-parent',
    'tx-child-target',
    'tx-child-context',
    'tx-exact',
  ]),
  q1(
    'q1-date-month-option',
    date('is', '2026-09', { month: true }),
    allLiveTransactionIDs(),
  ),
  q1(
    'q1-date-year-option',
    date('is', '2026', { year: true }),
    allLiveTransactionIDs(),
  ),
  q1('q1-account-is', idCondition('account', 'is', 'acct-on-1'), [
    'tx-parent',
    'tx-child-target',
    'tx-child-context',
  ]),
  q1('q1-account-is-not', idCondition('account', 'isNot', 'acct-on-1'), [
    'tx-before',
    'tx-exact',
    'tx-after',
    'tx-null',
  ]),
  q1(
    'q1-account-one-of',
    idCondition('account', 'oneOf', ['acct-on-1', 'acct-off']),
    ['tx-parent', 'tx-child-target', 'tx-child-context', 'tx-after'],
  ),
  q1(
    'q1-account-not-one-of',
    idCondition('account', 'notOneOf', ['acct-on-1', 'acct-off']),
    ['tx-before', 'tx-exact', 'tx-null'],
  ),
  q1(
    'q1-account-contains-name',
    idCondition('account', 'contains', 'Primary'),
    ['tx-parent', 'tx-child-target', 'tx-child-context'],
  ),
  q1(
    'q1-account-matches-name',
    idCondition('account', 'matches', '^Primary'),
    ['tx-parent', 'tx-child-target', 'tx-child-context'],
  ),
  q1(
    'q1-account-does-not-contain-name',
    idCondition('account', 'doesNotContain', 'Primary'),
    ['tx-before', 'tx-exact', 'tx-after', 'tx-null'],
  ),
  q1('q1-account-on-budget', idCondition('account', 'onBudget', null), [
    'tx-parent',
    'tx-child-target',
    'tx-child-context',
    'tx-before',
    'tx-exact',
    'tx-null',
  ]),
  q1('q1-account-off-budget', idCondition('account', 'offBudget', null), [
    'tx-after',
  ]),
  q1('q1-payee-is-mapped-id', idCondition('payee', 'is', 'payee-target'), [
    'tx-child-target',
  ]),
  q1('q1-payee-is-not-null', idCondition('payee', 'isNot', null), [
    'tx-parent',
    'tx-child-target',
    'tx-child-context',
    'tx-before',
    'tx-exact',
    'tx-after',
  ]),
  q1(
    'q1-payee-one-of',
    idCondition('payee', 'oneOf', ['payee-target', 'payee-after']),
    ['tx-child-target', 'tx-after'],
  ),
  q1(
    'q1-payee-not-one-of',
    idCondition('payee', 'notOneOf', ['payee-target', 'payee-after']),
    ['tx-parent', 'tx-child-context', 'tx-before', 'tx-exact', 'tx-null'],
  ),
  q1(
    'q1-payee-contains-name',
    idCondition('payee', 'contains', 'Mapped'),
    ['tx-child-target'],
  ),
  q1(
    'q1-payee-matches-name',
    idCondition('payee', 'matches', '^Mapped'),
    ['tx-child-target'],
  ),
  q1(
    'q1-payee-does-not-contain-name',
    idCondition('payee', 'doesNotContain', 'Mapped'),
    [
      'tx-parent',
      'tx-child-context',
      'tx-before',
      'tx-exact',
      'tx-after',
      'tx-null',
    ],
  ),
  q1('q1-payee-is-null', idCondition('payee', 'is', null), ['tx-null']),
  q1(
    'q1-category-is-mapped-id',
    idCondition('category', 'is', 'category-target'),
    ['tx-child-target'],
  ),
  q1(
    'q1-category-is-not-null',
    idCondition('category', 'isNot', null),
    [
      'tx-child-target',
      'tx-child-context',
      'tx-before',
      'tx-exact',
      'tx-after',
    ],
  ),
  q1(
    'q1-category-one-of',
    idCondition('category', 'oneOf', ['category-target', 'category-after']),
    ['tx-child-target', 'tx-after'],
  ),
  q1(
    'q1-category-not-one-of',
    idCondition('category', 'notOneOf', [
      'category-target',
      'category-after',
    ]),
    ['tx-parent', 'tx-child-context', 'tx-before', 'tx-exact', 'tx-null'],
  ),
  q1(
    'q1-category-contains-name',
    idCondition('category', 'contains', 'Mapped'),
    ['tx-child-target'],
  ),
  q1(
    'q1-category-matches-name',
    idCondition('category', 'matches', '^Mapped'),
    ['tx-child-target'],
  ),
  q1(
    'q1-category-does-not-contain-name',
    idCondition('category', 'doesNotContain', 'Mapped'),
    [
      'tx-parent',
      'tx-child-context',
      'tx-before',
      'tx-exact',
      'tx-after',
      'tx-null',
    ],
  ),
  q1('q1-category-is-null-uncategorized', idCondition('category', 'is', null), [
    'tx-null',
  ]),
];

const q3Cases = [
  {
    condition: date('is', '2026-09-20'),
    expectedPhysicalIDs: [
      'family-parent',
      'family-target',
      'family-context',
    ],
    id: 'q3-date-family-grouping',
    kind: 'condition' as const,
  },
  {
    condition: idCondition('account', 'is', 'acct-family'),
    expectedPhysicalIDs: [
      'family-parent',
      'family-target',
      'family-context',
    ],
    id: 'q3-account-family-grouping',
    kind: 'condition' as const,
  },
  {
    condition: idCondition('payee', 'is', 'payee-target'),
    expectedPhysicalIDs: ['family-target'],
    id: 'q3-payee-child-selects-family',
    kind: 'condition' as const,
  },
  {
    condition: idCondition('category', 'is', 'category-target'),
    expectedPhysicalIDs: ['family-target'],
    id: 'q3-category-child-selects-family',
    kind: 'condition' as const,
  },
  {
    expectedPhysicalIDs: ['family-target'],
    id: 'q3-free-text-grouped-versus-physical',
    kind: 'text' as const,
  },
];

const conditionA = idCondition('account', 'is', 'acct-a');
const conditionB = idCondition('payee', 'is', 'payee-b');
const q2Cases: Q2Case[] = [
  q2('q2-exact-condition-equivalence', [conditionA, conditionB], 'and', [
    conditionA,
    conditionB,
  ], 'and', 'Candidate exact', 'duplicate-condition'),
  q2('q2-reordered-condition-equivalence', [conditionA, conditionB], 'and', [
    conditionB,
    conditionA,
  ], 'and', 'Candidate reordered', 'duplicate-condition'),
  q2('q2-duplicate-condition-multiplicity', [conditionA, conditionB], 'and', [
    conditionA,
    conditionA,
  ], 'and', 'Candidate duplicate multiplicity', 'duplicate-condition'),
  q2(
    'q2-number-versus-string-value',
    [idCondition('account', 'is', 7)],
    'and',
    [idCondition('account', 'is', '7')],
    'and',
    'Candidate string value',
    'created',
  ),
  q2(
    'q2-options-key-order',
    [date('is', '2026-09', { month: true, year: false })],
    'and',
    [date('is', '2026-09', { year: false, month: true })],
    'and',
    'Candidate reordered options',
    'duplicate-condition',
  ),
  q2(
    'q2-single-condition-and-versus-or',
    [conditionA],
    'and',
    [conditionA],
    'or',
    'Candidate single or',
    'duplicate-condition',
  ),
  q2(
    'q2-multiple-condition-and-versus-or-control',
    [conditionA, conditionB],
    'and',
    [conditionA, conditionB],
    'or',
    'Candidate multi or',
    'created',
  ),
  q2(
    'q2-duplicate-live-name-precedes-condition-check',
    [conditionA],
    'and',
    [conditionB],
    'and',
    'Baseline',
    'duplicate-name',
  ),
];

const definitions: OracleCaseDefinition[] = [
  ...q1Cases.map(q1Definition),
  ...q3Cases.map(q3Definition),
  ...q2Cases.map(q2Definition),
];

test(
  'captures the predetermined Q1/Q2/Q3 transaction query parity matrix',
  async () => {
    uuidState.next = 1;
    const recorder = new OracleRecorder(definitions);
    const failures: string[] = [];

    try {
      setSyncingMode('offline');
      await resetAndSeedQ1Fixture();

      for (const item of q1Cases) {
        await recordCase(recorder, failures, item.id, async () => {
          const marker = await crdtMarker();
          const filterID = await createFilter({
            conditions: [item.condition],
            conditionsOp: 'and',
            name: item.id,
          });
          const compiled = await compileConditions([item.condition]);
          const physical = await queryTransactions(compiled.filters, 'all');
          const grouped = await queryTransactions(compiled.filters, 'grouped');
          const filterRows = await rawFilterRows();
          const stored = filterRows.find(row => row.id === filterID);
          const messages = await crdtMessagesSince(marker);
          const observed = {
            compiled: toJSON(compiled),
            crdt: toJSON(messages),
            domain: toJSON({
              fixture: await rawQueryFixture(),
              parsedConditions:
                typeof stored?.conditions === 'string'
                  ? JSON.parse(stored.conditions)
                  : null,
              rawFilter: stored ?? null,
            }),
            groupedQuery: toJSON(grouped),
            groupedRootIDs: toJSON(queryRootIDs(grouped)),
            physicalMatchIDs: toJSON(flattenQueryIDs(physical)),
            physicalQuery: toJSON(physical),
          };

          return {
            observed,
            verify: () => {
              expect(compiled.errors).toEqual([]);
              expect(stored).toBeDefined();
              expect(JSON.parse(String(stored?.conditions))).toEqual([
                item.condition,
              ]);
              expect(stored?.conditions_op).toBe('and');
              expect(flattenQueryIDs(physical)).toEqual(
                [...item.expectedPhysicalIDs].sort(),
              );
              expect(queryRootIDs(grouped)).toEqual(
                expectedRootIDs(item.expectedPhysicalIDs),
              );
              expect(messages).toHaveLength(3);
              expect(
                messages.every(
                  message => message.dataset === 'transaction_filters',
                ),
              ).toBe(true);
            },
          };
        });
      }

      for (const item of q3Cases) {
        await recordCase(recorder, failures, item.id, async () => {
          await resetAndSeedQ3Fixture();
          const compiled =
            item.kind === 'condition'
              ? await compileConditions([item.condition])
              : { errors: [], filters: [freeTextSearchFilter('needle')] };
          const physical = await queryTransactions(compiled.filters, 'all');
          const grouped = await queryTransactions(compiled.filters, 'grouped');
          const physicalIDs = flattenQueryIDs(physical);
          const displayedIDs = flattenQueryIDs(grouped);
          const attachedContextIDs = displayedIDs.filter(
            id => !physicalIDs.includes(id),
          );
          const observed = {
            attachedContextIDs: toJSON(attachedContextIDs),
            compiled: toJSON(compiled),
            domain: toJSON(await rawQueryFixture()),
            groupedDisplay: toJSON(grouped),
            groupedRootIDs: toJSON(queryRootIDs(grouped)),
            matchingPhysicalIDs: toJSON(physicalIDs),
            physicalRows: toJSON(physical),
          };

          return {
            observed,
            verify: () => {
              expect(compiled.errors).toEqual([]);
              expect(physicalIDs).toEqual(
                [...item.expectedPhysicalIDs].sort(),
              );
              expect(queryRootIDs(grouped)).toEqual(['family-parent']);
              expect(displayedIDs).toEqual([
                'family-context',
                'family-parent',
                'family-target',
              ]);
              if (item.expectedPhysicalIDs.length === 1) {
                expect(attachedContextIDs).toEqual([
                  'family-context',
                  'family-parent',
                ]);
              } else {
                expect(attachedContextIDs).toEqual([]);
              }
            },
          };
        });
      }

      for (const item of q2Cases) {
        await recordCase(recorder, failures, item.id, async () => {
          await resetForHandlerCase();
          seedRawFilter(
            'baseline-filter',
            'Baseline',
            item.baselineConditions,
            item.baselineJoin,
          );
          const baseline = {
            conditions: item.baselineConditions,
            conditionsOp: item.baselineJoin,
            id: 'baseline-filter',
            name: 'Baseline',
            tombstone: false,
          };
          const marker = await crdtMarker();
          const result = await classifyFilterCreate(
            {
              conditions: item.candidateConditions,
              conditionsOp: item.candidateJoin,
              name: item.candidateName,
            },
            [baseline],
          );
          const rows = await rawFilterRows();
          const messages = await crdtMessagesSince(marker);
          const observed = {
            classification: result.classification,
            crdt: toJSON(messages),
            domain: toJSON(rows),
            error: result.error,
            returnedID: result.id,
          };

          return {
            observed,
            verify: () => {
              expect(result.classification).toBe(item.expectedClassification);
              expect(rows.length).toBe(
                item.expectedClassification === 'created' ? 2 : 1,
              );
              expect(messages.length > 0).toBe(
                item.expectedClassification === 'created',
              );
            },
          };
        });
      }
    } finally {
      setSyncingMode('disabled');
      recorder.finish(failures);
    }

    expect(failures).toEqual([]);
  },
  170_000,
);

async function recordCase(
  recorder: OracleRecorder,
  failures: string[],
  id: string,
  execute: () => Promise<{
    observed: Record<string, JSONValue>;
    verify: () => void;
  }>,
): Promise<void> {
  recorder.begin(id);
  let observed: Record<string, JSONValue> | null = null;
  try {
    const execution = await execute();
    observed = execution.observed;
    execution.verify();
    recorder.pass(id, observed);
  } catch (error) {
    const failure = `${id}: ${normalizeError(error)}`;
    failures.push(failure);
    recorder.fail(id, error, observed);
  }
}

function q1(
  id: string,
  condition: Condition,
  expectedPhysicalIDs: string[],
): Q1Case {
  return { condition, expectedPhysicalIDs, id };
}

function q2(
  id: string,
  baselineConditions: Condition[],
  baselineJoin: 'and' | 'or',
  candidateConditions: Condition[],
  candidateJoin: 'and' | 'or',
  candidateName: string,
  expectedClassification: Q2Case['expectedClassification'],
): Q2Case {
  return {
    baselineConditions,
    baselineJoin,
    candidateConditions,
    candidateJoin,
    candidateName,
    expectedClassification,
    id,
  };
}

function date(
  op: string,
  value: string,
  options?: Record<string, boolean>,
): Condition {
  return {
    field: 'date',
    op,
    value,
    type: 'date',
    ...(options ? { options } : {}),
  };
}

function idCondition(
  field: 'account' | 'category' | 'payee',
  op: string,
  value: JSONValue,
): Condition {
  return { field, op, value, type: 'id' };
}

function allLiveTransactionIDs(): string[] {
  return [
    'tx-parent',
    'tx-child-target',
    'tx-child-context',
    'tx-before',
    'tx-exact',
    'tx-after',
    'tx-null',
  ];
}

function expectedRootIDs(physicalIDs: string[]): string[] {
  return [...new Set(physicalIDs.map(id => transactionRoot[id]))].sort();
}

function q1Definition(item: Q1Case): OracleCaseDefinition {
  return {
    assertions: [
      'filter-create persists the authored condition JSON without shape changes',
      'make-filters-from-conditions reports no validation error',
      'splits:all returns exactly the predicted live physical rows',
      'splits:grouped returns exactly the roots implied by matching physical rows',
      'filter-create emits only transaction_filters CRDT messages',
    ],
    gate: 'Q1',
    id: item.id,
    input: { condition: toJSON(item.condition), conditionsOp: 'and' },
    sourcePrediction: {
      expectedGroupedRootIDs: expectedRootIDs(item.expectedPhysicalIDs),
      expectedPersistedCondition: toJSON(item.condition),
      expectedPhysicalIDs: [...item.expectedPhysicalIDs].sort(),
    },
    sourceReferences: [
      {
        lines: '124-160, 447-481, 662-709',
        path: 'packages/desktop-client/src/components/filters/FiltersMenu.tsx',
        relevance: 'authored operators, values, type, and options shape',
      },
      {
        lines: '202-237, 453-460',
        path: 'packages/loot-core/src/server/rules/condition.ts',
        relevance: 'condition parsing and serialization',
      },
      {
        lines: '437-709',
        path: 'packages/loot-core/src/server/transactions/transaction-rules.ts',
        relevance: 'condition-to-AQL conversion and null special cases',
      },
      {
        lines: '112-145',
        path: 'packages/loot-core/src/server/filters/app.ts',
        relevance: 'saved-filter create handler and persisted row',
      },
    ],
  };
}

function q3Definition(item: (typeof q3Cases)[number]): OracleCaseDefinition {
  return {
    assertions: [
      'splits:all identifies the predicted matching physical rows',
      'splits:grouped selects one parent root',
      'the grouped result attaches the complete live family',
      'attached context is reported separately from matching physical rows',
    ],
    gate: 'Q3',
    id: item.id,
    input:
      item.kind === 'condition'
        ? { condition: toJSON(item.condition), splitModes: ['all', 'grouped'] }
        : { search: 'needle', splitModes: ['all', 'grouped'] },
    sourcePrediction: {
      expectedAttachedContextIDs:
        item.expectedPhysicalIDs.length === 1
          ? ['family-context', 'family-parent']
          : [],
      expectedGroupedRootIDs: ['family-parent'],
      expectedPhysicalIDs: [...item.expectedPhysicalIDs].sort(),
    },
    sourceReferences: [
      {
        lines: '78-95, 97-225',
        path: 'packages/loot-core/src/server/aql/schema/executors.ts',
        relevance: 'grouped happy/unhappy paths, root selection, and _unmatched context',
      },
      {
        lines: '83-123',
        path: 'packages/desktop-client/src/queries/index.ts',
        relevance: 'transaction free-text AQL shape',
      },
      {
        lines: '1575-1603',
        path: 'packages/desktop-client/src/components/accounts/Account.tsx',
        relevance: 'condition conversion and grouped account query application',
      },
    ],
  };
}

function q2Definition(item: Q2Case): OracleCaseDefinition {
  return {
    assertions: [
      'filter-create produces the predicted create or rejection classification',
      'a rejected candidate leaves only the seeded baseline row and emits no CRDT messages',
      'an accepted candidate adds one row and emits transaction_filters CRDT messages',
    ],
    gate: 'Q2',
    id: item.id,
    input: {
      baseline: toJSON({
        conditions: item.baselineConditions,
        conditionsOp: item.baselineJoin,
        name: 'Baseline',
      }),
      candidate: toJSON({
        conditions: item.candidateConditions,
        conditionsOp: item.candidateJoin,
        name: item.candidateName,
      }),
    },
    sourcePrediction: {
      expectedClassification: item.expectedClassification,
    },
    sourceReferences: [
      {
        lines: '43-110, 112-175',
        path: 'packages/loot-core/src/server/filters/app.ts',
        relevance: 'name and condition equivalence checks plus create/update ordering',
      },
      {
        lines: '114-152',
        path: 'packages/desktop-client/src/components/filters/SavedFilterMenuButton.tsx',
        relevance: 'real handler payload includes the caller-provided saved-filter list',
      },
    ],
  };
}

async function resetAndSeedQ1Fixture(): Promise<void> {
  await resetForHandlerCase();
  seedReferenceData();
  seedTransaction({
    account: 'acct-on-1',
    amount: -3000,
    category: 'category-context',
    date: 20260920,
    id: 'tx-parent',
    isParent: 1,
    notes: 'Family root',
    payee: 'payee-parent',
    sortOrder: 700,
  });
  seedTransaction({
    account: 'acct-on-1',
    amount: -1000,
    category: 'category-source',
    date: 20260920,
    id: 'tx-child-target',
    isChild: 1,
    notes: 'Needle child',
    parentID: 'tx-parent',
    payee: 'payee-source',
    sortOrder: 690,
  });
  seedTransaction({
    account: 'acct-on-1',
    amount: -2000,
    category: 'category-context',
    date: 20260920,
    id: 'tx-child-context',
    isChild: 1,
    notes: 'Sibling context',
    parentID: 'tx-parent',
    payee: 'payee-context',
    sortOrder: 680,
  });
  seedTransaction({
    account: 'acct-on-2',
    category: 'category-before',
    date: 20260919,
    id: 'tx-before',
    notes: 'Before',
    payee: 'payee-before',
    sortOrder: 600,
  });
  seedTransaction({
    account: 'acct-on-2',
    category: 'category-exact',
    date: 20260920,
    id: 'tx-exact',
    notes: 'Exact',
    payee: 'payee-exact',
    sortOrder: 500,
  });
  seedTransaction({
    account: 'acct-off',
    category: 'category-after',
    date: 20260921,
    id: 'tx-after',
    notes: 'After',
    payee: 'payee-after',
    sortOrder: 400,
  });
  seedTransaction({
    account: 'acct-on-2',
    category: null,
    date: 20260925,
    id: 'tx-null',
    notes: 'Null references',
    payee: null,
    sortOrder: 300,
  });
  seedTransaction({
    account: 'acct-on-1',
    category: 'category-source',
    date: 20260920,
    id: 'tx-tombstone',
    notes: 'Deleted target',
    payee: 'payee-source',
    sortOrder: 200,
    tombstone: 1,
  });
  await loadMappings();
}

async function resetAndSeedQ3Fixture(): Promise<void> {
  await resetForHandlerCase();
  seedReferenceData();
  seedTransaction({
    account: 'acct-family',
    amount: -3000,
    category: 'category-context',
    date: 20260920,
    id: 'family-parent',
    isParent: 1,
    notes: 'Family root',
    payee: 'payee-parent',
    sortOrder: 400,
  });
  seedTransaction({
    account: 'acct-family',
    amount: -1000,
    category: 'category-source',
    date: 20260920,
    id: 'family-target',
    isChild: 1,
    notes: 'needle child',
    parentID: 'family-parent',
    payee: 'payee-source',
    sortOrder: 390,
  });
  seedTransaction({
    account: 'acct-family',
    amount: -2000,
    category: 'category-context',
    date: 20260920,
    id: 'family-context',
    isChild: 1,
    notes: 'sibling context',
    parentID: 'family-parent',
    payee: 'payee-context',
    sortOrder: 380,
  });
  seedTransaction({
    account: 'acct-on-2',
    category: 'category-before',
    date: 20260919,
    id: 'family-decoy',
    notes: 'ordinary standalone',
    payee: 'payee-before',
    sortOrder: 100,
  });
  await loadMappings();
}

async function resetForHandlerCase(): Promise<void> {
  await global.emptyDatabase()();
  await loadMappings();
}

function seedReferenceData(): void {
  const accounts = [
    ['acct-on-1', 'Primary Checking', 0],
    ['acct-on-2', 'Secondary Savings', 0],
    ['acct-off', 'Off Budget Asset', 1],
    ['acct-family', 'Family Account', 0],
  ] as const;
  for (const [id, name, offbudget] of accounts) {
    db.runQuery(
      `INSERT INTO accounts
         (id, name, offbudget, closed, sort_order, tombstone)
       VALUES (?, ?, ?, 0, 0, 0)`,
      [id, name, offbudget],
    );
  }

  const payees = [
    ['payee-target', 'Mapped Merchant'],
    ['payee-parent', 'Parent Merchant'],
    ['payee-context', 'Sibling Cafe'],
    ['payee-before', 'Before Shop'],
    ['payee-exact', 'Exact Shop'],
    ['payee-after', 'After Shop'],
  ] as const;
  for (const [id, name] of payees) {
    db.runQuery(
      `INSERT INTO payees
         (id, name, transfer_acct, favorite, learn_categories, tombstone)
       VALUES (?, ?, NULL, 0, 0, 0)`,
      [id, name],
    );
    db.runQuery('INSERT INTO payee_mapping (id, targetId) VALUES (?, ?)', [
      id,
      id,
    ]);
  }
  db.runQuery('INSERT INTO payee_mapping (id, targetId) VALUES (?, ?)', [
    'payee-source',
    'payee-target',
  ]);

  db.runQuery(
    `INSERT INTO category_groups
       (id, name, is_income, sort_order, hidden, tombstone)
     VALUES ('category-group', 'Synthetic', 0, 0, 0, 0)`,
  );
  const categories = [
    ['category-target', 'Mapped Category'],
    ['category-context', 'Sibling Category'],
    ['category-before', 'Before Category'],
    ['category-exact', 'Exact Category'],
    ['category-after', 'After Category'],
  ] as const;
  for (const [id, name] of categories) {
    db.runQuery(
      `INSERT INTO categories
         (id, name, is_income, cat_group, sort_order, hidden, tombstone)
       VALUES (?, ?, 0, 'category-group', 0, 0, 0)`,
      [id, name],
    );
    db.runQuery(
      'INSERT INTO category_mapping (id, transferId) VALUES (?, ?)',
      [id, id],
    );
  }
  db.runQuery(
    'INSERT INTO category_mapping (id, transferId) VALUES (?, ?)',
    ['category-source', 'category-target'],
  );
}

function seedTransaction({
  account,
  amount = -100,
  category,
  date: transactionDate,
  id,
  isChild = 0,
  isParent = 0,
  notes,
  parentID = null,
  payee,
  sortOrder,
  tombstone = 0,
}: {
  account: string;
  amount?: number;
  category: string | null;
  date: number;
  id: string;
  isChild?: 0 | 1;
  isParent?: 0 | 1;
  notes: string;
  parentID?: string | null;
  payee: string | null;
  sortOrder: number;
  tombstone?: 0 | 1;
}): void {
  db.runQuery(
    `INSERT INTO transactions
       (id, isParent, isChild, parent_id, acct, category, amount, description,
        notes, date, sort_order, tombstone, cleared, reconciled,
        starting_balance_flag)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0)`,
    [
      id,
      isParent,
      isChild,
      parentID,
      account,
      category,
      amount,
      payee,
      notes,
      transactionDate,
      sortOrder,
      tombstone,
    ],
  );
}

async function compileConditions(conditions: Condition[]) {
  return runHandler(
    handlers['make-filters-from-conditions'],
    { applySpecialCases: true, conditions },
    { name: 'make-filters-from-conditions' },
  );
}

async function queryTransactions(
  filters: unknown[],
  splits: 'all' | 'grouped',
) {
  const { data } = await aqlQuery(
    q('transactions')
      .filter({ $and: filters })
      .options({ splits })
      .select('*'),
  );
  return normalizeQueryRows(data);
}

function freeTextSearchFilter(search: string): Record<string, unknown> {
  const escapedSearch = search.replace(/[\\%?]/g, '\\$&');
  return {
    $or: {
      'payee.name': { $like: `%${escapedSearch}%` },
      'payee.transfer_acct.name': { $like: `%${escapedSearch}%` },
      notes: { $like: `%${escapedSearch}%` },
      'category.name': { $like: `%${escapedSearch}%` },
      'account.name': { $like: `%${escapedSearch}%` },
      $or: [],
    },
  };
}

async function createFilter(state: {
  conditions: Condition[];
  conditionsOp: 'and' | 'or';
  name: string;
}): Promise<string> {
  return runHandler(
    handlers['filter-create'],
    { filters: [], state },
    { name: 'filter-create' },
  );
}

async function classifyFilterCreate(
  state: {
    conditions: Condition[];
    conditionsOp: 'and' | 'or';
    name: string;
  },
  filters: Array<Record<string, unknown>>,
): Promise<{
  classification: 'created' | 'duplicate-condition' | 'duplicate-name' | 'other-error';
  error: string | null;
  id: string | null;
}> {
  try {
    const id = await runHandler(
      handlers['filter-create'],
      { filters, state },
      { name: 'filter-create' },
    );
    return { classification: 'created', error: null, id };
  } catch (error) {
    const message = normalizeError(error);
    if (message.includes('Duplicate filter warning')) {
      return { classification: 'duplicate-condition', error: message, id: null };
    }
    if (message.includes('already a filter named')) {
      return { classification: 'duplicate-name', error: message, id: null };
    }
    return { classification: 'other-error', error: message, id: null };
  }
}

function seedRawFilter(
  id: string,
  name: string,
  conditions: Condition[],
  conditionsOp: 'and' | 'or',
): void {
  db.runQuery(
    `INSERT INTO transaction_filters
       (id, name, conditions, conditions_op, tombstone)
     VALUES (?, ?, ?, ?, 0)`,
    [id, name, JSON.stringify(conditions), conditionsOp],
  );
}
