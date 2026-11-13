// The payee parity plan: the seed world and every case's user input. Pure input,
// no expectations; the oracle runner decides what Actual's UI would send and records
// what Actual's handlers did. Actual's sources for each action are in README.md.
export const TIME_ZONE = 'UTC';

const transferPayee = account => ({ id: `payee-xfer-${account}`, name: '', transfer_acct: `acct-${account}` });

export const WORLD = {
  accounts: [
    { id: 'acct-checking', name: 'Checking', sort_order: 3000 },
    { id: 'acct-vault', name: 'Vault Savings', sort_order: 1000 },
    { id: 'acct-card', name: 'Card', sort_order: 2000, closed: 1 },
    { id: 'acct-brokerage', name: 'Brokerage', sort_order: 500, offbudget: 1 },
    { id: 'acct-gone', name: 'Gone', tombstone: 1 },
  ],
  payees: [
    ...['checking', 'vault', 'card', 'brokerage', 'gone'].map(transferPayee),
    { id: 'payee-grocer', name: 'Grocer' },
    { id: 'payee-cafe', name: 'Cafe' },
    { id: 'payee-old-cafe', name: 'Old Cafe', tombstone: 1, mapsTo: 'payee-cafe' },
    { id: 'payee-unused', name: 'Unused Shop' },
    { id: 'payee-unused-2', name: 'Another Unused' },
    { id: 'payee-rule-condition', name: 'Rule Condition Payee' },
    { id: 'payee-rule-action', name: 'Rule Action Payee' },
    { id: 'payee-schedule', name: 'Finished Schedule Payee' },
    { id: 'payee-deleted-txn', name: 'Deleted Txn Payee' },
    { id: 'payee-split-child', name: 'Split Child Payee' },
    { id: 'payee-favorite', name: 'Favorite Payee', favorite: 1 },
    { id: 'payee-nolearn', name: 'No Learning Payee', learn_categories: 0 },
    { id: 'payee-eclair', name: 'Éclair' },
    { id: 'payee-apple', name: 'apple' },
    { id: 'payee-banana', name: 'Banana' },
    { id: 'payee-zebra', name: 'zebra' },
    { id: 'payee-strasse', name: 'Straße Café' },
  ],
  groups: [{ id: 'cat-group', name: 'Group' }],
  categories: [{ id: 'cat-food', name: 'Food', group: 'cat-group' }],
  transactions: [
    { id: 't-grocer-1', date: '2026-09-01', amount: -1000, payee: 'payee-grocer' },
    { id: 't-grocer-2', date: '2026-09-02', amount: -1100, payee: 'payee-grocer' },
    { id: 't-cafe', date: '2026-09-03', amount: -450, payee: 'payee-cafe' },
    { id: 't-old-cafe', date: '2026-09-04', amount: -500, payee: 'payee-old-cafe' },
    { id: 't-deleted', date: '2026-09-05', amount: -700, payee: 'payee-deleted-txn', tombstone: 1 },
    { id: 't-split-parent', date: '2026-09-06', amount: -1500, payee: 'payee-grocer', is_parent: 1 },
    { id: 't-split-child', date: '2026-09-06', amount: -1500, payee: 'payee-split-child', is_child: 1, parent_id: 't-split-parent' },
  ],
  // Rules are stored through Actual's own insertRule (payee fields are stored as `description`).
  rules: [
    {
      id: 'r-condition',
      conditions: [{ op: 'is', field: 'payee', value: 'payee-rule-condition' }],
      actions: [{ op: 'set', field: 'category', value: 'cat-food' }],
    },
    {
      id: 'r-action',
      conditions: [{ op: 'contains', field: 'notes', value: 'synthetic' }],
      actions: [{ op: 'set', field: 'payee', value: 'payee-rule-action' }],
    },
  ],
  // The schedule's own rule is r-schedule: a condition on payee-schedule; the schedule is completed.
  schedules: [
    {
      id: 'sched-done',
      name: 'Synthetic Done Schedule',
      completed: 1,
      ruleID: 'r-schedule',
      conditions: [
        { op: 'is', field: 'payee', value: 'payee-schedule' },
        { op: 'is', field: 'date', value: '2026-09-15' },
      ],
    },
  ],
};

export const CASES = [
  { id: 'read-seed', kind: 'read', input: {} },

  ...[
    ['create-plain', 'Bakery'],
    ['create-trimmed', '  Bakery  '],
    ['create-case-duplicate', 'grocer'],
    ['create-diacritic-duplicate', 'Eclair'],
    ['create-padded-duplicate', 'Grocer '],
    ['create-account-name', 'Checking'],
    ['create-normalised-duplicate', 'strasse cafe'],
    ['create-normalised-padded', ' strasse cafe'],
  ].map(([id, typed]) => ({ id, kind: 'create', input: { typed } })),

  ...[
    ['rename-plain', 'payee-grocer', 'Green Grocer'],
    ['rename-trimmed', 'payee-grocer', '  Green Grocer  '],
    ['rename-unchanged', 'payee-grocer', 'Grocer'],
    ['rename-case-only', 'payee-grocer', 'GROCER'],
    ['rename-to-existing', 'payee-grocer', 'Cafe'],
    ['rename-empty', 'payee-grocer', '   '],
  ].map(([id, payeeID, typed]) => ({ id, kind: 'rename', input: { payeeID, typed } })),

  ...[
    ['merge-one', 'payee-grocer', ['payee-cafe']],
    ['merge-two', 'payee-grocer', ['payee-cafe', 'payee-unused']],
    ['merge-rule-referenced', 'payee-grocer', ['payee-rule-condition']],
  ].map(([id, targetID, mergeIDs]) => ({ id, kind: 'merge', input: { targetID, mergeIDs } })),

  ...[
    ['delete-unused', ['payee-unused']],
    ['delete-two-unused', ['payee-unused', 'payee-unused-2']],
    ['delete-with-transactions', ['payee-cafe']],
    ['delete-rule-condition', ['payee-rule-condition']],
    ['delete-rule-action', ['payee-rule-action']],
    ['delete-deleted-txn-only', ['payee-deleted-txn']],
    ['delete-mixed', ['payee-unused', 'payee-cafe']],
  ].map(([id, payeeIDs]) => ({ id, kind: 'delete', input: { payeeIDs } })),

  { id: 'favorite-one', kind: 'toggle-single', input: { payeeID: 'payee-grocer', field: 'favorite', value: true } },
  { id: 'unfavorite-one', kind: 'toggle-single', input: { payeeID: 'payee-favorite', field: 'favorite', value: false } },
  { id: 'favorite-selection-mixed', kind: 'toggle-selection', input: { field: 'favorite', selection: ['payee-grocer', 'payee-favorite'] } },
  { id: 'learn-off-one', kind: 'toggle-single', input: { payeeID: 'payee-grocer', field: 'learn_categories', value: false } },
  { id: 'learn-on-one', kind: 'toggle-single', input: { payeeID: 'payee-nolearn', field: 'learn_categories', value: true } },
  { id: 'learn-selection-mixed', kind: 'toggle-selection', input: { field: 'learn_categories', selection: ['payee-grocer', 'payee-nolearn'] } },

  { id: 'learn-global-off', kind: 'global-learning', input: {}, preferences: [] },
  { id: 'learn-global-on', kind: 'global-learning', input: {}, preferences: [{ id: 'learn-categories', value: 'false' }] },
];
