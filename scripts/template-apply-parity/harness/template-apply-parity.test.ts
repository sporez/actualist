// @ts-strict-ignore
// Copied into the pinned Actual checkout for one generator run and removed afterwards.
// The generator writes the case specs to ACTUALIST_TEMPLATE_APPLY_SPEC and reads
// the recorded results from ACTUALIST_TEMPLATE_APPLY_OUTPUT.
import { readFileSync, writeFileSync } from 'node:fs';
import { test } from 'vitest';

import { aqlQuery } from '#server/aql';
import * as budget from '#server/budget/base';
import { dryRunCategoryTemplate } from '#server/budget/goal-template';
import { storeNoteTemplates } from '#server/budget/template-notes';
import * as db from '#server/db';
import { handlers } from '#server/main';
import { runHandler } from '#server/mutators';
import { createSchedule } from '#server/schedules/app';
import * as sheet from '#server/sheet';
import { setSyncingMode } from '#server/sync';
import { loadRules } from '#server/transactions/transaction-rules';
import * as monthUtils from '#shared/months';
import { q } from '#shared/query';

const DUMP_TABLES = [
  'category_groups',
  'categories',
  'category_mapping',
  'transactions',
  'accounts',
  'payees',
  'schedules',
  'rules',
  'schedules_next_date',
  'zero_budgets',
  'reflect_budgets',
  'zero_budget_months',
  'notes',
  'preferences',
];

const spec = JSON.parse(readFileSync(process.env.ACTUALIST_TEMPLATE_APPLY_SPEC, 'utf8'));
const outputPath = process.env.ACTUALIST_TEMPLATE_APPLY_OUTPUT;

async function resetDatabase() {
  if (sheet.get()) {
    await sheet.waitOnSpreadsheet();
    sheet.unloadSpreadsheet();
  }
  setSyncingMode('disabled');
  await global.emptyDatabase()();
}

function yearMonth(month) {
  return Number(month.replace('-', ''));
}

async function seedCase(testCase) {
  await resetDatabase();
  if (testCase.budgetType !== 'envelope') {
    db.runQuery("INSERT OR REPLACE INTO preferences (id, value) VALUES ('budgetType', ?)", [
      testCase.budgetType,
    ]);
  }
  if (testCase.currency !== 'USD') {
    db.runQuery(
      "INSERT OR REPLACE INTO preferences (id, value) VALUES ('defaultCurrencyCode', ?)",
      [testCase.currency],
    );
  }
  for (const account of testCase.accounts) {
    await db.insertAccount(account);
  }
  for (const group of testCase.groups) {
    await db.insertCategoryGroup(group);
  }
  for (const category of testCase.categories) {
    await db.insertCategory({
      id: category.id,
      name: category.name,
      cat_group: category.group,
      is_income: category.is_income,
    });
    if (category.deleted) {
      db.runQuery('UPDATE categories SET tombstone = 1 WHERE id = ?', [category.id]);
    }
  }
  // Cases that need a global category order different from group order set it
  // here, after every insert has assigned its default sort_order.
  for (const entry of testCase.sortOrders ?? []) {
    db.runQuery('UPDATE categories SET sort_order = ? WHERE id = ?', [entry.sortOrder, entry.category]);
  }
  for (const transaction of testCase.transactions) {
    await db.insertTransaction({
      id: transaction.id,
      account: transaction.account,
      date: transaction.date,
      amount: transaction.amount,
      category: transaction.category,
      cleared: true,
    });
  }
  for (const schedule of testCase.schedules) {
    await createSchedule({
      schedule: { id: schedule.id, name: schedule.name, completed: schedule.completed ? 1 : 0 },
      conditions: [
        { op: 'isapprox', field: 'date', value: schedule.recur },
        { op: 'isapprox', field: 'amount', value: schedule.amount },
      ],
    });
  }
  // The budget-load path rebuilds the rule cache that schedule targets read.
  await loadRules();
  const budgetTable = testCase.budgetType === 'tracking' ? 'reflect_budgets' : 'zero_budgets';
  for (const row of testCase.budgets) {
    await db.insert(budgetTable, {
      id: `${yearMonth(row.month)}-${row.category}`,
      month: yearMonth(row.month),
      category: row.category,
      amount: row.amount,
      carryover: 0,
    });
  }
  for (const row of testCase.orphanGoals) {
    await db.insert(budgetTable, {
      id: `${yearMonth(row.month)}-${row.category}`,
      month: yearMonth(row.month),
      category: row.category,
      amount: 0,
      carryover: 0,
      goal: row.goal,
      long_goal: null,
    });
  }
  for (const row of testCase.buffered) {
    await db.insert('zero_budget_months', { id: row.month, buffered: row.amount });
  }
  for (const note of testCase.notes) {
    await db.insert('notes', { id: note.category, note: note.text });
  }
  for (const goal of testCase.storedGoals) {
    await runHandler(
      handlers['budget/set-category-automations'],
      {
        categoriesWithTemplates: [{ id: goal.category, templates: goal.templates }],
        source: goal.source,
      },
      { name: 'budget/set-category-automations' },
    );
  }
}

async function loadSheet(testCase) {
  if (sheet.get()) {
    await sheet.waitOnSpreadsheet();
    sheet.unloadSpreadsheet();
  }
  await sheet.loadSpreadsheet(db);
  if (testCase.budgetType !== 'envelope') {
    sheet.get().meta().budgetType = testCase.budgetType;
  }
  await budget.createBudget(testCase.months);
  await sheet.waitOnSpreadsheet();
}

function balanceCell(testCase) {
  return testCase.budgetType === 'tracking' ? 'total-saved' : 'to-budget';
}

function cellValue(month, name) {
  try {
    const value = sheet.getCell(monthUtils.sheetForMonth(month), name).value;
    return typeof value === 'number' ? value : null;
  } catch {
    return null;
  }
}

function readCategoryState(testCase, month) {
  return testCase.categories
    .filter(category => !category.is_income)
    .map(category => ({
      category: category.id,
      budget: cellValue(month, `budget-${category.id}`),
      goal: cellValue(month, `goal-${category.id}`),
      longGoal: cellValue(month, `long-goal-${category.id}`),
    }));
}

// Demand is what the operation would budget before the priority clamp, so the
// funding target can be placed relative to it. Remainder and goal-only
// categories do not draw on To Budget in the same way and are left out.
async function demandFor(testCase, scopeIDs) {
  const month = testCase.operation.month;
  const rows = await db.all(
    'SELECT id, goal_def, is_income FROM categories WHERE goal_def IS NOT NULL AND tombstone = 0',
  );
  let total = 0;
  for (const row of rows) {
    if (row.is_income && testCase.budgetType !== 'tracking') continue;
    if (scopeIDs !== null && !scopeIDs.includes(row.id)) continue;
    const templates = JSON.parse(row.goal_def);
    if (templates.some(template => template.type === 'remainder')) continue;
    if (templates.every(template => template.type === 'goal')) continue;
    const budgeted = cellValue(month, `budget-${row.id}`) ?? 0;
    if (!forces(testCase) && budgeted !== 0) continue;
    const result = await dryRunCategoryTemplate({ month, categoryId: row.id, templates });
    total += result.budgeted;
  }
  return total;
}

function isExcluding(testCase) {
  return testCase.operation.kind.endsWith('-excluding');
}

// Overwrite and the subset handler (force = true) replace existing budgets.
function forces(testCase) {
  return testCase.operation.kind === 'overwrite' || isExcluding(testCase);
}

// The categories Actual's whole-month apply iterates (goal-template.ts
// getCategories plus the computeTemplates filter), in the same order: visible
// groups in group order, visible categories within each group.
async function wholeMonthScope(testCase) {
  const { data: groups } = await aqlQuery(q('category_groups').filter({ hidden: false }).select('*'));
  const tracking = testCase.budgetType === 'tracking';
  return groups
    .flatMap(group => group.categories || [])
    .filter(category => !category.hidden)
    .filter(category => tracking || !category.is_income)
    .map(category => category.id);
}

// The exact list handed to budget/apply-multiple-templates: the whole-month
// scope minus the skipped categories. For fill-empty-excluding, categories that
// have a stored template and a nonzero budget are also removed, because plain
// apply skips them but the subset handler (force = true) would overwrite them.
// Needs the template definitions stored (call after storeNoteTemplates) and a
// loaded sheet. An empty list would make Actual process every category.
async function subsetCategoryIds(testCase) {
  const scope = await wholeMonthScope(testCase);
  const excluded = testCase.operation.excludedCategoryIds;
  for (const id of excluded) {
    if (!scope.includes(id)) throw new Error(`${testCase.id}: excluded ${id} is not in the whole-month scope`);
  }
  let ids = scope.filter(id => !excluded.includes(id));
  if (testCase.operation.kind === 'fill-empty-excluding') {
    const templated = new Set(
      (await db.all('SELECT id FROM categories WHERE goal_def IS NOT NULL AND tombstone = 0')).map(row => row.id),
    );
    ids = ids.filter(
      id => !(templated.has(id) && (cellValue(testCase.operation.month, `budget-${id}`) ?? 0) !== 0),
    );
  }
  if (ids.length === 0) throw new Error(`${testCase.id}: the subset is empty`);
  return ids;
}

function fundingTarget(funding, demand) {
  switch (funding.state) {
    case 'above':
      return demand + funding.delta;
    case 'below':
      return demand - funding.delta;
    case 'exact':
      return demand;
    case 'zero':
      return 0;
    case 'negative':
      return -funding.delta;
    default:
      throw new Error(`Unknown funding state ${funding.state}`);
  }
}

// Fixes To Budget (or tracking total saved) at the target by adding one income
// transaction in the operation month. Demand is measured first, so the solved
// amount is exact for these fixtures; the sheet is reloaded and checked after.
async function solveFunding(testCase) {
  const month = testCase.operation.month;
  const name = balanceCell(testCase);
  const snapshot = await db.all('SELECT id, goal_def, template_settings, cleanup_def FROM categories');
  await storeNoteTemplates();
  const windowIDs = isExcluding(testCase) ? await subsetCategoryIds(testCase) : null;
  const demand = await demandFor(testCase, windowIDs);
  const probe = cellValue(month, name);
  if (probe === null) throw new Error(`${testCase.id}: no ${name} cell for ${month}`);
  for (const row of snapshot) {
    db.runQuery(
      'UPDATE categories SET goal_def = ?, template_settings = ?, cleanup_def = ? WHERE id = ?',
      [row.goal_def, row.template_settings, row.cleanup_def, row.id],
    );
  }
  const target = fundingTarget(testCase.funding, demand);
  const needed = target - probe;
  if (needed !== 0 && testCase.budgetType === 'tracking') {
    // Tracking total saved is budgeted income minus budgeted spending, so funding
    // is an income budget row rather than a transaction.
    await db.insert('reflect_budgets', {
      id: `${yearMonth(month)}-${testCase.incomeCategory}`,
      month: yearMonth(month),
      category: testCase.incomeCategory,
      amount: needed,
      carryover: 0,
    });
  } else if (needed !== 0) {
    await db.insertTransaction({
      id: 'txn-funding',
      account: 'acc-checking',
      date: `${month}-15`,
      amount: needed,
      category: testCase.incomeCategory,
      cleared: true,
    });
  }
  await loadSheet(testCase);
  const solved = cellValue(month, name);
  if (solved !== target) {
    throw new Error(`${testCase.id}: funding solved to ${solved}, expected ${target}`);
  }
  if (windowIDs !== null) {
    const finalIDs = await subsetCategoryIds(testCase);
    if (JSON.stringify(finalIDs) !== JSON.stringify(windowIDs)) {
      throw new Error(`${testCase.id}: the subset changed while funding was solved`);
    }
  }
  return { state: testCase.funding.state, demand, probe, target, neededIncome: needed };
}

const DUMP_EXCLUDED_COLUMNS = /_ts$/;

async function dumpTables() {
  const tables = {};
  for (const table of DUMP_TABLES) {
    const info = await db.all(`PRAGMA table_info(${table})`);
    if (info.length === 0) throw new Error(`Missing table ${table}`);
    const columns = info.map(column => column.name).filter(name => !DUMP_EXCLUDED_COLUMNS.test(name));
    const keys = info
      .filter(column => column.pk > 0)
      .sort((a, b) => a.pk - b.pk)
      .map(column => column.name);
    const rows = await db.all(`SELECT ${columns.join(', ')} FROM ${table}`);
    const sortValue = row => keys.map(key => String(row[key] ?? '')).join('\u0000');
    rows.sort((a, b) => (sortValue(a) < sortValue(b) ? -1 : sortValue(a) > sortValue(b) ? 1 : 0));
    tables[table] = rows.map(row => Object.fromEntries(columns.map(column => [column, row[column] ?? null])));
  }
  return tables;
}

async function persistedBudgetRows(testCase) {
  const table = testCase.budgetType === 'tracking' ? 'reflect_budgets' : 'zero_budgets';
  const rows = await db.all(`SELECT * FROM ${table} WHERE month = ?`, [yearMonth(testCase.operation.month)]);
  return rows
    .map(row => Object.fromEntries(Object.entries(row).filter(([key]) => !DUMP_EXCLUDED_COLUMNS.test(key))))
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

async function goalDefinitions() {
  const rows = await db.all('SELECT id, goal_def, template_settings FROM categories ORDER BY id');
  return rows.map(row => ({
    id: row.id,
    goalDef: row.goal_def === null ? null : JSON.parse(row.goal_def),
    templateSettings: row.template_settings === null ? null : JSON.parse(row.template_settings),
  }));
}

async function runCase(testCase) {
  global.currentMonth = spec.currentMonth;
  await seedCase(testCase);
  await loadSheet(testCase);
  const funding = await solveFunding(testCase);
  const input = await dumpTables();
  const before = {
    balance: cellValue(testCase.operation.month, balanceCell(testCase)),
    categories: readCategoryState(testCase, testCase.operation.month),
  };

  let handlerName =
    testCase.operation.kind === 'overwrite'
      ? 'budget/overwrite-goal-template'
      : 'budget/apply-goal-template';
  let handlerArguments = { month: testCase.operation.month };
  let operation = testCase.operation;
  let order = null;
  if (isExcluding(testCase)) {
    // Excluding cases must use stored (UI) definitions: the subset is computed
    // twice around the note-template store/restore of the funding step.
    const categoryIds = await subsetCategoryIds(testCase);
    handlerName = 'budget/apply-multiple-templates';
    handlerArguments = { month: testCase.operation.month, categoryIds };
    operation = { ...testCase.operation, categoryIds };
    // The handler loads its categories with its own query, so the order it
    // iterates in can differ from the whole-month order the list was built in.
    const { data: handlerCategories } = await aqlQuery(
      q('categories').filter({ id: { $oneof: categoryIds } }).select('id'),
    );
    order = { wholeMonth: categoryIds, handler: handlerCategories.map(row => row.id) };
  }
  let returned = null;
  let error = null;
  try {
    returned = await runHandler(handlers[handlerName], handlerArguments, { name: handlerName });
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  }
  await sheet.waitOnSpreadsheet();

  const expected = {
    notification: returned ?? null,
    error,
    balance: cellValue(testCase.operation.month, balanceCell(testCase)),
    categories: readCategoryState(testCase, testCase.operation.month),
    persistedBudgets: await persistedBudgetRows(testCase),
    goalDefinitions: await goalDefinitions(),
  };

  return {
    id: testCase.id,
    description: testCase.description,
    family: testCase.family,
    operation,
    ...(order === null ? {} : { order }),
    funding,
    input,
    before,
    expected,
  };
}

// Actual's mock uuid counter (idN) changes with the order of inserts, so every
// case canonicalizes those tokens to first-appearance placeholders.
function canonicalize(value) {
  const tokens = new Map();
  const text = JSON.stringify(value).replace(/\bid\d+\b/g, token => {
    if (!tokens.has(token)) tokens.set(token, `uuid-${tokens.size + 1}`);
    return tokens.get(token);
  });
  return JSON.parse(text);
}

test(
  'Actual template apply oracle',
  async () => {
    const results = [];
    for (const testCase of spec.cases) {
      if (typeof global.resetRandomId === 'function') global.resetRandomId();
      results.push(canonicalize(await runCase(testCase)));
    }
    writeFileSync(outputPath, JSON.stringify({ cases: results }, null, 2) + '\n');
  },
  60 * 60 * 1000,
);
