// The category parity plan: the seed world and every case's user input. Pure input,
// no expectations; the oracle runner decides what Actual's UI would send and records
// what Actual's handlers did. Actual's sources for each action are in README.md.
export const TIME_ZONE = 'UTC';
// The clock the runner freezes; the current month is its month.
export const TODAY = '2026-09-27';
// The months whose spreadsheet cells exist (Actual's createdMonths). doTransfer writes
// a budget row for each of them.
export const SHEET_MONTHS = ['2026-08', '2026-09'];

export const WORLD = {
  accounts: [{ id: 'acct-checking', name: 'Checking' }],
  groups: [
    { id: 'grp-bills', name: 'Bills' },
    { id: 'grp-food', name: 'Food' },
    { id: 'grp-empty', name: 'Empty Group' },
    { id: 'grp-hidden', name: 'Hidden Group', hidden: 1 },
    { id: 'grp-income', name: 'Income', is_income: 1 },
  ],
  categories: [
    { id: 'cat-rent', name: 'Rent', group: 'grp-bills' },
    { id: 'cat-power', name: 'Power', group: 'grp-bills' },
    { id: 'cat-water', name: 'Water', group: 'grp-bills' },
    { id: 'cat-misc', name: 'Misc', group: 'grp-bills' },
    { id: 'cat-groceries', name: 'Groceries', group: 'grp-food' },
    { id: 'cat-dining', name: 'Dining', group: 'grp-food' },
    { id: 'cat-misc-food', name: 'Misc', group: 'grp-food' },
    { id: 'cat-hidden', name: 'Hidden Cat', group: 'grp-food', hidden: 1 },
    { id: 'cat-old', name: 'Old Stuff', group: 'grp-hidden' },
    { id: 'cat-salary', name: 'Salary', group: 'grp-income', is_income: 1 },
    { id: 'cat-other-income', name: 'Other Income', group: 'grp-income', is_income: 1 },
    // An earlier delete with a transfer: tombstoned, mapped to cat-dining.
    { id: 'cat-retired', name: 'Retired', group: 'grp-food', tombstone: 1, mapsTo: 'cat-dining' },
  ],
  // Envelope budget rows (zero_budgets), minor units.
  budgets: [
    { month: '2026-08', category: 'cat-rent', amount: 100000 },
    { month: '2026-08', category: 'cat-power', amount: 5000 },
    { month: '2026-08', category: 'cat-groceries', amount: 40000 },
    { month: '2026-08', category: 'cat-dining', amount: 10000 },
    { month: '2026-09', category: 'cat-rent', amount: 100000 },
    { month: '2026-09', category: 'cat-groceries', amount: 40000 },
    { month: '2026-09', category: 'cat-dining', amount: 12000 },
  ],
  transactions: [
    { id: 't-groceries', date: '2026-09-05', amount: -2500, category: 'cat-groceries' },
    { id: 't-dining', date: '2026-09-06', amount: -1500, category: 'cat-dining' },
    { id: 't-retired', date: '2026-09-07', amount: -700, category: 'cat-retired' },
    { id: 't-salary', date: '2026-09-01', amount: 300000, category: 'cat-salary' },
  ],
};

export const CASES = [
  ...[
    ['cat-create-plain', 'Internet', 'grp-bills', false],
    ['cat-create-trimmed', '  Internet  ', 'grp-bills', false],
    ['cat-create-duplicate-case', 'rent', 'grp-bills', false],
    ['cat-create-other-group', 'Rent', 'grp-food', false],
    ['cat-create-empty-group', 'First', 'grp-empty', false],
    ['cat-create-income', 'Bonus', 'grp-income', true],
  ].map(([id, typed, groupID, isIncome]) => ({ id, kind: 'category-create', input: { typed, groupID, isIncome } })),

  ...[
    ['grp-create-plain', 'Savings'],
    ['grp-create-trimmed', '  Savings  '],
    ['grp-create-duplicate-case', 'bills'],
  ].map(([id, typed]) => ({ id, kind: 'group-create', input: { typed } })),

  ...[
    ['cat-rename-plain', 'cat-power', 'Electric'],
    ['cat-rename-trimmed', 'cat-power', '  Electric  '],
    ['cat-rename-case-only', 'cat-power', 'POWER'],
    ['cat-rename-unchanged', 'cat-power', 'Power'],
    ['cat-rename-duplicate', 'cat-power', 'rent'],
  ].map(([id, categoryID, typed]) => ({ id, kind: 'category-rename', input: { categoryID, typed } })),

  ...[
    ['grp-rename-plain', 'grp-food', 'Groceries & Dining'],
    ['grp-rename-duplicate', 'grp-food', 'bills'],
  ].map(([id, groupID, typed]) => ({ id, kind: 'group-rename', input: { groupID, typed } })),

  ...[
    ['cat-hide', 'cat-water'],
    ['cat-unhide', 'cat-hidden'],
  ].map(([id, categoryID]) => ({ id, kind: 'category-hide', input: { categoryID } })),

  ...[
    ['grp-hide', 'grp-food'],
    ['grp-unhide', 'grp-hidden'],
  ].map(([id, groupID]) => ({ id, kind: 'group-hide', input: { groupID } })),

  ...[
    ['cat-move-within', 'cat-water', 'grp-bills', 'cat-rent'],
    ['cat-move-to-end', 'cat-rent', 'grp-bills', null],
    ['cat-move-other-group', 'cat-power', 'grp-food', 'cat-dining'],
    ['cat-move-into-empty', 'cat-power', 'grp-empty', null],
    ['cat-move-duplicate-name', 'cat-misc', 'grp-food', null],
  ].map(([id, categoryID, groupID, targetID]) => ({
    id, kind: 'category-move', input: { categoryID, groupID, targetID },
  })),

  ...[
    ['grp-move-first', 'grp-food', 'grp-bills'],
    ['grp-move-end', 'grp-bills', null],
  ].map(([id, groupID, targetID]) => ({ id, kind: 'group-move', input: { groupID, targetID } })),

  ...[
    ['cat-delete-unused', 'cat-water', 'cat-rent'],
    ['cat-delete-budget-transfer', 'cat-power', 'cat-rent'],
    ['cat-delete-transactions-transfer', 'cat-dining', 'cat-groceries'],
    ['cat-delete-income-transfer', 'cat-salary', 'cat-other-income'],
  ].map(([id, categoryID, transferID]) => ({
    id, kind: 'category-delete', input: { categoryID, transferID },
  })),

  ...[
    ['grp-delete-empty', 'grp-empty', 'cat-rent'],
    ['grp-delete-transfer', 'grp-food', 'cat-rent'],
    ['grp-delete-no-transfer', 'grp-hidden', 'cat-rent'],
  ].map(([id, groupID, transferID]) => ({ id, kind: 'group-delete', input: { groupID, transferID } })),

  { id: 'read-must-transfer', kind: 'read-must-transfer', input: {} },
  { id: 'read-outline', kind: 'read-outline', input: {} },
  // Another device's delete arrives: cat-dining is tombstoned with no transfer.
  { id: 'read-deleted-category-display', kind: 'read-deleted-display', input: { tombstoned: ['cat-dining'], account: 'acct-checking' } },
];
