// The transaction-query case plan: 51 named cases in four families.
//
// Pure data. generate.mjs runs every case through Actual's own filter handlers,
// condition compiler and transaction query executor; verify.mjs rebuilds this
// plan without an oracle and compares it with the committed fixture. Amounts
// are integer minor units. Dates are integer YYYYMMDD in seeded rows and ISO
// strings in conditions. Expected outputs are never written here; they come
// only from the oracle.

export const TIME_ZONE = 'UTC';
export const SEED = null;
export const SPLIT_MODES = ['all', 'inline', 'none', 'grouped'];
// Query order the desktop client uses for the account transaction list.
export const SPLITMODE_ORDER = [{ date: 'desc' }, { starting_balance_flag: 'asc' }, { sort_order: 'desc' }, { id: 'desc' }];

// ---------------------------------------------------------------- worlds

function row(id, fields) {
  return {
    amount: -100,
    category: null,
    isChild: false,
    isParent: false,
    parentID: null,
    payee: null,
    startingBalance: false,
    tombstone: false,
    ...fields,
    id,
  };
}

// Shared reference data of the Q1 and Q3 worlds.
function referenceData() {
  return {
    accounts: [
      { id: 'acct-on-1', name: 'Primary Checking', offbudget: false },
      { id: 'acct-on-2', name: 'Secondary Savings', offbudget: false },
      { id: 'acct-off', name: 'Off Budget Asset', offbudget: true },
      { id: 'acct-family', name: 'Family Account', offbudget: false },
    ],
    payees: [
      { id: 'payee-target', name: 'Mapped Merchant' },
      { id: 'payee-parent', name: 'Parent Merchant' },
      { id: 'payee-context', name: 'Sibling Cafe' },
      { id: 'payee-before', name: 'Before Shop' },
      { id: 'payee-exact', name: 'Exact Shop' },
      { id: 'payee-after', name: 'After Shop' },
    ],
    payeeMappings: [{ id: 'payee-source', targetID: 'payee-target' }],
    categories: [
      { id: 'category-target', name: 'Mapped Category' },
      { id: 'category-context', name: 'Sibling Category' },
      { id: 'category-before', name: 'Before Category' },
      { id: 'category-exact', name: 'Exact Category' },
      { id: 'category-after', name: 'After Category' },
    ],
    categoryMappings: [{ id: 'category-source', targetID: 'category-target' }],
  };
}

const QUERY_WORLD = {
  ...referenceData(),
  transactions: [
    row('tx-parent', { account: 'acct-on-1', amount: -3000, category: 'category-context', date: 20260920, isParent: true, notes: 'Family root', payee: 'payee-parent', sortOrder: 700 }),
    row('tx-child-target', { account: 'acct-on-1', amount: -1000, category: 'category-source', date: 20260920, isChild: true, notes: 'Needle child', parentID: 'tx-parent', payee: 'payee-source', sortOrder: 690 }),
    row('tx-child-context', { account: 'acct-on-1', amount: -2000, category: 'category-context', date: 20260920, isChild: true, notes: 'Sibling context', parentID: 'tx-parent', payee: 'payee-context', sortOrder: 680 }),
    row('tx-before', { account: 'acct-on-2', category: 'category-before', date: 20260919, notes: 'Before', payee: 'payee-before', sortOrder: 600 }),
    row('tx-exact', { account: 'acct-on-2', category: 'category-exact', date: 20260920, notes: 'Exact', payee: 'payee-exact', sortOrder: 500 }),
    row('tx-after', { account: 'acct-off', category: 'category-after', date: 20260921, notes: 'After', payee: 'payee-after', sortOrder: 400 }),
    row('tx-null', { account: 'acct-on-2', category: null, date: 20260925, notes: 'Null references', payee: null, sortOrder: 300 }),
    row('tx-tombstone', { account: 'acct-on-1', category: 'category-source', date: 20260920, notes: 'Deleted target', payee: 'payee-source', sortOrder: 200, tombstone: true }),
  ],
};

const FAMILY_WORLD = {
  ...referenceData(),
  transactions: [
    row('family-parent', { account: 'acct-family', amount: -3000, category: 'category-context', date: 20260920, isParent: true, notes: 'Family root', payee: 'payee-parent', sortOrder: 400 }),
    row('family-target', { account: 'acct-family', amount: -1000, category: 'category-source', date: 20260920, isChild: true, notes: 'needle child', parentID: 'family-parent', payee: 'payee-source', sortOrder: 390 }),
    row('family-context', { account: 'acct-family', amount: -2000, category: 'category-context', date: 20260920, isChild: true, notes: 'sibling context', parentID: 'family-parent', payee: 'payee-context', sortOrder: 380 }),
    row('family-decoy', { account: 'acct-on-2', category: 'category-before', date: 20260919, notes: 'ordinary standalone', payee: 'payee-before', sortOrder: 100 }),
  ],
};

const EMPTY_WORLD = {
  accounts: [], payees: [], payeeMappings: [], categories: [], categoryMappings: [], transactions: [],
};

// The split-mode worlds use the synthetic rows of ActualistTests/TransactionSplitQueryTests.
function splitModeWorld(transactions) {
  return {
    accounts: [{ id: 'checking', name: 'Checking', offbudget: false }],
    payees: [{ id: 'coffee', name: 'Coffee Shop' }],
    payeeMappings: [],
    categories: [{ id: 'groceries', name: 'Groceries' }, { id: 'utilities', name: 'Utilities' }],
    categoryMappings: [],
    transactions: transactions.map(([id, fields]) => row(id, { account: 'checking', ...fields })),
  };
}

export const WORLDS = {
  query: QUERY_WORLD,
  family: FAMILY_WORLD,
  empty: EMPTY_WORLD,
  'splitmodes-two-child-family': splitModeWorld([
    ['simple', { amount: -1000, category: 'groceries', payee: 'coffee', date: 20260820, sortOrder: 3 }],
    ['parent', { amount: -5000, isParent: true, notes: 'S01 parent', date: 20260815, sortOrder: 2 }],
    ['child-a', { amount: -2000, category: 'groceries', payee: 'coffee', notes: 'child a', isChild: true, parentID: 'parent', date: 20260815, sortOrder: 1 }],
    ['child-b', { amount: -3000, category: 'utilities', notes: 'Q01-CHILD-NOTE', isChild: true, parentID: 'parent', date: 20260815, sortOrder: 0 }],
  ]),
  'splitmodes-child-note-search': splitModeWorld([
    ['parent', { amount: -5000, isParent: true, notes: 'S03 parent', date: 20260815, sortOrder: 2 }],
    ['child-a', { amount: -2000, category: 'groceries', payee: 'coffee', notes: 'child a', isChild: true, parentID: 'parent', date: 20260815, sortOrder: 1 }],
    ['child-b', { amount: -3000, notes: 'Q01-CHILD-NOTE', isChild: true, parentID: 'parent', date: 20260815, sortOrder: 0 }],
  ]),
  'splitmodes-dead-parent': splitModeWorld([
    ['simple', { amount: -1000, category: 'groceries', payee: 'coffee', date: 20260820, sortOrder: 3 }],
    ['dead-parent', { amount: -5000, isParent: true, notes: 'dead', date: 20260815, sortOrder: 2, tombstone: true }],
    ['orphan', { amount: -2000, category: 'groceries', payee: 'coffee', notes: 'orphan', isChild: true, parentID: 'dead-parent', date: 20260815, sortOrder: 1 }],
    ['missing-parent-child', { amount: -900, category: 'groceries', payee: 'coffee', notes: 'missing', isChild: true, parentID: 'no-such-parent', date: 20260814, sortOrder: 0 }],
  ]),
  'splitmodes-flag-disagreement': splitModeWorld([
    ['flagged', { amount: -1000, category: 'groceries', payee: 'coffee', date: 20260815, sortOrder: 1, parentID: 'someone' }],
  ]),
  'splitmodes-default-order': splitModeWorld([
    ['older', { amount: -1000, category: 'groceries', payee: 'coffee', date: 20260810, sortOrder: 9 }],
    ['starting', { amount: 5000, category: 'groceries', payee: 'coffee', date: 20260815, sortOrder: 8, startingBalance: true }],
    ['regular', { amount: -2000, category: 'groceries', payee: 'coffee', date: 20260815, sortOrder: 7 }],
    ['newer', { amount: -3000, category: 'groceries', payee: 'coffee', date: 20260820, sortOrder: 1 }],
  ]),
};

// ---------------------------------------------------------------- conditions

function dateCondition(op, value, options) {
  return { field: 'date', op, value, type: 'date', ...(options ? { options } : {}) };
}

function idCondition(field, op, value) {
  return { field, op, value, type: 'id' };
}

// Operators Actualist's structured filters do not model (user decision 2026-10-11).
const FEATURE_GAP = 'feature gap: operator not supported by Actualist filters (user decision 2026-10-11)';

function conditionCase(id, description, condition, oracleOnly = null) {
  return {
    id, gate: 'Q1', family: 'condition', source: 'named', description, seed: null, oracleOnly,
    world: 'query', kind: 'condition', condition, conditionsOp: 'and',
  };
}

function conditionCases() {
  return [
    conditionCase('q1-date-is-day', 'date is a day', dateCondition('is', '2026-09-20')),
    conditionCase('q1-date-isapprox-day', 'date isapprox a day', dateCondition('isapprox', '2026-09-20')),
    conditionCase('q1-date-gt-exclusive-lower', 'date gt is exclusive', dateCondition('gt', '2026-09-20')),
    conditionCase('q1-date-gte-inclusive-lower', 'date gte is inclusive', dateCondition('gte', '2026-09-20')),
    conditionCase('q1-date-lt-exclusive-upper', 'date lt is exclusive', dateCondition('lt', '2026-09-20')),
    conditionCase('q1-date-lte-inclusive-upper', 'date lte is inclusive', dateCondition('lte', '2026-09-20')),
    conditionCase('q1-date-month-option', 'date is with the month option', dateCondition('is', '2026-09', { month: true }), FEATURE_GAP),
    conditionCase('q1-date-year-option', 'date is with the year option', dateCondition('is', '2026', { year: true }), FEATURE_GAP),
    conditionCase('q1-account-is', 'account is an id', idCondition('account', 'is', 'acct-on-1')),
    conditionCase('q1-account-is-not', 'account isNot an id', idCondition('account', 'isNot', 'acct-on-1')),
    conditionCase('q1-account-one-of', 'account oneOf ids', idCondition('account', 'oneOf', ['acct-on-1', 'acct-off'])),
    conditionCase('q1-account-not-one-of', 'account notOneOf ids', idCondition('account', 'notOneOf', ['acct-on-1', 'acct-off'])),
    conditionCase('q1-account-contains-name', 'account contains a name fragment', idCondition('account', 'contains', 'Primary'), FEATURE_GAP),
    conditionCase('q1-account-matches-name', 'account matches a name pattern', idCondition('account', 'matches', '^Primary'), FEATURE_GAP),
    conditionCase('q1-account-does-not-contain-name', 'account doesNotContain a name fragment', idCondition('account', 'doesNotContain', 'Primary'), FEATURE_GAP),
    conditionCase('q1-account-on-budget', 'account onBudget', idCondition('account', 'onBudget', null), FEATURE_GAP),
    conditionCase('q1-account-off-budget', 'account offBudget', idCondition('account', 'offBudget', null), FEATURE_GAP),
    conditionCase('q1-payee-is-mapped-id', 'payee is a merged-away id resolved through the mapping', idCondition('payee', 'is', 'payee-target')),
    conditionCase('q1-payee-is-not-null', 'payee isNot null', idCondition('payee', 'isNot', null)),
    conditionCase('q1-payee-one-of', 'payee oneOf ids', idCondition('payee', 'oneOf', ['payee-target', 'payee-after'])),
    conditionCase('q1-payee-not-one-of', 'payee notOneOf ids', idCondition('payee', 'notOneOf', ['payee-target', 'payee-after'])),
    conditionCase('q1-payee-contains-name', 'payee contains a name fragment', idCondition('payee', 'contains', 'Mapped'), FEATURE_GAP),
    conditionCase('q1-payee-matches-name', 'payee matches a name pattern', idCondition('payee', 'matches', '^Mapped'), FEATURE_GAP),
    conditionCase('q1-payee-does-not-contain-name', 'payee doesNotContain a name fragment', idCondition('payee', 'doesNotContain', 'Mapped'), FEATURE_GAP),
    conditionCase('q1-payee-is-null', 'payee is null', idCondition('payee', 'is', null)),
    conditionCase('q1-category-is-mapped-id', 'category is a merged-away id resolved through the mapping', idCondition('category', 'is', 'category-target')),
    conditionCase('q1-category-is-not-null', 'category isNot null', idCondition('category', 'isNot', null)),
    conditionCase('q1-category-one-of', 'category oneOf ids', idCondition('category', 'oneOf', ['category-target', 'category-after'])),
    conditionCase('q1-category-not-one-of', 'category notOneOf ids', idCondition('category', 'notOneOf', ['category-target', 'category-after'])),
    conditionCase('q1-category-contains-name', 'category contains a name fragment', idCondition('category', 'contains', 'Mapped'), FEATURE_GAP),
    conditionCase('q1-category-matches-name', 'category matches a name pattern', idCondition('category', 'matches', '^Mapped'), FEATURE_GAP),
    conditionCase('q1-category-does-not-contain-name', 'category doesNotContain a name fragment', idCondition('category', 'doesNotContain', 'Mapped'), FEATURE_GAP),
    conditionCase('q1-category-is-null-uncategorized', 'category is null (uncategorized)', idCondition('category', 'is', null)),
  ];
}

// ---------------------------------------------------------------- families

function familyCase(id, description, spec) {
  return {
    id, gate: 'Q3', family: 'family', source: 'named', description, seed: null, oracleOnly: null,
    world: 'family', conditionsOp: 'and', ...spec,
  };
}

function familyCases() {
  return [
    familyCase('q3-date-family-grouping', 'date condition matches every row of the family', {
      kind: 'condition', condition: dateCondition('is', '2026-09-20'),
    }),
    familyCase('q3-account-family-grouping', 'account condition matches every row of the family', {
      kind: 'condition', condition: idCondition('account', 'is', 'acct-family'),
    }),
    familyCase('q3-payee-child-selects-family', 'a child payee match selects the family', {
      kind: 'condition', condition: idCondition('payee', 'is', 'payee-target'),
    }),
    familyCase('q3-category-child-selects-family', 'a child category match selects the family', {
      kind: 'condition', condition: idCondition('category', 'is', 'category-target'),
    }),
    familyCase('q3-free-text-grouped-versus-physical', 'free-text search over child notes', {
      kind: 'search', search: 'needle',
    }),
  ];
}

// ---------------------------------------------------------------- handler cases

const CONDITION_A = idCondition('account', 'is', 'acct-a');
const CONDITION_B = idCondition('payee', 'is', 'payee-b');

function handlerCase(id, description, baseline, candidate) {
  return {
    id, gate: 'Q2', family: 'filter', source: 'named', description, seed: null, oracleOnly: null,
    world: 'empty', kind: 'filter-create',
    baseline: { id: 'baseline-filter', name: 'Baseline', ...baseline },
    candidate,
  };
}

function handlerCases() {
  const base = (conditions, conditionsOp = 'and') => ({ conditions, conditionsOp });
  const candidate = (name, conditions, conditionsOp = 'and') => ({ name, conditions, conditionsOp });
  return [
    handlerCase('q2-exact-condition-equivalence', 'identical conditions under a new name',
      base([CONDITION_A, CONDITION_B]), candidate('Candidate exact', [CONDITION_A, CONDITION_B])),
    handlerCase('q2-reordered-condition-equivalence', 'same conditions in another order',
      base([CONDITION_A, CONDITION_B]), candidate('Candidate reordered', [CONDITION_B, CONDITION_A])),
    handlerCase('q2-duplicate-condition-multiplicity', 'a repeated condition against two distinct ones',
      base([CONDITION_A, CONDITION_B]), candidate('Candidate duplicate multiplicity', [CONDITION_A, CONDITION_A])),
    handlerCase('q2-number-versus-string-value', 'number versus string operand',
      base([idCondition('account', 'is', 7)]), candidate('Candidate string value', [idCondition('account', 'is', '7')])),
    handlerCase('q2-options-key-order', 'options keys in another order',
      base([dateCondition('is', '2026-09', { month: true, year: false })]),
      candidate('Candidate reordered options', [dateCondition('is', '2026-09', { year: false, month: true })])),
    handlerCase('q2-single-condition-and-versus-or', 'one condition joined with and versus or',
      base([CONDITION_A]), candidate('Candidate single or', [CONDITION_A], 'or')),
    handlerCase('q2-multiple-condition-and-versus-or-control', 'two conditions joined with and versus or',
      base([CONDITION_A, CONDITION_B]), candidate('Candidate multi or', [CONDITION_A, CONDITION_B], 'or')),
    handlerCase('q2-duplicate-live-name-precedes-condition-check', 'a duplicate live name is checked before conditions',
      base([CONDITION_A]), candidate('Baseline', [CONDITION_B])),
  ];
}

// ---------------------------------------------------------------- split modes

function splitModeCase(id, description, world, spec) {
  return {
    id, gate: 'Splits', family: 'splitmodes', source: 'named', description, seed: null, oracleOnly: null,
    world, kind: 'split-modes', account: 'checking', search: null, modes: SPLIT_MODES, order: SPLITMODE_ORDER,
    balance: false, ...spec,
  };
}

function splitModeCases() {
  return [
    splitModeCase('split-modes-two-child-family', 'one simple row and a two-child family in every split mode',
      'splitmodes-two-child-family', { projection: ['all', 'inline', 'none', 'grouped'] }),
    splitModeCase('child-note-search', 'free-text search that only a child note matches',
      'splitmodes-child-note-search', { account: null, search: 'Q01-CHILD-NOTE', projection: ['query', 'all', 'grouped'] }),
    splitModeCase('dead-parent-excludes-orphan', 'a deleted parent hides its orphan child and a child of a missing parent',
      'splitmodes-dead-parent', { balance: true, projection: ['all', 'inline', 'balances'] }),
    splitModeCase('flag-disagreement-parent-id-without-is-child', 'parent_id set while is_child is false',
      'splitmodes-flag-disagreement', { projection: ['all', 'inline'] }),
    splitModeCase('default-order', 'date, starting-balance flag, sort order then id',
      'splitmodes-default-order', { projection: ['all'] }),
  ];
}

// ---------------------------------------------------------------- plan

export const ORACLE_ONLY_FIELDS = [];
export const FAMILIES = ['condition', 'family', 'filter', 'splitmodes'];

export function buildPlan() {
  const cases = [...conditionCases(), ...familyCases(), ...handlerCases(), ...splitModeCases()];
  return { seed: SEED, timeZone: TIME_ZONE, worlds: WORLDS, cases };
}

export function oracleOnlyEntries(plan) {
  return plan.cases
    .filter(planCase => planCase.oracleOnly !== null)
    .map(planCase => ({ id: planCase.id, reason: planCase.oracleOnly }));
}

// The Actualist-visible projection written to Splits/grouped-query-cases.json.
// Keys keep the order of the original hand-written file.
export function groupedQueryProjection(record, planCase) {
  const projected = { id: record.id };
  for (const key of planCase.projection) {
    if (key === 'query') projected.query = planCase.search;
    else if (key === 'balances') projected.balances = record.balances;
    else projected[key] = record.results[key].ids;
  }
  return projected;
}

function rootOf(world, id) {
  const found = world.transactions.find(candidate => candidate.id === id);
  return found?.isChild && found.parentID ? found.parentID : id;
}

// Structural checks of the author's expectations against a recorded case. It
// never compares recorded values with hand-written ones.
export function expectationFailures(record, planCase) {
  const failures = [];
  const world = WORLDS[planCase.world];
  const sorted = ids => JSON.stringify([...ids].sort());
  if (planCase.kind === 'condition' || planCase.kind === 'search') {
    if (record.compiled.errors.length > 0) failures.push(`compile errors: ${JSON.stringify(record.compiled.errors)}`);
    const roots = new Set(record.physical.ids.map(id => rootOf(world, id)));
    if (sorted(record.grouped.rootIDs) !== sorted([...roots])) failures.push('grouped roots differ from the roots of the physical matches');
    const displayed = new Set(record.grouped.displayedIDs);
    for (const id of record.physical.ids) {
      if (!displayed.has(id)) failures.push(`physical match ${id} is missing from the grouped family`);
    }
    if (sorted(record.grouped.contextIDs) !== sorted(record.grouped.displayedIDs.filter(id => !record.physical.ids.includes(id)))) {
      failures.push('context ids are not the grouped rows that are not physical matches');
    }
  }
  if (planCase.kind === 'condition') {
    const filter = record.filter;
    if (filter.outcome !== 'created') failures.push(`filter-create ${filter.outcome}: ${filter.error}`);
    else if (JSON.stringify(filter.row?.conditions) !== JSON.stringify([planCase.condition])) failures.push('stored conditions differ from the authored condition');
    if (!filter.messages.every(message => message.dataset === 'transaction_filters')) failures.push('filter-create touched another dataset');
  }
  if (planCase.kind === 'filter-create') {
    if (record.filter.outcome === 'other-error') failures.push(`unclassified filter-create error: ${record.filter.error}`);
    const created = record.filter.outcome === 'created';
    if (record.filter.rows.length !== (created ? 2 : 1)) failures.push('filter row count does not match the outcome');
    if ((record.filter.messages.length > 0) !== created) failures.push('CRDT messages do not match the outcome');
  }
  if (planCase.kind === 'split-modes') {
    for (const mode of planCase.modes) {
      if (!Array.isArray(record.results[mode]?.ids)) failures.push(`${mode}: no ids recorded`);
    }
    if (planCase.balance && typeof record.balances?.[planCase.account] !== 'number') failures.push('no account balance recorded');
  }
  return failures;
}
