#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertPinnedOracle,
  hasOracleRoot,
  oraclePin,
  ORACLE_ROOT_VARIABLE,
  pinnedFixtureDirectory,
  pinnedOracleRoot,
} from '../parity/lib/oracle-pin.mjs';
import { compareWithCommitted } from '../parity/lib/fixture-diff.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const harnessPath = 'scripts/template-apply-parity/harness/template-apply-parity.test.ts';
const helperPaths = ['scripts/parity/lib/oracle-pin.mjs', 'scripts/parity/lib/fixture-diff.mjs'];
const upstreamPaths = [
  'packages/loot-core/src/server/budget/goal-template.ts',
  'packages/loot-core/src/server/budget/goal-template.pegjs',
  'packages/loot-core/src/server/budget/template-notes.ts',
  'packages/loot-core/src/server/budget/template-notification.ts',
  'packages/loot-core/src/server/budget/category-template-context.ts',
  'packages/loot-core/src/server/budget/schedule-template.ts',
  'packages/loot-core/src/server/budget/statements.ts',
  'packages/loot-core/src/server/budget/actions.ts',
  'packages/loot-core/src/server/budget/base.ts',
  'packages/loot-core/src/server/budget/app.ts',
  'packages/loot-core/src/server/budget/envelope.ts',
  'packages/loot-core/src/server/budget/tracking.ts',
  'packages/loot-core/src/server/schedules/app.ts',
  'packages/loot-core/src/server/transactions/transaction-rules.ts',
  'packages/loot-core/src/shared/schedules.ts',
  'packages/loot-core/src/shared/months.ts',
  'packages/loot-core/src/shared/util.ts',
  'packages/loot-core/src/types/models/templates.ts',
  'packages/loot-core/src/mocks/setup.ts',
  'packages/loot-core/src/server/main.ts',
  'packages/loot-core/src/server/mutators.ts',
  'packages/loot-core/src/server/sheet.ts',
  'packages/loot-core/src/server/db/index.ts',
  'packages/loot-core/src/server/sync/index.ts',
  'vitest.config.ts',
];
const EXPECTED_TAG = oraclePin.tag;
const EXPECTED_COMMIT = oraclePin.commit;
const EXPECTED_VERSION = oraclePin.packageVersion;
const SCHEMA_VERSION = 1;
const SEED = 20261011;
const CURRENT_MONTH = '2026-10';
const GENERATED_PER_COMBINATION = 3;
const contractName = 'template-apply-contract.json';
const manifestName = 'template-apply-manifest.json';

const FAMILIES = ['fixed', 'priority', 'schedule', 'average-copy', 'percent', 'remainder', 'goal-by', 'limit-refill'];
const FUNDING_STATES = ['above', 'below', 'exact', 'zero', 'negative'];
const OPERATION_MONTHS = ['2026-10', '2026-11', '2026-12', '2027-01'];
// Excluding cases (budget/apply-multiple-templates over a computed subset) use
// their own random stream so the 135 earlier cases keep their content.
const EXCLUDING_SEED = SEED + 1;
const EXCLUDING_FAMILIES = ['fixed', 'priority', 'remainder', 'percent'];

if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${EXPECTED_TAG}.`);
  process.exit(2);
}
const checking = process.argv.includes('--check');
const checkout = pinnedOracleRoot();
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-template-apply-check-'))
  : resolve(argument('--output') ?? pinnedFixtureDirectory('TemplateApply'));

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function run(command, args, cwd = checkout, environment = process.env) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', env: environment });
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw new Error(`${command} ${args.join(' ')} failed with status ${result.status}`);
  }
  return result.stdout.trim();
}

// Seeded so the case list is identical on every run; the seed is recorded in the manifest.
function createRandom(seed) {
  let state = seed >>> 0;
  const next = () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    int: (low, high) => low + Math.floor(next() * (high - low + 1)),
    pick: list => list[Math.floor(next() * list.length)],
    chance: probability => next() < probability,
  };
}

function addMonths(month, delta) {
  const [year, monthNumber] = month.split('-').map(Number);
  const total = year * 12 + (monthNumber - 1) + delta;
  return `${Math.floor(total / 12)}-${String((total % 12) + 1).padStart(2, '0')}`;
}

// Contiguous window from 14 months before today through the operation month plus two.
function windowFor(operationMonth) {
  const months = [];
  for (let month = addMonths(CURRENT_MONTH, -14); month <= addMonths(operationMonth, 2); month = addMonths(month, 1)) {
    months.push(month);
  }
  return months;
}

function baseCase({ id, description, family, operation, funding, budgetType = 'envelope', currency = 'USD' }) {
  return {
    id,
    description,
    family,
    budgetType,
    currency,
    operation,
    funding,
    months: windowFor(operation.month),
    incomeCategory: 'cat-salary',
    accounts: [{ id: 'acc-checking', name: 'Synthetic Checking', offbudget: 0 }],
    groups: [
      { id: 'grp-income', name: 'Synthetic Income', is_income: 1 },
      { id: 'grp-expenses', name: 'Synthetic Expenses', is_income: 0 },
    ],
    categories: [
      { id: 'cat-salary', name: 'Synthetic Salary', group: 'grp-income', is_income: 1 },
      { id: 'cat-rent', name: 'Synthetic Rent', group: 'grp-expenses', is_income: 0 },
      { id: 'cat-groceries', name: 'Synthetic Groceries', group: 'grp-expenses', is_income: 0 },
      { id: 'cat-utilities', name: 'Synthetic Utilities', group: 'grp-expenses', is_income: 0 },
      { id: 'cat-fun', name: 'Synthetic Fun', group: 'grp-expenses', is_income: 0 },
      { id: 'cat-savings', name: 'Synthetic Savings', group: 'grp-expenses', is_income: 0 },
    ],
    transactions: [],
    schedules: [],
    budgets: [],
    orphanGoals: [],
    buffered: [],
    notes: [],
    storedGoals: [],
    sortOrders: [],
  };
}

// Stored (UI-sourced) template definitions, so excluding cases do not depend on
// note regeneration.
const ui = {
  simple: (monthly, priority = 0) => ({ type: 'simple', monthly, priority, directive: 'template' }),
  remainder: weight => ({ type: 'remainder', weight, priority: null, directive: 'template' }),
  percentage: (percent, priority = 0) => ({
    type: 'percentage', percent, previous: true, category: 'cat-salary', priority, directive: 'template',
  }),
  schedule: (name, priority = 0) => ({ type: 'schedule', name, priority, directive: 'template', full: false }),
};

function store(c, category, ...templates) {
  c.storedGoals.push({ category, source: 'ui', templates });
}

function note(c, category, text) {
  c.notes.push({ category, text });
}

function addSpend(c, category, month, amount) {
  c.transactions.push({
    id: `txn-spend-${category}-${month}`,
    account: 'acc-checking',
    date: `${month}-10`,
    amount: -amount,
    category,
  });
}

function addPreviousIncome(c, operationMonth, amount) {
  const month = addMonths(operationMonth, -1);
  c.transactions.push({
    id: `txn-income-${month}`,
    account: 'acc-checking',
    date: `${month}-01`,
    amount,
    category: 'cat-salary',
  });
}

const HISTORY_MONTHS = ['2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09'];

// Each family writes the template shapes Actual reads: note syntax for typed
// notes, and UI goal_def JSON (stored through the upstream setter) for shapes
// notes cannot express. Amounts in notes and UI templates are display units.
const familyBuilders = {
  fixed(rng, c) {
    note(c, 'cat-rent', `#template ${rng.int(500, 2500)}${rng.pick(['', '.50', '.25'])}`);
    note(c, 'cat-groceries', `#template ${rng.int(50, 600)}`);
  },
  priority(rng, c) {
    note(c, 'cat-rent', `#template-1 ${rng.int(500, 1500)}`);
    note(c, 'cat-groceries', `#template-2 ${rng.int(200, 900)}`);
    note(c, 'cat-utilities', `#template-3 ${rng.int(50, 400)}`);
  },
  schedule(rng, c) {
    c.schedules.push({
      id: 'sch-rent',
      name: 'Rent',
      completed: false,
      recur: { start: '2026-01-01', frequency: 'monthly', interval: 1 },
      amount: -rng.int(60000, 150000),
    });
    const full = rng.pick(['', 'full ']);
    const modifier = rng.pick(['', ' [increase 10%]', ' [decrease 5%]']);
    note(c, 'cat-rent', `#template schedule ${full}Rent${modifier}`);
  },
  'average-copy'(rng, c) {
    note(c, 'cat-groceries', `#template average ${rng.pick([3, 6])} months`);
    note(c, 'cat-fun', `#template copy from ${rng.int(1, 3)} months ago`);
    for (const month of HISTORY_MONTHS) {
      if (rng.chance(0.8)) addSpend(c, 'cat-groceries', month, rng.int(5000, 30000));
      if (rng.chance(0.8)) addSpend(c, 'cat-fun', month, rng.int(1000, 20000));
    }
  },
  percent(rng, c, operationMonth) {
    note(c, 'cat-savings', `#template ${rng.pick([5, 10, 15, 20, 25, 50])}% of previous Synthetic Salary`);
    addPreviousIncome(c, operationMonth, rng.int(200000, 450000));
  },
  remainder(rng, c) {
    note(c, 'cat-savings', `#template remainder ${rng.int(1, 3)}`);
    note(c, 'cat-fun', `#template remainder ${rng.int(1, 3)}`);
    note(c, 'cat-groceries', `#template ${rng.int(100, 500)}`);
  },
  'goal-by'(rng, c) {
    note(c, 'cat-rent', `#template ${rng.int(500, 3000)} by 2027-06 spend from 2026-06 repeat every month`);
    note(c, 'cat-utilities', `#template ${rng.int(50, 300)} repeat every 1 months starting 2026-04-01`);
    note(c, 'cat-fun', `#goal ${rng.int(10, 500)}`);
    for (const month of HISTORY_MONTHS.slice(2)) {
      if (rng.chance(0.7)) addSpend(c, 'cat-rent', month, rng.int(10000, 60000));
    }
  },
  'limit-refill'(rng, c) {
    c.storedGoals.push({
      category: 'cat-utilities',
      source: 'ui',
      templates: [
        { type: 'limit', amount: rng.int(50, 300), hold: false, period: 'monthly', directive: 'template', priority: null },
        { type: 'refill', priority: 1, directive: 'template' },
      ],
    });
    note(c, 'cat-groceries', `#template-2 ${rng.int(100, 400)}`);
    note(c, 'cat-fun', `#template 0 up to ${rng.int(100, 300)}`);
  },
};

function namedCases() {
  const cases = [];
  const named = (name, description, options, build) => {
    const c = baseCase({ id: `tapply-named-${name}`, description, ...options });
    if (build) build(c);
    cases.push(c);
  };
  const exactFunding = { state: 'exact', delta: 0 };
  const apply = month => ({ kind: 'apply', month });

  named('ended-schedule', 'A schedule template points at a completed schedule.', {
    family: 'schedule', operation: apply('2026-11'), funding: exactFunding,
  }, c => {
    c.schedules.push({
      id: 'sch-gym', name: 'Old Gym', completed: true,
      recur: { start: '2025-01-01', frequency: 'monthly', interval: 1 }, amount: -4500,
    });
    note(c, 'cat-rent', '#template schedule Old Gym');
    note(c, 'cat-groceries', '#template 300');
  });

  named('deleted-category', 'A deleted category with a template note is excluded from the run.', {
    family: 'fixed', operation: apply('2026-11'), funding: exactFunding,
  }, c => {
    c.categories.push({ id: 'cat-deleted', name: 'Synthetic Retired', group: 'grp-expenses', is_income: 0, deleted: true });
    note(c, 'cat-deleted', '#template 200');
    note(c, 'cat-rent', '#template 900');
  });

  named('priority-clamp', 'Priority templates exceed To Budget, so the lowest priority is clamped.', {
    family: 'priority', operation: apply('2026-11'), funding: { state: 'below', delta: 150000 },
  }, c => {
    note(c, 'cat-rent', '#template-1 1000');
    note(c, 'cat-groceries', '#template-2 800');
    note(c, 'cat-utilities', '#template-3 600');
  });

  named('average-missing-months', 'An average over six months with spending in only two of them.', {
    family: 'average-copy', operation: apply('2026-11'), funding: exactFunding,
  }, c => {
    note(c, 'cat-groceries', '#template average 6 months');
    addSpend(c, 'cat-groceries', '2026-04', 12000);
    addSpend(c, 'cat-groceries', '2026-08', 9000);
  });

  named('yearly-sinking-fund', 'A yearly periodic template divided across months.', {
    family: 'goal-by', operation: apply('2026-11'), funding: exactFunding,
  }, c => {
    note(c, 'cat-savings', '#template 1200 repeat every 1 years starting 2026-04-01');
  });

  named('schedule-by-id', 'A UI schedule template links to a schedule by id rather than by name.', {
    family: 'schedule', operation: apply('2026-11'), funding: exactFunding,
  }, c => {
    c.schedules.push({
      id: 'sch-rent', name: 'Rent', completed: false,
      recur: { start: '2026-01-01', frequency: 'monthly', interval: 1 }, amount: -95000,
    });
    c.storedGoals.push({
      category: 'cat-rent',
      source: 'ui',
      templates: [{ type: 'schedule', name: 'Rent', scheduleId: 'sch-rent', priority: 1, directive: 'template', full: false }],
    });
  });

  named('stale-note-goal-def', 'A notes-sourced goal definition with no matching template note is cleared.', {
    family: 'fixed', operation: apply('2026-11'), funding: exactFunding,
  }, c => {
    c.storedGoals.push({
      category: 'cat-rent',
      source: 'notes',
      templates: [{ type: 'simple', monthly: 500, limit: null, priority: null, directive: 'template' }],
    });
    note(c, 'cat-groceries', '#template 300');
  });

  named('tracking-budget', 'Templates in a tracking budget fund from total saved.', {
    family: 'fixed', operation: apply('2026-11'), funding: { state: 'above', delta: 20000 }, budgetType: 'tracking',
  }, c => {
    note(c, 'cat-rent', '#template 500');
    note(c, 'cat-groceries', '#template-2 300');
  });

  named('jpy-currency', 'Templates in a zero-decimal currency.', {
    family: 'fixed', operation: apply('2026-11'), funding: exactFunding, currency: 'JPY',
  }, c => {
    note(c, 'cat-rent', '#template 150000');
    note(c, 'cat-groceries', '#template 42000');
  });

  named('leap-year-periodic', 'A monthly periodic template across the February 2028 leap day.', {
    family: 'goal-by', operation: apply('2028-02'), funding: exactFunding,
  }, c => {
    note(c, 'cat-utilities', '#template 75 repeat every 1 months starting 2027-12-01');
    note(c, 'cat-rent', '#template 900');
  });

  named('year-boundary-by', 'A by-date spend template evaluated in January, across the year boundary.', {
    family: 'goal-by', operation: apply('2027-01'), funding: { state: 'above', delta: 5000 },
  }, c => {
    note(c, 'cat-rent', '#template 500 by 2027-06 spend from 2026-07 repeat every month');
    note(c, 'cat-groceries', '#template 250');
  });

  named('overwrite-existing-budget', 'Overwrite replaces a category that already has a budget.', {
    family: 'fixed', operation: { kind: 'overwrite', month: '2026-11' }, funding: exactFunding,
  }, c => {
    c.budgets.push({ category: 'cat-groceries', month: '2026-11', amount: 12345 });
    note(c, 'cat-groceries', '#template 300');
    note(c, 'cat-rent', '#template 900');
  });

  named('apply-skips-budgeted', 'Apply leaves a category that already has a budget unchanged.', {
    family: 'fixed', operation: apply('2026-11'), funding: exactFunding,
  }, c => {
    c.budgets.push({ category: 'cat-groceries', month: '2026-11', amount: 25000 });
    note(c, 'cat-groceries', '#template 300');
    note(c, 'cat-rent', '#template 900');
  });

  named('no-templates', 'Apply with no template definitions reports up to date.', {
    family: 'fixed', operation: apply('2026-11'), funding: exactFunding,
  });

  named('orphan-goal-reset', 'A stored goal with no template definition is reset.', {
    family: 'fixed', operation: apply('2026-11'), funding: exactFunding,
  }, c => {
    c.orphanGoals.push({ category: 'cat-fun', month: '2026-11', goal: 50000 });
    note(c, 'cat-rent', '#template 300');
  });

  return cases;
}

// Subset applies through budget/apply-multiple-templates. Every definition is a
// stored UI definition. The excluded category list is fixed per case; the
// harness derives the handler's category list from the seeded state.
function excludingNamedCases() {
  const cases = [];
  const named = (name, description, options, build) => {
    const c = baseCase({ id: `tapply-named-excluding-${name}`, description, family: 'fixed', ...options });
    build(c);
    cases.push(c);
  };
  const exactFunding = { state: 'exact', delta: 0 };
  const overwrite = (excluded, month = '2026-11') => ({
    kind: 'overwrite-excluding', month, excludedCategoryIds: excluded,
  });
  const fillEmpty = (excluded, month = '2026-11') => ({
    kind: 'fill-empty-excluding', month, excludedCategoryIds: excluded,
  });

  named('priority-levels', 'Two priority levels with the higher-priority category excluded.', {
    family: 'priority', operation: overwrite(['cat-rent']), funding: { state: 'below', delta: 30000 },
  }, c => {
    store(c, 'cat-rent', ui.simple(1000, 1));
    store(c, 'cat-groceries', ui.simple(800, 2));
    store(c, 'cat-utilities', ui.simple(300, 2));
    store(c, 'cat-fun', ui.simple(200, 3));
  });

  named('remainder-split', 'One remainder category is excluded and the others split the leftover.', {
    family: 'remainder', operation: overwrite(['cat-savings']), funding: { state: 'above', delta: 10001 },
  }, c => {
    store(c, 'cat-groceries', ui.simple(300));
    store(c, 'cat-savings', ui.remainder(2));
    store(c, 'cat-fun', ui.remainder(1));
    store(c, 'cat-utilities', ui.remainder(1));
  });

  named('budgeted-category', 'An excluded category keeps its existing budget, which stays spent from To Budget.', {
    operation: overwrite(['cat-groceries']), funding: { state: 'above', delta: 5000 },
  }, c => {
    c.budgets.push({ category: 'cat-groceries', month: '2026-11', amount: 12345 });
    store(c, 'cat-groceries', ui.simple(300));
    store(c, 'cat-rent', ui.simple(900));
    store(c, 'cat-fun', ui.remainder(1));
  });

  named('orphan-goals', 'A kept category with a stored goal and no template is reset; an excluded one is untouched.', {
    operation: overwrite(['cat-utilities']), funding: exactFunding,
  }, c => {
    c.orphanGoals.push({ category: 'cat-fun', month: '2026-11', goal: 50000 });
    c.orphanGoals.push({ category: 'cat-utilities', month: '2026-11', goal: 30000 });
    store(c, 'cat-rent', ui.simple(300));
    store(c, 'cat-groceries', ui.simple(200));
  });

  named('tracking-income', 'A tracking budget with its income category excluded.', {
    operation: overwrite(['cat-salary']), funding: { state: 'above', delta: 20000 }, budgetType: 'tracking',
  }, c => {
    store(c, 'cat-salary', ui.simple(400, 1));
    store(c, 'cat-rent', ui.simple(500, 1));
    store(c, 'cat-groceries', ui.simple(300, 2));
  });

  named('fill-empty-mixed', 'Fill Empty: a budgeted templated category is dropped from the list, an excluded empty one stays out.', {
    operation: fillEmpty(['cat-utilities']), funding: { state: 'above', delta: 7001 },
  }, c => {
    c.budgets.push({ category: 'cat-groceries', month: '2026-11', amount: 25000 });
    store(c, 'cat-rent', ui.simple(900, 1));
    store(c, 'cat-groceries', ui.simple(300, 1));
    store(c, 'cat-utilities', ui.simple(150, 2));
    store(c, 'cat-fun', ui.remainder(1));
  });

  named('priority-clamp', 'The excluded category would have consumed the To Budget headroom.', {
    family: 'priority', operation: overwrite(['cat-rent']), funding: { state: 'below', delta: 50000 },
  }, c => {
    store(c, 'cat-rent', ui.simple(1000, 1));
    store(c, 'cat-groceries', ui.simple(800, 2));
    store(c, 'cat-utilities', ui.simple(600, 3));
  });

  named('all-but-one', 'Every category except one is excluded.', {
    operation: overwrite(['cat-rent', 'cat-utilities', 'cat-fun', 'cat-savings']), funding: exactFunding,
  }, c => {
    store(c, 'cat-rent', ui.simple(900));
    store(c, 'cat-groceries', ui.simple(300));
    store(c, 'cat-utilities', ui.simple(150));
    store(c, 'cat-fun', ui.remainder(1));
    store(c, 'cat-savings', ui.simple(200));
  });

  // Actual rejects a schedule template that names no active schedule when it
  // builds the category's context, and one rejection aborts the whole run.
  named('invalid-template', 'A category with a template Actual rejects is excluded; the rest apply.', {
    family: 'schedule', operation: overwrite(['cat-utilities']), funding: exactFunding,
  }, c => {
    store(c, 'cat-utilities', ui.schedule('Missing Gym', 1));
    store(c, 'cat-rent', ui.simple(900, 1));
    store(c, 'cat-groceries', ui.simple(300, 2));
  });

  // Category order. The handler loads its categories ordered by sort_order, id
  // across all groups; the whole-month run walks groups first. Here the second
  // group's categories sort before the first group's, so the two orders differ.
  const reorder = c => {
    c.groups.push({ id: 'grp-extras', name: 'Synthetic Extras', is_income: 0 });
    for (const id of ['cat-fun', 'cat-savings']) c.categories.find(entry => entry.id === id).group = 'grp-extras';
    c.sortOrders = [
      { category: 'cat-fun', sortOrder: 100 },
      { category: 'cat-savings', sortOrder: 200 },
      { category: 'cat-rent', sortOrder: 1000 },
      { category: 'cat-groceries', sortOrder: 2000 },
      { category: 'cat-utilities', sortOrder: 3000 },
    ];
  };

  named('order-remainder', 'Remainder rounding across groups whose order differs from category sort order.', {
    family: 'remainder', operation: overwrite(['cat-savings']), funding: { state: 'above', delta: 10001 },
  }, c => {
    reorder(c);
    store(c, 'cat-groceries', ui.simple(300));
    store(c, 'cat-savings', ui.simple(200));
    store(c, 'cat-rent', ui.remainder(1));
    store(c, 'cat-utilities', ui.remainder(1));
    store(c, 'cat-fun', ui.remainder(1));
  });

  named('order-priority-clamp', 'Priority clamping across groups whose order differs from category sort order.', {
    family: 'priority', operation: overwrite(['cat-savings']), funding: { state: 'below', delta: 50000 },
  }, c => {
    reorder(c);
    store(c, 'cat-rent', ui.simple(1000, 1));
    store(c, 'cat-fun', ui.simple(800, 1));
    store(c, 'cat-groceries', ui.simple(300, 2));
    store(c, 'cat-savings', ui.simple(200, 1));
  });

  return cases;
}

const uiFamilyBuilders = {
  fixed(rng, c) {
    store(c, 'cat-rent', ui.simple(rng.int(500, 2500)));
    store(c, 'cat-groceries', ui.simple(rng.int(50, 600)));
    store(c, 'cat-fun', ui.simple(rng.int(20, 200)));
  },
  priority(rng, c) {
    store(c, 'cat-rent', ui.simple(rng.int(500, 1500), 1));
    store(c, 'cat-groceries', ui.simple(rng.int(200, 900), 2));
    store(c, 'cat-utilities', ui.simple(rng.int(50, 400), 2));
    store(c, 'cat-fun', ui.simple(rng.int(20, 200), 3));
  },
  remainder(rng, c) {
    store(c, 'cat-savings', ui.remainder(rng.int(1, 3)));
    store(c, 'cat-fun', ui.remainder(rng.int(1, 3)));
    store(c, 'cat-utilities', ui.remainder(rng.int(1, 3)));
    store(c, 'cat-groceries', ui.simple(rng.int(100, 500)));
  },
  percent(rng, c, operationMonth) {
    store(c, 'cat-savings', ui.percentage(rng.pick([5, 10, 15, 20, 25, 50])));
    store(c, 'cat-rent', ui.simple(rng.int(500, 1500)));
    addPreviousIncome(c, operationMonth, rng.int(200000, 450000));
  },
};

function excludingGeneratedCases() {
  const rng = createRandom(EXCLUDING_SEED);
  const scope = ['cat-rent', 'cat-groceries', 'cat-utilities', 'cat-fun', 'cat-savings'];
  const cases = [];
  for (const family of EXCLUDING_FAMILIES) {
    for (const state of FUNDING_STATES) {
      const operationMonth = rng.pick(OPERATION_MONTHS);
      const kind = rng.chance(0.5) ? 'overwrite-excluding' : 'fill-empty-excluding';
      const excluded = rng.pick(scope);
      const c = baseCase({
        id: `tapply-generated-excluding-${family}-${state}-1`,
        description: `Generated ${family} templates with ${state} To Budget and one category excluded.`,
        family,
        operation: { kind, month: operationMonth, excludedCategoryIds: [excluded] },
        funding: { state, delta: rng.int(500, 40000) },
      });
      uiFamilyBuilders[family](rng, c, operationMonth);
      if (rng.chance(kind === 'fill-empty-excluding' ? 0.7 : 0.3)) {
        const target = rng.pick(c.storedGoals.map(goal => goal.category));
        c.budgets.push({ category: target, month: operationMonth, amount: rng.int(1000, 5000) * 100 });
      }
      cases.push(c);
    }
  }
  return cases;
}

function generatedCases() {
  const rng = createRandom(SEED);
  const cases = [];
  for (const family of FAMILIES) {
    for (const state of FUNDING_STATES) {
      for (let index = 1; index <= GENERATED_PER_COMBINATION; index += 1) {
        const operationMonth = rng.pick(OPERATION_MONTHS);
        const kind = rng.chance(0.3) ? 'overwrite' : 'apply';
        const c = baseCase({
          id: `tapply-generated-${family}-${state}-${index}`,
          description: `Generated ${family} templates with ${state} To Budget.`,
          family,
          operation: { kind, month: operationMonth },
          funding: { state, delta: rng.int(500, 40000) },
        });
        familyBuilders[family](rng, c, operationMonth);
        if (rng.chance(0.2)) {
          const target = rng.pick(['cat-rent', 'cat-groceries', 'cat-savings']);
          c.budgets.push({ category: target, month: operationMonth, amount: rng.int(1000, 5000) * 100 });
        }
        cases.push(c);
      }
    }
  }
  return cases;
}

// Generated cases draw from one random stream; named cases are fixed.
const named = namedCases();
const generated = generatedCases();
const excludingNamed = excludingNamedCases();
const excludingGenerated = excludingGeneratedCases();
// The 135 earlier cases keep their position; excluding cases are appended.
const cases = [...named, ...generated, ...excludingNamed, ...excludingGenerated];
const caseIDs = cases.map(testCase => testCase.id);
if (new Set(caseIDs).size !== caseIDs.length) throw new Error('Duplicate template apply case ids');

const packageVersion = JSON.parse(
  readFileSync(join(checkout, 'packages/loot-core/package.json'), 'utf8'),
).version;
if (packageVersion !== EXPECTED_VERSION) {
  throw new Error(`Expected @actual-app/core ${EXPECTED_VERSION}, found ${packageVersion}`);
}

const sourceFiles = upstreamPaths.map(path => {
  const sourcePath = join(checkout, path);
  if (!existsSync(sourcePath)) throw new Error(`Pinned source is missing: ${path}`);
  return { path, sha256: sha256(readFileSync(sourcePath)) };
});

const runnerRelative = 'packages/loot-core/src/server/budget/__actualist_template_apply_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const specPath = join(checkout, '.actualist-template-apply-spec.json');
const outputFile = join(checkout, '.actualist-template-apply-output.json');
const dataDirectory = join(checkout, '.actualist-template-apply-data');
for (const path of [runnerPath, specPath, outputFile]) {
  if (existsSync(path)) throw new Error(`Refusing to overwrite ${relative(checkout, path)}`);
}

let runnerOutput;
const started = Date.now();
try {
  mkdirSync(dataDirectory, { recursive: true });
  writeFileSync(runnerPath, readFileSync(join(repositoryRoot, harnessPath)));
  writeFileSync(specPath, JSON.stringify({ currentMonth: CURRENT_MONTH, cases }, null, 2) + '\n');
  run(
    'node',
    ['.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/core', 'vitest', '--run', runnerRelative.replace('packages/loot-core/', '')],
    checkout,
    {
      ...process.env,
      ACTUAL_DATA_DIR: dataDirectory,
      ACTUALIST_TEMPLATE_APPLY_SPEC: specPath,
      ACTUALIST_TEMPLATE_APPLY_OUTPUT: outputFile,
    },
  );
  runnerOutput = readFileSync(outputFile);
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(specPath, { force: true });
  rmSync(outputFile, { force: true });
  rmSync(dataDirectory, { force: true, recursive: true });
}
const oracleSeconds = (Date.now() - started) / 1000;
assertPinnedOracle(checkout, 'after generating');

const recorded = JSON.parse(runnerOutput.toString('utf8'));
const recordedIDs = recorded.cases.map(testCase => testCase.id);
if (recordedIDs.length !== caseIDs.length || recordedIDs.some((id, index) => id !== caseIDs[index])) {
  throw new Error(`Oracle recorded ${recordedIDs.length} cases; expected ${caseIDs.length} in order`);
}

const contract = {
  schemaVersion: SCHEMA_VERSION,
  oracle: { tag: EXPECTED_TAG, commit: EXPECTED_COMMIT, packageVersion: EXPECTED_VERSION },
  syntheticData: {
    only: true,
    accountIDs: ['acc-checking'],
    categoryIDs: ['cat-salary', 'cat-rent', 'cat-groceries', 'cat-utilities', 'cat-fun', 'cat-savings'],
    currentMonth: CURRENT_MONTH,
  },
  cases: recorded.cases,
};
const contractData = Buffer.from(JSON.stringify(contract, null, 2) + '\n');

// Manifest paths name the pinned fixture location, never the temporary --check directory.
const fixtureDirectory = pinnedFixtureDirectory('TemplateApply');
const logicalPath = name => relative(repositoryRoot, join(fixtureDirectory, name));
const generatedFamilies = new Set(generated.map(testCase => `${testCase.family}/${testCase.funding.state}`));
const expectedCombinations = FAMILIES.flatMap(family => FUNDING_STATES.map(state => `${family}/${state}`));
if (expectedCombinations.some(combination => !generatedFamilies.has(combination))) {
  throw new Error('Generated cases do not cover every family and funding state');
}

mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, contractName), contractData);
const manifestText = JSON.stringify({
  schemaVersion: SCHEMA_VERSION,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/template-apply-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  harness: { path: harnessPath, sha256: sha256(readFileSync(join(repositoryRoot, harnessPath))) },
  helpers: helperPaths.map(path => ({ path, sha256: sha256(readFileSync(join(repositoryRoot, path))) })),
  seed: SEED,
  seedAlgorithm: 'mulberry32',
  currentMonth: CURRENT_MONTH,
  amountUnits: 'integer minor units; note and UI template amounts are display units',
  execution: 'Actual budget handlers through runHandler and the sheet, in a vitest run on the pinned checkout',
  scope: 'synthetic local SQLite only; no sync server',
  normalization: [
    'Actual mock uuid tokens (idN) are replaced by first-appearance placeholders per case',
    'Columns ending in _ts are dropped',
    'Rows are sorted by primary key',
    'Values are not rounded or converted; amounts are compared exactly',
  ],
  coverage: {
    families: FAMILIES,
    fundingStates: FUNDING_STATES,
    operationMonths: OPERATION_MONTHS,
    namedCaseIDs: named.map(testCase => testCase.id),
    generatedCaseCount: generated.length,
    namedCaseCount: named.length,
    excludingFamilies: EXCLUDING_FAMILIES,
    excludingSeed: EXCLUDING_SEED,
    excludingNamedCaseIDs: excludingNamed.map(testCase => testCase.id),
    excludingGeneratedCaseIDs: excludingGenerated.map(testCase => testCase.id),
  },
  caseCount: recorded.cases.length,
  upstreamSources: sourceFiles,
  fixtures: [{
    path: logicalPath(contractName),
    sha256: sha256(contractData),
    caseCount: recorded.cases.length,
    caseIDs,
  }],
  privacy: {
    syntheticOnly: true,
    containsServerCredentials: false,
    containsPersonalFinancialData: false,
  },
}, null, 2) + '\n';
writeFileSync(join(outputRoot, manifestName), manifestText);

if (checking) {
  const failures = compareWithCommitted(fixtureDirectory, outputRoot, [contractName, manifestName]);
  rmSync(outputRoot, { recursive: true, force: true });
  if (failures.length > 0) {
    for (const failure of failures) console.error(`template apply parity drift: ${failure}`);
    process.exit(1);
  }
  console.log(`Template apply parity fixtures match a fresh generation (${recorded.cases.length} cases).`);
} else {
  console.log(
    `Generated template apply parity fixture (${oraclePin.tag}, ${recorded.cases.length} cases, ${oracleSeconds.toFixed(1)} s oracle run).`,
  );
}
