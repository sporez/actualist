// The Bank Sync / import matching case plan: named cases plus seeded generated cases.
//
// Pure data. generate.mjs runs every case through Actual's own reconcile path
// (reconcileTransactions, or simpleFinBatchSync for provider downloads);
// verify.mjs rebuilds this plan without an oracle and compares it with the
// committed fixture. Amounts are integer minor units except in provider
// downloads, which carry decimal strings like the SimpleFIN wire format. Dates
// are ISO strings. Expected outputs are never written here; they come only from
// the oracle.

export const SEED = 20261011;
export const TODAY = '2026-10-15';
export const TIME_ZONE = 'America/New_York';
export const GENERATED_FUZZY_CASES = 110;
export const GENERATED_MULTI_CASES = 60;
export const GENERATED_BOUNDARY_CASES = 48;
export const GENERATED_IMPORTED_ID_CASES = 44;
export const GENERATED_PAYEE_NAME_CASES = 48;
export const GENERATED_MERGE_CASES = 40;
export const GENERATED_UPDATE_DATES_CASES = 30;

export function mulberry32(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let value = Math.imul(state ^ (state >>> 15), 1 | state);
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value;
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------------------------------------------------------------- helpers

export function addDays(iso, days) {
  const [year, month, day] = iso.split('-').map(Number);
  return new Date(Date.UTC(year, month - 1, day + days)).toISOString().slice(0, 10);
}

const decimal = cents => (cents / 100).toFixed(2);

// ---------------------------------------------------------------- world

const CHECKING = 'acc-checking';
const SAVINGS = 'acc-savings';
const BROKERAGE = 'acc-brokerage';

const ACCOUNTS = [
  { id: CHECKING, name: 'Synthetic Checking', offbudget: false, closed: false, providerID: 'sf-checking' },
  { id: SAVINGS, name: 'Synthetic Savings', offbudget: false, closed: false, providerID: 'sf-savings' },
  { id: BROKERAGE, name: 'Synthetic Brokerage', offbudget: true, closed: false, providerID: 'sf-brokerage' },
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
  { id: 'pay-xfer-checking', name: '', transferAccount: CHECKING },
  { id: 'pay-xfer-savings', name: '', transferAccount: SAVINGS },
  { id: 'pay-xfer-brokerage', name: '', transferAccount: BROKERAGE },
];
const PAYEE_IDS = ['pay-store', 'pay-landlord', 'pay-cafe', 'pay-employer'];
const PAYEE_NAMES = Object.fromEntries(PAYEES.map(payee => [payee.id, payee.name]));

// An existing row as setup describes it. Everything else defaults to a plain,
// cleared, unreconciled row in the checking account.
export function row(id, overrides = {}) {
  return {
    id,
    account: CHECKING,
    date: '2026-10-05',
    amount: -4250,
    payee: null,
    category: null,
    cleared: true,
    reconciled: false,
    imported_id: null,
    imported_payee: null,
    notes: null,
    is_parent: false,
    is_child: false,
    parent_id: null,
    transfer_id: null,
    tombstone: false,
    ...overrides,
  };
}

// The shared budget every case starts from. The contract records it once.
export const WORLD = { accounts: ACCOUNTS, groups: GROUPS, categories: CATEGORIES, payees: PAYEES };

// What a case adds to WORLD: existing rows, synced preferences, schedules.
export function world({ transactions = [], prefs = {}, schedules = [] } = {}) {
  return { transactions, prefs, schedules };
}

const SCHEDULE_RENT = {
  id: 'sched-rent',
  name: 'Synthetic Rent Schedule',
  completed: false,
  ruleID: 'rule-sched-rent',
  conditions: [
    { op: 'is', field: 'date', value: '2026-10-05' },
    { op: 'isapprox', field: 'amount', value: -4250 },
    { op: 'is', field: 'payee', value: 'pay-store' },
  ],
};

// ------------------------------------------------------------- builders

const condition = (field, op, value) => ({ field, op, value });
const set = (field, value) => ({ op: 'set', field, value });
const rule = (id, stage, conditions, actions, conditionsOp = 'and') => ({ id, stage, conditionsOp, conditions, actions });

// CSV / file import transaction (what `transactions-import` hands reconcile).
export const csvTx = (date, amount, payeeName, extras = {}) => ({
  date,
  amount,
  ...(payeeName === undefined ? {} : { payee_name: payeeName }),
  ...extras,
});
// Provider download transaction (SimpleFIN wire shape: decimal string amount).
export const bankTx = (date, cents, payeeName, transactionId, extras = {}) => ({
  booked: true,
  date,
  ...(payeeName === undefined ? {} : { payeeName }),
  transactionAmount: { amount: decimal(cents) },
  ...(transactionId === undefined ? {} : { transactionId }),
  ...extras,
});

// kind: csv = reconcileTransactions with isBankSyncAccount false;
//       bank = reconcileTransactions with isBankSyncAccount true;
//       simplefin = simpleFinBatchSync over a mocked provider response, which is
//       the whole bank-sync path including first-sync opening balance.
function call(kind, transactions, options = {}, accountId = CHECKING) {
  return { kind, accountId, options, transactions };
}

function makeCase({
  id, description, setup = world(), rules = [], call: planned, seed = null, oracleOnly = null,
  tags = [], mustNotLearnRules = false,
}) {
  // A provider download into an account with no live row dated on or before today is that
  // account's first sync (upstream ignores later-dated rows) and inserts a Starting Balance row. Only the opening-balance cases want that; the
  // others get an old zero-distance anchor row so they exercise matching alone.
  const firstSync = planned.kind === 'simplefin' && !tags.includes('opening-balance')
    && !setup.transactions.some(transaction => (
      transaction.account === planned.accountId && !transaction.tombstone && transaction.date <= TODAY
    ));
  if (firstSync) {
    setup = { ...setup, transactions: [...setup.transactions, row(`anchor-${planned.accountId}`, { account: planned.accountId, date: '2020-01-01', amount: 100 })] };
  }
  return {
    id,
    source: seed === null ? 'named' : 'generated',
    description,
    seed,
    oracleOnly,
    tags,
    mustNotLearnRules,
    setup,
    rules,
    call: planned,
  };
}

// ---------------------------------------------------------------- named

function namedCases() {
  const cases = [];
  const add = definition => cases.push(makeCase(definition));

  // --- Rules run before matching (mistakes 2026-09-14..16).
  add({
    id: 'named-rule-moves-account-csv',
    description: 'An import rule that moves the row to another account: upstream inserts into the rule account',
    setup: world(),
    rules: [rule('rule-account', null, [condition('imported_payee', 'is', 'Synthetic Market')], [set('account', SAVINGS)])],
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], {}),
    oracleOnly: 'Actualist fails closed when a rule moves an import to another account (BankSync mistakes 2026-09-16); the replay refuses instead of inserting',
    tags: ['rule-account-move'],
  });
  add({
    id: 'named-rule-moves-account-simplefin',
    description: 'The same account-moving rule on a provider download',
    rules: [rule('rule-account', null, [condition('imported_payee', 'is', 'Synthetic Market')], [set('account', SAVINGS)])],
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1')], {}),
    oracleOnly: 'Actualist fails closed when a rule moves an import to another account (BankSync mistakes 2026-09-16); the replay refuses instead of inserting',
    tags: ['rule-account-move'],
  });
  add({
    id: 'named-rule-category-no-learning',
    description: 'A rule-assigned category on an import must not create or change a learned payee-category rule',
    rules: [rule('rule-cat', null, [condition('imported_payee', 'is', 'Synthetic Market')], [set('category', 'cat-groceries')])],
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], {}),
    mustNotLearnRules: true,
    tags: ['no-category-learning'],
  });
  add({
    id: 'named-rule-category-no-learning-simplefin',
    description: 'The same on a provider download',
    rules: [rule('rule-cat', null, [condition('imported_payee', 'is', 'Synthetic Market')], [set('category', 'cat-groceries')])],
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1')], {}),
    mustNotLearnRules: true,
    tags: ['no-category-learning'],
  });
  add({
    id: 'named-rule-transfer-payee-insert',
    description: 'A rule sets the payee to a transfer payee on a new row: upstream creates the paired leg',
    rules: [rule('rule-xfer', null, [condition('imported_payee', 'is', 'Move To Savings')], [set('payee', 'pay-xfer-savings')])],
    call: call('csv', [csvTx('2026-10-10', -20000, 'Move To Savings')], {}),
    tags: ['transfer-graph'],
  });
  add({
    id: 'named-rule-transfer-payee-simplefin',
    description: 'The same transfer rule on a provider download',
    rules: [rule('rule-xfer', null, [condition('imported_payee', 'is', 'Move To Savings')], [set('payee', 'pay-xfer-savings')])],
    call: call('simplefin', [bankTx('2026-10-10', -20000, 'Move To Savings', 'sf-1')], {}),
    tags: ['transfer-graph'],
  });
  add({
    id: 'named-rule-transfer-payee-matched-plain-row',
    description: 'A rule gives the payee a transfer payee when the matched existing row has no payee',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-09', amount: -20000 })] }),
    rules: [rule('rule-xfer', null, [condition('imported_payee', 'is', 'Move To Savings')], [set('payee', 'pay-xfer-savings')])],
    call: call('csv', [csvTx('2026-10-10', -20000, 'Move To Savings')], {}),
    tags: ['transfer-graph', 'match-fill'],
  });
  add({
    id: 'named-offbudget-rule-category',
    description: 'A rule categorizes an import into an off-budget account: the category is stripped',
    rules: [rule('rule-cat', null, [condition('imported_payee', 'is', 'Dividend')], [set('category', 'cat-salary')])],
    call: call('simplefin', [bankTx('2026-10-10', 1200, 'Dividend', 'sf-1')], {}, BROKERAGE),
    tags: ['offbudget'],
  });
  add({
    id: 'named-offbudget-csv-category',
    description: 'A CSV row carrying a category lands in an off-budget account',
    call: call('csv', [csvTx('2026-10-10', 1200, 'Dividend', { category: 'cat-salary' })], {}, BROKERAGE),
    tags: ['offbudget'],
  });
  add({
    id: 'named-offbudget-split-children',
    description: 'A split import into an off-budget account loses categories on the parent and every child',
    call: call('csv', [csvTx('2026-10-10', -3000, 'Dividend', {
      subtransactions: [
        { amount: -1000, category: 'cat-dining', notes: 'a' },
        { amount: -2000, category: 'cat-games', notes: 'b' },
      ],
    })], {}, BROKERAGE),
    oracleOnly: 'no Actualist import path (CSV or Bank Sync) supplies subtransactions; imported splits come only from rules',
    tags: ['offbudget', 'split'],
  });
  add({
    id: 'named-offbudget-match-rule-category',
    description: 'A rule category must not fill the blank category of a matched off-budget row',
    setup: world({ transactions: [row('ex-1', { account: BROKERAGE, date: '2026-10-09', amount: 1200, payee: 'pay-employer' })] }),
    rules: [rule('rule-cat', null, [condition('imported_payee', 'is', 'Synthetic Employer')], [set('category', 'cat-salary')])],
    call: call('simplefin', [bankTx('2026-10-10', 1200, 'Synthetic Employer', 'sf-1')], {}, BROKERAGE),
    tags: ['offbudget', 'match-fill'],
  });
  const transferPair = [
    row('xf-1', { date: '2026-10-09', amount: -20000, payee: 'pay-xfer-savings', transfer_id: 'xf-2' }),
    row('xf-2', { account: SAVINGS, date: '2026-10-09', amount: 20000, payee: 'pay-xfer-checking', transfer_id: 'xf-1' }),
  ];
  add({
    id: 'named-matched-transfer-rule-category',
    description: 'A rule category must not be written onto a matched transfer leg whose category is blank',
    setup: world({ transactions: transferPair }),
    rules: [rule('rule-cat', null, [condition('imported_payee', 'is', 'Move To Savings')], [set('category', 'cat-groceries')])],
    call: call('csv', [csvTx('2026-10-10', -20000, 'Move To Savings')], {}),
    tags: ['transfer-graph', 'match-fill'],
  });
  add({
    id: 'named-matched-transfer-rule-category-simplefin',
    description: 'The same matched transfer on a provider download',
    setup: world({ transactions: transferPair }),
    rules: [rule('rule-cat', null, [condition('imported_payee', 'is', 'Move To Savings')], [set('category', 'cat-groceries')])],
    call: call('simplefin', [bankTx('2026-10-10', -20000, 'Move To Savings', 'sf-1')], {}),
    tags: ['transfer-graph', 'match-fill'],
  });
  add({
    id: 'named-rule-sees-resolved-payee-id',
    description: 'A "payee is" rule fires for an import whose payee name resolves to an existing payee',
    rules: [rule('rule-payee', null, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-groceries')])],
    call: call('csv', [csvTx('2026-10-10', -1500, 'synthetic market')], { payeeNameNormalization: 'original' }),
    tags: ['payee-resolution'],
  });
  add({
    id: 'named-rule-sees-resolved-payee-id-simplefin',
    description: 'The same payee rule on a provider download, which matches payee names case-insensitively',
    rules: [rule('rule-payee', null, [condition('payee', 'is', 'pay-store')], [set('category', 'cat-groceries')])],
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'SYNTHETIC MARKET', 'sf-1')], {}),
    tags: ['payee-resolution'],
  });
  add({
    id: 'named-rule-imported-payee-title-case',
    description: 'An imported-payee rule written in upper case against a CSV row that normalization title-cases',
    rules: [rule('rule-imported', null, [condition('imported_payee', 'is', 'WHOLE FOODS #123')], [set('category', 'cat-groceries')])],
    call: call('csv', [csvTx('2026-10-10', -1500, 'WHOLE FOODS #123')], {}),
    tags: ['imported-payee-rule'],
  });
  add({
    id: 'named-rule-imported-payee-original',
    description: 'The same rule with payeeNameNormalization original',
    rules: [rule('rule-imported', null, [condition('imported_payee', 'is', 'WHOLE FOODS #123')], [set('category', 'cat-groceries')])],
    call: call('csv', [csvTx('2026-10-10', -1500, 'WHOLE FOODS #123')], { payeeNameNormalization: 'original' }),
    tags: ['imported-payee-rule'],
  });
  add({
    id: 'named-rule-imported-payee-simplefin',
    description: 'An imported-payee rule against a provider payee name with padding',
    rules: [rule('rule-imported', null, [condition('imported_payee', 'is', 'WHOLE FOODS #123')], [set('category', 'cat-groceries')])],
    call: call('simplefin', [bankTx('2026-10-10', -1500, '  WHOLE FOODS #123  ', 'sf-1')], {}),
    tags: ['imported-payee-rule'],
  });
  add({
    id: 'named-rule-delete-transaction',
    description: 'A delete rule drops the incoming row before matching',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-09', amount: -1500 })] }),
    rules: [rule('rule-delete', null, [condition('imported_payee', 'is', 'Noise')], [{ op: 'delete-transaction' }])],
    call: call('csv', [csvTx('2026-10-10', -1500, 'Noise'), csvTx('2026-10-11', -700, 'Keep')], { isPreview: true }),
    tags: ['delete-rule'],
  });
  add({
    id: 'named-rule-delete-transaction-commit',
    description: 'A delete rule on a commit run',
    rules: [rule('rule-delete', null, [condition('imported_payee', 'is', 'Noise')], [{ op: 'delete-transaction' }])],
    call: call('csv', [csvTx('2026-10-10', -1500, 'Noise'), csvTx('2026-10-11', -700, 'Keep')], {}),
    tags: ['delete-rule'],
  });
  add({
    id: 'named-rule-link-schedule',
    description: 'A rule links the imported row to a schedule',
    setup: world({ schedules: [SCHEDULE_RENT] }),
    rules: [rule('rule-link', null, [condition('imported_payee', 'is', 'Synthetic Market')], [{ op: 'link-schedule', value: 'sched-rent' }])],
    call: call('csv', [csvTx('2026-10-05', -4250, 'Synthetic Market')], {}),
    tags: ['schedule'],
  });
  add({
    id: 'named-rule-stages',
    description: 'Pre, default and post stage rules touching the same field',
    rules: [
      rule('rule-post', 'post', [condition('imported_payee', 'is', 'Synthetic Market')], [set('notes', 'post')]),
      rule('rule-pre', 'pre', [condition('imported_payee', 'is', 'Synthetic Market')], [set('notes', 'pre')]),
      rule('rule-mid', null, [condition('imported_payee', 'is', 'Synthetic Market')], [set('category', 'cat-dining')]),
    ],
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], {}),
    tags: ['rule-stages'],
  });
  add({
    id: 'named-rule-changes-amount-then-match',
    description: 'A rule changes the amount so the row now matches an existing one',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -2000 })] }),
    rules: [rule('rule-amount', null, [condition('imported_payee', 'is', 'Fix Me')], [set('amount', -2000)])],
    call: call('csv', [csvTx('2026-10-10', -1000, 'Fix Me')], {}),
    tags: ['rule-amount'],
  });
  add({
    id: 'named-rule-changes-date-then-match',
    description: 'A rule moves the date outside the window the original date matched',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -2000 })] }),
    rules: [rule('rule-date', null, [condition('imported_payee', 'is', 'Fix Me')], [set('date', '2026-09-01')])],
    call: call('csv', [csvTx('2026-10-10', -2000, 'Fix Me')], {}),
    tags: ['rule-date'],
  });

  // --- Reimport deleted preference and tombstones.
  const deletedBank = row('ex-del', { date: '2026-10-08', amount: -1500, payee: 'pay-store', imported_id: 'sf-1', tombstone: true });
  const deletedPref = value => ({ [`sync-reimport-deleted-${CHECKING}`]: value });
  for (const [label, prefs] of [['unset', {}], ['false', deletedPref('false')], ['true', deletedPref('true')]]) {
    add({
      id: `named-reimport-deleted-simplefin-${label}`,
      description: `A deleted row's provider id comes back with sync-reimport-deleted ${label}`,
      setup: world({ transactions: [deletedBank], prefs }),
      call: call('simplefin', [bankTx('2026-10-08', -1500, 'Synthetic Market', 'sf-1')], {}),
      tags: ['reimport-deleted'],
    });
    add({
      id: `named-reimport-deleted-fuzzy-${label}`,
      description: `The deleted row is not fuzzy matched; the preference is ${label}`,
      setup: world({ transactions: [deletedBank], prefs }),
      call: call('simplefin', [bankTx('2026-10-09', -1500, 'Synthetic Market', 'sf-other')], {}),
      tags: ['reimport-deleted'],
    });
  }
  add({
    id: 'named-reimport-deleted-option-false',
    description: 'The reimportDeleted option overrides the preference for CSV: false',
    setup: world({ transactions: [row('ex-del', { date: '2026-10-08', amount: -1500, imported_id: 'csv-1', tombstone: true })] }),
    call: call('csv', [csvTx('2026-10-08', -1500, 'Synthetic Market', { imported_id: 'csv-1' })], { reimportDeleted: false }),
    tags: ['reimport-deleted'],
  });
  add({
    id: 'named-reimport-deleted-option-true-pref-false',
    description: 'The option true wins over a false preference',
    setup: world({ transactions: [row('ex-del', { date: '2026-10-08', amount: -1500, imported_id: 'csv-1', tombstone: true })], prefs: deletedPref('false') }),
    call: call('csv', [csvTx('2026-10-08', -1500, 'Synthetic Market', { imported_id: 'csv-1' })], { reimportDeleted: true }),
    tags: ['reimport-deleted'],
  });
  add({
    id: 'named-reimport-deleted-pref-false-csv',
    description: 'A file import with no reimportDeleted option and the preference false: upstream reads the preference',
    setup: world({ transactions: [row('ex-del', { date: '2026-10-08', amount: -1500, imported_id: 'csv-1', tombstone: true })], prefs: deletedPref('false') }),
    call: call('csv', [csvTx('2026-10-08', -1500, 'Synthetic Market', { imported_id: 'csv-1' })], {}),
    tags: ['reimport-deleted'],
  });
  add({
    id: 'named-reimport-deleted-live-wins',
    description: 'A live row and a deleted row share a provider id: the live row matches',
    setup: world({
      transactions: [deletedBank, row('ex-live', { date: '2026-10-08', amount: -1500, imported_id: 'sf-1' })],
      prefs: deletedPref('false'),
    }),
    call: call('simplefin', [bankTx('2026-10-08', -1500, 'Synthetic Market', 'sf-1')], {}),
    tags: ['reimport-deleted'],
  });
  add({
    id: 'named-tombstone-no-imported-id-not-matched',
    description: 'A deleted row without an imported id is never a fuzzy match',
    setup: world({ transactions: [row('ex-del', { date: '2026-10-09', amount: -1500, tombstone: true })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], {}),
    tags: ['tombstone'],
  });
  add({
    id: 'named-imported-id-other-account',
    description: 'The same imported id on another account does not match',
    setup: world({ transactions: [row('ex-1', { account: SAVINGS, date: '2026-10-09', amount: -1500, imported_id: 'sf-1' })] }),
    call: call('simplefin', [bankTx('2026-10-09', -1500, 'Synthetic Market', 'sf-1')], {}),
    tags: ['imported-id'],
  });

  // --- First sync is decided by rows dated on or before today.
  add({
    id: 'named-first-sync-future-dated-rows-only',
    description: 'An account whose only live rows are dated after today is a first sync: a Starting Balance row is added',
    setup: world({ transactions: [row('ex-1', { date: '2027-01-05', amount: -1500 })] }),
    call: call('simplefin', [bankTx('2026-10-10', -700, 'Synthetic Market', 'sf-1')], { startingBalance: 100000 }),
    tags: ['opening-balance', 'first-sync'],
  });
  add({
    id: 'named-first-sync-row-dated-today',
    description: 'A live row dated exactly today makes it a later sync: no Starting Balance row',
    setup: world({ transactions: [row('ex-1', { date: TODAY, amount: -1500 })] }),
    call: call('simplefin', [bankTx('2026-10-10', -700, 'Synthetic Market', 'sf-1')], { startingBalance: 100000 }),
    tags: ['opening-balance', 'first-sync'],
  });
  add({
    id: 'named-id-match-outside-window-csv',
    description: 'An imported id matches a row months from the download date (file import)',
    setup: world({ transactions: [row('ex-1', { date: '2026-08-01', amount: -1500, imported_id: 'id-1' })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market', { imported_id: 'id-1' })], {}),
    tags: ['imported-id'],
  });
  add({
    id: 'named-id-match-outside-window-simplefin',
    description: 'A provider id matches a row months from the download date',
    setup: world({ transactions: [row('ex-1', { date: '2026-08-01', amount: -1500, imported_id: 'sf-1' })] }),
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1')], {}),
    tags: ['imported-id'],
  });
  add({
    id: 'named-id-match-outside-window-bank',
    description: 'The same with a direct provider call',
    setup: world({ transactions: [row('ex-1', { date: '2026-08-01', amount: -1500, imported_id: 'sf-1' })] }),
    call: call('bank', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1')], {}),
    tags: ['imported-id'],
  });

  // --- Opening balance, pending, mapping, currency-neutral provider details.
  const firstSync = (extra = {}) => ({ startingBalance: 250000, ...extra });
  add({
    id: 'named-opening-balance-first-sync',
    description: 'First sync of an account without transactions inserts a Starting Balance row from the current balance',
    setup: world(),
    call: call('simplefin', [
      bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1'),
      bankTx('2026-10-01', 90000, 'Synthetic Employer', 'sf-2'),
    ], firstSync(), SAVINGS),
    tags: ['opening-balance'],
  });
  add({
    id: 'named-opening-balance-rule-deletes-row',
    description: 'A delete rule drops a downloaded row; upstream still subtracts it from the opening balance',
    setup: world(),
    rules: [rule('rule-delete', null, [condition('imported_payee', 'is', 'Noise')], [{ op: 'delete-transaction' }])],
    call: call('simplefin', [
      bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1'),
      bankTx('2026-10-02', -700, 'Noise', 'sf-2'),
    ], firstSync(), SAVINGS),
    tags: ['opening-balance', 'delete-rule'],
  });
  add({
    id: 'named-opening-balance-rule-changes-amount',
    description: 'A rule changes the amount of a downloaded row on first sync',
    setup: world(),
    rules: [rule('rule-amount', null, [condition('imported_payee', 'is', 'Synthetic Market')], [set('amount', -999)])],
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1')], firstSync(), SAVINGS),
    tags: ['opening-balance', 'rule-amount'],
  });
  add({
    id: 'named-opening-balance-pending-skipped',
    description: 'First sync with import-pending off: the pending row is neither imported nor excluded from the balance',
    setup: world({ prefs: { [`sync-import-pending-${SAVINGS}`]: 'false' } }),
    call: call('simplefin', [
      bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1'),
      bankTx('2026-10-10', -700, 'Corner Cafe', 'sf-2', { booked: false }),
    ], firstSync(), SAVINGS),
    tags: ['opening-balance', 'pending'],
  });
  add({
    id: 'named-opening-balance-date-from-last-row',
    description: 'First sync with the download listed oldest first: the Starting Balance row takes the date of the last downloaded row',
    setup: world(),
    call: call('simplefin', [
      bankTx('2026-10-03', -700, 'Corner Cafe', 'sf-2'),
      bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1'),
    ], firstSync(), SAVINGS),
    tags: ['opening-balance'],
  });
  add({
    id: 'named-opening-balance-offbudget',
    description: 'First sync into an off-budget account: the Starting Balance row carries no category',
    setup: world(),
    call: call('simplefin', [bankTx('2026-10-10', 1200, 'Dividend', 'sf-1')], firstSync(), BROKERAGE),
    tags: ['opening-balance', 'offbudget'],
  });
  add({
    id: 'named-opening-balance-empty-download',
    description: 'First sync with an empty download: the Starting Balance row takes today',
    setup: world(),
    call: call('simplefin', [], firstSync(), SAVINGS),
    oracleOnly: 'the opening balance row of an empty download takes today from the real clock (BankSyncReconciliation.todayDayID has no clock seam)',
    tags: ['opening-balance'],
  });
  add({
    id: 'named-account-with-history-no-opening-balance',
    description: 'A later sync into an account with transactions adds no Starting Balance row and updates the balance',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-01', amount: -100 })] }),
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1')], firstSync()),
    tags: ['balance'],
  });
  add({
    id: 'named-pending-then-booked-update',
    description: 'An uncleared local row meets a booked download: the row becomes cleared and takes the provider id',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-09', amount: -1500, cleared: false })] }),
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1')], {}),
    tags: ['cleared'],
  });
  add({
    id: 'named-booked-then-pending-stays-cleared',
    description: 'A cleared local row meets a pending download: the row stays cleared',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-09', amount: -1500, cleared: true })] }),
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1', { booked: false })], {}),
    tags: ['cleared'],
  });
  add({
    id: 'named-pending-insert-uncleared',
    description: 'A pending download inserts an uncleared row',
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1', { booked: false })], {}),
    tags: ['cleared'],
  });
  add({
    id: 'named-import-pending-off',
    description: 'With import-pending off the pending row is skipped entirely',
    setup: world({ prefs: { [`sync-import-pending-${CHECKING}`]: 'false' } }),
    call: call('simplefin', [
      bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1', { booked: false }),
      bankTx('2026-10-10', -700, 'Corner Cafe', 'sf-2'),
    ], {}),
    oracleOnly: 'the case tests the provider-side field mapping (prepareDownload), which the replay takes from the post-mapping transaction the oracle recorded instead of reproducing',
    tags: ['pending'],
  });
  add({
    id: 'named-import-notes-off',
    description: 'With import-notes off a provider note is dropped',
    setup: world({ prefs: { [`sync-import-notes-${CHECKING}`]: 'false' } }),
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1', { notes: 'card #1' })], {}),
    oracleOnly: 'the case tests the provider-side field mapping (prepareDownload), which the replay takes from the post-mapping transaction the oracle recorded instead of reproducing',
    tags: ['notes'],
  });
  add({
    id: 'named-import-notes-hash-escape',
    description: 'A provider note with # is stored with ## (rules and tags read it that way)',
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1', { notes: ' groceries #food ' })], {}),
    oracleOnly: 'the case tests the provider-side field mapping (prepareDownload), which the replay takes from the post-mapping transaction the oracle recorded instead of reproducing',
    tags: ['notes'],
  });
  add({
    id: 'named-custom-mapping',
    description: 'A custom field mapping reads the payee and notes from other provider fields',
    setup: world({
      prefs: {
        [`custom-sync-mappings-${CHECKING}`]: JSON.stringify({
          payment: { date: 'date', payee: 'creditorName', notes: 'remittance' },
          deposit: { date: 'date', payee: 'debtorName', notes: 'remittance' },
        }),
      },
    }),
    call: call('simplefin', [
      bankTx('2026-10-10', -1500, 'IGNORED', 'sf-1', { creditorName: 'Creditor One', remittance: 'invoice 7' }),
      bankTx('2026-10-11', 2500, 'IGNORED', 'sf-2', { debtorName: 'Debtor Two', remittance: 'refund' }),
    ], {}),
    oracleOnly: 'the case tests the provider-side field mapping (prepareDownload), which the replay takes from the post-mapping transaction the oracle recorded instead of reproducing',
    tags: ['mapping'],
  });
  add({
    id: 'named-provider-category-valid',
    description: 'A provider category that exists is kept; an unknown one is dropped',
    call: call('simplefin', [
      bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1', { category: 'cat-groceries' }),
      bankTx('2026-10-11', -700, 'Corner Cafe', 'sf-2', { category: 'cat-missing' }),
    ], {}),
    oracleOnly: 'the case tests the provider-side field mapping (prepareDownload), which the replay takes from the post-mapping transaction the oracle recorded instead of reproducing',
    tags: ['category'],
  });
  add({
    id: 'named-provider-zero-amount',
    description: 'A zero-amount download uses the deposit/payment mapping for amounts <= 0',
    call: call('simplefin', [bankTx('2026-10-10', 0, 'Synthetic Market', 'sf-1')], {}),
    oracleOnly: 'the case tests the provider-side field mapping (prepareDownload), which the replay takes from the post-mapping transaction the oracle recorded instead of reproducing',
    tags: ['zero-amount'],
  });
  add({
    id: 'named-provider-missing-payee-name',
    description: 'A download without a payee name fails the account (upstream throws)',
    call: call('simplefin', [bankTx('2026-10-10', -1500, undefined, 'sf-1')], {}),
    oracleOnly: 'a row without a payee is a per-row problem in Actualist; upstream throws and fails the whole account',
    tags: ['error'],
  });
  add({
    id: 'named-provider-internal-transaction-id',
    description: 'A booked download with only an internal id imports as account-id-prefixed',
    call: call('bank', [{ ...bankTx('2026-10-10', -1500, 'Synthetic Market'), internalTransactionId: 'int-1' }], {}),
    oracleOnly: 'Actualist reads only the provider transaction id; internalTransactionId is not a field Actualist maps',
    tags: ['imported-id'],
  });

  // --- Matching.
  add({
    id: 'named-month-boundary-plus-7',
    description: 'Existing row 7 days after the download across a month end',
    setup: world({ transactions: [row('ex-1', { date: '2026-11-07', amount: -1500 })] }),
    call: call('csv', [csvTx('2026-10-31', -1500, 'Synthetic Market')], {}),
    tags: ['fuzzy', 'boundary'],
  });
  add({
    id: 'named-month-boundary-plus-8',
    description: 'Existing row 8 days after the download across a month end: outside the window',
    setup: world({ transactions: [row('ex-1', { date: '2026-11-08', amount: -1500 })] }),
    call: call('csv', [csvTx('2026-10-31', -1500, 'Synthetic Market')], {}),
    tags: ['fuzzy', 'boundary'],
  });
  add({
    id: 'named-year-boundary-minus-7',
    description: 'Existing row 7 days before the download across a year end',
    setup: world({ transactions: [row('ex-1', { date: '2026-12-26', amount: -1500 })] }),
    call: call('csv', [csvTx('2027-01-02', -1500, 'Synthetic Market')], {}),
    tags: ['fuzzy', 'boundary'],
  });
  add({
    id: 'named-year-boundary-minus-8',
    description: 'Existing row 8 days before the download across a year end: outside the window',
    setup: world({ transactions: [row('ex-1', { date: '2026-12-25', amount: -1500 })] }),
    call: call('csv', [csvTx('2027-01-02', -1500, 'Synthetic Market')], {}),
    tags: ['fuzzy', 'boundary'],
  });
  add({
    id: 'named-leap-day-boundary',
    description: 'Fuzzy window over 29 February 2028',
    setup: world({ transactions: [row('ex-1', { date: '2028-02-29', amount: -1500 }), row('ex-2', { date: '2028-02-22', amount: -1500 })] }),
    call: call('csv', [csvTx('2028-03-07', -1500, 'Synthetic Market'), csvTx('2028-03-08', -1500, 'Synthetic Market')], {}),
    tags: ['fuzzy', 'boundary'],
  });
  add({
    id: 'named-nearest-date-wins',
    description: 'Two same-amount rows: the nearer date matches',
    setup: world({ transactions: [row('ex-far', { date: '2026-10-05', amount: -1500 }), row('ex-near', { date: '2026-10-09', amount: -1500 })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], {}),
    tags: ['fuzzy', 'ordering'],
  });
  add({
    id: 'named-equidistant-tie',
    description: 'Two same-amount rows equally far on either side of the download date',
    setup: world({ transactions: [row('ex-a', { date: '2026-10-07', amount: -1500 }), row('ex-b', { date: '2026-10-13', amount: -1500 })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], {}),
    tags: ['fuzzy', 'ordering'],
  });
  add({
    id: 'named-payee-pass-beats-nearer-date',
    description: 'A farther row with the same payee wins over a nearer row with another payee',
    setup: world({ transactions: [
      row('ex-near', { date: '2026-10-10', amount: -1500, payee: 'pay-cafe' }),
      row('ex-far', { date: '2026-10-05', amount: -1500, payee: 'pay-store' }),
    ] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], {}),
    tags: ['fuzzy', 'ordering'],
  });
  add({
    id: 'named-batch-claims-in-passes',
    description: 'Two downloads, one existing row: the download with the matching payee claims it, not the first',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500, payee: 'pay-store' })] }),
    call: call('csv', [
      csvTx('2026-10-10', -1500, 'Corner Cafe'),
      csvTx('2026-10-10', -1500, 'Synthetic Market'),
    ], {}),
    tags: ['fuzzy', 'ordering'],
  });
  add({
    id: 'named-batch-duplicates-one-existing',
    description: 'Two identical downloads and one existing row: one update, one insert',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500 })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market'), csvTx('2026-10-10', -1500, 'Synthetic Market')], {}),
    tags: ['fuzzy'],
  });
  add({
    id: 'named-batch-duplicate-imported-ids',
    description: 'Two downloads share one imported id',
    call: call('csv', [
      csvTx('2026-10-10', -1500, 'Synthetic Market', { imported_id: 'dup-1' }),
      csvTx('2026-10-10', -1500, 'Synthetic Market', { imported_id: 'dup-1' }),
    ], {}),
    tags: ['imported-id'],
  });
  add({
    id: 'named-strict-id-checking-true',
    description: 'Download with an id vs existing row with another id: strictIdChecking true skips it',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500, imported_id: 'old-id' })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market', { imported_id: 'new-id' })], { strictIdChecking: true }),
    tags: ['strict-id'],
  });
  add({
    id: 'named-strict-id-checking-false',
    description: 'The same with strictIdChecking false: the rows fuzzy match despite different ids',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500, imported_id: 'old-id' })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market', { imported_id: 'new-id' })], { strictIdChecking: false }),
    tags: ['strict-id'],
  });
  add({
    id: 'named-strict-id-checking-no-incoming-id',
    description: 'A download without an id matches a row that has one even under strictIdChecking',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500, imported_id: 'old-id' })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], { strictIdChecking: true }),
    tags: ['strict-id'],
  });
  add({
    id: 'named-bank-strict-id-checking-true',
    description: 'A non-SimpleFIN provider account (strictIdChecking true)',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500, imported_id: 'old-id' })] }),
    call: call('bank', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'new-id')], { strictIdChecking: true }),
    tags: ['strict-id'],
  });
  add({
    id: 'named-reconciled-row-locked',
    description: 'A reconciled row that matches is left untouched',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500, reconciled: true, cleared: true })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market', { category: 'cat-groceries' })], {}),
    tags: ['reconciled'],
  });
  add({
    id: 'named-update-dates-true',
    description: 'updateDates moves the matched row to the download date',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-07', amount: -1500 })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], { updateDates: true }),
    tags: ['update-dates'],
  });
  add({
    id: 'named-update-dates-false',
    description: 'Without updateDates the matched row keeps its date',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-07', amount: -1500 })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market')], { updateDates: false }),
    tags: ['update-dates'],
  });
  add({
    id: 'named-update-dates-simplefin-pref',
    description: 'The sync-update-dates preference on a provider download',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-07', amount: -1500 })], prefs: { [`sync-update-dates-${CHECKING}`]: 'true' } }),
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1')], {}),
    tags: ['update-dates'],
  });
  add({
    id: 'named-default-cleared-false',
    description: 'defaultCleared false: an inserted row with no cleared flag is uncleared',
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market'), csvTx('2026-10-11', -700, 'Corner Cafe', { cleared: true })], { defaultCleared: false }),
    tags: ['cleared'],
  });
  add({
    id: 'named-default-cleared-true',
    description: 'defaultCleared true with an explicit uncleared row',
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market'), csvTx('2026-10-11', -700, 'Corner Cafe', { cleared: false })], { defaultCleared: true }),
    tags: ['cleared'],
  });
  add({
    id: 'named-csv-clears-matched-imported-identity',
    description: 'A CSV match without an imported id clears the stored imported id and payee',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500, imported_id: 'old-id', imported_payee: 'Old Payee' })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, undefined)], { strictIdChecking: false }),
    tags: ['import-identity'],
  });
  add({
    id: 'named-simplefin-keeps-matched-imported-identity',
    description: 'A provider match always has an id, so the stored identity is replaced, never cleared',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500, imported_id: 'old-id', imported_payee: 'Old Payee' })] }),
    call: call('simplefin', [bankTx('2026-10-10', -1500, 'Synthetic Market', 'sf-1')], {}),
    tags: ['import-identity'],
  });

  // --- Splits.
  const splitFamily = (extra = {}) => [
    row('sp-parent', { date: '2026-10-10', amount: -3000, is_parent: true, cleared: false, ...extra }),
    row('sp-1', { date: '2026-10-10', amount: -1000, is_child: true, parent_id: 'sp-parent', category: 'cat-dining', cleared: false }),
    row('sp-2', { date: '2026-10-10', amount: -2000, is_child: true, parent_id: 'sp-parent', category: 'cat-games', cleared: false }),
  ];
  add({
    id: 'named-split-parent-match-cascades-cleared',
    description: 'A download matches a split parent: cleared cascades to the children',
    setup: world({ transactions: splitFamily() }),
    call: call('csv', [csvTx('2026-10-11', -3000, 'Synthetic Market', { cleared: true })], {}),
    tags: ['split'],
  });
  add({
    id: 'named-split-parent-match-cascades-date',
    description: 'A download matches a split parent with updateDates: the date cascades to the children',
    setup: world({ transactions: splitFamily() }),
    call: call('csv', [csvTx('2026-10-12', -3000, 'Synthetic Market', { cleared: true })], { updateDates: true }),
    tags: ['split'],
  });
  add({
    id: 'named-split-parent-match-by-imported-id',
    description: 'A provider id on the split parent matches by id even far from the date',
    setup: world({ transactions: splitFamily({ imported_id: 'sf-1', date: '2026-09-01' }) }),
    call: call('simplefin', [bankTx('2026-10-10', -3000, 'Synthetic Market', 'sf-1')], {}),
    tags: ['split'],
  });
  add({
    id: 'named-split-child-amount-collision',
    description: 'A download whose amount equals one split child: upstream may match the child row',
    setup: world({ transactions: splitFamily() }),
    call: call('csv', [csvTx('2026-10-10', -1000, 'Synthetic Market')], {}),
    tags: ['split', 'child-collision'],
  });
  add({
    id: 'named-split-child-collision-with-parent-claimed',
    description: 'Parent matched by id, child-amount download in the same batch',
    setup: world({ transactions: splitFamily({ imported_id: 'csv-p' }) }),
    call: call('csv', [csvTx('2026-10-10', -3000, 'Synthetic Market', { imported_id: 'csv-p' }), csvTx('2026-10-10', -1000, 'Synthetic Market')], {}),
    tags: ['split', 'child-collision'],
  });
  add({
    id: 'named-import-split-insert',
    description: 'A split download inserts a parent and children',
    call: call('csv', [csvTx('2026-10-10', -3000, 'Synthetic Market', {
      subtransactions: [
        { amount: -1000, category: 'cat-dining', notes: 'one' },
        { amount: -2000, category: 'cat-games', notes: 'two' },
      ],
    })], {}),
    oracleOnly: 'no Actualist import path (CSV or Bank Sync) supplies subtransactions; imported splits come only from rules',
    tags: ['split'],
  });
  add({
    id: 'named-import-split-remainder',
    description: 'A split download whose children do not add up to the parent',
    call: call('csv', [csvTx('2026-10-10', -3000, 'Synthetic Market', {
      subtransactions: [{ amount: -1000, category: 'cat-dining' }],
    })], {}),
    oracleOnly: 'no Actualist import path (CSV or Bank Sync) supplies subtransactions; imported splits come only from rules',
    tags: ['split'],
  });
  add({
    id: 'named-import-split-matches-existing',
    description: 'A split download whose parent amount matches an existing plain row updates it and adds no children',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -3000 })] }),
    call: call('csv', [csvTx('2026-10-10', -3000, 'Synthetic Market', {
      subtransactions: [{ amount: -1000, category: 'cat-dining' }, { amount: -2000, category: 'cat-games' }],
    })], {}),
    oracleOnly: 'no Actualist import path (CSV or Bank Sync) supplies subtransactions; imported splits come only from rules',
    tags: ['split'],
  });

  // --- Preview vs commit, force add, errors.
  const previewSetup = world({ transactions: [row('ex-1', { date: '2026-10-09', amount: -1500, payee: 'pay-store' }), row('ex-del', { date: '2026-10-08', amount: -500, imported_id: 'csv-9', tombstone: true })] });
  const previewTransactions = [
    csvTx('2026-10-10', -1500, 'Synthetic Market', { category: 'cat-groceries', notes: 'weekly' }),
    csvTx('2026-10-11', -700, 'New Place'),
    csvTx('2026-10-08', -500, 'Synthetic Market', { imported_id: 'csv-9' }),
  ];
  add({
    id: 'named-preview',
    description: 'A preview run: result only, no writes',
    setup: previewSetup,
    call: call('csv', previewTransactions, { isPreview: true, reimportDeleted: false }),
    tags: ['preview'],
  });
  add({
    id: 'named-commit',
    description: 'The same batch committed',
    setup: previewSetup,
    call: call('csv', previewTransactions, { reimportDeleted: false }),
    tags: ['preview'],
  });
  add({
    id: 'named-preview-reconciled-and-unchanged',
    description: 'A preview over a reconciled match and an identical match',
    setup: world({ transactions: [
      row('ex-1', { date: '2026-10-09', amount: -1500, reconciled: true }),
      row('ex-2', { date: '2026-10-09', amount: -2500, payee: 'pay-store', imported_id: 'csv-2', imported_payee: 'Synthetic Market' }),
    ] }),
    call: call('csv', [
      csvTx('2026-10-10', -1500, 'Synthetic Market'),
      csvTx('2026-10-09', -2500, 'Synthetic Market', { imported_id: 'csv-2' }),
    ], { isPreview: true, payeeNameNormalization: 'original' }),
    tags: ['preview'],
  });
  add({
    id: 'named-force-add-transaction',
    description: 'forceAddTransaction inserts even when a row matches',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500 })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market', { forceAddTransaction: true })], {}),
    oracleOnly: 'forceAddTransaction is a transactions-import flag the CSV review does not use; Actualist has no equivalent input',
    tags: ['force-add'],
  });
  add({
    id: 'named-csv-non-integer-amount',
    description: 'A fractional amount is rejected by upstream (a TransactionError)',
    call: call('csv', [csvTx('2026-10-10', -15.5, 'Synthetic Market')], {}),
    oracleOnly: 'Actualist parses CSV amounts to integer minor units before reconcile; there is no fractional amount input',
    tags: ['error'],
  });
  add({
    id: 'named-csv-missing-date',
    description: 'A row without a date is rejected by upstream',
    call: call('csv', [{ amount: -1500, payee_name: 'Synthetic Market' }], {}),
    oracleOnly: 'Actualist validates CSV dates before reconcile; there is no dateless input',
    tags: ['error'],
  });

  // --- Payees and names.
  add({
    id: 'named-payee-missing',
    description: 'A CSV row with no payee text stays payee-less',
    call: call('csv', [csvTx('2026-10-10', -1500, undefined), csvTx('2026-10-11', -700, '   ')], {}),
    tags: ['payee'],
  });
  add({
    id: 'named-payee-by-id',
    description: 'A download that already carries a payee id keeps it and creates no payee',
    call: call('csv', [csvTx('2026-10-10', -1500, 'Ignored Text', { payee: 'pay-cafe' })], {}),
    oracleOnly: 'a CSV row carries payee text only; no Actualist import path supplies a payee id',
    tags: ['payee'],
  });
  add({
    id: 'named-payee-new-shared-by-two-rows',
    description: 'Two rows with the same new payee name create one payee',
    call: call('csv', [csvTx('2026-10-10', -1500, 'brand new shop'), csvTx('2026-10-11', -700, 'BRAND NEW SHOP')], {}),
    tags: ['payee'],
  });
  add({
    id: 'named-payee-created-only-if-used',
    description: 'A new payee name on a row that matches an existing row with a payee is not created',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500, payee: 'pay-store' })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'brand new shop')], {}),
    tags: ['payee'],
  });
  add({
    id: 'named-payee-created-for-blank-match',
    description: 'A new payee name on a row that matches an existing payee-less row creates the payee',
    setup: world({ transactions: [row('ex-1', { date: '2026-10-10', amount: -1500 })] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'brand new shop')], {}),
    tags: ['payee'],
  });
  add({
    id: 'named-payee-matches-transfer-payee-name',
    description: 'A payee name that equals the empty transfer payee name does not resolve to a transfer',
    call: call('csv', [csvTx('2026-10-10', -1500, '')], {}),
    tags: ['payee'],
  });
  add({
    id: 'named-existing-payee-wins-over-incoming',
    description: 'A matched row with a payee keeps it; a matched row without one takes the download payee',
    setup: world({ transactions: [
      row('ex-1', { date: '2026-10-10', amount: -1500, payee: 'pay-cafe' }),
      row('ex-2', { date: '2026-10-10', amount: -700 }),
    ] }),
    call: call('csv', [csvTx('2026-10-10', -1500, 'Synthetic Market'), csvTx('2026-10-10', -700, 'Synthetic Market')], {}),
    tags: ['payee', 'match-fill'],
  });

  return cases;
}

// ---------------------------------------------------------------- seeded

const BASE_DATES = [
  '2026-10-12', '2026-03-01', '2026-12-31', '2026-02-28', '2027-01-03', '2026-05-31',
  '2026-07-01', '2028-02-29', '2026-10-15', '2026-11-30',
];

function pick(random, list) {
  return list[Math.floor(random() * list.length)];
}

function chance(random, probability) {
  return random() < probability;
}

// kind decides which wire shape and which options apply.
function incoming(kind, random, date, cents, payeeName, importedID, extras = {}) {
  if (kind === 'csv') {
    return csvTx(date, cents, payeeName, {
      ...(importedID ? { imported_id: importedID } : {}),
      ...extras,
    });
  }
  return bankTx(date, cents, payeeName, importedID ?? `gen-${Math.floor(random() * 1e6)}`, extras);
}

function optionsFor(kind, random, wide) {
  const options = {};
  if (kind !== 'simplefin') {
    if (chance(random, 0.5)) options.strictIdChecking = chance(random, 0.5);
    if (kind === 'csv' && chance(random, 0.3)) options.defaultCleared = chance(random, 0.5);
    if (kind === 'csv' && chance(random, 0.3)) options.payeeNameNormalization = pick(random, ['original', 'title-case']);
    if (chance(random, 0.25)) options.reimportDeleted = chance(random, 0.5);
    if (wide && chance(random, 0.15)) options.isPreview = true;
  }
  return options;
}

function generatedPrefs(kind, random) {
  const prefs = {};
  if (kind === 'simplefin') {
    if (chance(random, 0.25)) prefs[`sync-reimport-deleted-${CHECKING}`] = pick(random, ['true', 'false']);
    if (chance(random, 0.15)) prefs[`sync-import-pending-${CHECKING}`] = pick(random, ['true', 'false']);
  } else if (chance(random, 0.2)) {
    prefs[`sync-reimport-deleted-${CHECKING}`] = pick(random, ['true', 'false']);
  }
  return prefs;
}

function fuzzyCases() {
  const random = mulberry32(SEED);
  const cases = [];
  for (let index = 0; index < GENERATED_FUZZY_CASES; index++) {
    const kind = pick(random, ['csv', 'csv', 'bank', 'simplefin']);
    const base = pick(random, BASE_DATES);
    const offset = chance(random, 0.45) ? pick(random, [-8, -7, -6, 6, 7, 8, 0]) : Math.floor(random() * 19) - 9;
    const cents = -1000 - 25 * Math.floor(random() * 40);
    const existingCents = chance(random, 0.78) ? cents : cents + pick(random, [-1, 1, 100]);
    const existingPayee = chance(random, 0.7) ? pick(random, PAYEE_IDS) : null;
    const payeeMode = pick(random, ['same', 'different', 'missing']);
    const incomingPayee = payeeMode === 'same' && existingPayee ? PAYEE_NAMES[existingPayee]
      : payeeMode === 'missing' && kind === 'csv' ? undefined
      : PAYEE_NAMES[pick(random, PAYEE_IDS)];
    const existingID = chance(random, 0.35) ? `ext-${index}` : null;
    const incomingID = chance(random, 0.4) ? (existingID && chance(random, 0.4) ? existingID : `in-${index}`) : null;
    const existing = row('ex-1', {
      date: addDays(base, offset),
      amount: existingCents,
      payee: existingPayee,
      cleared: chance(random, 0.6),
      imported_id: existingID,
      imported_payee: chance(random, 0.3) ? 'Stored Payee' : null,
      tombstone: chance(random, 0.08),
      reconciled: chance(random, 0.1),
    });
    const extras = {};
    if (kind === 'csv' && chance(random, 0.3)) extras.cleared = chance(random, 0.5);
    if (kind !== 'csv' && chance(random, 0.25)) extras.booked = false;
    if (chance(random, 0.25)) extras[kind === 'csv' ? 'notes' : 'notes'] = pick(random, ['coffee', 'rent #bills']);
    if (kind === 'csv' && chance(random, 0.2)) extras.category = pick(random, ['cat-groceries', 'cat-dining']);
    cases.push(makeCase({
      id: `gen-fuzzy-${String(index + 1).padStart(3, '0')}`,
      description: `${kind} download ${offset >= 0 ? '+' : ''}${offset}d from ${base}, amount ${existingCents === cents ? 'equal' : 'different'}, payee ${payeeMode}`,
      seed: SEED,
      setup: world({ transactions: [existing], prefs: generatedPrefs(kind, random) }),
      call: call(kind, [incoming(kind, random, base, cents, incomingPayee, incomingID, extras)], optionsFor(kind, random, true)),
      tags: ['fuzzy'],
    }));
  }
  return cases;
}

function multiCases() {
  const random = mulberry32(SEED + 1);
  const cases = [];
  for (let index = 0; index < GENERATED_MULTI_CASES; index++) {
    const kind = pick(random, ['csv', 'csv', 'bank', 'simplefin']);
    const base = pick(random, BASE_DATES);
    const cents = -2000 - 25 * Math.floor(random() * 20);
    const existingCount = 2 + Math.floor(random() * 3);
    const transactions = [];
    for (let slot = 0; slot < existingCount; slot++) {
      transactions.push(row(`ex-${slot + 1}`, {
        date: addDays(base, Math.floor(random() * 15) - 7),
        amount: chance(random, 0.9) ? cents : cents - 1,
        payee: chance(random, 0.6) ? pick(random, PAYEE_IDS) : null,
        cleared: chance(random, 0.5),
        imported_id: chance(random, 0.3) ? `ext-${index}-${slot}` : null,
        tombstone: chance(random, 0.1),
        reconciled: chance(random, 0.08),
      }));
    }
    const downloads = [];
    const downloadCount = 1 + Math.floor(random() * 3);
    for (let slot = 0; slot < downloadCount; slot++) {
      const reuse = chance(random, 0.25) && transactions[slot]?.imported_id;
      downloads.push(incoming(
        kind, random,
        addDays(base, Math.floor(random() * 5) - 2),
        chance(random, 0.9) ? cents : cents + 5,
        chance(random, 0.15) && kind === 'csv' ? undefined : PAYEE_NAMES[pick(random, PAYEE_IDS)],
        reuse ? transactions[slot].imported_id : chance(random, 0.4) ? `in-${index}-${slot}` : null,
        {},
      ));
    }
    cases.push(makeCase({
      id: `gen-multi-${String(index + 1).padStart(3, '0')}`,
      description: `${kind}: ${downloadCount} downloads against ${existingCount} same-amount rows`,
      seed: SEED + 1,
      setup: world({ transactions, prefs: generatedPrefs(kind, random) }),
      call: call(kind, downloads, optionsFor(kind, random, true)),
      tags: ['fuzzy', 'ordering'],
    }));
  }
  return cases;
}

// Month ends, year ends and a leap day, each with offsets around the window edge.
const BOUNDARY_BASES = [
  '2026-01-31', '2026-02-28', '2026-03-01', '2026-03-29', '2026-10-31', '2026-12-31', '2027-01-01',
  '2027-12-31', '2028-02-28', '2028-02-29', '2028-03-01', '2026-11-01',
];

function boundaryCases() {
  const random = mulberry32(SEED + 2);
  const cases = [];
  const offsets = [-8, -7, 7, 8];
  for (let index = 0; index < GENERATED_BOUNDARY_CASES; index++) {
    const base = BOUNDARY_BASES[index % BOUNDARY_BASES.length];
    const offset = offsets[Math.floor(index / BOUNDARY_BASES.length) % offsets.length];
    const kind = pick(random, ['csv', 'simplefin']);
    const cents = -1234;
    cases.push(makeCase({
      id: `gen-boundary-${String(index + 1).padStart(3, '0')}`,
      description: `${kind}: existing row ${offset >= 0 ? '+' : ''}${offset}d from ${base}`,
      seed: SEED + 2,
      setup: world({ transactions: [row('ex-1', { date: addDays(base, offset), amount: cents, payee: chance(random, 0.5) ? 'pay-store' : null })] }),
      call: call(kind, [incoming(kind, random, base, cents, 'Synthetic Market', null)], optionsFor(kind, random, false)),
      tags: ['fuzzy', 'boundary'],
    }));
  }
  return cases;
}

function importedIDCases() {
  const random = mulberry32(SEED + 3);
  const cases = [];
  for (let index = 0; index < GENERATED_IMPORTED_ID_CASES; index++) {
    const kind = pick(random, ['csv', 'bank', 'simplefin']);
    const accountOfExisting = pick(random, [CHECKING, CHECKING, SAVINGS]);
    const farOffset = pick(random, [0, 3, -2, 5]);
    const tombstone = chance(random, 0.5);
    const cents = -1500;
    const transactions = [row('ex-1', {
      account: accountOfExisting,
      date: addDays('2026-10-10', farOffset),
      amount: chance(random, 0.7) ? cents : -999,
      payee: chance(random, 0.5) ? 'pay-store' : null,
      imported_id: 'shared-id',
      tombstone,
    })];
    if (chance(random, 0.35)) {
      transactions.push(row('ex-2', {
        date: addDays('2026-10-10', 1),
        amount: cents,
        imported_id: chance(random, 0.5) ? 'shared-id' : null,
      }));
    }
    const prefValue = pick(random, [undefined, 'true', 'false']);
    const prefs = prefValue === undefined ? {} : { [`sync-reimport-deleted-${CHECKING}`]: prefValue };
    const downloads = [incoming(kind, random, '2026-10-10', cents, 'Synthetic Market', 'shared-id')];
    if (chance(random, 0.3)) downloads.push(incoming(kind, random, '2026-10-10', cents, 'Corner Cafe', 'shared-id'));
    const options = optionsFor(kind, random, false);
    cases.push(makeCase({
      id: `gen-imported-id-${String(index + 1).padStart(3, '0')}`,
      description: `${kind}: id match, existing ${tombstone ? 'deleted' : 'live'} in ${accountOfExisting}, ${farOffset}d away, pref ${prefValue ?? 'unset'}`,
      seed: SEED + 3,
      setup: world({ transactions, prefs }),
      call: call(kind, downloads, options),
      tags: ['imported-id', 'reimport-deleted'],
    }));
  }
  return cases;
}

const PAYEE_NAME_SAMPLES = [
  'WHOLE FOODS #123', "mcdonald's #4421", 'amazon.com/bill', 'AT&T BILL PAYMENT', 'nintendo store new york ny',
  'synthetic market', 'SYNTHETIC MARKET', 'Corner Cafe', '  padded name  ', 'o\'reilly auto parts', 'McDONALD\'S',
  'ebay o*12-34567', 'THE HOME DEPOT #0123', 'uber *trip', 'cvs/pharmacy #1', 'x-ray lab (west)', 'ÉCOLE du café',
  'a and the of', 'ONE-TWO three_four', '7-eleven', 'paypal *netflix', 'ATM WITHDRAWAL 1234', 'dr. smith & sons llc',
  'ACME CORP. INC.',
];

function payeeNameCases() {
  const random = mulberry32(SEED + 4);
  const cases = [];
  for (let index = 0; index < GENERATED_PAYEE_NAME_CASES; index++) {
    const kind = pick(random, ['csv', 'csv', 'bank', 'simplefin']);
    const name = PAYEE_NAME_SAMPLES[index % PAYEE_NAME_SAMPLES.length];
    const options = kind === 'csv' ? { payeeNameNormalization: pick(random, ['original', 'title-case', undefined]) } : optionsFor(kind, random, false);
    if (options.payeeNameNormalization === undefined) delete options.payeeNameNormalization;
    cases.push(makeCase({
      id: `gen-payee-name-${String(index + 1).padStart(3, '0')}`,
      description: `${kind}: payee text ${JSON.stringify(name)} with ${options.payeeNameNormalization ?? 'default'} normalization`,
      seed: SEED + 4,
      setup: world({ transactions: chance(random, 0.3) ? [row('ex-1', { date: '2026-10-10', amount: -1500, payee: null })] : [] }),
      call: call(kind, [incoming(kind, random, '2026-10-10', -1500, name, null), incoming(kind, random, '2026-10-12', -2500, name, null)], options),
      tags: ['payee-normalization'],
    }));
  }
  return cases;
}

function updateDatesCases() {
  const random = mulberry32(SEED + 6);
  const cases = [];
  for (let index = 0; index < GENERATED_UPDATE_DATES_CASES; index++) {
    const kind = pick(random, ['csv', 'bank', 'simplefin']);
    const base = pick(random, BASE_DATES);
    const offset = pick(random, [-7, -6, -3, -1, 0, 1, 2, 5, 7]);
    const cents = -2000 - 25 * Math.floor(random() * 20);
    const payee = pick(random, PAYEE_IDS);
    const update = chance(random, 0.75);
    const withSplit = chance(random, 0.2);
    const transactions = withSplit
      ? [
        row('ex-1', { date: addDays(base, offset), amount: cents, payee, is_parent: true, cleared: false }),
        row('ex-1a', { date: addDays(base, offset), amount: cents + 500, is_child: true, parent_id: 'ex-1', category: 'cat-dining', cleared: false }),
        row('ex-1b', { date: addDays(base, offset), amount: -500, is_child: true, parent_id: 'ex-1', category: 'cat-games', cleared: false }),
      ]
      : [row('ex-1', { date: addDays(base, offset), amount: cents, payee, cleared: chance(random, 0.5) })];
    const options = {};
    const prefs = {};
    if (kind === 'simplefin') prefs[`sync-update-dates-${CHECKING}`] = String(update);
    else options.updateDates = update;
    if (kind !== 'simplefin') options.strictIdChecking = false;
    cases.push(makeCase({
      id: `gen-update-dates-${String(index + 1).padStart(3, '0')}`,
      description: `${kind}: updateDates ${update}, existing row ${offset >= 0 ? '+' : ''}${offset}d from ${base}${withSplit ? ', split parent' : ''}`,
      seed: SEED + 6,
      setup: world({ transactions, prefs }),
      call: call(kind, [incoming(kind, random, base, cents, PAYEE_NAMES[payee], null, kind === 'csv' ? { cleared: true } : {})], options),
      tags: ['update-dates'],
    }));
  }
  return cases;
}

function mergeCases() {
  const random = mulberry32(SEED + 5);
  const cases = [];
  for (let index = 0; index < GENERATED_MERGE_CASES; index++) {
    const kind = pick(random, ['csv', 'csv', 'simplefin']);
    const existing = row('ex-1', {
      date: '2026-10-10',
      amount: -1500,
      payee: chance(random, 0.5) ? 'pay-cafe' : null,
      category: chance(random, 0.4) ? 'cat-dining' : null,
      notes: chance(random, 0.4) ? 'existing note' : null,
      cleared: chance(random, 0.5),
      imported_id: chance(random, 0.4) ? 'old-id' : null,
      imported_payee: chance(random, 0.4) ? 'Old Imported' : null,
    });
    const extras = {};
    if (kind === 'csv') {
      if (chance(random, 0.5)) extras.category = pick(random, ['cat-groceries', 'cat-dining']);
      if (chance(random, 0.5)) extras.notes = 'incoming note';
      if (chance(random, 0.5)) extras.cleared = chance(random, 0.5);
    } else {
      if (chance(random, 0.5)) extras.category = pick(random, ['cat-groceries', 'cat-missing']);
      if (chance(random, 0.5)) extras.notes = 'incoming note';
      if (chance(random, 0.4)) extras.booked = false;
    }
    const rules = chance(random, 0.4)
      ? [rule('rule-fill', null, [condition('imported_payee', 'contains', 'market')], [set(pick(random, ['category', 'notes']), pick(random, ['cat-groceries', 'ruled']))].map(action => (
        action.field === 'category' ? set('category', 'cat-groceries') : set('notes', 'ruled'))))]
      : [];
    cases.push(makeCase({
      id: `gen-merge-${String(index + 1).padStart(3, '0')}`,
      description: `${kind}: matched row merge of payee, category, notes, cleared and identity`,
      seed: SEED + 5,
      setup: world({ transactions: [existing], prefs: generatedPrefs(kind, random) }),
      rules,
      call: call(kind, [incoming(kind, random, '2026-10-11', -1500, 'Synthetic Market', chance(random, 0.5) ? 'new-id' : null, extras)], optionsFor(kind, random, false)),
      tags: ['merge', 'match-fill'],
    }));
  }
  return cases;
}

// ---------------------------------------------------------------- plan

export function buildPlan() {
  const cases = [
    ...namedCases(),
    ...fuzzyCases(),
    ...multiCases(),
    ...boundaryCases(),
    ...importedIDCases(),
    ...payeeNameCases(),
    ...mergeCases(),
    ...updateDatesCases(),
  ];
  return { seed: SEED, today: TODAY, timeZone: TIME_ZONE, world: WORLD, cases };
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
  const expectedError = planCase.tags.includes('error');
  if (!expectedError && record.error !== null) failures.push(`unexpected error: ${record.error}`);
  if (expectedError && record.error === null && !JSON.stringify(record.result ?? '').includes('error_type')) {
    failures.push('an error case recorded neither an error nor an error result');
  }
  for (const table of ['rules', 'schedules', 'transactions']) {
    if (!Array.isArray(record.input?.[table])) failures.push(`input.${table} is missing`);
  }
  for (const table of ['accounts', 'payees', 'transactions', 'rules']) {
    if (!Array.isArray(record.after?.[table])) failures.push(`after.${table} is missing`);
  }
  if (!Array.isArray(record.candidates)) failures.push('candidates are missing');
  else if (record.error === null && planCase.call.kind !== 'simplefin' && record.candidates.length !== planCase.call.transactions.length) {
    failures.push(`${record.candidates.length} candidates recorded for ${planCase.call.transactions.length} downloads`);
  }
  if (record.error === null && record.result === null) failures.push('no result recorded');
  if (planCase.call.options.isPreview === true && record.unchanged !== true) {
    failures.push('a preview run changed the transactions table');
  }
  if (planCase.mustNotLearnRules && JSON.stringify(record.after?.rules) !== JSON.stringify(record.input?.rules)) {
    failures.push('the import changed the rules table (category learning)');
  }
  return failures;
}
