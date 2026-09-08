import { writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import vm from 'node:vm';

const root = process.argv[2];
if (!root) throw new Error('Usage: node scripts/tracking-parity/generate.mjs <Actual checkout>');
const commit = '59fe126f637d858c061e1eeedbef5436c8f2225a';
if (execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() !== commit) {
  throw new Error('Expected pinned Actual 26.9.0 checkout');
}
const path = 'packages/loot-core/src/server/budget/tracking.ts';
const source = execFileSync('git', ['-C', root, 'show', `${commit}:${path}`], { encoding: 'utf8' });
// Execute the upstream cell definitions with a minimal spreadsheet registry.
// Financial callbacks and dependencies are taken verbatim from the pinned source.
const cells = new Map();
const sheet = { get: () => ({
  createStatic() {}, getCellValue: () => 0, set() {},
  createDynamic: (name, key, definition) => cells.set(key, definition),
}) };
const number = value => typeof value === 'number' ? value : 0;
const context = vm.createContext({ sheet, number, safeNumber: n => {
    if (!Number.isInteger(n) || Math.abs(n) > 2 ** 51 - 1) throw new Error("Unsafe Actual amount");
    return n;
  },
  sumAmounts: (...values) => values.reduce((total, value) => total + number(value), 0) });
const body = source.slice(source.indexOf('export async function createCategory('), source.indexOf('export function handleCategoryChange('))
  .replaceAll('export ', '');
vm.runInContext(body, context);
const cases = [];
for (const isIncome of [false, true]) {
  await context.createCategory({ id: 'category', is_income: isIncome }, 'current', 'previous');
  const run = cells.get('leftover-category').run;
  for (const previousBalance of [-700, 0, 900]) {
    for (const previousCarryover of [false, true]) {
      for (const activity of [-300, 0, 400]) {
        cases.push({ isIncome, budgeted: 500, activity, previousBalance, previousCarryover,
          balance: run(500, activity, previousCarryover, previousBalance) });
      }
    }
  }
}
context.createCategoryGroup({ id: 'group', categories: [{ id: 'visible' }, { id: 'hidden', hidden: true }] }, 'current');
const groupDependencies = cells.get('group-budget-group').dependencies;
context.createSummary([{ id: 'income', is_income: true }, { id: 'expense' }, { id: 'hidden', hidden: true }], 'current');
const result = { commit, source: path, sha256: createHash('sha256').update(source).digest('hex'), cases,
  groupDependencies, expenseDependencies: cells.get('total-budgeted').dependencies,
  projectedSavings: cells.get('total-saved').run(1500, 500), actualSavings: cells.get('real-saved').run(1200, -300) };
writeFileSync('ActualistTests/Fixtures/ActualCore26_9_0/Tracking/contract.json', JSON.stringify(result, null, 2) + '\n');
console.log(`Generated ${cases.length} upstream recurrence cases`);
