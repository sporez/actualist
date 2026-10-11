#!/usr/bin/env node
// Executes the pinned editor functions with synthetic dates and reference lists.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';
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
const helperPath = join(repositoryRoot, 'scripts/parity/lib/oracle-pin.mjs');
const checking = process.argv.includes('--check');
if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const oracleRoot = pinnedOracleRoot();
const outputIndex = process.argv.indexOf('--output');
const destination = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-template-check-'))
  : resolve(outputIndex === -1 ? pinnedFixtureDirectory('Templates') : process.argv[outputIndex + 1]);
const commit = oraclePin.commit;
const paths = {
  migration: 'packages/desktop-client/src/components/modals/BudgetAutomationsModal/migrateTemplatesToAutomations.ts',
  reducer: 'packages/desktop-client/src/components/budget/goals/reducer.ts',
  validation: 'packages/desktop-client/src/components/budget/goals/validateAutomation.ts',
};
const hash = value => createHash('sha256').update(value).digest('hex');
const sources = Object.fromEntries(Object.entries(paths).map(([name, path]) => [name, execFileSync('git', ['show', `${commit}:${path}`], { cwd: oracleRoot, encoding: 'utf8' })]));
const sourceFiles = Object.entries(paths).map(([name, path]) => ({ path, sha256: hash(sources[name]) }));
const fixedDate = '2026-09-04T12:00:00.000Z';
class OracleDate extends Date { constructor(...args) { super(...(args.length ? args : [fixedDate])); } }
const monthFromDate = date => new Date(date).toISOString().slice(0, 7);
const ordinal = month => Number(month.slice(0, 4)) * 12 + Number(month.slice(5, 7)) - 1;
const adapters = {
  Date: OracleDate,
  currentDate: () => fixedDate,
  dayFromDate: date => new Date(date).toISOString().slice(0, 10),
  firstDayOfMonth: date => `${monthFromDate(date)}-01`,
  monthFromDate,
  addMonths: (month, count) => {
    const n = ordinal(month) + count;
    return `${Math.floor(n / 12)}-${String(n % 12 + 1).padStart(2, '0')}`;
  },
  createAutomationEntry: (template, displayType) => ({ template, displayType }),
  monthUtils: {
    monthFromDate,
    isValidYearMonth: value => /^\d{4}-(0[1-9]|1[0-2])$/.test(value),
    differenceInCalendarMonths: (a, b) => ordinal(a) - ordinal(b),
  },
};
function load(source, symbols) {
  const withoutImports = source.replace(/^import\s[\s\S]*?;\s*/gm, '');
  const js = stripTypeScriptTypes(withoutImports, { mode: 'strip' }).replace(/\bexport\s+/g, '');
  return new Function(...Object.keys(adapters), `${js}\nreturn {${symbols.join(',')}};`)(...Object.values(adapters));
}
const { migrateTemplatesToAutomations } = load(sources.migration, ['migrateTemplatesToAutomations']);
const { getInitialState, templateReducer } = load(sources.reducer, ['getInitialState', 'templateReducer']);
const { validateAutomation, validatePercentageAllocation, validateSchedulePriorities } = load(sources.validation, ['validateAutomation', 'validatePercentageAllocation', 'validateSchedulePriorities']);
const t = (type, properties = {}) => ({ directive: type === 'goal' ? 'goal' : 'template', type, ...properties });
const cap = { amount: 100, hold: false, period: 'monthly' };
const fixed = t('periodic', { amount: 400, period: { period: 'month', amount: 1 }, starting: '2026-09-01', priority: 3, description: '  Note\nsecond line — café #template 99  ' });
const inputs = [
  ['simple-missing-monthly-cap', [t('simple', { priority: 1, limit: cap, description: 'Cap note' })]],
  ['simple-zero-cap-plus-fixed', [t('simple', { monthly: 0, priority: 1, limit: cap, description: 'Cap note' }), fixed]],
  ['simple-monthly-cap-order', [t('simple', { monthly: 400, priority: 1, limit: cap, description: 'Contribution note' })]],
  ['simple-zero-no-cap', [t('simple', { monthly: 0, priority: 1 })]],
  ['periodic-nested-cap', [{ ...fixed, limit: { ...cap, period: 'weekly', start: '2026-09-07' } }]],
  ['remainder-nested-cap', [t('remainder', { weight: 2, priority: null, limit: cap, description: 'Remainder note' })]],
  ['copy-inert-cap', [t('copy', { lookBack: 1, priority: 1, limit: cap, description: 'Ignored cap' })]],
  ...['day', 'week', 'month', 'year'].map(period => [`fixed-${period}`, [{ ...fixed, period: { period, amount: 2 } }]]),
  ...[true, false].map(annual => [`legacy-annual-${annual}`, [t('by', { amount: 1200, month: '2027-09', annual, priority: 1 })]]),
  ['by-legacy-from', [t('by', { amount: 1200, month: '2027-09', from: '2027-01', priority: 1 })]],
  ['spend-repeat', [t('spend', { amount: 1200, month: '2027-09', from: '2027-01', annual: false, repeat: 3, priority: 1 })]],
  ['percentage-previous', [t('percentage', { percent: 15.5, category: 'Salary', previous: true, priority: 1 })]],
  ['schedule-full-signed-fixed', [t('schedule', { scheduleId: 'rent', name: 'Rent', full: true, adjustment: -12.5, adjustmentType: 'fixed', priority: 1 })]],
  ['average-signed-percent', [t('average', { numMonths: 3, adjustment: -25, adjustmentType: 'percent', priority: 1 })]],
  ['monthly-retained-anchor', [t('limit', { ...cap, start: '2026-09-07', priority: null }), fixed]],
  ['goal-note', [t('goal', { amount: 1000, description: 'Goal note' }), fixed]],
];
const normalizations = inputs.map(([id, input]) => ({ id, sourceSymbol: 'migrateTemplatesToAutomations/getInitialState', input: JSON.stringify(input), expected: JSON.stringify(migrateTemplatesToAutomations(input).map(e => getInitialState(e.template).template)) }));
const transitions = [];
for (const [visual, kind] of [['fixed', 'monthlyFixed'], ['by', 'dateTarget'], ['percentage', 'percentage'], ['schedule', 'schedule'], ['historical', 'average'], ['limit', 'balanceLimit'], ['refill', 'refill'], ['remainder', 'remainder'], ['goal', 'goal']]) {
  const input = visual === 'fixed' ? t('percentage', { percent: 25, previous: true, category: 'Salary', priority: 7, description: 'Keep note' }) : fixed;
  const result = templateReducer(getInitialState(input), { type: 'set-type', payload: visual }).template;
  // AutomationEditorPane.dispatch restores the note after the reducer.
  result.description = input.description;
  transitions.push({ id: `switch-${visual}`, sourceSymbol: 'templateReducer/set-type; AutomationEditorPane.dispatch', kind, input: JSON.stringify([input]), expected: JSON.stringify([result]) });
}
for (const [input, kind] of [[t('copy', { lookBack: 5, priority: 3, description: 'History' }), 'average'], [t('average', { numMonths: 5, priority: 3, adjustment: 10, adjustmentType: 'fixed', description: 'History' }), 'copy']]) {
  const result = templateReducer(getInitialState(input), { type: 'update-template', payload: { type: kind } }).template;
  result.description = input.description;
  transitions.push({ id: `${input.type}-to-${kind}`, sourceSymbol: 'mapTemplateTypesForUpdate; AutomationEditorPane.dispatch', kind, input: JSON.stringify([input]), expected: JSON.stringify([result]) });
}
const schedules = [{ id: 'rent', name: 'Rent' }];
const validSources = new Set(['all income', 'available funds', 'salary', 'income-1']);
const validationInputs = [
  ['refill-with-limit', [t('refill', { priority: 1 }), t('limit', { ...cap, priority: null })]],
  ['refill-no-limit', [t('refill', { priority: 1 })]],
  ['limit-no-contributor', [t('limit', { ...cap, priority: null })]],
  ['percentage-range', [t('percentage', { percent: 101, previous: false, category: 'all income', priority: 1 })]],
  ['percentage-conflict', [60, 50].map(percent => t('percentage', { percent, previous: false, category: 'Salary', priority: 1 }))],
  ['percentage-separate-periods', [false, true].map(previous => t('percentage', { percent: 60, previous, category: 'Salary', priority: 1 }))],
  ['missing-source', [t('percentage', { percent: 10, previous: false, category: 'deleted', priority: 1 })]],
  ['missing-schedule-id-wins', [t('schedule', { scheduleId: 'deleted', name: 'Rent', priority: 1 })]],
  ['past-once', [t('by', { amount: 100, month: '2026-08', priority: 1 })]],
  ['past-recurring', [t('by', { amount: 100, month: '2025-08', annual: true, repeat: 1, priority: 1 })]],
  ['spend-start-after-target', [t('spend', { amount: 100, month: '2027-08', from: '2027-09', priority: 1 })]],
  ['schedule-by-priority', [t('schedule', { scheduleId: 'rent', priority: 2 }), t('by', { amount: 100, month: '2027-08', priority: 1 })]],
  ['adjustment-boundary', [t('average', { numMonths: 3, priority: 1, adjustment: -100, adjustmentType: 'percent' })]],
];
const validations = validationInputs.map(([id, input]) => {
  const errors = input.map(template => validateAutomation(template, getInitialState(template).displayType, input, schedules, new OracleDate(), validSources)).filter(Boolean);
  errors.push(...[validatePercentageAllocation(input), validateSchedulePriorities(input)].filter(Boolean));
  return { id, sourceSymbol: 'validateAutomation/validatePercentageAllocation/validateSchedulePriorities', input: JSON.stringify(input), valid: errors.length === 0, errors };
});
const fixture = JSON.stringify({ today: '2026-09-04', normalizations, transitions, validations }, null, 2) + '\n';
// Also pin the note-preserving wrapper, model contract, and money engine sources.
for (const path of ['packages/desktop-client/src/components/modals/BudgetAutomationsModal/AutomationEditorPane.tsx', 'packages/loot-core/src/types/models/templates.ts', 'packages/loot-core/src/server/budget/category-template-context.ts']) {
  sourceFiles.push({ path, sha256: hash(execFileSync('git', ['show', `${commit}:${path}`], { cwd: oracleRoot })) });
}
const caseCount = normalizations.length + transitions.length + validations.length;
const manifest = JSON.stringify({ schemaVersion: 1, tag: oraclePin.tag, commit, packageVersion: oraclePin.packageVersion, sourceFiles, generatorSHA256: hash(readFileSync(scriptPath)), helpers: [{ path: 'scripts/parity/lib/oracle-pin.mjs', sha256: hash(readFileSync(helperPath)) }], seed: null, fixtureSHA256: hash(fixture), caseCount, oracleScope: 'Pinned unmodified reducer, migration and validation bodies. Synthetic UTC-noon calendar adapters; no schedule hydration or engine oracle execution. Note restoration follows AutomationEditorPane.dispatch. Preview/Apply and currency parity are tested separately through SQLite.', amountUnits: 'JSON display units; previews and Apply integer minor units' }, null, 2) + '\n';
assertPinnedOracle(oracleRoot, 'after generating');
const outputs = [['editor-cases.json', fixture], ['template-editor-manifest.json', manifest]];
for (const [name, content] of outputs) writeFileSync(join(destination, name), content);

if (checking) {
  const failures = compareWithCommitted(pinnedFixtureDirectory('Templates'), destination, outputs.map(([name]) => name));
  rmSync(destination, { recursive: true, force: true });
  if (failures.length > 0) {
    for (const failure of failures) console.error(`template parity drift: ${failure}`);
    process.exit(1);
  }
  console.log(`Template editor oracle: ${caseCount} cases match a fresh generation.`);
} else {
  console.log(`Template editor oracle: ${caseCount} cases generated.`);
}
