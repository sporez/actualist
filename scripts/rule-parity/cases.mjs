// The rules-engine case plan: named cases plus seeded generated cases.
//
// Pure data. generate.mjs runs every case through Actual's runRules; verify.mjs
// rebuilds this plan without an oracle and compares it with the committed
// fixture. Amounts are integer minor units. Dates are ISO strings. Expected
// outputs are never written here; they come only from the oracle.

export const SEED = 20261011;
export const TODAY = '2026-10-15';
export const TIME_ZONE = 'America/New_York';
export const GENERATED_CONDITION_CASES_PER_SPEC = 2;
export const GENERATED_RANK_CASES = 40;
export const GENERATED_JOIN_CASES = 24;

export function mulberry32(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let value = Math.imul(state ^ (state >>> 15), 1 | state);
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value;
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------------------------------------------------------------- world

const ACCOUNTS = [
  { id: 'acc-checking', name: 'Synthetic Checking', offbudget: false, closed: false },
  { id: 'acc-savings', name: 'Synthetic Savings', offbudget: false, closed: false },
  { id: 'acc-brokerage', name: 'Synthetic Brokerage', offbudget: true, closed: false },
  { id: 'acc-old', name: 'Synthetic Old Card', offbudget: false, closed: true },
];
const GROUPS = [
  { id: 'grp-bills', name: 'Synthetic Bills', income: false },
  { id: 'grp-fun', name: 'Synthetic Fun', income: false },
  { id: 'grp-income', name: 'Synthetic Income', income: true },
];
const CATEGORIES = [
  { id: 'cat-groceries', name: 'Synthetic Groceries', group: 'grp-bills', income: false },
  { id: 'cat-rent', name: 'Synthetic Rent', group: 'grp-bills', income: false },
  { id: 'cat-dining', name: 'Synthetic Dining', group: 'grp-fun', income: false },
  { id: 'cat-games', name: 'Synthetic Games', group: 'grp-fun', income: false },
  { id: 'cat-salary', name: 'Synthetic Salary', group: 'grp-income', income: true },
];
const PAYEES = [
  { id: 'pay-store', name: 'Synthetic Market', transferAccount: null },
  { id: 'pay-landlord', name: 'Synthetic Landlord', transferAccount: null },
  { id: 'pay-cafe', name: 'Corner Cafe', transferAccount: null },
  { id: 'pay-employer', name: 'Synthetic Employer', transferAccount: null },
  { id: 'pay-xfer-savings', name: '', transferAccount: 'acc-savings' },
  { id: 'pay-xfer-brokerage', name: '', transferAccount: 'acc-brokerage' },
];
// Existing history, read only by BALANCE_OF and the running-balance variable.
const HISTORY = [
  { id: 'txn-h1', account: 'acc-checking', date: '2026-09-20', amount: 300000, payee: 'pay-employer', category: 'cat-salary' },
  { id: 'txn-h2', account: 'acc-checking', date: '2026-10-01', amount: -150000, payee: 'pay-landlord', category: 'cat-rent' },
  { id: 'txn-h3', account: 'acc-checking', date: '2026-10-05', amount: -1000, payee: 'pay-cafe', category: 'cat-dining' },
  { id: 'txn-h4', account: 'acc-savings', date: '2026-09-01', amount: 50000, payee: 'pay-employer', category: null },
  { id: 'txn-h5', account: 'acc-brokerage', date: '2026-08-15', amount: 123456, payee: null, category: null },
];

const MONTHLY_5 = {
  frequency: 'monthly', start: '2026-01-05', interval: 1, patterns: [],
  skipWeekend: false, weekendSolveMode: 'after', endMode: 'never',
};
const MONTHLY_3_SKIP_WEEKEND = { ...MONTHLY_5, start: '2026-01-03', skipWeekend: true, weekendSolveMode: 'after' };
const BIWEEKLY = { ...MONTHLY_5, frequency: 'weekly', start: '2026-10-05', interval: 2 };
const WEEKLY_ENDED = { ...MONTHLY_5, frequency: 'weekly', start: '2026-09-07', endMode: 'after_n_occurrences', endOccurrences: 3 };

const SCHEDULES = [
  {
    id: 'sched-rent', name: 'Synthetic Rent Schedule', completed: false, ruleID: 'rule-sched-rent',
    conditions: [
      { op: 'isapprox', field: 'date', value: MONTHLY_5 },
      { op: 'isapprox', field: 'amount', value: -150000 },
      { op: 'is', field: 'payee', value: 'pay-landlord' },
    ],
  },
  {
    id: 'sched-oneoff', name: 'Synthetic One-off Schedule', completed: false, ruleID: 'rule-sched-oneoff',
    conditions: [
      { op: 'is', field: 'date', value: '2026-10-05' },
      { op: 'is', field: 'payee', value: 'pay-landlord' },
    ],
  },
  {
    id: 'sched-oneoff-done', name: 'Synthetic Finished One-off Schedule', completed: true, ruleID: 'rule-sched-oneoff-done',
    conditions: [
      { op: 'is', field: 'date', value: '2026-10-05' },
      { op: 'is', field: 'payee', value: 'pay-cafe' },
    ],
  },
  {
    id: 'sched-done', name: 'Synthetic Done Schedule', completed: true, ruleID: 'rule-sched-done',
    conditions: [
      { op: 'isapprox', field: 'date', value: BIWEEKLY },
      { op: 'isapprox', field: 'amount', value: -4250 },
    ],
  },
];

export function world({ schedules = [], transactions = HISTORY } = {}) {
  return {
    accounts: ACCOUNTS,
    groups: GROUPS,
    categories: CATEGORIES,
    payees: PAYEES,
    transactions,
    schedules: schedules.map(id => SCHEDULES.find(schedule => schedule.id === id)),
  };
}

// The transaction an import or manual entry hands runRules.
export const BASE = {
  account: 'acc-checking',
  date: '2026-10-05',
  amount: -4250,
  payee: 'pay-store',
  imported_payee: 'WHOLE FOODS #123',
  notes: 'weekly shop #food #weekly',
  category: null,
  cleared: false,
  reconciled: false,
};

const input = (label, overrides = {}) => ({ label, transaction: { ...BASE, ...overrides } });

// ------------------------------------------------------------- builders

const condition = (field, op, value, options) => ({ field, op, value, ...(options ? { options } : {}) });
const set = (field, value, options) => ({ op: 'set', field, value, ...(options ? { options } : {}) });
const rule = (id, stage, conditionsOp, conditions, actions) => ({ id, stage, conditionsOp, conditions, actions });
const AND = 'and';
const OR = 'or';
const splitSet = (splitIndex, field, value) => set(field, value, { splitIndex });
const splitAmount = (splitIndex, method, value, extra = {}) => ({
  op: 'set-split-amount', value, options: { splitIndex, method, ...extra },
});

// Fields the production preview cannot surface, and Handlebars templates it cannot
// run, so such a case cannot be replayed through previewRules without a new
// production seam. These cases stay in the fixture as oracle-only.
const INEXPRESSIBLE_ACTION_FIELDS = new Map([
  ['imported_payee', 'preview does not return imported_payee'],
  ['reconciled', 'preview does not return reconciled'],
  ['payee_name', 'preview does not create payees or return payee_name'],
]);

function oracleOnlyReason(rules, extra) {
  if (extra) return extra;
  for (const planned of rules) {
    for (const action of planned.actions) {
      if (action.options?.template) return 'production fail-closes Handlebars template actions; there is no template engine';
      if (action.op === 'set' && action.options?.formula) return 'production fail-closes formula set actions: a rule with one is not evaluated';
      const reason = INEXPRESSIBLE_ACTION_FIELDS.get(action.field);
      if (reason) return reason;
    }
  }
  return null;
}

function makeCase({ id, description, rules, inputs, setup = world(), seed = null, mustApply = true, oracleOnly = null }) {
  return {
    id,
    source: seed === null ? 'named' : 'generated',
    description,
    seed,
    mustApply,
    oracleOnly: oracleOnlyReason(rules, oracleOnly),
    setup,
    rules,
    inputs,
  };
}

// ----------------------------------------------------- generation tables

// Each spec is one condition; hits and misses are overrides of BASE. A spec's
// case must apply a rule to some input unless the spec sets mustApply: false.
const CONDITION_SPECS = [
  { key: 'payee-is', cond: condition('payee', 'is', 'pay-store'), hits: [{}], misses: [{ payee: 'pay-cafe' }] },
  { key: 'payee-isnot', cond: condition('payee', 'isNot', 'pay-cafe'), hits: [{}], misses: [{ payee: 'pay-cafe' }] },
  { key: 'payee-oneof', cond: condition('payee', 'oneOf', ['pay-store', 'pay-cafe']), hits: [{}, { payee: 'pay-cafe' }], misses: [{ payee: 'pay-landlord' }] },
  { key: 'payee-notoneof', cond: condition('payee', 'notOneOf', ['pay-cafe', 'pay-employer']), hits: [{}], misses: [{ payee: 'pay-cafe' }] },
  { key: 'payee-contains-id', cond: condition('payee', 'contains', 'store'), hits: [{}], misses: [{ payee: 'pay-cafe' }] },
  { key: 'payee-matches-id', cond: condition('payee', 'matches', '^pay-st'), hits: [{}], misses: [{ payee: 'pay-cafe' }] },
  { key: 'payee-name-is', cond: condition('payee_name', 'is', 'synthetic market'), hits: [{}], misses: [{ payee: 'pay-cafe' }] },
  { key: 'payee-name-contains', cond: condition('payee_name', 'contains', 'cafe'), hits: [{ payee: 'pay-cafe' }], misses: [{}] },
  { key: 'imported-is', cond: condition('imported_payee', 'is', 'Whole Foods #123'), hits: [{}, { imported_payee: 'whole foods #123' }], misses: [{ imported_payee: 'WHOLE FOODS #124' }] },
  { key: 'imported-isnot', cond: condition('imported_payee', 'isNot', 'amazon'), hits: [{}], misses: [{ imported_payee: 'AMAZON' }] },
  { key: 'imported-oneof', cond: condition('imported_payee', 'oneOf', ['Whole Foods #123', 'Trader Joes']), hits: [{}, { imported_payee: 'trader joes' }], misses: [{ imported_payee: 'Costco' }] },
  { key: 'imported-notoneof', cond: condition('imported_payee', 'notOneOf', ['amazon', 'costco']), hits: [{}], misses: [{ imported_payee: 'COSTCO' }] },
  { key: 'imported-contains', cond: condition('imported_payee', 'contains', 'FOODS'), hits: [{}], misses: [{ imported_payee: 'TRADER' }] },
  { key: 'imported-doesnotcontain', cond: condition('imported_payee', 'doesNotContain', 'amazon'), hits: [{}], misses: [{ imported_payee: 'AMAZON MKTP' }] },
  { key: 'imported-matches', cond: condition('imported_payee', 'matches', '^whole\\s+foods\\s+#\\d+$'), hits: [{}], misses: [{ imported_payee: 'WHOLE FOODS' }] },
  { key: 'imported-matches-invalid', cond: condition('imported_payee', 'matches', '(whole'), hits: [], misses: [{}], mustApply: false },
  { key: 'notes-is', cond: condition('notes', 'is', 'Weekly Shop #food #weekly'), hits: [{}], misses: [{ notes: 'weekly shop' }] },
  { key: 'notes-isnot', cond: condition('notes', 'isNot', 'other'), hits: [{}], misses: [{ notes: 'other' }] },
  { key: 'notes-contains', cond: condition('notes', 'contains', '#FOOD'), hits: [{}], misses: [{ notes: 'nothing here' }, { notes: null }] },
  { key: 'notes-doesnotcontain', cond: condition('notes', 'doesNotContain', 'refund'), hits: [{}, { notes: null }], misses: [{ notes: 'Refund pending' }] },
  { key: 'notes-matches', cond: condition('notes', 'matches', '#(food|dining)\\b'), hits: [{}], misses: [{ notes: '#foodie' }] },
  { key: 'notes-hastags', cond: condition('notes', 'hasTags', '#food #weekly'), hits: [{}, { notes: '#weekly #food' }], misses: [{ notes: '#foodie #weekly' }, { notes: '##food #weekly' }] },
  { key: 'notes-hasanytag', cond: condition('notes', 'hasAnyTag', '#dining #weekly'), hits: [{}], misses: [{ notes: '#dinner' }] },
  { key: 'amount-is', cond: condition('amount', 'is', -4250), hits: [{}], misses: [{ amount: -4251 }] },
  { key: 'amount-isapprox', cond: condition('amount', 'isapprox', -4250), hits: [{ amount: -3931 }, { amount: -4569 }], misses: [{ amount: -3930 }, { amount: -4570 }] },
  { key: 'amount-isbetween', cond: condition('amount', 'isbetween', { num1: -5000, num2: -4000 }), hits: [{ amount: -4000 }, { amount: -5000 }], misses: [{ amount: -3999 }, { amount: -5001 }] },
  { key: 'amount-isbetween-reversed', cond: condition('amount', 'isbetween', { num1: -4000, num2: -5000 }), hits: [{ amount: -4500 }], misses: [{ amount: 100 }] },
  { key: 'amount-gt', cond: condition('amount', 'gt', -4250), hits: [{ amount: -4249 }], misses: [{}] },
  { key: 'amount-gte', cond: condition('amount', 'gte', -4250), hits: [{}], misses: [{ amount: -4251 }] },
  { key: 'amount-lt', cond: condition('amount', 'lt', -4250), hits: [{ amount: -4251 }], misses: [{}] },
  { key: 'amount-lte', cond: condition('amount', 'lte', -4250), hits: [{}], misses: [{ amount: -4249 }] },
  { key: 'amount-inflow-gt', cond: condition('amount', 'gt', 1000, { inflow: true }), hits: [{ amount: 1500 }], misses: [{ amount: -1500 }, { amount: 500 }] },
  { key: 'amount-outflow-gt', cond: condition('amount', 'gt', 4000, { outflow: true }), hits: [{}], misses: [{ amount: 4500 }, { amount: -3999 }] },
  { key: 'amount-outflow-isbetween', cond: condition('amount', 'isbetween', { num1: 1000, num2: 5000 }, { outflow: true }), hits: [{}], misses: [{ amount: -6000 }, { amount: 2000 }] },
  { key: 'amount-outflow-isapprox', cond: condition('amount', 'isapprox', 4250, { outflow: true }), hits: [{}, { amount: -4569 }], misses: [{ amount: 4250 }] },
  { key: 'amount-inflow-is-zero', cond: condition('amount', 'is', 0, { inflow: true }), hits: [{ amount: 0 }], misses: [{}] },
  { key: 'date-is', cond: condition('date', 'is', '2026-10-05'), hits: [{}], misses: [{ date: '2026-10-06' }] },
  { key: 'date-is-month', cond: condition('date', 'is', '2026-10'), hits: [{}, { date: '2026-10-31' }], misses: [{ date: '2026-11-01' }] },
  { key: 'date-is-year', cond: condition('date', 'is', '2026'), hits: [{}, { date: '2026-12-31' }], misses: [{ date: '2027-01-01' }] },
  { key: 'date-isapprox', cond: condition('date', 'isapprox', '2026-10-05'), hits: [{ date: '2026-10-03' }, { date: '2026-10-07' }], misses: [{ date: '2026-10-08' }, { date: '2026-10-02' }] },
  { key: 'date-gt', cond: condition('date', 'gt', '2026-10-05'), hits: [{ date: '2026-10-06' }], misses: [{}] },
  { key: 'date-gte', cond: condition('date', 'gte', '2026-10-05'), hits: [{}], misses: [{ date: '2026-10-04' }] },
  { key: 'date-lt', cond: condition('date', 'lt', '2026-10-05'), hits: [{ date: '2026-10-04' }], misses: [{}] },
  { key: 'date-lte', cond: condition('date', 'lte', '2026-10-05'), hits: [{}], misses: [{ date: '2026-10-06' }] },
  { key: 'date-is-recur', cond: condition('date', 'is', MONTHLY_5), hits: [{}, { date: '2026-11-05' }], misses: [{ date: '2026-10-06' }] },
  { key: 'date-isapprox-recur', cond: condition('date', 'isapprox', MONTHLY_5), hits: [{ date: '2026-10-07' }, { date: '2026-10-03' }], misses: [{ date: '2026-10-08' }] },
  { key: 'date-is-recur-biweekly', cond: condition('date', 'is', BIWEEKLY), hits: [{ date: '2026-10-19' }], misses: [{ date: '2026-10-12' }] },
  { key: 'date-is-recur-skip-weekend', cond: condition('date', 'is', MONTHLY_3_SKIP_WEEKEND), hits: [{ date: '2026-10-05' }], misses: [{ date: '2026-10-03' }] },
  { key: 'date-is-recur-ended', cond: condition('date', 'is', WEEKLY_ENDED), hits: [{ date: '2026-09-14' }], misses: [{ date: '2026-10-05' }] },
  { key: 'account-is', cond: condition('account', 'is', 'acc-checking'), hits: [{}], misses: [{ account: 'acc-savings' }] },
  { key: 'account-isnot', cond: condition('account', 'isNot', 'acc-savings'), hits: [{}], misses: [{ account: 'acc-savings' }] },
  { key: 'account-oneof', cond: condition('account', 'oneOf', ['acc-checking', 'acc-old']), hits: [{}, { account: 'acc-old' }], misses: [{ account: 'acc-savings' }] },
  { key: 'account-notoneof', cond: condition('account', 'notOneOf', ['acc-savings', 'acc-old']), hits: [{}], misses: [{ account: 'acc-old' }] },
  { key: 'account-onbudget', cond: condition('account', 'onBudget', null), hits: [{}, { account: 'acc-old' }], misses: [{ account: 'acc-brokerage' }] },
  { key: 'account-offbudget', cond: condition('account', 'offBudget', null), hits: [{ account: 'acc-brokerage' }], misses: [{}] },
  { key: 'category-is', cond: condition('category', 'is', 'cat-groceries'), hits: [{ category: 'cat-groceries' }], misses: [{ category: 'cat-dining' }, {}] },
  { key: 'category-is-null', cond: condition('category', 'is', null), hits: [{}], misses: [{ category: 'cat-dining' }] },
  { key: 'category-isnot', cond: condition('category', 'isNot', 'cat-dining'), hits: [{ category: 'cat-groceries' }, {}], misses: [{ category: 'cat-dining' }] },
  { key: 'category-oneof', cond: condition('category', 'oneOf', ['cat-groceries', 'cat-rent']), hits: [{ category: 'cat-rent' }], misses: [{ category: 'cat-games' }] },
  { key: 'category-group-is', cond: condition('category_group', 'is', 'grp-bills'), hits: [{ category: 'cat-groceries' }, { category: 'cat-rent' }], misses: [{ category: 'cat-dining' }, {}] },
  { key: 'cleared-is-true', cond: condition('cleared', 'is', true), hits: [{ cleared: true }], misses: [{}] },
  { key: 'cleared-is-false', cond: condition('cleared', 'is', false), hits: [{}], misses: [{ cleared: true }] },
  { key: 'reconciled-is-true', cond: condition('reconciled', 'is', true), hits: [{ reconciled: true }], misses: [{}] },
];

const ACTION_SPECS = [
  { key: 'set-category', actions: () => [set('category', 'cat-dining')] },
  { key: 'clear-category', actions: () => [set('category', null)] },
  { key: 'set-payee', actions: () => [set('payee', 'pay-cafe')] },
  { key: 'set-payee-transfer', actions: () => [set('payee', 'pay-xfer-savings')] },
  { key: 'set-payee-name-new', actions: () => [set('payee_name', 'Brand New Payee')] },
  { key: 'set-payee-name-existing', actions: () => [set('payee_name', 'Corner Cafe')] },
  { key: 'set-notes', actions: () => [set('notes', 'rule note')] },
  { key: 'clear-notes-null', actions: () => [set('notes', null)] },
  { key: 'clear-notes-empty', actions: () => [set('notes', '')] },
  { key: 'set-cleared', actions: () => [set('cleared', true)] },
  { key: 'set-reconciled', actions: () => [set('reconciled', true)] },
  { key: 'set-account', actions: () => [set('account', 'acc-savings')] },
  { key: 'set-account-offbudget', actions: () => [set('account', 'acc-brokerage')] },
  { key: 'set-date', actions: () => [set('date', '2026-10-20')] },
  { key: 'set-amount', actions: () => [set('amount', -999)] },
  { key: 'set-imported-payee', actions: () => [set('imported_payee', 'RENAMED')] },
  { key: 'prepend-notes', actions: () => [{ op: 'prepend-notes', value: '[pre] ' }] },
  { key: 'append-notes', actions: () => [{ op: 'append-notes', value: ' [app]' }] },
  { key: 'formula-notes', actions: () => [set('notes', null, { formula: '=notes & " | " & account_name' })] },
  { key: 'formula-amount', actions: () => [set('amount', null, { formula: '=amount * 2' })] },
  { key: 'formula-amount-negate', actions: () => [set('amount', null, { formula: '=-amount' })] },
  { key: 'formula-date-today', actions: () => [set('date', null, { formula: '=today' })] },
  { key: 'formula-balance-of-id', actions: () => [set('notes', null, { formula: '=BALANCE_OF("acc-checking")' })] },
  { key: 'formula-balance-of-name', actions: () => [set('notes', null, { formula: '=BALANCE_OF("Synthetic Savings")' })] },
  { key: 'formula-cleared', actions: () => [set('cleared', null, { formula: '=amount < 0' })] },
  { key: 'formula-category-name', actions: () => [set('notes', null, { formula: '=category_name' })] },
  { key: 'template-notes', actions: () => [set('notes', null, { template: '{{notes}} / {{imported_payee}}' })] },
  { key: 'template-amount', actions: () => [set('amount', null, { template: '{{add amount 100}}' })] },
  { key: 'template-date', actions: () => [set('date', null, { template: '{{addDays date 3}}' })] },
  { key: 'template-regex', actions: () => [set('notes', null, { template: '{{regex imported_payee "/#\\d+/" ""}}' })] },
  { key: 'template-cleared', actions: () => [set('cleared', null, { template: 'true' })] },
  { key: 'link-schedule', actions: () => [{ op: 'link-schedule', value: 'sched-rent' }] },
  { key: 'delete-transaction', actions: () => [{ op: 'delete-transaction' }] },
  { key: 'multi-field', actions: () => [set('category', 'cat-groceries'), set('notes', 'multi'), set('cleared', true)] },
];

// Actions the production preview can express. Seeded condition, rank and join
// cases draw only from these so that most of the fixture is replayable; the
// gen-action-* cases and named cases cover the rest as oracle-only.
const REPLAYABLE_ACTIONS = ACTION_SPECS.filter(
  spec => oracleOnlyReason([{ actions: spec.actions() }], null) === null,
);

// Actions Actualist handles differently (see the README's "Swift replay"). The
// gen-action-* cases and named cases exercise each one on its own; the shared
// pools below leave them out so a divergent case has one cause.
const DIVERGENT_ACTION_KEYS = new Set([
  'set-account', 'set-account-offbudget', 'delete-transaction', 'clear-notes-empty',
]);
const SHARED_ACTIONS = REPLAYABLE_ACTIONS.filter(spec => !DIVERGENT_ACTION_KEYS.has(spec.key));

// Conditions BASE satisfies, with an override that breaks each one.
const COMATCH_SPECS = [
  { cond: condition('payee', 'is', 'pay-store'), breakWith: { payee: 'pay-cafe' } },
  { cond: condition('notes', 'contains', 'shop'), breakWith: { notes: 'other' } },
  { cond: condition('amount', 'lt', 0), breakWith: { amount: 500 } },
  { cond: condition('imported_payee', 'matches', 'whole'), breakWith: { imported_payee: 'AMAZON' } },
  { cond: condition('account', 'is', 'acc-checking'), breakWith: { account: 'acc-savings' } },
  { cond: condition('date', 'gte', '2026-10-01'), breakWith: { date: '2026-09-30' } },
  { cond: condition('category', 'is', null), breakWith: { category: 'cat-dining' } },
  { cond: condition('payee', 'oneOf', ['pay-store', 'pay-cafe']), breakWith: { payee: 'pay-landlord' } },
  { cond: condition('amount', 'isbetween', { num1: -5000, num2: -4000 }), breakWith: { amount: -9000 } },
  { cond: condition('cleared', 'is', false), breakWith: { cleared: true } },
];

const STAGES = ['pre', null, 'post'];

function shuffledRuleIDs(rng, count) {
  const pool = Array.from({ length: 40 }, (_, index) => index + 1);
  for (let index = pool.length - 1; index > 0; index -= 1) {
    const swap = Math.floor(rng() * (index + 1));
    [pool[index], pool[swap]] = [pool[swap], pool[index]];
  }
  return pool.slice(0, count).map(number => `rule-${String(number).padStart(2, '0')}`);
}

function pick(rng, list) {
  return list[Math.floor(rng() * list.length)];
}

// ------------------------------------------------------- seeded cases

function conditionCases() {
  const cases = [];
  CONDITION_SPECS.forEach((spec, specIndex) => {
    for (let variant = 0; variant < GENERATED_CONDITION_CASES_PER_SPEC; variant += 1) {
      const caseSeed = SEED + specIndex * 101 + variant * 7919;
      const rng = mulberry32(caseSeed);
      const [targetID, distractorID] = shuffledRuleIDs(rng, 2);
      const action = pick(rng, SHARED_ACTIONS);
      const distractorAction = pick(rng, SHARED_ACTIONS);
      const distractorCondition = pick(rng, COMATCH_SPECS).cond;
      const inputs = [
        ...spec.hits.map((overrides, index) => input(`hit-${index + 1}`, overrides)),
        ...spec.misses.map((overrides, index) => input(`miss-${index + 1}`, overrides)),
      ];
      cases.push(makeCase({
        id: `gen-cond-${spec.key}-${variant + 1}`,
        description: `Seeded: ${spec.cond.field} ${spec.cond.op} with action ${action.key}, distractor ${distractorAction.key}.`,
        seed: caseSeed,
        mustApply: spec.mustApply !== false,
        rules: [
          rule(targetID, pick(rng, STAGES), AND, [spec.cond], action.actions(rng)),
          rule(distractorID, pick(rng, STAGES), AND, [distractorCondition], distractorAction.actions(rng)),
        ],
        inputs,
      }));
    }
  });
  return cases;
}

function actionCases() {
  return ACTION_SPECS.map((action, index) => {
    const caseSeed = SEED + 500000 + index * 131;
    const rng = mulberry32(caseSeed);
    const [firstID, secondID] = shuffledRuleIDs(rng, 2);
    const other = pick(rng, SHARED_ACTIONS.filter(candidate => candidate.key !== action.key));
    return makeCase({
      id: `gen-action-${action.key}`,
      description: `Seeded: action ${action.key} behind payee is, with a second ${other.key} rule on notes.`,
      seed: caseSeed,
      rules: [
        rule(firstID, pick(rng, STAGES), AND, [condition('payee', 'is', 'pay-store')], action.actions(rng)),
        rule(secondID, pick(rng, STAGES), AND, [condition('notes', 'contains', 'shop')], other.actions(rng)),
      ],
      inputs: [
        input('base'),
        input('control', { payee: 'pay-cafe', notes: null }),
        input('offbudget-account', { account: 'acc-brokerage', category: 'cat-games' }),
        input('inflow', { amount: 250000, payee: 'pay-store', notes: 'Shop refund' }),
      ],
    });
  });
}

function rankCases() {
  const cases = [];
  const settable = SHARED_ACTIONS.filter(action => action.key !== 'link-schedule');
  for (let index = 0; index < GENERATED_RANK_CASES; index += 1) {
    const caseSeed = SEED + 700000 + index * 977;
    const rng = mulberry32(caseSeed);
    const count = 2 + Math.floor(rng() * 3);
    const ids = shuffledRuleIDs(rng, count);
    const rules = ids.map(id => {
      const spec = pick(rng, COMATCH_SPECS);
      return rule(id, pick(rng, STAGES), AND, [spec.cond], pick(rng, settable).actions(rng));
    });
    cases.push(makeCase({
      id: `gen-rank-${String(index + 1).padStart(2, '0')}`,
      description: `Seeded: ${count} rules that all match the base transaction; stage and rank decide the result.`,
      seed: caseSeed,
      rules,
      inputs: [
        input('base'),
        input('cafe', { payee: 'pay-cafe' }),
        input('savings', { account: 'acc-savings', category: 'cat-rent' }),
      ],
    }));
  }
  return cases;
}

function joinCases() {
  const cases = [];
  for (let index = 0; index < GENERATED_JOIN_CASES; index += 1) {
    const caseSeed = SEED + 900000 + index * 613;
    const rng = mulberry32(caseSeed);
    const first = pick(rng, COMATCH_SPECS);
    let second = pick(rng, COMATCH_SPECS);
    while (second === first) second = pick(rng, COMATCH_SPECS);
    const join = index % 2 === 0 ? AND : OR;
    const [ruleID] = shuffledRuleIDs(rng, 1);
    cases.push(makeCase({
      id: `gen-join-${String(index + 1).padStart(2, '0')}-${join}`,
      description: `Seeded: two conditions joined by ${join}; each input breaks none, one, or both.`,
      seed: caseSeed,
      rules: [rule(ruleID, pick(rng, STAGES), join, [first.cond, second.cond], pick(rng, SHARED_ACTIONS.filter(action => action.key !== 'link-schedule')).actions(rng))],
      inputs: [
        input('all-ok'),
        input('break-first', first.breakWith),
        input('break-second', second.breakWith),
        input('break-both', { ...first.breakWith, ...second.breakWith }),
      ],
    }));
  }
  return cases;
}

// --------------------------------------------------------- named cases

function namedCases() {
  const named = [];
  const add = definition => named.push(makeCase(definition));

  add({
    id: 'control-no-rules',
    description: 'No rules: runRules returns the transaction unchanged apart from derived fields.',
    mustApply: false,
    rules: [],
    inputs: [input('base'), input('absent-fields', { payee: undefined, category: undefined, notes: undefined })],
  });
  add({
    id: 'control-non-matching',
    description: 'A rule whose condition matches nothing leaves the transaction unchanged.',
    mustApply: false,
    rules: [rule('rule-01', null, AND, [condition('payee', 'is', 'pay-landlord')], [set('category', 'cat-rent')])],
    inputs: [input('base')],
  });
  add({
    id: 'payee-is-resolved-payee-id',
    description: 'A payee-is rule matches the resolved payee ID; a display name or an unresolved payee does not.',
    rules: [
      rule('rule-01', null, AND, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-groceries')]),
      rule('rule-02', null, AND, [condition('payee', 'is', 'Synthetic Market')], [set('notes', 'matched by name')]),
    ],
    inputs: [input('resolved-id'), input('no-payee', { payee: null }), input('payee-absent', { payee: undefined }), input('other-payee', { payee: 'pay-cafe' })],
  });
  add({
    id: 'imported-payee-raw-text',
    description: 'An imported_payee rule matches the raw bank text case-insensitively and renames the payee.',
    rules: [rule('rule-01', 'pre', AND, [condition('imported_payee', 'is', 'Whole Foods #123')], [set('payee', 'pay-store')])],
    inputs: [
      input('exact', { payee: null }),
      input('upper', { payee: null, imported_payee: 'WHOLE FOODS #123' }),
      input('trailing-space', { payee: null, imported_payee: 'WHOLE FOODS #123 ' }),
      input('different', { payee: null, imported_payee: 'WHOLE FOODS #124' }),
    ],
  });
  add({
    id: 'imported-payee-empty-null-absent',
    description: 'imported_payee is "" matches empty and null text; an absent imported_payee is treated as empty by string conditions.',
    rules: [rule('rule-01', null, AND, [condition('imported_payee', 'is', '')], [set('notes', 'empty import text')])],
    inputs: [input('null', { imported_payee: null }), input('empty', { imported_payee: '' }), input('absent', { imported_payee: undefined }), input('text', { imported_payee: 'x' })],
  });
  add({
    id: 'imported-payee-firstchar-index',
    description: 'imported_payee oneOf is found through the first-character rule index.',
    rules: [rule('rule-01', null, AND, [condition('imported_payee', 'oneOf', ['amazon mktp', 'amzn'])], [set('category', 'cat-games')])],
    inputs: [input('amzn', { imported_payee: 'AMZN Mktp' }), input('amazon', { imported_payee: 'Amazon Mktp' }), input('zebra', { imported_payee: 'Zebra' })],
  });
  add({
    id: 'notes-set-null-and-empty',
    description: 'Rules that set notes to null and to an empty string, in separate stages.',
    rules: [
      rule('rule-01', 'pre', AND, [condition('payee', 'is', 'pay-store')], [set('notes', null)]),
      rule('rule-02', 'post', AND, [condition('payee', 'is', 'pay-cafe')], [set('notes', '')]),
    ],
    inputs: [input('store'), input('cafe', { payee: 'pay-cafe' }), input('store-no-notes', { notes: null })],
  });
  add({
    id: 'notes-prepend-append-empty-and-existing',
    description: 'prepend-notes and append-notes on null, empty and populated notes.',
    rules: [
      rule('rule-01', 'pre', AND, [condition('amount', 'lt', 0)], [{ op: 'prepend-notes', value: '[p] ' }]),
      rule('rule-02', 'post', AND, [condition('amount', 'lt', 0)], [{ op: 'append-notes', value: ' [a]' }]),
    ],
    inputs: [input('populated'), input('null', { notes: null }), input('empty', { notes: '' })],
  });
  add({
    id: 'transfer-payee-set-by-rule',
    description: 'A rule sets a transfer payee; the category and account stay as they are.',
    rules: [rule('rule-01', null, AND, [condition('imported_payee', 'contains', 'transfer')], [set('payee', 'pay-xfer-savings')])],
    inputs: [input('transfer', { imported_payee: 'Online Transfer to Savings', payee: null }), input('other', { imported_payee: 'Coffee' })],
  });
  add({
    id: 'payee-set-then-later-payee-rules',
    description: 'A later payee-is rule sees the payee an earlier rule set, but payee_name is computed once before any rule runs.',
    rules: [
      rule('rule-01', 'pre', AND, [condition('imported_payee', 'contains', 'foods')], [set('payee', 'pay-cafe')]),
      rule('rule-02', null, AND, [condition('payee', 'is', 'pay-cafe')], [set('category', 'cat-dining')]),
      rule('rule-03', null, AND, [condition('payee_name', 'is', 'corner cafe')], [set('notes', 'chained by payee_name')]),
    ],
    inputs: [input('base', { payee: null }), input('already-cafe', { payee: 'pay-cafe', imported_payee: 'Foods' })],
  });
  add({
    id: 'payee-isnot-single-condition',
    description: 'A lone payee-isNot rule runs for every payee but the excluded one.',
    rules: [rule('rule-01', null, AND, [condition('payee', 'isNot', 'pay-cafe')], [set('category', 'cat-groceries')])],
    inputs: [input('store'), input('cafe', { payee: 'pay-cafe' }), input('no-payee', { payee: null })],
  });
  add({
    id: 'index-excludes-or-rule-with-two-indexed-conditions',
    description: 'A rule with both a payee and an imported_payee condition is indexed under both values, so a candidate lookup can skip it even when an or join would match.',
    mustApply: false,
    rules: [
      rule('rule-01', null, OR, [condition('payee', 'isNot', 'pay-cafe'), condition('imported_payee', 'isNot', 'xyz')], [set('category', 'cat-games')]),
      rule('rule-02', null, OR, [condition('payee', 'is', 'pay-cafe'), condition('imported_payee', 'is', 'zebra')], [set('notes', 'indexed or')]),
    ],
    inputs: [
      input('store-costco', { imported_payee: 'Costco' }), input('store-xyz', { imported_payee: 'XYZ' }),
      input('cafe-zebra', { payee: 'pay-cafe', imported_payee: 'Zebra' }), input('cafe-costco', { payee: 'pay-cafe', imported_payee: 'Costco' }),
      input('store-zebra', { imported_payee: 'Zebra' }),
    ],
  });
  add({
    id: 'payee-absent-vs-null-id-conditions',
    description: 'Id-typed conditions on an absent field never match, while null matches is-null.',
    mustApply: false,
    rules: [
      rule('rule-01', null, AND, [condition('category', 'isNot', 'cat-dining')], [set('notes', 'category isNot')]),
      rule('rule-02', null, AND, [condition('category', 'is', null)], [set('cleared', true)]),
      rule('rule-03', null, AND, [condition('category', 'notOneOf', ['cat-dining'])], [set('amount', -1)]),
    ],
    inputs: [input('null', { category: null }), input('absent', { category: undefined }), input('dining', { category: 'cat-dining' })],
  });
  add({
    id: 'offbudget-account-sets-category',
    description: 'A rule on an off-budget account sets a category.',
    rules: [rule('rule-01', null, AND, [condition('account', 'offBudget', null)], [set('category', 'cat-games')])],
    inputs: [input('brokerage', { account: 'acc-brokerage' }), input('checking')],
  });
  add({
    id: 'regex-special-characters-case-insensitive',
    description: 'matches with escaped metacharacters; the pattern is lowercased and the text is lowercased.',
    rules: [
      rule('rule-01', null, AND, [condition('imported_payee', 'matches', '^CAFE \\(#\\d+\\)\\s*\\$?5\\.00$')], [set('category', 'cat-dining')]),
      rule('rule-02', 'post', AND, [condition('notes', 'matches', 'a.c|\\[x\\]')], [set('cleared', true)]),
    ],
    inputs: [
      input('cafe', { imported_payee: 'Cafe (#12) $5.00', notes: 'abc' }),
      input('cafe-no-dollar', { imported_payee: 'CAFE (#7) 5.00', notes: '[X] done' }),
      input('cafe-wrong', { imported_payee: 'CAFE #12 $5.00', notes: 'ac' }),
    ],
  });
  add({
    id: 'regex-uppercase-class-is-lowercased',
    description: 'The value is lowercased before it is compiled, so \\D in a pattern behaves as \\d.',
    mustApply: false,
    rules: [rule('rule-01', null, AND, [condition('notes', 'matches', '^\\D+$')], [set('category', 'cat-games')])],
    inputs: [input('letters', { notes: 'abc' }), input('digits', { notes: '123' })],
  });
  add({
    id: 'amount-isapprox-boundaries',
    description: 'isapprox uses a 7.5% rounded threshold: -10000 spans -10750..-9250; a small value has threshold 0.',
    rules: [
      rule('rule-01', null, AND, [condition('amount', 'isapprox', -10000)], [set('category', 'cat-rent')]),
      rule('rule-02', 'post', AND, [condition('amount', 'isapprox', 5)], [set('cleared', true)]),
    ],
    inputs: [
      input('at-low', { amount: -10750 }), input('beyond-low', { amount: -10751 }),
      input('at-high', { amount: -9250 }), input('beyond-high', { amount: -9249 }),
      input('five', { amount: 5 }), input('six', { amount: 6 }), input('zero', { amount: 0 }),
    ],
  });
  add({
    id: 'amount-isbetween-reversed-and-inclusive',
    description: 'isbetween sorts its bounds and is inclusive; inflow and outflow options flip the sign handling.',
    rules: [
      rule('rule-01', null, AND, [condition('amount', 'isbetween', { num1: 5000, num2: 1000 })], [set('category', 'cat-dining')]),
      rule('rule-02', null, AND, [condition('amount', 'isbetween', { num1: 1000, num2: 5000 }, { outflow: true })], [set('notes', 'outflow window')]),
    ],
    inputs: [input('1000', { amount: 1000 }), input('5000', { amount: 5000 }), input('5001', { amount: 5001 }), input('-4999', { amount: -4999 }), input('-5001', { amount: -5001 })],
  });
  add({
    id: 'amount-zero-with-inflow-outflow-options',
    description: 'A zero amount against inflow and outflow options.',
    rules: [
      rule('rule-01', null, AND, [condition('amount', 'gte', 0, { inflow: true })], [set('notes', 'inflow gte 0')]),
      rule('rule-02', null, AND, [condition('amount', 'lte', 0, { outflow: true })], [set('cleared', true)]),
    ],
    inputs: [input('zero', { amount: 0, notes: null }), input('one', { amount: 1, notes: null }), input('minus-one', { amount: -1, notes: null })],
  });
  add({
    id: 'date-recurring-schedule-style-value',
    description: 'date conditions with a recurrence object: exact, approximate, weekend skip and an ended series.',
    rules: [
      rule('rule-01', null, AND, [condition('date', 'isapprox', MONTHLY_5)], [set('category', 'cat-rent')]),
      rule('rule-02', 'post', AND, [condition('date', 'is', MONTHLY_3_SKIP_WEEKEND)], [set('notes', 'weekend-skipped third')]),
      rule('rule-03', 'pre', AND, [condition('date', 'is', WEEKLY_ENDED)], [set('cleared', true)]),
    ],
    inputs: [
      input('on-fifth', { date: '2026-10-05' }), input('saturday-third', { date: '2026-10-03' }),
      input('two-days-after', { date: '2026-10-07' }), input('three-days-after', { date: '2026-10-08' }),
      input('ended-series-last', { date: '2026-09-21' }), input('after-ended-series', { date: '2026-09-28' }),
    ],
  });
  add({
    id: 'date-month-and-year-values',
    description: 'date is with a month value and a year value.',
    rules: [
      rule('rule-01', null, AND, [condition('date', 'is', '2026-10')], [set('category', 'cat-groceries')]),
      rule('rule-02', 'post', AND, [condition('date', 'is', '2027')], [set('notes', 'next year')]),
    ],
    inputs: [input('oct', { date: '2026-10-31' }), input('nov', { date: '2026-11-01' }), input('2027', { date: '2027-06-01' })],
  });
  add({
    id: 'schedule-rule-links-by-conditions',
    description: 'A transaction without a schedule that matches a schedule rule gets the schedule linked; a completed schedule rule is still a rule upstream.',
    setup: world({ schedules: ['sched-rent', 'sched-done'] }),
    rules: [],
    inputs: [
      input('rent', { amount: -150000, payee: 'pay-landlord', date: '2026-10-05' }),
      input('rent-late', { amount: -150000, payee: 'pay-landlord', date: '2026-10-07' }),
      input('done-schedule-match', { amount: -4250, date: '2026-10-05' }),
      input('done-schedule-date-off', { amount: -4250, date: '2026-10-12' }),
    ],
  });
  add({
    id: 'schedule-attached-runs-its-rule-regardless-of-conditions',
    description: 'A transaction already attached to a schedule runs that schedule rule without its conditions and skips other schedules rules.',
    setup: world({ schedules: ['sched-rent', 'sched-done'] }),
    rules: [
      rule('rule-01', null, AND, [condition('amount', 'lt', 0)], [set('notes', 'plain rule')]),
      rule('rule-02', 'post', AND, [condition('payee', 'is', 'pay-store')], [set('cleared', true)]),
    ],
    inputs: [
      input('attached-rent-off-date', { schedule: 'sched-rent', amount: -1, date: '2026-10-28' }),
      input('attached-done', { schedule: 'sched-done', amount: -1, date: '2026-10-28' }),
      input('attached-unknown', { schedule: 'sched-missing' }),
      input('unattached-date-off', { date: '2026-10-13' }),
    ],
  });
  add({
    id: 'schedule-rule-with-plain-conditions-active-and-completed',
    description: 'Schedule rules with an exact date and a payee: the active one links its schedule; upstream also links a completed schedule.',
    setup: world({ schedules: ['sched-oneoff', 'sched-oneoff-done'] }),
    rules: [],
    inputs: [
      input('active', { payee: 'pay-landlord', date: '2026-10-05' }),
      input('completed', { payee: 'pay-cafe', date: '2026-10-05' }),
      input('wrong-date', { payee: 'pay-landlord', date: '2026-10-06' }),
    ],
  });
  add({
    id: 'link-schedule-action-then-later-rules',
    description: 'A user rule links a schedule; the schedule is set on the output.',
    setup: world({ schedules: ['sched-rent'] }),
    rules: [rule('rule-01', null, AND, [condition('payee', 'is', 'pay-landlord')], [{ op: 'link-schedule', value: 'sched-rent' }])],
    inputs: [input('landlord', { payee: 'pay-landlord', amount: -150000 }), input('store')],
  });
  add({
    id: 'same-field-last-rule-wins-within-stage',
    description: 'Two rules set the same category in one stage; the higher-scored (is) rule runs later and wins over contains.',
    rules: [
      rule('rule-01', null, AND, [condition('notes', 'contains', 'shop')], [set('category', 'cat-dining')]),
      rule('rule-02', null, AND, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-groceries')]),
    ],
    inputs: [input('base')],
  });
  add({
    id: 'same-field-stage-order',
    description: 'Pre, default and post rules set the same category; post wins. Ids are the reverse of stage order.',
    rules: [
      rule('rule-03', 'pre', AND, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-dining')]),
      rule('rule-02', null, AND, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-groceries')]),
      rule('rule-01', 'post', AND, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-games')]),
    ],
    inputs: [input('base')],
  });
  add({
    id: 'same-score-id-tie-break',
    description: 'Two equally scored rules in one stage run in id order; the later id wins.',
    rules: [
      rule('rule-b', null, AND, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-games')]),
      rule('rule-a', null, AND, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-rent')]),
    ],
    inputs: [input('base')],
  });
  add({
    id: 'rank-scores-by-operator',
    description: 'A rule of only exact operators is scored double and runs after looser rules in the same stage.',
    rules: [
      rule('rule-01', null, AND, [condition('payee', 'is', 'pay-store'), condition('amount', 'is', -4250)], [set('notes', 'exact')]),
      rule('rule-02', null, AND, [condition('notes', 'contains', 'shop'), condition('amount', 'lt', 0)], [set('notes', 'loose')]),
      rule('rule-03', null, AND, [condition('amount', 'isapprox', -4250)], [{ op: 'append-notes', value: '+approx' }]),
    ],
    inputs: [input('base')],
  });
  add({
    id: 'notes-unicode-and-case',
    description: 'contains, matches and hasTags with accents, ligature-like capitals, a dotted capital I and emoji.',
    rules: [
      rule('rule-01', null, AND, [condition('notes', 'contains', 'ÉCLAIR')], [set('category', 'cat-dining')]),
      rule('rule-02', null, AND, [condition('notes', 'contains', 'İ')], [set('cleared', true)]),
      rule('rule-03', 'post', AND, [condition('notes', 'hasTags', '#naïve')], [set('payee', 'pay-cafe')]),
      rule('rule-04', 'pre', AND, [condition('notes', 'contains', '🍕')], [set('amount', -1)]),
    ],
    inputs: [
      input('accents', { notes: 'Café Résumé éclair #naïve' }),
      input('dotted-capital-i', { notes: 'İstanbul' }),
      input('emoji', { notes: 'pizza 🍕 night' }),
      input('plain', { notes: 'eclair' }),
    ],
  });
  add({
    id: 'hastags-edge-cases',
    description: 'hasTags requires a whole tag: not a prefix, not a double hash, not mid-word.',
    mustApply: false,
    rules: [rule('rule-01', null, AND, [condition('notes', 'hasTags', '#food')], [set('category', 'cat-groceries')])],
    inputs: [input('exact', { notes: '#food' }), input('with-text', { notes: 'x #food y' }), input('prefix', { notes: '#foodie' }), input('double-hash', { notes: '##food' }), input('mid-word', { notes: 'x#food' }), input('adjacent-tag', { notes: '#food#more' })],
  });
  add({
    id: 'delete-transaction-then-later-rules',
    description: 'delete-transaction sets the tombstone; later rules still run.',
    rules: [
      rule('rule-01', 'pre', AND, [condition('imported_payee', 'contains', 'foods')], [{ op: 'delete-transaction' }]),
      rule('rule-02', 'post', AND, [condition('amount', 'lt', 0)], [set('notes', 'after delete')]),
    ],
    inputs: [input('deleted'), input('kept', { imported_payee: 'Costco' })],
  });
  add({
    id: 'formula-balance-of',
    description: 'BALANCE_OF by account id, by name, for an unknown account, and on the same day as history.',
    rules: [
      rule('rule-01', null, AND, [condition('amount', 'lt', 0)], [set('notes', null, { formula: '=BALANCE_OF("acc-checking")' })]),
      rule('rule-02', 'post', AND, [condition('amount', 'lt', 0)], [set('category', null, { formula: '=IF(BALANCE_OF("Synthetic Savings") > 0, "positive", "none")' })]),
      rule('rule-03', 'post', AND, [condition('amount', 'lt', 0)], [set('amount', null, { formula: '=BALANCE_OF("Nonexistent")' })]),
    ],
    inputs: [
      input('base'), input('before-history', { date: '2026-09-01' }),
      input('same-day-as-history', { date: '2026-10-05', sort_order: 1 }),
      input('far-future', { date: '2027-01-01' }),
    ],
  });
  add({
    id: 'balance-variable-in-templates-and-formulas',
    description: 'The running balance variable in a template and in a formula.',
    rules: [
      rule('rule-01', null, AND, [condition('amount', 'lt', 0)], [set('notes', null, { template: 'bal {{balance}}' })]),
      rule('rule-02', 'post', AND, [condition('amount', 'lt', 0)], [set('imported_payee', null, { formula: '=balance' })]),
    ],
    inputs: [input('base'), input('earlier', { date: '2026-09-25' })],
  });
  add({
    id: 'formula-errors-and-non-numeric',
    description: 'Invalid formulas and non-numeric results are reported in _ruleErrors and leave the field alone.',
    oracleOnly: 'preview does not return _ruleErrors',
    rules: [
      rule('rule-01', 'pre', AND, [condition('amount', 'lt', 0)], [set('notes', null, { formula: '=NOPE(' })]),
      rule('rule-02', null, AND, [condition('amount', 'lt', 0)], [set('amount', null, { formula: '="abc"' })]),
      rule('rule-03', 'post', AND, [condition('amount', 'lt', 0)], [set('date', null, { formula: '="not a date"' })]),
      rule('rule-04', 'post', AND, [condition('amount', 'lt', 0)], [set('notes', null, { formula: 'no equals sign' })]),
    ],
    inputs: [input('base')],
  });
  add({
    id: 'template-edge-values',
    description: 'Templates producing NaN amounts, invalid dates, booleans and helper calls.',
    rules: [
      rule('rule-01', 'pre', AND, [condition('amount', 'lt', 0)], [set('amount', null, { template: '{{notes}}' })]),
      rule('rule-02', null, AND, [condition('amount', 'is', 0)], [set('date', null, { template: 'not a date' })]),
      rule('rule-03', null, AND, [condition('date', 'is', '9999-12-31')], [set('cleared', null, { template: 'yes' })]),
      rule('rule-04', 'post', AND, [condition('payee', 'is', 'pay-store')], [set('notes', null, { template: '{{concat (month date) "/" (day date) " " (add 2 3)}}' })]),
    ],
    inputs: [input('base'), input('numeric-notes', { notes: '12.5' })],
  });
  add({
    id: 'payee-name-creates-or-reuses-payee',
    description: 'Setting payee_name creates a payee when none has that name, reuses an existing one, and clears the payee for an empty name.',
    rules: [
      rule('rule-01', null, AND, [condition('imported_payee', 'is', 'NEW SHOP')], [set('payee_name', 'Fresh Shop')]),
      rule('rule-02', null, AND, [condition('imported_payee', 'is', 'OLD CAFE')], [set('payee_name', 'Corner Cafe')]),
      rule('rule-03', null, AND, [condition('imported_payee', 'is', 'BLANK')], [set('payee_name', '')]),
    ],
    inputs: [
      input('creates', { imported_payee: 'NEW SHOP', payee: null }), input('creates-again', { imported_payee: 'NEW SHOP', payee: null }),
      input('reuses', { imported_payee: 'OLD CAFE', payee: null }), input('blank', { imported_payee: 'BLANK' }),
    ],
  });
  add({
    id: 'category-group-condition-after-category-change',
    description: 'A category_group condition sees the group of a category set earlier in the chain.',
    rules: [
      rule('rule-01', 'pre', AND, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-games')]),
      rule('rule-02', null, AND, [condition('category_group', 'is', 'grp-fun')], [set('notes', 'fun group')]),
      rule('rule-03', 'post', AND, [condition('category_group', 'is', 'grp-bills')], [set('cleared', true)]),
    ],
    inputs: [input('base'), input('starts-bills', { category: 'cat-rent', payee: 'pay-cafe' })],
  });
  add({
    id: 'transfer-and-parent-conditions-in-run-rules',
    description: 'transfer and parent conditions read fields runRules does not populate, so they match only when the input carries them.',
    mustApply: false,
    rules: [
      rule('rule-01', null, AND, [condition('transfer', 'is', false)], [set('notes', 'not transfer')]),
      rule('rule-02', null, AND, [condition('parent', 'is', false)], [set('cleared', true)]),
    ],
    inputs: [input('base'), input('with-fields', { transfer: false, parent: false })],
  });
  add({
    id: 'invalid-and-empty-rules-are-ignored',
    description: 'A rule with an invalid operator, an invalid action field, or no conditions never runs; a valid rule still does.',
    mustApply: true,
    rules: [
      rule('rule-01', null, AND, [condition('notes', 'oneOf', ['a'])], [set('category', 'cat-games')]),
      rule('rule-02', null, AND, [condition('payee', 'is', 'pay-store')], [set('nonexistent_field', 'x')]),
      rule('rule-03', null, AND, [], [set('category', 'cat-rent')]),
      rule('rule-04', null, AND, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-groceries')]),
    ],
    inputs: [input('base')],
  });
  add({
    id: 'set-cleared-and-reconciled',
    description: 'Rules set cleared and reconciled.',
    rules: [
      rule('rule-01', null, AND, [condition('cleared', 'is', false)], [set('cleared', true)]),
      rule('rule-02', 'post', AND, [condition('cleared', 'is', true)], [set('reconciled', true)]),
    ],
    inputs: [input('base'), input('already-cleared', { cleared: true })],
  });
  add({
    id: 'set-account-and-date-and-amount',
    description: 'Rules change account, date and amount; a later rule reads the changed values.',
    rules: [
      rule('rule-01', 'pre', AND, [condition('payee', 'is', 'pay-store')], [set('account', 'acc-savings'), set('date', '2026-11-02'), set('amount', -100)]),
      rule('rule-02', null, AND, [condition('account', 'is', 'acc-savings')], [set('notes', 'saw savings')]),
      rule('rule-03', 'post', AND, [condition('date', 'gte', '2026-11-01')], [set('cleared', true)]),
    ],
    inputs: [input('base'), input('cafe', { payee: 'pay-cafe', account: 'acc-savings' })],
  });
  add({
    id: 'split-fixed-and-remainder-interaction',
    description: 'Interaction check only (split math is covered by split-parity): fixed-amount and remainder splits from one rule.',
    rules: [rule('rule-01', null, AND, [condition('payee', 'is', 'pay-store')], [
      splitSet(1, 'category', 'cat-groceries'), splitAmount(1, 'fixed-amount', -1000),
      splitSet(2, 'category', 'cat-dining'), splitAmount(2, 'remainder', 1),
    ])],
    inputs: [input('base'), input('control', { payee: 'pay-cafe' })],
  });
  add({
    id: 'split-amount-formula-literal-and-balance-of',
    description: 'Interaction check: set-split-amount with method formula, a literal and a BALANCE_OF value, with a remainder split.',
    rules: [rule('rule-01', null, AND, [condition('payee', 'is', 'pay-store')], [
      splitSet(1, 'category', 'cat-groceries'), splitAmount(1, 'formula', null, { formula: '=-10' }),
      splitSet(2, 'category', 'cat-dining'), splitAmount(2, 'formula', null, { formula: '=BALANCE_OF("acc-checking") / 100000' }),
      splitSet(3, 'category', 'cat-games'), splitAmount(3, 'remainder', 1),
    ])],
    inputs: [input('base'), input('before-history', { date: '2026-09-01' })],
  });
  add({
    id: 'split-parent-fields-in-formula',
    description: 'Interaction check: a split child formula reads the parent_* variables added in 26.10.',
    rules: [rule('rule-01', null, AND, [condition('payee', 'is', 'pay-store')], [
      splitSet(1, 'category', 'cat-groceries'),
      set('notes', null, { formula: '=parent_notes & " / " & parent_imported_payee', splitIndex: 1 }),
      splitAmount(1, 'fixed-percent', 50),
      splitSet(2, 'category', 'cat-dining'),
      set('payee', 'pay-cafe', { splitIndex: 2 }),
      splitAmount(2, 'remainder', 1),
    ])],
    inputs: [input('base')],
  });

  return named;
}

// ---------------------------------------------------------------- plan

export function buildPlan() {
  const cases = [
    ...namedCases(),
    ...conditionCases(),
    ...actionCases(),
    ...rankCases(),
    ...joinCases(),
  ];
  return { seed: SEED, today: TODAY, timeZone: TIME_ZONE, cases };
}

export function oracleOnlyEntries(plan) {
  return plan.cases
    .filter(planCase => planCase.oracleOnly !== null)
    .map(planCase => ({ id: planCase.id, reason: planCase.oracleOnly }));
}

// Checks the author's structural expectations against a recorded case. It never
// compares recorded values with hand-written ones.
export function expectationFailures(record, planCase) {
  const failures = [];
  if (!Array.isArray(record.runs) || record.runs.length !== planCase.inputs.length) {
    failures.push(`${record.runs?.length} runs recorded, ${planCase.inputs.length} planned`);
    return failures;
  }
  record.runs.forEach((run, index) => {
    const planned = planCase.inputs[index];
    if (run.label !== planned.label) failures.push(`run ${index} is ${run.label}, plan says ${planned.label}`);
    if (JSON.stringify(run.transaction) !== JSON.stringify(planned.transaction)) {
      failures.push(`run ${run.label}: transaction differs from the plan`);
    }
    if (run.error !== null) failures.push(`run ${run.label}: runRules threw: ${run.error}`);
    if (run.output === null || typeof run.output !== 'object') failures.push(`run ${run.label}: no output`);
    if (!Array.isArray(run.evaluated) || !Array.isArray(run.applied) || !Array.isArray(run.createdPayees)) {
      failures.push(`run ${run.label}: missing evaluated, applied or createdPayees`);
    }
  });
  if (planCase.mustApply && !record.runs.some(run => run.applied.length > 0)) {
    failures.push('no run applied any rule although the case requires one');
  }
  return failures;
}
