// The file-import oracle plan: named cases plus seeded generated cases per
// registered function.
//
// Pure data. generate.mjs runs every case through Actual's own functions;
// verify.mjs rebuilds this plan without an oracle and compares it with the
// committed fixture. Expected outputs are never written here; they come only
// from the oracle. Inputs are synthetic.
//
// Output encoding (see README): a JS value that JSON cannot carry is the object
// { "$js": "undefined" | "NaN" | "-0" | "Infinity" | "-Infinity" | "threw" }.

import { mulberry32 } from '../sync-merkle/cases.mjs';
import { REGISTRY } from './registry.mjs';

export { mulberry32 };
export const SEED = 20261109;
export const GENERATED_AMOUNT_CASES = 50;

function named(id, input, description) {
  return { id, source: 'named', description, input };
}

const amountText = (id, text, description) => named(`looselyParseAmount/${id}`, { text }, description);

function looselyParseAmountNamed() {
  return [
    amountText('currency-grouped', '$1,234.56', 'currency symbol, grouping comma, point decimal'),
    amountText('comma-decimal', '1.234,56', 'point grouping, comma decimal'),
    amountText('three-places', '1,234', 'three digits after a separator are not decimals'),
    amountText('parentheses', '(25.00)', 'parentheses mean negative'),
    amountText('unicode-minus', '−25', 'U+2212 minus'),
    amountText('trailing-minus', '25-', 'trailing minus'),
    amountText('double-minus', '--5', 'parseFloat reads no prefix of --5'),
    amountText('empty', '', 'empty string'),
    amountText('sub-cent', '0.005', 'three decimals are read as digits only'),
    amountText('past-max', '99999999999999', 'times 100 exceeds MAX_SAFE_NUMBER'),
    amountText('at-max', '22517998136852.47', 'times 100 near MAX_SAFE_NUMBER'),
    amountText('code-after', '  12.50 USD  ', 'currency code after the number, padded'),
    amountText('code-before', 'EUR 1 234,5', 'code before, space grouping, one decimal'),
    amountText('prefix-letters', '12abc', 'trailing letters are dropped'),
    amountText('paren-unicode-minus', '(−25.00)', 'U+2212 inside parentheses is removed'),
    amountText('four-places', '1.2345', 'four decimal places are decimals'),
    amountText('arabic-digits', '٣٤.٥٠', 'non-ASCII digits are not digits'),
    amountText('lone-minus', '-', 'sign only'),
    amountText('exponent', '1e5', 'exponent letter is dropped'),
    amountText('plus-sign', '+5.00', 'plus sign is dropped'),
  ];
}

const CURRENCY_BEFORE = ['', '$', '€', '£', 'USD ', 'CHF '];
const CURRENCY_AFTER = ['', '', '', ' USD', '€', ' kr'];
const SEPARATOR_PAIRS = [[',', '.'], ['.', ','], ["'", '.'], [' ', ','], ['', '.'], ['', ',']];

function digits(random, count) {
  let text = '';
  for (let index = 0; index < count; index += 1) text += String(Math.floor(random() * 10));
  return text;
}

function pick(random, list) {
  return list[Math.floor(random() * list.length)];
}

function generatedAmount(random) {
  const [group, decimal] = pick(random, SEPARATOR_PAIRS);
  const integerLength = Math.floor(random() * 13);
  let integer = digits(random, integerLength);
  if (group !== '' && integer.length > 3) {
    integer = integer.replace(/\B(?=(\d{3})+(?!\d))/g, group);
  }
  const fraction = random() < 0.7 ? decimal + digits(random, Math.floor(random() * 10)) : '';
  let text = `${pick(random, CURRENCY_BEFORE)}${integer}${fraction}${pick(random, CURRENCY_AFTER)}`;
  const style = Math.floor(random() * 8);
  if (style === 0) text = `-${text}`;
  else if (style === 1) text = `−${text}`;
  else if (style === 2) text = `${text}-`;
  else if (style === 3) text = `(${text})`;
  else if (style === 4) text = `(−${text})`;
  if (random() < 0.15) text = `${text}${pick(random, ['x', 'ab', ' CR'])}`;
  return random() < 0.2 ? ` ${text} ` : text;
}

function looselyParseAmountGenerated() {
  const random = mulberry32(SEED);
  const cases = [];
  for (let index = 0; index < GENERATED_AMOUNT_CASES; index += 1) {
    const text = generatedAmount(random);
    cases.push({
      id: `looselyParseAmount/gen-${String(index + 1).padStart(3, '0')}`,
      source: 'generated',
      description: 'seeded mix of separators, signs, currency marks and stray letters',
      seed: SEED,
      input: { text },
    });
  }
  return cases;
}

// amountToInteger is applied to every non-null looselyParseAmount result. Such a
// case carries no input here; the runner fills it from the source case's output.
function amountToIntegerCases(looselyParsed) {
  const derived = looselyParsed.map(source => ({
    id: source.id.replace('looselyParseAmount/', 'amountToInteger/after-'),
    source: 'derived',
    derivedFrom: source.id,
    description: 'applied to the non-null result of looselyParseAmount',
    input: null,
  }));
  const direct = (id, amount, decimalPlaces, description) =>
    named(`amountToInteger/${id}`, decimalPlaces === undefined ? { amount } : { amount, decimalPlaces }, description);
  return [
    direct('half-up', 0.005, undefined, 'a positive half rounds up'),
    direct('negative-half', -0.005, undefined, 'a negative half rounds toward positive infinity'),
    direct('float-edge', 1.005, undefined, 'binary float product just under a half'),
    direct('zero-places', 12.5, 0, 'no decimal places'),
    direct('three-places', 1.2345, 3, 'three decimal places'),
    direct('large', 22517998136852.47, undefined, 'near MAX_SAFE_NUMBER'),
    ...derived,
  ];
}

const INITIAL_DATE_ROWS = [
  [{ Date: '2026-01-05' }, 'yyyy-mm-dd date'],
  [{ Date: '31/12/2026' }, 'day first, only dd mm yyyy parses'],
  [{ Date: '12/31/2026' }, 'month first'],
  [{ Date: '26-01-05' }, 'two-digit year first'],
  [{ Date: 'abc' }, 'no format parses'],
  [{ Other: '2026-01-05' }, 'mapped column absent from the row'],
];

function getInitialDateFormatNamed() {
  const cases = INITIAL_DATE_ROWS.map(([row, description], index) =>
    named(`getInitialDateFormat/row-${index + 1}`, { transactions: [row], mappings: { date: 'Date' } }, description));
  cases.push(
    named('getInitialDateFormat/empty', { transactions: [], mappings: { date: 'Date' } }, 'empty list'),
    named('getInitialDateFormat/no-date-mapping', { transactions: [{ Date: '2026-01-05' }], mappings: { date: null } }, 'no date column mapped'),
    named('getInitialDateFormat/indexed', { transactions: [{ 0: '05.01.2026' }], mappings: { date: '0' } }, 'headerless row keyed by index'),
  );
  return cases;
}

function getInitialMappingsNamed() {
  const tx = (id, transactions, description) => named(`getInitialMappings/${id}`, { transactions }, description);
  return [
    tx('header-row', [{ 'Posting Date': '2026-01-05', Amount: '-12.34', Description: 'Example Store', Category: 'Dining' }],
      'named header columns'),
    tx('indexed', [{ 0: '01/05/2026', 1: 'Example Store', 2: '-12.34', 3: 'memo', 4: 'extra' }],
      'headerless row keyed by column index'),
    tx('empty', [], 'empty list'),
    tx('internal-fields', [{ Date: '2026-01-05', Payee: 'Example', Notes: 'n', Amount: '1.00', selected: true, ignored: false, trx_id: 'x' }],
      'import bookkeeping fields are stripped first'),
    tx('shape-only', [{ a: '2026-01-05', b: '12.50', c: 'Example Store', d: 'memo' }],
      'columns found by value shape'),
    tx('few-columns', [{ Date: '2026-01-05', Amount: '1.00' }], 'only date and amount'),
  ];
}

// One builder per registry entry; the plan refuses an entry without one.
export const CASE_BUILDERS = {
  looselyParseAmount: () => [...looselyParseAmountNamed(), ...looselyParseAmountGenerated()],
  amountToInteger: ({ looselyParseAmount }) => amountToIntegerCases(looselyParseAmount),
  getInitialMappings: getInitialMappingsNamed,
  getInitialDateFormat: getInitialDateFormatNamed,
};

export function buildPlan() {
  const byFunction = {};
  for (const entry of REGISTRY) {
    const build = CASE_BUILDERS[entry.name];
    if (!build) throw new Error(`No case builder for registered function ${entry.name}`);
    byFunction[entry.name] = build(byFunction).map(planCase => ({ function: entry.name, ...planCase }));
    if (byFunction[entry.name].length === 0) throw new Error(`${entry.name} has no cases`);
  }
  return { seed: SEED, cases: REGISTRY.flatMap(entry => byFunction[entry.name]) };
}

const isTagged = value => value !== null && typeof value === 'object' && typeof value.$js === 'string';

// Structural invariants of a recorded case. They never restate an expected value.
export function expectationFailures(record, planCase) {
  const failures = [];
  const output = record.output;
  if (record.function !== planCase.function) failures.push('function differs from the plan');
  if (isTagged(output) && output.$js === 'threw') failures.push('Actual threw');
  switch (planCase.function) {
    case 'looselyParseAmount':
      if (output !== null && typeof output !== 'number' && !(isTagged(output) && output.$js === '-0')) {
        failures.push('output is neither null nor a number');
      }
      break;
    case 'amountToInteger':
      if (typeof output !== 'number' && !(isTagged(output) && output.$js === '-0')) failures.push('output is not an integer');
      else if (typeof output === 'number' && !Number.isInteger(output)) failures.push('output is not an integer');
      break;
    case 'getInitialMappings':
      if (output === null || typeof output !== 'object' || Array.isArray(output)) failures.push('output is not an object');
      break;
    case 'getInitialDateFormat':
      if (typeof output !== 'string') failures.push('output is not a string');
      break;
    default:
  }
  return failures;
}
