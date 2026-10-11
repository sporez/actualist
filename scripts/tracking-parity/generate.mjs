import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
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
const defaultOutput = pinnedFixtureDirectory('Tracking');
const checking = process.argv.includes('--check');
if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const oracleRoot = pinnedOracleRoot();
const outputIndex = process.argv.indexOf('--output');
const outputDirectory = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-tracking-check-'))
  : resolve(outputIndex === -1 ? defaultOutput : process.argv[outputIndex + 1]);
const commit = oraclePin.commit;
const path = 'packages/loot-core/src/server/budget/tracking.ts';
const source = execFileSync('git', ['-C', oracleRoot, 'show', `${commit}:${path}`], { encoding: 'utf8' });
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
const sourceSha256 = createHash('sha256').update(source).digest('hex');
const result = { commit, source: path, sha256: sourceSha256, cases,
  groupDependencies, expenseDependencies: cells.get('total-budgeted').dependencies,
  projectedSavings: cells.get('total-saved').run(1500, 500), actualSavings: cells.get('real-saved').run(1200, -300) };
assertPinnedOracle(oracleRoot, 'after generating');

const sha256 = data => createHash('sha256').update(data).digest('hex');
const contractText = JSON.stringify(result, null, 2) + '\n';
writeFileSync(join(outputDirectory, 'contract.json'), contractText);
const manifest = JSON.stringify({
  schemaVersion: 1,
  actual: { tag: oraclePin.tag, commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/tracking-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: [{ path: relative(repositoryRoot, helperPath), sha256: sha256(readFileSync(helperPath)) }],
  seed: null,
  caseCount: cases.length,
  sourceFiles: [{ path, sha256: sourceSha256 }],
  fixtures: [{
    path: relative(repositoryRoot, join(defaultOutput, 'contract.json')),
    sha256: sha256(contractText),
    caseCount: cases.length,
  }],
}, null, 2) + '\n';
writeFileSync(join(outputDirectory, 'tracking-manifest.json'), manifest);

if (checking) {
  const failures = compareWithCommitted(defaultOutput, outputDirectory, ['contract.json', 'tracking-manifest.json']);
  rmSync(outputDirectory, { recursive: true, force: true });
  if (failures.length > 0) {
    for (const failure of failures) console.error(`tracking parity drift: ${failure}`);
    process.exit(1);
  }
  console.log(`Tracking parity fixtures match a fresh generation (${cases.length} cases).`);
} else {
  console.log(`Generated ${cases.length} upstream recurrence cases`);
}
