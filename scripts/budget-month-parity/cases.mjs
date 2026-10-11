// The budget-month case plan: named cases plus seeded generated cases.
//
// Pure data. generate.mjs runs every step through Actual's handlers; verify.mjs
// rebuilds this plan without an oracle and compares it with the committed
// fixture. Amounts are integer minor units. Dates are ISO strings.

export const SEED = 20261011;
export const TODAY = '2026-10-15';
export const GENERATED_CASE_COUNT = 60;
export const CURRENCY = 'USD';

export function monthRange(start, end) {
  const months = [];
  for (let month = start; month <= end; month = addMonths(month, 1)) months.push(month);
  return months;
}

export function addMonths(month, delta) {
  const [year, value] = month.split('-').map(Number);
  const index = year * 12 + (value - 1) + delta;
  return `${Math.floor(index / 12)}-${String((index % 12) + 1).padStart(2, '0')}`;
}

// Named cases share a window that starts two months before the first step and
// includes an empty June and July, so averages and carry-in read real sheets.
const NAMED_WINDOW = monthRange('2026-06', '2027-02');

export function mulberry32(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let value = Math.imul(state ^ (state >>> 15), 1 | state);
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value;
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

const BASE_GROUPS = [
  { id: 'income-group', name: 'Synthetic Income', income: true, hidden: false },
  { id: 'expense-group', name: 'Synthetic Expenses', income: false, hidden: false },
];
const BASE_CATEGORIES = [
  { id: 'salary', name: 'Synthetic Salary', group: 'income-group', income: true, hidden: false },
  { id: 'groceries', name: 'Synthetic Groceries', group: 'expense-group', income: false, hidden: false },
  { id: 'dining', name: 'Synthetic Dining', group: 'expense-group', income: false, hidden: false },
];
const BASE_ACCOUNTS = [
  { id: 'checking', name: 'Synthetic Checking', offbudget: false },
  { id: 'savings', name: 'Synthetic Savings', offbudget: true },
];

function setup(overrides = {}) {
  return {
    budgetType: 'envelope',
    groups: BASE_GROUPS,
    categories: BASE_CATEGORIES,
    accounts: BASE_ACCOUNTS,
    transactions: [],
    budgets: [],
    buffers: [],
    ...overrides,
  };
}

function tx(id, account, category, date, amount) {
  return { id, account, category, date, amount };
}

function row(month, category, amount, carryover = false) {
  return { month, category, amount, carryover };
}

function stepOf(handler, affectedFrom, args) {
  return { handler, affectedFrom, args };
}

const assign = (month, category, amount) =>
  stepOf('budget/budget-amount', month, { month, category, amount });
const move = (month, from, to, amount) =>
  stepOf('budget/transfer-category', month, { month, amount, from, to, currencyCode: CURRENCY });
const transferAvailable = (month, category, amount) =>
  stepOf('budget/transfer-available', month, { month, amount, category });
function cover(month, to, from, amount) {
  const args = amount === undefined
    ? { month, to, from, currencyCode: CURRENCY }
    : { month, to, from, amount, currencyCode: CURRENCY };
  return stepOf('budget/cover-overspending', month, args);
}
const carryover = (startMonth, category, flag) =>
  stepOf('budget/set-carryover', startMonth, { startMonth, category, flag });
const resetIncome = month => stepOf('budget/reset-income-carryover', month, { month });
const resetHold = month => stepOf('budget/reset-hold', month, { month });
// ToBudgetMenu sends reset-income-carryover when Hold is chosen, then the amount.
const holdSteps = (month, amount) => [
  resetIncome(month),
  stepOf('budget/hold-for-next-month', month, { month, amount }),
];

function expectBefore(month, path, equals) {
  return { at: 'before', month, path, equals };
}
function expectFinal(month, path, equals) {
  return { at: 'final', month, path, equals };
}
function expectReturned(step, equals) {
  return { at: 'returned', step, equals };
}

function named({
  id,
  description,
  setup: caseSetup,
  sheetMonths = NAMED_WINDOW,
  steps,
  expectations = [],
  oracleOnly = null,
}) {
  return {
    id,
    source: 'named',
    description,
    seed: null,
    oracleOnly,
    setup: caseSetup,
    sheetMonths,
    steps,
    expectations,
  };
}

const INCOME_AUG = tx('income-aug', 'checking', 'salary', '2026-08-01', 100000);
const GROCERIES_AUG_30000 = tx('groceries-aug', 'checking', 'groceries', '2026-08-10', -30000);

function namedCases() {
  return [
    named({
      id: 'overspend-resets-without-carryover',
      description: 'August groceries overspent by 30000 without carryover: September starts from zero.',
      setup: setup({ transactions: [INCOME_AUG, GROCERIES_AUG_30000] }),
      steps: [assign('2026-08', 'dining', 0)],
      expectations: [
        expectFinal('2026-08', 'categories.groceries.leftover', -30000),
        expectFinal('2026-09', 'categories.groceries.leftover', 0),
      ],
    }),
    named({
      id: 'overspend-carries-negative-with-carryover',
      description: 'The same overspend carries into September once groceries carryover is on.',
      setup: setup({ transactions: [INCOME_AUG, GROCERIES_AUG_30000] }),
      steps: [carryover('2026-08', 'groceries', true)],
      expectations: [
        expectFinal('2026-08', 'categories.groceries.carryover', true),
        expectFinal('2026-09', 'categories.groceries.leftover', -30000),
      ],
    }),
    named({
      id: 'positive-balance-carries-without-rollover',
      description: 'An unspent August groceries budget carries into September without carryover on.',
      setup: setup({
        transactions: [INCOME_AUG],
        budgets: [row('2026-08', 'groceries', 50000)],
      }),
      steps: [assign('2026-08', 'dining', 0)],
      expectations: [expectFinal('2026-09', 'categories.groceries.leftover', 50000)],
    }),
    named({
      id: 'hidden-category-overspent-counts',
      description: 'A hidden category overspent in August is still part of the August sheet.',
      setup: setup({
        categories: [
          ...BASE_CATEGORIES,
          { id: 'fun', name: 'Synthetic Fun', group: 'expense-group', income: false, hidden: true },
        ],
        transactions: [INCOME_AUG, tx('fun-aug', 'checking', 'fun', '2026-08-12', -20000)],
      }),
      steps: [assign('2026-08', 'dining', 0)],
    }),
    named({
      id: 'hold-reduces-to-budget-and-arrives-next-month',
      description: 'Holding 30000 of August To Budget reduces it and keeps the hold on August.',
      setup: setup({ transactions: [INCOME_AUG] }),
      steps: holdSteps('2026-08', 30000),
      expectations: [
        expectFinal('2026-08', 'summary.buffered-selected', 30000),
        expectFinal('2026-08', 'summary.to-budget', 70000),
      ],
    }),
    named({
      id: 'cover-overspending-from-to-budget',
      description: 'Covering August groceries overspending from To Budget funds the full 30000.',
      setup: setup({ transactions: [INCOME_AUG, GROCERIES_AUG_30000] }),
      steps: [cover('2026-08', 'groceries', 'to-budget')],
      expectations: [
        expectFinal('2026-08', 'categories.groceries.budgeted', 30000),
        expectFinal('2026-08', 'categories.groceries.leftover', 0),
      ],
    }),
    named({
      id: 'cover-clamped-to-source-leftover',
      description: 'Covering more than the source category has left moves only that leftover.',
      setup: setup({
        transactions: [INCOME_AUG, GROCERIES_AUG_30000],
        budgets: [row('2026-08', 'dining', 10000)],
      }),
      steps: [cover('2026-08', 'groceries', 'dining')],
      expectations: [
        expectFinal('2026-08', 'categories.groceries.budgeted', 10000),
        expectFinal('2026-08', 'categories.dining.budgeted', 0),
        expectFinal('2026-08', 'categories.groceries.leftover', -20000),
      ],
    }),
    named({
      id: 'cover-partial-amount',
      description: 'A partial cover of 10000 from To Budget leaves the rest of the overspend.',
      setup: setup({ transactions: [INCOME_AUG, GROCERIES_AUG_30000] }),
      steps: [cover('2026-08', 'groceries', 'to-budget', 10000)],
      expectations: [
        expectFinal('2026-08', 'categories.groceries.budgeted', 10000),
        expectFinal('2026-08', 'categories.groceries.leftover', -20000),
      ],
    }),
    named({
      id: 'move-creates-overspend',
      description: 'Moving 50000 out of a 40000 groceries budget leaves groceries overbudgeted.',
      setup: setup({
        transactions: [INCOME_AUG],
        budgets: [row('2026-08', 'groceries', 40000)],
      }),
      steps: [move('2026-08', 'groceries', 'dining', 50000)],
      expectations: [
        expectFinal('2026-08', 'categories.groceries.budgeted', -10000),
        expectFinal('2026-08', 'categories.dining.budgeted', 50000),
      ],
    }),
    named({
      id: 'move-to-to-budget',
      description: 'Moving 20000 from groceries back to To Budget lowers the groceries budget.',
      setup: setup({
        transactions: [INCOME_AUG],
        budgets: [row('2026-08', 'groceries', 40000)],
      }),
      steps: [move('2026-08', 'groceries', 'to-budget', 20000)],
      expectations: [expectFinal('2026-08', 'categories.groceries.budgeted', 20000)],
    }),
    named({
      id: 'transfer-available-clamped-to-to-budget',
      description: 'Transferring more than To Budget into groceries clamps to To Budget.',
      setup: setup({ transactions: [INCOME_AUG] }),
      steps: [transferAvailable('2026-08', 'groceries', 500000)],
      expectations: [expectFinal('2026-08', 'categories.groceries.budgeted', 100000)],
    }),
    named({
      id: 'assign-overbudgets-and-hold-refused',
      description: 'Assigning more than the income leaves To Budget negative, so a later hold is refused.',
      setup: setup({ transactions: [INCOME_AUG] }),
      steps: [assign('2026-08', 'groceries', 150000), ...holdSteps('2026-08', 10000)],
      expectations: [
        expectReturned(2, false),
        expectFinal('2026-08', 'summary.to-budget', -50000),
      ],
    }),
    named({
      id: 'income-category-carryover-holds-next-month',
      description: 'Turning on carryover for the income category holds August income automatically.',
      setup: setup({ transactions: [INCOME_AUG] }),
      steps: [carryover('2026-08', 'salary', true)],
      expectations: [
        expectFinal('2026-08', 'summary.buffered-auto', 100000),
        expectFinal('2026-08', 'summary.to-budget', 0),
      ],
    }),
    named({
      id: 'reset-income-carryover-clears-automatic-hold',
      description: 'Resetting income carryover clears the automatic August hold and frees the income.',
      setup: setup({
        transactions: [INCOME_AUG],
        budgets: [row('2026-08', 'salary', 0, true)],
      }),
      steps: [resetIncome('2026-08')],
      expectations: [
        expectBefore('2026-08', 'summary.buffered-auto', 100000),
        expectFinal('2026-08', 'summary.buffered-auto', 0),
        expectFinal('2026-08', 'summary.to-budget', 100000),
      ],
    }),
    named({
      id: 'rollover-all-expense-equals-per-category-toggles',
      description: 'Rolling over all expense categories is the same as one carryover toggle per category.',
      setup: setup({ transactions: [INCOME_AUG] }),
      steps: [
        carryover('2026-08', 'groceries', true),
        carryover('2026-08', 'dining', true),
      ],
      expectations: [
        expectFinal('2027-02', 'categories.groceries.carryover', true),
        expectFinal('2027-02', 'categories.dining.carryover', true),
      ],
    }),
    named({
      id: 'year-end-hold-and-overspend-roll-into-january',
      description: 'A December overspend with carryover and a December hold both continue into January.',
      setup: setup({
        transactions: [
          tx('income-dec', 'checking', 'salary', '2026-12-01', 100000),
          tx('groceries-dec', 'checking', 'groceries', '2026-12-10', -30000),
        ],
      }),
      steps: [carryover('2026-12', 'groceries', true), ...holdSteps('2026-12', 40000)],
      expectations: [
        expectFinal('2026-12', 'summary.buffered-selected', 40000),
        expectFinal('2027-01', 'categories.groceries.leftover', -30000),
      ],
    }),
    named({
      id: 'leap-day-2028-counts-in-sum',
      description: 'A transaction dated 2028-02-29 counts in February 2028 spending.',
      setup: setup({
        transactions: [tx('groceries-leap', 'checking', 'groceries', '2028-02-29', -5000)],
      }),
      sheetMonths: monthRange('2028-01', '2028-03'),
      steps: [assign('2028-02', 'dining', 0)],
      expectations: [expectFinal('2028-02', 'categories.groceries.spent', -5000)],
    }),
    named({
      id: 'offbudget-and-uncategorized-excluded',
      description: 'Off-budget account spending and uncategorized spending stay out of category spending.',
      setup: setup({
        transactions: [
          INCOME_AUG,
          tx('savings-aug', 'savings', 'groceries', '2026-08-05', -7000),
          tx('uncategorized-aug', 'checking', null, '2026-08-06', -3000),
        ],
      }),
      steps: [assign('2026-08', 'dining', 0)],
      expectations: [expectFinal('2026-08', 'categories.groceries.spent', 0)],
    }),
    named({
      id: 'copy-previous-month',
      description: 'Copy previous month copies August budgets into September.',
      setup: setup({
        transactions: [INCOME_AUG],
        budgets: [row('2026-08', 'groceries', 40000)],
      }),
      steps: [stepOf('budget/copy-previous-month', '2026-09', { month: '2026-09' })],
      expectations: [expectFinal('2026-09', 'categories.groceries.budgeted', 40000)],
      oracleOnly:
        'Actualist has no copy-previous-month action. The oracle pins the copy of expense budgets from the previous month.',
    }),
    named({
      id: 'set-zero',
      description: 'Set zero clears every expense budget in August.',
      setup: setup({
        transactions: [INCOME_AUG],
        budgets: [row('2026-08', 'groceries', 40000)],
      }),
      steps: [stepOf('budget/set-zero', '2026-08', { month: '2026-08' })],
      expectations: [expectFinal('2026-08', 'categories.groceries.budgeted', 0)],
      oracleOnly: 'Actualist has no set-zero action. The oracle pins zeroing every budget row for the month.',
    }),
    named({
      id: 'set-3month-avg',
      description: 'Set three-month average budgets September from August spending, sign-flipped for expenses.',
      setup: setup({ transactions: [INCOME_AUG, GROCERIES_AUG_30000] }),
      steps: [stepOf('budget/set-3month-avg', '2026-09', { month: '2026-09' })],
      expectations: [expectFinal('2026-09', 'categories.groceries.budgeted', 30000)],
      oracleOnly:
        'Actualist has no three-month average action. The oracle pins the averaging and sign rule for expense categories.',
    }),
    named({
      id: 'cover-overbudgeted',
      description: 'Cover overbudgeted takes the overbudgeted amount from groceries leftover.',
      setup: setup({
        transactions: [INCOME_AUG],
        budgets: [row('2026-08', 'groceries', 150000)],
      }),
      steps: [stepOf('budget/cover-overbudgeted', '2026-08', {
        month: '2026-08',
        category: 'groceries',
        currencyCode: CURRENCY,
      })],
      expectations: [
        expectFinal('2026-08', 'categories.groceries.budgeted', 100000),
        expectFinal('2026-08', 'summary.to-budget', 0),
      ],
      oracleOnly:
        'Actualist has no cover-overbudgeted action; its overspending cover covers a category, not the To Budget overage.',
    }),
    named({
      id: 'copy-until-year-end',
      description: 'Copy until year end copies the August groceries budget through December only.',
      setup: setup({
        transactions: [INCOME_AUG],
        budgets: [row('2026-08', 'groceries', 40000)],
      }),
      steps: [stepOf('budget/copy-until-year-end', '2026-08', {
        month: '2026-08',
        category: 'groceries',
      })],
      expectations: [
        expectFinal('2026-12', 'categories.groceries.budgeted', 40000),
        expectFinal('2027-01', 'categories.groceries.budgeted', 0),
      ],
      oracleOnly: 'Actualist has no copy-until-year-end action.',
    }),
    named({
      id: 'tracking-assign-to-income-category',
      description: 'On tracking budgets, an income category takes a budget amount.',
      setup: setup({ budgetType: 'tracking', transactions: [INCOME_AUG] }),
      steps: [assign('2026-08', 'salary', 50000)],
    }),
    named({
      id: 'tracking-carryover-chain-no-positive-clamp',
      description: 'Tracking carryover keeps the August leftover into September.',
      setup: setup({
        budgetType: 'tracking',
        transactions: [INCOME_AUG, GROCERIES_AUG_30000],
        budgets: [row('2026-08', 'groceries', 50000)],
      }),
      steps: [carryover('2026-08', 'groceries', true)],
      expectations: [expectFinal('2026-08', 'categories.groceries.leftover', 20000)],
    }),
    named({
      id: 'tracking-move-money-oracle-only',
      description: 'Move money on a tracking budget, which Actualist refuses.',
      setup: setup({
        budgetType: 'tracking',
        budgets: [row('2026-08', 'groceries', 40000)],
      }),
      steps: [move('2026-08', 'groceries', 'dining', 10000)],
      oracleOnly:
        'Actualist refuses move-money on tracking budgets (BudgetActionEligibility); the oracle pins what Actual writes instead.',
    }),
  ];
}

// Generated cases: the expense categories, optional hidden category and group,
// transactions, pre-seeded budgets and carryover, and a random step sequence.
const POOL = [
  ['groceries', 'Groceries'],
  ['dining', 'Dining'],
  ['transport', 'Transport'],
  ['utilities', 'Utilities'],
  ['rent', 'Rent'],
  ['fun', 'Fun'],
  ['health', 'Health'],
  ['pets', 'Pets'],
];

function generatedCase(index, caseSeed) {
  const rng = mulberry32(caseSeed);
  const chance = probability => rng() < probability;
  const between = (low, high) => low + Math.floor(rng() * (high - low + 1));
  const pick = items => items[Math.floor(rng() * items.length)];
  const leapWindow = index % 2 === 1;
  const windowStart = leapWindow ? '2027-11' : '2026-11';
  const sheetMonths = monthRange(addMonths(windowStart, -2), addMonths(windowStart, 12));
  const windowMonths = sheetMonths.slice(2);

  const others = POOL.filter(([id]) => id !== 'groceries');
  for (let position = others.length - 1; position > 0; position -= 1) {
    const swap = Math.floor(rng() * (position + 1));
    [others[position], others[swap]] = [others[swap], others[position]];
  }
  const expenseEntries = [POOL[0], ...others.slice(0, between(3, 5))];
  const expenseIDs = expenseEntries.map(([id]) => id);
  const labels = Object.fromEntries(POOL);
  const hiddenGroupMember = chance(0.3) ? expenseIDs[expenseIDs.length - 1] : null;

  const categories = [
    { id: 'salary', name: 'Synthetic Salary', group: 'income-group', income: true, hidden: false },
  ];
  if (chance(0.3)) {
    categories.push({ id: 'bonus', name: 'Synthetic Bonus', group: 'income-group', income: true, hidden: false });
  }
  for (const id of expenseIDs) {
    categories.push({
      id,
      name: `Synthetic ${labels[id]}`,
      group: id === hiddenGroupMember ? 'hidden-group' : 'expense-group',
      income: false,
      hidden: chance(0.2),
    });
  }
  const groups = hiddenGroupMember
    ? [...BASE_GROUPS, { id: 'hidden-group', name: 'Synthetic Hidden Group', income: false, hidden: true }]
    : BASE_GROUPS;

  const transactions = [];
  let counter = 0;
  const transactionID = prefix => `${prefix}-${(counter += 1)}`;
  const dateIn = month => `${month}-${String(between(1, 28)).padStart(2, '0')}`;
  for (const month of sheetMonths) {
    if (chance(0.9)) {
      transactions.push(tx(transactionID('income'), 'checking', 'salary', dateIn(month), between(60000, 240000)));
    }
    for (const id of expenseIDs) {
      const count = between(0, 2);
      for (let spend = 0; spend < count; spend += 1) {
        transactions.push(tx(transactionID('spend'), 'checking', id, dateIn(month), -between(500, 45000)));
      }
    }
  }
  if (chance(0.5)) {
    transactions.push(tx(transactionID('uncategorized'), 'checking', null, dateIn(pick(sheetMonths)), -between(100, 5000)));
  }
  if (chance(0.5)) {
    transactions.push(tx(transactionID('offbudget'), 'savings', pick(expenseIDs), dateIn(pick(sheetMonths)), -between(500, 20000)));
  }
  if (leapWindow) {
    transactions.push(tx('groceries-leap-day', 'checking', 'groceries', '2028-02-29', -between(500, 20000)));
  }

  const budgetRows = new Map();
  const setRow = (month, category, amount, carry) => {
    budgetRows.set(`${month}|${category}`, row(month, category, amount, carry));
  };
  for (const month of sheetMonths) {
    for (const id of expenseIDs) {
      const amount = chance(0.35) ? between(0, 80000) : 0;
      const carry = chance(0.2);
      if (amount !== 0 || carry) setRow(month, id, amount, carry);
    }
  }
  if (chance(0.15)) setRow(pick(sheetMonths), 'salary', 0, true);
  const buffers = windowMonths
    .filter(() => chance(0.25))
    .map(month => ({ month, buffered: between(0, 20000) }));

  const steps = [];
  const stepCount = between(4, 9);
  const expenseMonth = () => pick(windowMonths);
  for (let count = 0; count < stepCount; count += 1) {
    const roll = rng();
    if (roll < 0.25) {
      steps.push(assign(expenseMonth(), pick(expenseIDs), between(0, 90000)));
    } else if (roll < 0.4) {
      const fromBudget = chance(0.15);
      const from = fromBudget ? 'to-budget' : pick(expenseIDs);
      const toBudget = !fromBudget && chance(0.15);
      const to = toBudget ? 'to-budget' : pick(expenseIDs.filter(id => id !== from));
      steps.push(move(expenseMonth(), from, to, between(0, 60000)));
    } else if (roll < 0.5) {
      steps.push(transferAvailable(expenseMonth(), pick(expenseIDs), between(0, 150000)));
    } else if (roll < 0.65) {
      const to = pick(expenseIDs);
      const from = chance(0.5) ? 'to-budget' : pick(expenseIDs.filter(id => id !== to));
      steps.push(cover(expenseMonth(), to, from, chance(0.5) ? undefined : between(1, 40000)));
    } else if (roll < 0.75) {
      const category = chance(0.85) ? pick(expenseIDs) : 'salary';
      steps.push(carryover(expenseMonth(), category, chance(0.5)));
    } else if (roll < 0.87) {
      steps.push(...holdSteps(expenseMonth(), between(0, 120000)));
    } else if (roll < 0.93) {
      steps.push(resetHold(expenseMonth()));
    } else {
      steps.push(resetIncome(expenseMonth()));
    }
  }

  return {
    id: `generated-${String(index + 1).padStart(3, '0')}-${windowStart}`,
    source: 'generated',
    description: `Generated ${windowStart} window: ${expenseIDs.length} expense categories, ${steps.length} steps (case seed ${caseSeed}).`,
    seed: caseSeed,
    oracleOnly: null,
    setup: setup({
      groups,
      categories,
      transactions,
      budgets: [...budgetRows.values()],
      buffers,
    }),
    sheetMonths,
    steps,
    expectations: [],
  };
}

export function buildPlan() {
  const master = mulberry32(SEED);
  const generated = [];
  for (let index = 0; index < GENERATED_CASE_COUNT; index += 1) {
    generated.push(generatedCase(index, Math.floor(master() * 4294967296)));
  }
  return { seed: SEED, today: TODAY, cases: [...namedCases(), ...generated] };
}

export function oracleOnlyEntries(plan) {
  return plan.cases
    .filter(planCase => planCase.oracleOnly !== null)
    .map(planCase => ({ id: planCase.id, reason: planCase.oracleOnly }));
}

function valueAt(node, path) {
  return path.split('.').reduce((current, key) => (current == null ? undefined : current[key]), node);
}

// Checks the author's expectations and step errors against a recorded case. The
// expectations are sanity checks on how the setup was read, not stored results.
export function expectationFailures(record, planCase) {
  const failures = [];
  record.steps.forEach((step, index) => {
    if (step.error !== null && !planCase.steps[index]?.expectError) {
      failures.push(`step ${index} ${step.handler} failed: ${step.error}`);
    }
  });
  for (const expectation of planCase.expectations) {
    let actual;
    if (expectation.at === 'returned') {
      actual = record.steps[expectation.step]?.returned;
    } else {
      const states = expectation.at === 'before' ? record.before : record.expected;
      actual = valueAt(states.find(state => state.month === expectation.month), expectation.path);
    }
    if (actual !== expectation.equals) {
      const where = expectation.at === 'returned'
        ? `step ${expectation.step} returned`
        : `${expectation.at} ${expectation.month} ${expectation.path}`;
      failures.push(`${where}: expected ${JSON.stringify(expectation.equals)}, got ${JSON.stringify(actual)}`);
    }
  }
  return failures;
}
