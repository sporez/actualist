#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
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

const SCHEMA_VERSION = 1;
// Every file whose behaviour the cases depend on. Their hashes pin the contract.
const sourceFiles = [
  'packages/desktop-client/src/hooks/useFormat.ts',
  'packages/desktop-client/src/components/util/AmountInput.tsx',
  'packages/desktop-client/src/components/modals/HoldBufferModal.tsx',
  'packages/desktop-client/src/components/accounts/Reconcile.tsx',
  'packages/loot-core/src/shared/arithmetic.ts',
  'packages/loot-core/src/shared/util.ts',
  'packages/loot-core/src/shared/currencies.ts',
  'packages/loot-core/src/server/budget/actions.ts',
];

const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), '..', '..');
const helperPath = join(root, 'scripts/parity/lib/oracle-pin.mjs');
const checking = process.argv.includes('--check');

if (!hasOracleRoot()) {
  console.error(
    `Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`,
  );
  process.exit(2);
}

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

const oracleRoot = pinnedOracleRoot();
const defaultOutput = pinnedFixtureDirectory('MoneyInput');
const outputRoot = checking
  ? mkdtempSync(join(tmpdir(), 'actualist-money-input-check-'))
  : resolve(argument('--output') ?? defaultOutput);

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: oracleRoot, encoding: 'utf8', ...options });
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw new Error(`${command} ${args.join(' ')} failed`);
  }
  return result.stdout.trim();
}

const packageVersion = JSON.parse(
  readFileSync(join(oracleRoot, 'packages/desktop-client/package.json'), 'utf8'),
).version;
if (packageVersion !== oraclePin.packageVersion) {
  throw new Error(`Expected @actual-app/web ${oraclePin.packageVersion}, found ${packageVersion}`);
}
for (const path of sourceFiles) {
  if (!existsSync(join(oracleRoot, path))) throw new Error(`Pinned source is missing: ${path}`);
}
const yarnPath = join(oracleRoot, '.yarn/releases/yarn-4.17.1.cjs');
if (!existsSync(yarnPath)) {
  throw new Error('Install the pinned Actual checkout with Yarn 4.17.1 before generating');
}

// Strings a person can type into an amount field. Each runs through every number format and
// both currency scales. Separators written as escapes keep the file readable in review.
const typedInputs = [
  '1.005', '.5', '5.', '0', '-0', '100', '1,234.56', '1.234,56', '1 234,56', '1 234,56',
  '1 234,56', "1'234.56", '1’234.56', '1,00,000.33', '(12.34)', '12a', 'abc', '', '  ',
  '12.34', '-12.34', '−12.34', '+5', '10+5', '2*3.5', '10/4', '2^3', '2^3^2', '(1+2)*3', '-5+3',
  '1,5', '1,234', '1.234', '12,345', '1,23', '1.2.3', '1.234.567', '$12.34', '12.34€',
  '‎12.34', '12 34', '1 000', '0.005', '0.015', '1.255', '2.675', '--5', '0.1+0.2',
  '1/0', '0/0', '2^1024', '(1+', '1e3',
  '90000000000000.00', '90000000000000.01', '92233720368547758.07', '999999999999999999999999999999',
];
// Strings typed into the Hold amount field. Digits shift into cents as they are typed.
const autoDecimalInputs = [
  '1005', '1.005', '1,234.56', '12a', '', '  ', 'abc', '0', '5', '00012', '-12', '10+5',
  '123456789012345678901234567890',
];
const forEditAmounts = [0, 5, -5, 100, 1234, -123456, 123456789, 100000033];
const numberFormats = ['comma-dot', 'dot-comma', 'space-comma', 'apostrophe-dot', 'comma-dot-in'];
// Actual's currency list has only 0- and 2-decimal currencies. '' is its currency-neutral entry.
const currencyScales = [
  { code: '', decimalPlaces: 2 },
  { code: 'JPY', decimalPlaces: 0 },
];

const runnerRelative = 'packages/desktop-client/src/hooks/__actualist_money_input_oracle.test.tsx';
const runnerPath = join(oracleRoot, runnerRelative);
const temporaryOutput = join(oracleRoot, '.actualist-money-input-oracle.json');
if (existsSync(runnerPath)) throw new Error(`Refusing to overwrite ${runnerRelative}`);

// The runner drives Actual's own hook and component: useFormat().fromEdit for the typed fields,
// and a mounted AmountInput (autoDecimals) for Hold, so the cases are what a person's typing
// produces, not a re-implementation.
const runner = String.raw`import React from 'react';
import { writeFileSync } from 'node:fs';
import { fireEvent, render, renderHook } from '@testing-library/react';
import { afterAll, expect, test, vi } from 'vitest';

const preferences = vi.hoisted(() => ({ values: {} as Record<string, string> }));
vi.mock('./useSyncedPref', () => ({
  useSyncedPref: (key: string) => [preferences.values[key], () => {}],
}));

import { AmountInput } from '#components/util/AmountInput';

import { useFormat } from './useFormat';

const typedInputs: string[] = ${JSON.stringify(typedInputs)};
const autoDecimalInputs: string[] = ${JSON.stringify(autoDecimalInputs)};
const forEditAmounts: number[] = ${JSON.stringify(forEditAmounts)};
const numberFormats: string[] = ${JSON.stringify(numberFormats)};
const currencyScales: Array<{ code: string; decimalPlaces: number }> = ${JSON.stringify(currencyScales)};

type Outcome =
  | { kind: 'integer'; value: number }
  | { kind: 'none' }
  | { kind: 'unsafe'; repr: string }
  | { kind: 'threw'; message: string };

function outcome(read: () => number | null): Outcome {
  try {
    const value = read();
    if (value === null || value === undefined) return { kind: 'none' };
    if (Number.isSafeInteger(value)) return { kind: 'integer', value: value === 0 ? 0 : value };
    return { kind: 'unsafe', repr: String(value) };
  } catch (error) {
    return { kind: 'threw', message: error instanceof Error ? error.message : String(error) };
  }
}

const cases: Array<Record<string, unknown>> = [];
// React reports a throw inside an event handler as a window error after the handler has run.
let handlerErrors: string[] = [];
window.addEventListener('error', event => {
  handlerErrors.push(event.error instanceof Error ? event.error.message : String(event.message));
  event.preventDefault();
});

function configure(numberFormat: string, code: string) {
  preferences.values = { numberFormat, hideFraction: 'false', defaultCurrencyCode: code };
}

test('Actual money text input contract', () => {
  for (const numberFormat of numberFormats) {
    for (const scale of currencyScales) {
      configure(numberFormat, scale.code);
      const { result, unmount } = renderHook(() => useFormat());
      const prefix = numberFormat + '-dp' + scale.decimalPlaces;
      typedInputs.forEach((text, index) => {
        cases.push({
          id: 'from-edit-' + prefix + '-' + index,
          mode: 'fromEdit',
          input: { text, numberFormat, currencyCode: scale.code, decimalPlaces: scale.decimalPlaces },
          expected: outcome(() => result.current.fromEdit(text)),
        });
      });
      forEditAmounts.forEach((minorUnits, index) => {
        let text = '';
        const produced = outcome(() => {
          text = result.current.forEdit(minorUnits);
          return result.current.fromEdit(text);
        });
        cases.push({
          id: 'for-edit-' + prefix + '-' + index,
          mode: 'forEdit',
          input: { minorUnits, numberFormat, currencyCode: scale.code, decimalPlaces: scale.decimalPlaces },
          expected: { text, parsedBack: produced },
        });
      });
      unmount();

      autoDecimalInputs.forEach((typed, index) => {
        let amount: number | null = null;
        const { container, unmount: unmountField } = render(
          <AmountInput value={0} autoDecimals zeroSign="+" onUpdate={value => { amount = value; }} />,
        );
        const field = container.querySelector('input') as HTMLInputElement;
        let editText = '';
        handlerErrors = [];
        const produced = outcome(() => {
          fireEvent.focus(field);
          fireEvent.change(field, { target: { value: typed } });
          editText = field.value;
          fireEvent.blur(field);
          return amount;
        });
        unmountField();
        // onUpdate runs before the field re-renders its display, so the amount is read first.
        // Actual's display formatter then throws for an amount outside the safe-integer range.
        cases.push({
          id: 'auto-decimals-' + prefix + '-' + index,
          mode: 'autoDecimals',
          input: { text: typed, numberFormat, currencyCode: scale.code, decimalPlaces: scale.decimalPlaces },
          expected: { editText, amount: produced, displayThrew: handlerErrors.length > 0 },
        });
      });
    }
  }
  expect(cases.length).toBeGreaterThan(0);
});

afterAll(() => {
  writeFileSync('${temporaryOutput}', JSON.stringify({
    schemaVersion: ${SCHEMA_VERSION},
    oracle: { tag: '${oraclePin.tag}', commit: '${oraclePin.commit}', packageVersion: '${oraclePin.packageVersion}' },
    cases,
  }, null, 2) + '\n');
});
`;

let generated;
try {
  writeFileSync(runnerPath, runner);
  run(process.execPath, [
    yarnPath, 'workspace', '@actual-app/web', 'vitest', '--run',
    runnerRelative.replace('packages/desktop-client/', ''), '--reporter=dot',
  ]);
  generated = JSON.parse(readFileSync(temporaryOutput, 'utf8'));
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(temporaryOutput, { force: true });
}
assertPinnedOracle(oracleRoot, 'after generating');

const expectedCaseCount =
  numberFormats.length * currencyScales.length *
  (typedInputs.length + forEditAmounts.length + autoDecimalInputs.length);
if (!Array.isArray(generated.cases) || generated.cases.length !== expectedCaseCount) {
  throw new Error(`Oracle did not produce ${expectedCaseCount} cases`);
}
const caseIDs = generated.cases.map(testCase => testCase.id);
if (new Set(caseIDs).size !== caseIDs.length) throw new Error('Duplicate money input case ids');

// Where Actual itself throws (the parse, or the field's display formatter after it parsed). A
// case listed here is a finding for the handoff, not a value the app can match.
const threw = [];
for (const testCase of generated.cases) {
  const outcomes = testCase.mode === 'autoDecimals'
    ? [testCase.expected.amount]
    : testCase.mode === 'forEdit' ? [testCase.expected.parsedBack] : [testCase.expected];
  if (outcomes.some(value => value.kind === 'threw') || testCase.expected.displayThrew === true) {
    threw.push(testCase.id);
  }
}

const fixtureName = 'money-input-contract.json';
const fixtureText = JSON.stringify(generated, null, 2) + '\n';
mkdirSync(outputRoot, { recursive: true });
writeFileSync(join(outputRoot, fixtureName), fixtureText);

const manifest = {
  schemaVersion: SCHEMA_VERSION,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/money-input-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  helpers: [{ path: relative(root, helperPath), sha256: sha256(readFileSync(helperPath)) }],
  seed: null,
  amountUnits: 'integer minor units',
  sourceFiles: sourceFiles.map(path => ({ path, sha256: sha256(readFileSync(join(oracleRoot, path))) })),
  dimensions: { numberFormats, currencyScales, typedInputs: typedInputs.length, autoDecimalInputs: autoDecimalInputs.length },
  fixture: {
    path: relative(root, join(defaultOutput, fixtureName)),
    sha256: sha256(fixtureText),
    caseCount: generated.cases.length,
  },
  caseCount: generated.cases.length,
  casesWhereActualThrows: threw,
};
writeFileSync(join(outputRoot, 'money-input-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

if (checking) {
  const failures = compareWithCommitted(defaultOutput, outputRoot, [fixtureName, 'money-input-manifest.json']);
  rmSync(outputRoot, { recursive: true, force: true });
  if (failures.length > 0) {
    for (const failure of failures) console.error(`money input parity drift: ${failure}`);
    process.exit(1);
  }
  console.log(`Money input parity fixture matches a fresh generation (${generated.cases.length} cases).`);
} else {
  console.log(`Generated money input parity fixture (${oraclePin.tag}, ${generated.cases.length} cases).`);
}
