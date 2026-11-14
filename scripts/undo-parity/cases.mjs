// The undo parity plan: the seed world and every case's user input. Pure input, no
// expectations; the oracle runner decides what Actual's mobile UI would send and records what
// Actual's handlers and undo() did. Actual's sources for each action are in README.md.
export const TIME_ZONE = 'UTC';
// The clock the runner freezes; the current month is its month.
export const TODAY = '2026-09-15';
// The months whose spreadsheet cells exist (Actual's createdMonths).
export const SHEET_MONTHS = ['2026-09'];
export const BUDGET_MONTH = '2026-09';

// Explicit ids throughout; the envelope budget is Actual's default.
export const WORLD = {
  accounts: [
    { id: 'acct-checking', name: 'Checking' },
    { id: 'acct-card', name: 'Card' },
  ],
  // Actual's envelope summary needs an income group to build the sheet, so the world has one empty of
  // transactions: upstream's createSummary reads the income group's id.
  groups: [
    { id: 'grp-expenses', name: 'Expenses' },
    { id: 'grp-income', name: 'Income', is_income: 1 },
  ],
  categories: [
    { id: 'cat-groceries', name: 'Groceries', group: 'grp-expenses' },
    { id: 'cat-dining', name: 'Dining', group: 'grp-expenses' },
    { id: 'cat-bills', name: 'Bills', group: 'grp-expenses' },
    { id: 'cat-income', name: 'Income', group: 'grp-income', is_income: 1 },
  ],
  payees: [
    { id: 'payee-grocer', name: 'Grocer' },
    { id: 'payee-xfer-checking', name: 'Transfer: Checking', transfer_acct: 'acct-checking' },
    { id: 'payee-xfer-card', name: 'Transfer: Card', transfer_acct: 'acct-card' },
  ],
  budgets: [
    { month: '2026-09', category: 'cat-groceries', amount: 40000 },
    { month: '2026-09', category: 'cat-dining', amount: 10000 },
  ],
  // TransactionEntity fields, as upstream's db.insertTransaction takes them.
  transactions: [
    { id: 't-simple', account: 'acct-checking', date: '2026-09-05', amount: -2500, payee: 'payee-grocer', category: 'cat-groceries' },
    { id: 't-uncat', account: 'acct-checking', date: '2026-09-06', amount: -1200, category: null },
    { id: 't-split', account: 'acct-checking', date: '2026-09-07', amount: -3000, category: null, is_parent: true },
    { id: 't-split-1', account: 'acct-checking', date: '2026-09-07', amount: -2000, category: 'cat-groceries', is_child: true, parent_id: 't-split' },
    { id: 't-split-2', account: 'acct-checking', date: '2026-09-07', amount: -1000, category: 'cat-dining', is_child: true, parent_id: 't-split' },
    // A checking-to-card transfer, linked both ways, each leg on its destination's transfer payee.
    { id: 't-xfer', account: 'acct-checking', date: '2026-09-08', amount: -5000, payee: 'payee-xfer-card', category: null, transfer_id: 't-xfer-card' },
    { id: 't-xfer-card', account: 'acct-card', date: '2026-09-08', amount: 5000, payee: 'payee-xfer-checking', category: null, transfer_id: 't-xfer' },
  ],
};

export const CASES = [
  { id: 'assign-groceries', kind: 'assign', input: { month: BUDGET_MONTH, categoryID: 'cat-groceries', amount: 55000 } },
  { id: 'move-dining-to-groceries', kind: 'move', input: { month: BUDGET_MONTH, fromID: 'cat-dining', toID: 'cat-groceries', amount: 4000 } },
  { id: 'create-simple', kind: 'create', input: { accountID: 'acct-checking', categoryID: 'cat-dining', amount: -900, date: '2026-09-10' } },
  { id: 'edit-amount-payee', kind: 'edit', input: { transactionID: 't-simple', amount: -2600, newPayeeName: 'Corner Shop' } },
  { id: 'delete-simple', kind: 'delete', input: { transactionID: 't-simple' } },
  { id: 'delete-split', kind: 'delete', input: { transactionID: 't-split' } },
  { id: 'delete-transfer', kind: 'delete', input: { transactionID: 't-xfer' } },
  { id: 'categorize-uncat', kind: 'categorize', input: { transactionID: 't-uncat', categoryID: 'cat-dining' } },
  { id: 'batch-delete', kind: 'batch-delete', input: { ids: ['t-simple', 't-uncat'] } },
  { id: 'batch-categorize', kind: 'batch-categorize', input: { ids: ['t-simple', 't-uncat'], categoryID: 'cat-bills' } },
];

// The Payees fixture cases whose recorded undo this suite replays. Every other Payees case is
// listed with the reason it is not (no call sent, Actualist refuses, or Actual's undo failed).
export const PAYEE_UNDO_REPLAYED = [
  'create-plain', 'create-trimmed', 'create-padded-duplicate', 'create-account-name', 'create-normalised-padded',
  'rename-plain', 'rename-trimmed', 'rename-unchanged', 'rename-case-only',
  'merge-one', 'merge-two', 'merge-rule-referenced',
  'delete-unused', 'delete-two-unused', 'delete-with-transactions', 'delete-rule-condition',
  'delete-rule-action', 'delete-deleted-txn-only', 'delete-mixed',
  'favorite-one', 'unfavorite-one', 'favorite-selection-mixed',
  'learn-off-one', 'learn-on-one', 'learn-selection-mixed',
  'learn-global-on',
];
export const PAYEE_UNDO_OMITTED = [
  { id: 'read-seed', reason: 'a read: nothing to undo' },
  { id: 'create-case-duplicate', reason: "Actual's UI sends no call (the create gate picks the existing payee): nothing to undo" },
  { id: 'create-diacritic-duplicate', reason: "Actual's UI sends no call (the create gate picks the existing payee): nothing to undo" },
  { id: 'create-normalised-duplicate', reason: "Actual's UI sends no call (the create gate picks the existing payee): nothing to undo" },
  { id: 'rename-empty', reason: "Actual's UI sends no call for an empty name: nothing to undo" },
  { id: 'rename-to-existing', reason: 'Actualist refuses the rename (OP-97), so it has no change to undo' },
  { id: 'learn-global-off', reason: "Actual's undo() fails with SyncError: invalid-schema, so there is no recorded undo to compare" },
];
