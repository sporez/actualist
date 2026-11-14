// The account group parity plan: the seed world and every case's user input. Pure input,
// no expectations; the oracle runner decides what Actual's UI would send and records what
// Actual's handlers did. Actual's sources for each action are in README.md.
export const TIME_ZONE = 'UTC';
// The clock the runner freezes.
export const TODAY = '2026-09-27';

export const WORLD = {
  // sort_order is pinned after insertAccountGroup, which would otherwise append.
  groups: [
    { id: 'grp-banks', name: 'Banks', sort_order: 16384 },
    { id: 'grp-cards', name: 'Cards', sort_order: 32768 },
    { id: 'grp-invest', name: 'Investments', sort_order: 49152 },
    { id: 'grp-empty', name: 'Empty', sort_order: 65536 },
    // A deleted group some account still points at.
    { id: 'grp-gone', name: 'Gone', sort_order: 81920, tombstone: 1 },
  ],
  accounts: [
    { id: 'acct-checking', name: 'Checking', offbudget: 0, sort_order: 1000, group: null },
    { id: 'acct-savings', name: 'Savings', offbudget: 0, sort_order: 2000, group: 'grp-banks' },
    { id: 'acct-card', name: 'Card', offbudget: 0, sort_order: 3000, group: 'grp-cards' },
    { id: 'acct-orphan', name: 'Orphan', offbudget: 0, sort_order: 4000, group: 'grp-gone' },
    { id: 'acct-brokerage', name: 'Brokerage', offbudget: 1, sort_order: 1000, group: 'grp-invest' },
    { id: 'acct-house', name: 'House', offbudget: 1, sort_order: 2000, group: null },
    { id: 'acct-old', name: 'Old Account', offbudget: 0, sort_order: 5000, group: 'grp-banks', closed: 1 },
  ],
};

export const CASES = [
  ...[
    ['grp-create-plain', 'Loans'],
    ['grp-create-trimmed', '  Loans  '],
    ['grp-create-duplicate', 'banks'],
  ].map(([id, typed]) => ({ id, kind: 'group-create', input: { typed } })),

  ...[
    ['grp-rename-plain', 'Credit Cards'],
    ['grp-rename-trimmed', '  Credit Cards  '],
    ['grp-rename-case-only', 'CARDS'],
    ['grp-rename-unchanged', 'Cards'],
    ['grp-rename-empty', '   '],
    ['grp-rename-duplicate', 'banks'],
  ].map(([id, typed]) => ({ id, kind: 'group-rename', input: { groupID: 'grp-cards', typed } })),

  ...[
    ['grp-move-up', 'grp-invest', 'up'],
    ['grp-move-down', 'grp-banks', 'down'],
    ['grp-move-down-to-end', 'grp-invest', 'down'],
  ].map(([id, groupID, direction]) => ({ id, kind: 'group-move', input: { groupID, direction } })),

  ...[
    ['grp-delete-with-accounts', 'grp-banks'],
    ['grp-delete-empty', 'grp-empty'],
  ].map(([id, groupID]) => ({ id, kind: 'group-delete', input: { groupID } })),

  ...[
    ['acct-assign', 'acct-checking', 'grp-cards'],
    ['acct-unassign', 'acct-savings', null],
    ['acct-assign-same', 'acct-card', 'grp-cards'],
    ['acct-assign-orphan', 'acct-orphan', 'grp-banks'],
  ].map(([id, accountID, groupID]) => ({ id, kind: 'account-assign', input: { accountID, groupID } })),

  { id: 'read-groups', kind: 'read-groups', input: {} },
  { id: 'read-tree', kind: 'read-tree', input: {} },
];
