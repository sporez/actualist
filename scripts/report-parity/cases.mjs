// The Reports parity plan: the seed worlds and every case's input. Pure input, no expectations;
// the oracle runner calls Actual's report spreadsheets and records what they return.
export const TIME_ZONE = 'UTC';
// The clock the runner freezes unless a case names its own `today`.
export const TODAY = '2026-09-15';
export const LATE_TODAY = '2026-09-30';

const MONTHS = ['2026-03', '2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09'];
const MONTHS_WITH_31 = new Set(['2026-03', '2026-05', '2026-07', '2026-08']);

const accounts = [
  { id: 'acct-checking', name: 'Checking', offbudget: 0 },
  { id: 'acct-card', name: 'Card', offbudget: 0 },
  { id: 'acct-invest', name: 'Invest', offbudget: 1 },
  { id: 'acct-house', name: 'House', offbudget: 1 },
  { id: 'acct-closed', name: 'Closed', offbudget: 0, closed: 1 },
  { id: 'acct-gone', name: 'Gone', offbudget: 0, tombstone: 1 },
];

const groups = [
  { id: 'grp-expenses', name: 'Expenses', is_income: 0, hidden: 0 },
  { id: 'grp-income', name: 'Income', is_income: 1, hidden: 0 },
  { id: 'grp-hidden', name: 'Hidden Group', is_income: 0, hidden: 1 },
];

const categories = [
  { id: 'cat-groceries', name: 'Groceries', cat_group: 'grp-expenses', is_income: 0, hidden: 0 },
  { id: 'cat-dining', name: 'Dining', cat_group: 'grp-expenses', is_income: 0, hidden: 0 },
  { id: 'cat-hidden', name: 'Hidden Category', cat_group: 'grp-expenses', is_income: 0, hidden: 1 },
  { id: 'cat-salary', name: 'Salary', cat_group: 'grp-income', is_income: 1, hidden: 0 },
  // An expense category (is_income 0) that sits in the income group.
  { id: 'cat-in-income-group', name: 'Reimbursable', cat_group: 'grp-income', is_income: 0, hidden: 0 },
  { id: 'cat-hidden-grp', name: 'In Hidden Group', cat_group: 'grp-hidden', is_income: 0, hidden: 0 },
];

const payees = [
  { id: 'pay-employer', name: 'Employer' },
  { id: 'pay-grocer', name: 'Grocer' },
  { id: 'pay-diner', name: 'Diner' },
  { id: 'pay-xfer-checking', name: 'Transfer: Checking', transfer_acct: 'acct-checking' },
  { id: 'pay-xfer-card', name: 'Transfer: Card', transfer_acct: 'acct-card' },
  { id: 'pay-xfer-invest', name: 'Transfer: Invest', transfer_acct: 'acct-invest' },
  { id: 'pay-xfer-house', name: 'Transfer: House', transfer_acct: 'acct-house' },
];

const transactions = [];
const add = (id, account, date, amount, extra = {}) => {
  transactions.push({ id, account, date, amount, ...extra });
};

// Starting balances.
for (const [account, amount] of [
  ['acct-checking', 500000], ['acct-card', -120000], ['acct-invest', 2000000],
  ['acct-house', 30000000], ['acct-closed', 80000],
]) {
  add(`tx-start-${account}`, account, '2026-03-01', amount, { starting_balance_flag: 1 });
}
// A deleted account's deleted history.
add('tx-start-acct-gone', 'acct-gone', '2026-03-01', 99999, { starting_balance_flag: 1, tombstone: 1 });
add('tx-gone-groceries', 'acct-gone', '2026-05-10', -50000, { category: 'cat-groceries', tombstone: 1 });

MONTHS.forEach((m, i) => {
  add(`tx-${m}-salary`, 'acct-checking', `${m}-01`, 300000 + 1000 * i,
    { category: 'cat-salary', payee: 'pay-employer' });
  add(`tx-${m}-d01`, 'acct-checking', `${m}-01`, -(12000 + 100 * i),
    { category: 'cat-groceries', payee: 'pay-grocer' });
  add(`tx-${m}-d15`, 'acct-checking', `${m}-15`, -(4500 + 50 * i),
    { category: 'cat-dining', payee: 'pay-diner' });
  add(`tx-${m}-d28`, 'acct-checking', `${m}-28`, -(7000 + 25 * i),
    { category: 'cat-groceries', payee: 'pay-grocer' });
  add(`tx-${m}-d29`, 'acct-checking', `${m}-29`, -(3100 + 10 * i),
    { category: 'cat-dining', payee: 'pay-diner' });
  add(`tx-${m}-d30`, 'acct-checking', `${m}-30`, -(2900 + i),
    { category: 'cat-groceries', payee: 'pay-grocer' });
  if (MONTHS_WITH_31.has(m)) {
    add(`tx-${m}-d31`, 'acct-checking', `${m}-31`, -1500, { category: 'cat-dining', payee: 'pay-diner' });
  }
  add(`tx-${m}-card-d10`, 'acct-card', `${m}-10`, -(8000 + 100 * i),
    { category: 'cat-groceries', payee: 'pay-grocer' });
  add(`tx-${m}-card-d20`, 'acct-card', `${m}-20`, -2500, { category: 'cat-dining', payee: 'pay-diner' });
});

// A refund, a zero amount, uncategorized rows, hidden and income-group categories.
add('tx-refund', 'acct-checking', '2026-08-10', 2500, { category: 'cat-groceries', payee: 'pay-grocer' });
add('tx-zero', 'acct-checking', '2026-07-12', 0, { category: 'cat-groceries', payee: 'pay-grocer' });
add('tx-uncat-out', 'acct-checking', '2026-06-05', -3300, { payee: 'pay-grocer' });
add('tx-uncat-in', 'acct-checking', '2026-08-20', 1200, { payee: 'pay-employer' });
add('tx-hidden-1', 'acct-checking', '2026-07-03', -2200, { category: 'cat-hidden', payee: 'pay-diner' });
add('tx-hidden-2', 'acct-checking', '2026-09-03', -1800, { category: 'cat-hidden', payee: 'pay-diner' });
add('tx-income-group-1', 'acct-checking', '2026-07-20', -5000, { category: 'cat-in-income-group', payee: 'pay-grocer' });
add('tx-income-group-2', 'acct-checking', '2026-09-05', -2000, { category: 'cat-in-income-group', payee: 'pay-grocer' });
add('tx-income-group-3', 'acct-checking', '2026-08-22', 4000, { category: 'cat-in-income-group', payee: 'pay-employer' });
add('tx-hidden-grp', 'acct-checking', '2026-08-14', -3400, { category: 'cat-hidden-grp', payee: 'pay-diner' });
// Off-budget and closed accounts.
add('tx-invest-gain', 'acct-invest', '2026-05-15', 45000);
add('tx-invest-fee', 'acct-invest', '2026-09-04', -4000, { category: 'cat-dining' });
add('tx-house-gain', 'acct-house', '2026-06-01', 100000);
add('tx-closed-1', 'acct-closed', '2026-03-15', -3000, { category: 'cat-dining', payee: 'pay-diner' });
add('tx-closed-2', 'acct-closed', '2026-05-20', -9000, { category: 'cat-groceries', payee: 'pay-grocer' });
// After "today" (2026-09-15).
add('tx-future', 'acct-checking', '2026-09-20', -6600, { category: 'cat-groceries', payee: 'pay-grocer' });

// Transfers: same date, legs on different dates, on budget to off budget, in range.
add('tx-xfer1-a', 'acct-checking', '2026-07-10', -20000, { payee: 'pay-xfer-card', transfer_id: 'tx-xfer1-b' });
add('tx-xfer1-b', 'acct-card', '2026-07-10', 20000, { payee: 'pay-xfer-checking', transfer_id: 'tx-xfer1-a' });
add('tx-xfer2-a', 'acct-checking', '2026-08-30', -15000, { payee: 'pay-xfer-card', transfer_id: 'tx-xfer2-b' });
add('tx-xfer2-b', 'acct-card', '2026-09-02', 15000, { payee: 'pay-xfer-checking', transfer_id: 'tx-xfer2-a' });
add('tx-xfer3-a', 'acct-checking', '2026-06-20', -50000, { payee: 'pay-xfer-invest', transfer_id: 'tx-xfer3-b' });
add('tx-xfer3-b', 'acct-invest', '2026-06-20', 50000, { payee: 'pay-xfer-checking', transfer_id: 'tx-xfer3-a' });
add('tx-xfer4-a', 'acct-checking', '2026-09-12', -10000, { payee: 'pay-xfer-card', transfer_id: 'tx-xfer4-b' });
add('tx-xfer4-b', 'acct-card', '2026-09-12', 10000, { payee: 'pay-xfer-checking', transfer_id: 'tx-xfer4-a' });
// A transfer payee without a linked counterpart.
add('tx-xfer-orphan', 'acct-checking', '2026-08-25', -6000, { payee: 'pay-xfer-house' });

// Splits: a live parent with categorized children; a deleted parent with live children.
add('tx-split-parent', 'acct-checking', '2026-08-18', -9000, { is_parent: 1, payee: 'pay-grocer' });
add('tx-split-child-1', 'acct-checking', '2026-08-18', -6000,
  { is_child: 1, parent_id: 'tx-split-parent', category: 'cat-groceries', payee: 'pay-grocer' });
add('tx-split-child-2', 'acct-checking', '2026-08-18', -3000,
  { is_child: 1, parent_id: 'tx-split-parent', category: 'cat-dining', payee: 'pay-grocer' });
add('tx-split-dead-parent', 'acct-checking', '2026-08-19', -8000,
  { is_parent: 1, payee: 'pay-grocer', tombstone: 1 });
add('tx-split-dead-child-1', 'acct-checking', '2026-08-19', -5000,
  { is_child: 1, parent_id: 'tx-split-dead-parent', category: 'cat-groceries', payee: 'pay-grocer' });
add('tx-split-dead-child-2', 'acct-checking', '2026-08-19', -3000,
  { is_child: 1, parent_id: 'tx-split-dead-parent', category: 'cat-dining', payee: 'pay-grocer' });

// Budgets for 2026-06 .. 2026-09 on every expense category plus the income category.
const budgetFor = (offset) => ['2026-06', '2026-07', '2026-08', '2026-09'].flatMap((month, i) => [
  ['cat-groceries', 40000], ['cat-dining', 20000], ['cat-hidden', 5000],
  ['cat-in-income-group', 3000], ['cat-hidden-grp', 2500], ['cat-salary', 300000],
].map(([category, amount]) => ({ month, category, amount: amount + offset + 100 * i })));

export const WORLD = {
  accounts,
  groups,
  categories,
  payees,
  transactions,
  budgets: { envelope: budgetFor(0), tracking: budgetFor(1000) },
};

const nw = (id, interval, start, end, accountSet, extra = {}) => (
  { id, kind: 'net-worth', input: { start, end, interval, accountSet, ...extra } }
);
const cf = (id, start, end, concise, conditions = [], extra = {}) => (
  { id, kind: 'cash-flow', input: { start, end, concise, conditions, ...extra } }
);
const sp = (id, compare, compareTo, extra = {}) => (
  { id, kind: 'spending', input: { compare, compareTo, conditions: [], ...extra } }
);
const cal = (id, extra = {}) => (
  { id, kind: 'calendar', input: { start: '2026-07', end: '2026-09', conditions: [], ...extra } }
);
const lateToday = { today: LATE_TODAY };
const dining = [{ field: 'category', op: 'is', value: 'cat-dining' }];
const checking = [{ field: 'account', op: 'is', value: 'acct-checking' }];
const noTransfers = [{ field: 'transfer', op: 'is', value: false }];
const lastThree = { mode: 'last-n-months', months: 3 };

export const CASES = [
  nw('nw-monthly-open', 'Monthly', '2026-04', '2026-09', 'open'),
  nw('nw-monthly-ui', 'Monthly', '2026-04', '2026-09', 'ui'),
  nw('nw-monthly-onbudget', 'Monthly', '2026-04', '2026-09', 'onbudget'),
  nw('nw-daily-ui', 'Daily', '2026-09', '2026-09', 'ui'),
  nw('nw-monthly-early-start', 'Monthly', '2026-01', '2026-09', 'ui'),
  nw('nw-daily-ui-late', 'Daily', '2026-09', '2026-09', 'ui', lateToday),

  cf('cf-monthly', '2026-04', '2026-09', true),
  cf('cf-daily', '2026-09', '2026-09', false),
  cf('cf-monthly-checking', '2026-04', '2026-09', true, checking),
  cf('cf-daily-late', '2026-09', '2026-09', false, [], lateToday),

  sp('sp-single-sep', '2026-09', '2026-08'),
  sp('sp-single-jul', '2026-07', '2026-06'),
  sp('sp-budget-envelope-sep', '2026-09', '2026-08', { budgetType: 'envelope' }),
  sp('sp-budget-envelope-aug', '2026-08', '2026-07', { budgetType: 'envelope' }),
  { ...sp('sp-budget-tracking-sep', '2026-09', '2026-08', { budgetType: 'tracking' }), world: 'tracking' },
  { ...sp('sp-budget-tracking-aug', '2026-08', '2026-07', { budgetType: 'tracking' }), world: 'tracking' },
  sp('sp-average-sep', '2026-09', '2026-08', { averageRange: lastThree }),
  sp('sp-condition-category', '2026-09', '2026-08', { conditions: dining }),
  sp('sp-condition-account', '2026-09', '2026-08', { conditions: checking }),
  sp('sp-single-sep-late', '2026-09', '2026-08', lateToday),

  cal('cal-default'),
  cal('cal-first-day-1', { firstDayOfWeekIdx: '1' }),
  cal('cal-first-day-invalid', { firstDayOfWeekIdx: '9' }),
  cal('cal-no-transfers', { conditions: noTransfers }),
  cal('cal-default-late', lateToday),
];
