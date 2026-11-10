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
//
// CSV-based functions take { csv, hasHeaderRow, delimiter } and the oracle runs
// the text through Actual's real parseFile. The inputs never depend on JSON key
// order, so a Swift replay can read them with any JSON reader.

import { mulberry32 } from '../sync-merkle/cases.mjs';
import {
  between, chance, generatedAmount, groupedInteger, named, pad, pick, table,
} from './case-kit.mjs';
import { parseAmountFieldsCases } from './amount-fields-cases.mjs';
import { checkCsvParseChecklist, parseCsvRecordsCases } from './csv-parse-cases.mjs';
import { checkDecodeChecklist, decodeCsvBytesCases } from './decode-cases.mjs';
import {
  PIPELINE_CATEGORIES, PREF, pipelineSettingsInput, savedApplyFieldMappingsCases, savedGetInitialDateFormatCases, savedPipelineCases,
} from './saved-settings-cases.mjs';
import { REGISTRY } from './registry.mjs';

export { mulberry32 };
export const SEED = 20261109;

// One fixed seed per generated family, recorded on every generated case.
const SEEDS = {
  amount: SEED,
  date: SEED + 1,
  mappings: SEED + 2,
  dateFormat: SEED + 3,
  applyMappings: SEED + 4,
  category: SEED + 5,
  pipeline: SEED + 6,
  pipelineLarge: SEED + 7,
};
export const GENERATED_COUNTS = {
  amount: 1500,
  date: 2500,
  mappings: 300,
  dateFormat: 300,
  applyMappings: 300,
  category: 100,
  pipeline: 300,
  pipelineLarge: 10,
};

function generated(id, family, input, description) {
  return { id, source: 'generated', description, seed: SEEDS[family], input };
}

// ---------------------------------------------------------------------------
// looselyParseAmount

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
    // Decimal-place alternatives of /[.,](\d{4,9}|\d{1,2})[^\d.,]*$/.
    amountText('places-1-point', '1.5', 'one decimal place after a point'),
    amountText('places-1-comma', '1,5', 'one decimal place after a comma'),
    amountText('places-2-comma', '1.234,56', 'two decimal places after a comma'),
    amountText('places-4-comma', '12,3456', 'four decimal places after a comma'),
    amountText('places-5', '1.23456', 'five decimal places'),
    amountText('places-8', '1.23456789', 'eight decimal places'),
    amountText('places-9', '0,123456789', 'nine decimal places'),
    amountText('places-10', '1.2345678901', 'ten places match no alternative'),
    amountText('places-3-comma', '1.234,567', 'three places after the last separator'),
    amountText('tail-letters', '12.50abc', 'non-digits after the decimals are allowed'),
    amountText('tail-space', '12,50 ', 'trailing space is trimmed first'),
    amountText('tail-separator', '12.50.', 'a separator after the digits breaks the match'),
    amountText('tail-digit-after-code', '12.50 USD 3', 'a digit after the code breaks the match'),
    amountText('separator-only-tail', '12.', 'separator with no digits after'),
    amountText('leading-separator', '.5', 'leading point'),
    amountText('leading-comma', ',05', 'leading comma'),
    // Parentheses branch.
    amountText('paren-only-open', '(25.00', 'open parenthesis without a close'),
    amountText('paren-only-close', '25.00)', 'close parenthesis without an open'),
    amountText('paren-nested', '((25.00))', 'only the first and last parentheses count once each'),
    amountText('paren-currency', '($1,234.56)', 'currency inside parentheses'),
    amountText('paren-spaces', '  ( 25.00 )  ', 'padded parentheses'),
    amountText('paren-minus-inside', '(-25.00)', 'ASCII minus inside parentheses'),
    amountText('paren-empty', '()', 'empty parentheses'),
    amountText('minus-middle', '12-34', 'minus between digits'),
    amountText('minus-triple', '---5', 'several minus signs'),
    amountText('unicode-minus-trailing', '25.00−', 'trailing U+2212'),
    // JS whitespace trimming.
    amountText('feff-padded', '﻿12.50', 'byte order mark is JS whitespace'),
    amountText('nbsp-padded', ' 12.50 ', 'no-break space is JS whitespace'),
    amountText('line-separator-padded', ' 12.50 ', 'U+2028 and U+2029 are JS whitespace'),
    amountText('nel-padded', '\u008512.50', 'U+0085 is not JS whitespace'),
    amountText('zero-width-padded', '​12.50', 'U+200B is not JS whitespace'),
    amountText('mongolian-vowel-padded', '᠎12.50', 'U+180E is not JS whitespace'),
    amountText('ideographic-padded', '　12.50　', 'ideographic space is JS whitespace'),
    amountText('thin-space-group', '1 234,56', 'thin space grouping'),
    amountText('nbsp-group', '1 234,56', 'no-break space grouping'),
    amountText('narrow-nbsp-group', '1 234.56', 'narrow no-break space grouping'),
    amountText('apostrophe-group', "1'234.56", 'apostrophe grouping'),
    // Digits and letters.
    amountText('fullwidth-digits', '１２.５０', 'fullwidth digits are dropped'),
    amountText('superscript-digits', '12²', 'superscripts are dropped'),
    amountText('arabic-with-ascii', '1٢3.45', 'mixed digit scripts'),
    amountText('letter-only', 'abc', 'no digits'),
    amountText('e-notation-decimal', '1.5e3', 'exponent with decimals'),
    amountText('negative-zero', '-0', 'negative zero'),
    amountText('negative-zero-decimals', '-0.00', 'negative zero with decimals'),
    amountText('zero', '0', 'zero'),
    amountText('leading-zeros', '000012.50', 'leading zeros'),
    amountText('many-digits-no-decimal', '12345678901234567890', 'beyond double precision'),
    amountText('many-digits-decimal', '123456789012345678.90', 'beyond double precision with decimals'),
    amountText('negative-past-max', '-99999999999999.99', 'times 100 below MIN_SAFE_NUMBER'),
    amountText('at-max-integer', '22517998136852', 'integer just under the limit'),
    amountText('just-past-max', '22517998136853', 'integer just past the limit'),
    amountText('code-letters-with-decimals-after', '1,234.56 EUR', 'code after a grouped amount'),
    amountText('cr-suffix', '12.50 CR', 'credit suffix'),
    amountText('dr-suffix', '12.50DR', 'debit suffix'),
    amountText('sign-currency-order', '-$12.50', 'minus before the currency'),
    amountText('currency-sign-order', '$-12.50', 'minus after the currency'),
    amountText('minus-after-decimals', '12.50-', 'minus after decimals'),
  ];
}

function looselyParseAmountGenerated() {
  const random = mulberry32(SEEDS.amount);
  const cases = [];
  for (let index = 0; index < GENERATED_COUNTS.amount; index += 1) {
    cases.push(generated(`looselyParseAmount/gen-${pad(index)}`, 'amount', { text: generatedAmount(random) },
      'seeded mix of separators, signs, currency marks, padding and stray characters'));
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
    // With zero places amountToInteger is bare Math.round, which every Swift
    // port of it (JavaScriptText.round) must match. floor(x + 0.5) gets these
    // two wrong: the sum rounds up to 1 below a half, and to the next even
    // integer above 2^52.
    direct('round-just-below-half', 0.49999999999999994, 0, 'Math.round just below one half'),
    direct('round-negative-just-below-half', -0.49999999999999994, 0, 'Math.round just above minus one half'),
    direct('round-odd-above-2-52', 4503599627370497, 0, 'Math.round of an odd integer above 2^52'),
    direct('round-negative-half', -2.5, 0, 'Math.round of a negative half'),
    direct('round-negative-small', -0.3, 0, 'Math.round of a small negative gives -0'),
    ...derived,
  ];
}

// ---------------------------------------------------------------------------
// parseDate

const DATE_FORMATS = ['yyyy mm dd', 'yy mm dd', 'mm dd yyyy', 'mm dd yy', 'dd mm yyyy', 'dd mm yy'];
const formatSlug = format => format.replaceAll(' ', '');
const dateCase = (id, text, format, description) => named(`parseDate/${id}`, { text, format }, description);

// Month words as the source spells them: [name, number, abbreviation, forms the
// regular expression offers]. The suffix forms are exercised in both ways that
// matter: a dot followed by a word character (the dotted alternative matches) and
// a dot followed by a space (the final \b fails, so the regex backtracks).
const MONTHS = [
  ['jan', 'January', ['', '.', 'uary']],
  ['feb', 'February', ['', '.', 'ruary']],
  ['mar', 'March', ['', '.', 'ch']],
  ['apr', 'April', ['', '.', 'il']],
  ['may', 'May', ['', '.']],
  ['jun', 'June', ['', '.', 'e']],
  ['jul', 'July', ['', '.', 'y']],
  ['aug', 'August', ['', '.', 'ust']],
  ['sep', 'September', ['', '.', 't', 't.', 'tember']],
  ['oct', 'October', ['', '.', 'ober']],
  ['nov', 'November', ['', '.', 'ember']],
  ['dec', 'December', ['', '.', 'ember']],
];

// Every regular-expression alternative in parseDate and looselyParseAmount that V8
// block coverage cannot see. Each entry names the case that exercises it, and the
// plan refuses an entry whose case does not exist or whose input does not match
// the entry's pattern. The pattern is a test of the input, not an expected value.
export const REGEX_ALTERNATIVE_CHECKLIST = [];
function listAlternative(label, caseId, pattern, field = 'text') {
  REGEX_ALTERNATIVE_CHECKLIST.push({ label, caseId, pattern, field });
}

function monthNamedCases() {
  const cases = [];
  MONTHS.forEach(([abbreviation, , suffixes], monthIndex) => {
    const month = String(monthIndex + 1).padStart(2, '0');
    for (const suffix of suffixes) {
      const word = abbreviation + suffix;
      const slug = word.replace('.', 'dot');
      const wordPattern = suffix.endsWith('.')
        ? new RegExp(`\\b${abbreviation}${suffix.slice(0, -1)}\\.\\b`, 'i')
        : new RegExp(`\\b${word}\\b`, 'i');
      // Dotted form followed by a word character: the dotted alternative matches.
      const text = suffix.endsWith('.') ? `15 ${word}2026` : `15 ${word} 2026`;
      const id = `month-${abbreviation}-${slug === '' ? 'bare' : slug}`;
      cases.push(dateCase(id, text, 'dd mm yyyy', `${abbreviation} alternative "${suffix}" (${month})`));
      listAlternative(`${abbreviation}${suffix === '' ? '' : `(${suffix})`}`, `parseDate/${id}`, wordPattern);
      // Upper and mixed case spellings.
      cases.push(dateCase(`${id}-upper`, text.toUpperCase(), 'dd mm yyyy', `${word} in capitals`));
      if (suffix.endsWith('.')) {
        cases.push(dateCase(`${id}-space`, `15 ${word} 2026`, 'dd mm yyyy', `${word} followed by a space: the final \\b fails and the regex backtracks`));
      }
    }
    cases.push(dateCase(`month-${abbreviation}-full`, `${MONTHS[monthIndex][1]} 15, 2026`, 'mm dd yyyy', 'full name first'));
    cases.push(dateCase(`month-${abbreviation}-in-word`, `15 ${abbreviation}x 2026`, 'dd mm yyyy', 'abbreviation inside a longer word is not a month'));
  });
  return cases;
}

const DATE_BASES = [
  ['iso', '2026-01-05'],
  ['iso-slash', '2026/01/05'],
  ['iso-dot', '2026.01.05'],
  ['iso-space', '2026 01 05'],
  ['iso-unpadded', '2026-1-5'],
  ['iso-mixed', '2026-01/05'],
  ['iso-mixed-2', '2026.1-05'],
  ['slash', '05/01/2026'],
  ['slash-us', '12/31/2026'],
  ['slash-short-year', '5/1/26'],
  ['dash', '31-12-2026'],
  ['dot-eu', '31.12.2026'],
  ['space', '31 12 2026'],
  ['compact-8', '20260105'],
  ['compact-8-dmy', '05012026'],
  ['compact-6', '050126'],
  ['compact-6-ymd', '260105'],
  ['compact-5', '51026'],
  ['compact-4', '0501'],
  ['compact-10', '2026010512'],
  ['two-parts', '01/2026'],
  ['one-part', '2026'],
  ['four-parts', '05/01/2026/12'],
  ['time-suffix', '2026-01-05 12:34:56'],
  ['time-suffix-us', '05/01/2026 12:30'],
  ['iso-t', '2026-01-05T10:00:00Z'],
  ['iso-t-offset', '2026-01-05T10:00:00+02:00'],
  ['leading-text', 'Posted 2026-01-05'],
  ['trailing-text', '05/01/2026 (pending)'],
  ['both-text', 'on 05/01/2026 posted'],
  ['leading-punct', '(05/01/2026)'],
  ['comma-sep', '05,01,2026'],
  ['comma-space', '5, 1, 2026'],
  ['long-sep', '05 // 01 -- 2026'],
  ['spaces-padded', '  05/01/2026  '],
  ['tab-sep', '05\t01\t2026'],
  ['newline-sep', '05\n01\n2026'],
  ['month-name-us', 'Jan 5, 2026'],
  ['month-name-eu', '5 Jan 2026'],
  ['month-name-iso', '2026 Jan 05'],
  ['month-name-upper', '5 JANUARY 2026'],
  ['month-name-glued', '5jan2026'],
  ['month-name-dash', '05-Jan-2026'],
  ['month-name-dash-short-year', '05-Jan-26'],
  ['month-name-sept-dot', '5 Sept. 2026'],
  ['month-name-sep-dot', '5 sep. 2026'],
  ['month-name-may-dot', '5 May. 2026'],
  ['month-janet', '5 janet 2026'],
  ['month-mayday', 'mayday 5 2026'],
  ['month-decimal', '5 decimal 2026'],
  ['month-two-names', 'Jan 5 Feb 2026'],
  ['month-only', 'January 2026'],
  ['month-day-only', 'Jan 5'],
  ['month-trailing-text', 'Jan 5, 2026 purchase'],
  ['month-name-after-digits', '2026-01-05 Mon'],
  ['month-marketplace', 'Marketplace 01/02/2026'],
  ['year-2', '26-01-05'],
  ['year-3', '126-01-05'],
  ['year-5', '20260-01-05'],
  ['year-0', '0000-01-05'],
  ['year-1900', '1900-01-05'],
  ['year-9999', '9999-12-31'],
  ['year-3-dmy', '05/01/126'],
  ['year-5-dmy', '05/01/20260'],
  ['day-0', '2026-01-00'],
  ['day-32', '2026-01-32'],
  ['month-0', '2026-00-10'],
  ['month-13', '2026-13-01'],
  ['feb-30', '2026-02-30'],
  ['apr-31', '2026-04-31'],
  ['leap-2024', '2024-02-29'],
  ['nonleap-2023', '2023-02-29'],
  ['century-1900', '1900-02-29'],
  ['century-2000', '2000-02-29'],
  ['year-zero-feb-29', '0000-02-29'],
  ['year-4-feb-29', '0004-02-29'],
  ['leap-dmy', '29/02/2024'],
  ['nonleap-dmy', '29/02/2023'],
  ['century-dmy', '29/02/1900'],
  ['negative', '-2026-01-05'],
  ['plus', '+2026-01-05'],
  ['arabic-digits', '٢٠٢٦-٠١-٠٥'],
  ['fullwidth-digits', '２０２６-０１-０５'],
  ['mixed-digits', '2026-٠١-05'],
  ['superscript', '2026-01-05²'],
  ['letters-only', 'not a date'],
  ['empty-text', ''],
  ['spaces-only', '   '],
  ['digits-only-long', '12345678901234567890'],
  ['unicode-letters-lead', 'Datum: 05.01.2026'],
  ['nbsp-sep', '05 01 2026'],
  ['non-bmp-lead', '😀 05/01/2026'],
  ['combining-after-digit', '05/01/2026́'],
  ['dot-trailing', '05.01.2026.'],
  ['dash-leading', '-05/01/2026'],
];

function parseDateNamed() {
  const cases = [];
  for (const [slug, text] of DATE_BASES) {
    for (const format of DATE_FORMATS) {
      cases.push(dateCase(`${slug}-${formatSlug(format)}`, text, format, `"${slug}" read as ${format}`));
    }
  }
  cases.push(
    dateCase('null-input', null, 'yyyy mm dd', 'a null value is not a string'),
    dateCase('null-input-dmy', null, 'dd mm yyyy', 'a null value is not a string'),
    // The modal passes null when a saved format is not one of the six; the switch then
    // falls to its default branch, which reads mm dd yyyy.
    dateCase('null-format', '12/31/2026', null, 'a null format falls to the default branch, mm dd yyyy'),
    dateCase('null-format-iso', '2026-01-05', null, 'a null format reads an ISO date as mm dd yyyy'),
  );
  cases.push(...monthNamedCases());
  // Structural alternatives and branches of the cleanup chain.
  listAlternative('leading non-digits stripped', 'parseDate/leading-text-yyyymmdd', /^[^\d]+/);
  listAlternative('trailing non-digits stripped', 'parseDate/trailing-text-mmddyyyy', /[^\d]+$/);
  listAlternative('three or more parts', 'parseDate/four-parts-ddmmyyyy', /\d+[^\d]+\d+[^\d]+\d+/);
  listAlternative('digit fallback', 'parseDate/compact-8-yyyymmdd', /^\d{8}$/);
  listAlternative('digit fallback, two parts', 'parseDate/two-parts-mmddyyyy', /^\d+[^\d]\d+$/);
  listAlternative('year-first fallback with a 6-digit string', 'parseDate/compact-6-ymd-yymmdd', /^\d{6}$/);
  listAlternative('single-digit padding', 'parseDate/iso-unpadded-yyyymmdd', /-\d-\d$/);
  return cases;
}

function dateString(random, forcedOrder) {
  const lengthYear = chance(random, 0.1) ? pick(random, [1, 2, 3, 5]) : 4;
  const year = lengthYear === 4 ? between(random, chance(random, 0.2) ? 0 : 1990, chance(random, 0.1) ? 9999 : 2040) : between(random, 0, 10 ** lengthYear - 1);
  const month = chance(random, 0.05) ? pick(random, [0, 13, 99]) : between(random, 1, 12);
  const day = chance(random, 0.1) ? pick(random, [0, 29, 30, 31, 32, 99]) : between(random, 1, 31);
  const yearText = String(year).padStart(chance(random, 0.7) ? lengthYear : 1, '0');
  const shortYear = String(year % 100).padStart(chance(random, 0.8) ? 2 : 1, '0');
  const padPart = value => String(value).padStart(chance(random, 0.7) ? 2 : 1, '0');
  const monthPart = chance(random, 0.12)
    ? pick(random, ['Jan', 'JAN', 'january', 'Feb.', 'mar', 'APRIL', 'May', 'may.', 'Jun', 'July', 'aug', 'Sept', 'Sep.', 'sept.', 'Oct', 'Nov', 'dec', 'December', 'Janet', 'Mayday'])
    : padPart(month);
  const yearPart = chance(random, 0.3) ? shortYear : yearText;
  const separator = () => pick(random, ['/', '-', '.', ' ', '/', '-', '.', ' ', '', ', ', ' - ', '//']);
  const order = forcedOrder ?? between(random, 0, 2);
  const parts = order === 0 ? [yearPart, monthPart, padPart(day)]
    : order === 1 ? [padPart(day), monthPart, yearPart] : [monthPart, padPart(day), yearPart];
  const uniform = chance(random, 0.75);
  const fixed = separator();
  let text = parts[0] + (uniform ? fixed : separator()) + parts[1] + (uniform ? fixed : separator()) + parts[2];
  if (chance(random, 0.12)) text += pick(random, [' 12:34', ' 23:59:59', 'T10:00:00Z', ' PM', ' (pending)', ' 00:00 UTC']);
  if (chance(random, 0.08)) text = pick(random, ['Posted ', 'on ', '(', 'Date: ', '#']) + text;
  if (chance(random, 0.05)) text = pick(random, [' ', '\t', ' ']) + text;
  if (chance(random, 0.03)) text = text.replace(/\d/, pick(random, ['٣', '３', '²']));
  return text;
}

function junkString(random) {
  const alphabet = '0123456789 /-.,:abJanMayDecSepT';
  let text = '';
  const length = between(random, 0, 14);
  for (let index = 0; index < length; index += 1) text += alphabet[between(random, 0, alphabet.length - 1)];
  return text;
}

function parseDateGenerated() {
  const random = mulberry32(SEEDS.date);
  const cases = [];
  for (let index = 0; index < GENERATED_COUNTS.date; index += 1) {
    const order = between(random, 0, 2);
    const text = chance(random, 0.06) ? junkString(random) : dateString(random, order);
    // Most cases pair the layout with a format of the same field order.
    const format = chance(random, 0.75)
      ? pick(random, [['yyyy mm dd', 'yy mm dd'], ['dd mm yyyy', 'dd mm yy'], ['mm dd yyyy', 'mm dd yy']][order])
      : pick(random, DATE_FORMATS);
    cases.push(generated(`parseDate/gen-${pad(index)}`, 'date', { text, format },
      'seeded date text in a random layout and format'));
  }
  return cases;
}

// ---------------------------------------------------------------------------
// CSV tables for getInitialMappings, getInitialDateFormat, applyFieldMappings

const csvInput = (csv, hasHeaderRow = true) => ({ csv, hasHeaderRow, delimiter: ',' });

const mappingsCase = (id, csv, description, hasHeaderRow = true) =>
  named(`getInitialMappings/${id}`, csvInput(csv, hasHeaderRow), description);

function getInitialMappingsNamed() {
  const row = ['2026-01-05', '-12.34', 'Example Store', 'memo text', 'Dining'];
  const cases = [
    mappingsCase('header-row', table(['Posting Date', 'Amount', 'Description', 'Category'],
      [['2026-01-05', '-12.34', 'Example Store', 'Dining']]), 'named header columns'),
    mappingsCase('indexed', table(null, [['01/05/2026', 'Example Store', '-12.34', 'memo', 'extra']]),
      'headerless file keyed by column index', false),
    mappingsCase('empty-file', '', 'no rows at all'),
    mappingsCase('empty-file-headerless', '', 'no rows at all, no header row', false),
    mappingsCase('header-only', 'Date,Amount,Payee\r\n', 'a header and no data rows'),
    mappingsCase('internal-fields', table(['Date', 'Payee', 'Notes', 'Amount', 'selected', 'ignored', 'trx_id'],
      [['2026-01-05', 'Example', 'n', '1.00', 'true', 'false', 'x']]), 'selected and trx_id columns are replaced by the parse step and stripped'),
    mappingsCase('shape-only', table(['a', 'b', 'c', 'd'], [['2026-01-05', '12.50', 'Example Store', 'memo']]),
      'columns found by value shape'),
    mappingsCase('few-columns', table(['Date', 'Amount'], [['2026-01-05', '1.00']]), 'only date and amount'),
    mappingsCase('title-case', table(['Date', 'Amount', 'Payee', 'Notes', 'Category'], [row]), 'standard title-case headers'),
    mappingsCase('lowercase-date', table(['date', 'amount', 'payee', 'notes', 'category'], [row]), 'lowercase headers'),
    mappingsCase('uppercase', table(['DATE', 'AMOUNT', 'PAYEE', 'NOTES', 'CATEGORY'], [row]), 'uppercase headers'),
    mappingsCase('two-date-columns', table(['Posting Date', 'Transaction Date', 'Amount', 'Description'],
      [['2026-01-06', '2026-01-05', '-1.00', 'Example Store']]), 'the first column containing "date" wins'),
    mappingsCase('date-after-other', table(['Description', 'Update', 'Date', 'Amount'], [['Example', 'x', '2026-01-05', '1.00']]),
      '"Update" contains "date" and comes first'),
    mappingsCase('description-and-memo', table(['Date', 'Amount', 'Description', 'Memo'], [['2026-01-05', '1.00', 'Example', 'note']]),
      'Description and Memo are not name matches'),
    mappingsCase('notes-header', table(['Date', 'Amount', 'Description', 'Notes'], [['2026-01-05', '1.00', 'Example', 'note']]),
      'a Notes header is a name match'),
    mappingsCase('payee-substring', table(['Date', 'Amount', 'Payee Name', 'Memo'], [['2026-01-05', '1.00', 'Example', 'note']]),
      'substring match for payee'),
    mappingsCase('amount-substring', table(['Date', 'Transaction Amount (USD)', 'Description'], [['2026-01-05', '1.00', 'Example']]),
      'substring match for amount'),
    mappingsCase('numeric-headers', table(['2026', '0', '10', '01'], [['2026-01-05', '12.50', 'Example', 'memo']]),
      'integer-like keys sort first in an object, 01 does not'),
    mappingsCase('numeric-headers-reversed', table(['10', '2', '1', 'b', 'a'], [['2026-01-05', '12.50', 'Example', 'memo', 'x']]),
      'integer-like keys sort numerically before string keys'),
    mappingsCase('numeric-headers-large', table(['4294967295', '4294967294', '99999999999', '1'], [['Example', 'memo', '12.50', '2026-01-05']]),
      'array-index range of integer-like keys'),
    mappingsCase('numeric-and-names', table(['b', '3', 'a', '1'], [['2026-01-05', '12.50', 'Example', 'memo']]),
      'integer-like keys move ahead of names'),
    mappingsCase('empty-header', table(['', 'Amount', 'Payee'], [['2026-01-05', '1.00', 'Example']]), 'an empty header name'),
    mappingsCase('duplicate-headers', table(['Date', 'Amount', 'Date', 'Payee'], [['2026-01-05', '1.00', '2026-02-06', 'Example']]),
      'duplicate header names collapse to one key'),
    mappingsCase('duplicate-payee', table(['Payee', 'Payee', 'Amount', 'Date'], [['A', 'B', '1.00', '2026-01-05']]),
      'duplicate Payee headers: the later value wins'),
    mappingsCase('proto-header', table(['__proto__', 'Date', 'Amount'], [['x', '2026-01-05', '1.00']]), 'a __proto__ header'),
    mappingsCase('constructor-header', table(['constructor', 'Date', 'Amount'], [['x', '2026-01-05', '1.00']]), 'a constructor header'),
    mappingsCase('non-ascii-headers', table(['Dätum', 'Betrag', 'Empfänger'], [['05.01.2026', '12,50', 'Example']]), 'German headers'),
    mappingsCase('turkish-dotted-i', table(['İ', 'Date', 'Amount'], [['x', '2026-01-05', '1.00']]), 'capital dotted I lowercases to two characters'),
    mappingsCase('kelvin-sign', table(['K', 'Date', 'Amount'], [['x', '2026-01-05', '1.00']]), 'Kelvin sign lowercases to k'),
    mappingsCase('combining-date', table(['Daté', 'Amount́', 'Payeé', 'Noteś', 'Categorý'], [row]),
      'combining accents after the keyword: JS includes() still matches the code units'),
    mappingsCase('precomposed-name', table(['Däte', 'Amount'], [['2026-01-05', '1.00']]), 'precomposed letter inside the word'),
    mappingsCase('decomposed-name', table(['Däte', 'Amount'], [['2026-01-05', '1.00']]), 'decomposed letter inside the word'),
    mappingsCase('bom', `﻿${table(['Date', 'Amount', 'Payee'], [['2026-01-05', '1.00', 'Example']])}`, 'a leading byte order mark'),
    mappingsCase('bom-headerless', `﻿${table(null, [['2026-01-05', '1.00', 'Example']])}`, 'a leading byte order mark, no header row', false),
    mappingsCase('quoted-comma', table(['Date', 'Amount', 'Payee'], [['2026-01-05', '1.00', 'Store, Inc.']]), 'quoted field with a comma'),
    mappingsCase('quoted-newline', table(['Date', 'Amount', 'Payee', 'Notes'], [['2026-01-05', '1.00', 'Store', 'line one\nline two']]),
      'quoted field with a newline'),
    mappingsCase('quoted-quote', table(['Date', 'Amount', 'Payee'], [['2026-01-05', '1.00', 'The "Best" Store']]), 'quoted field with a quote'),
    mappingsCase('short-first-row', 'Date,Amount,Payee\r\n2026-01-05\r\n', 'first data row shorter than the header'),
    mappingsCase('long-first-row', 'Date,Amount\r\n2026-01-05,1.00,Example,extra\r\n', 'first data row longer than the header'),
    mappingsCase('headerless-short', '2026-01-05\r\n', 'single-column headerless file', false),
    mappingsCase('headerless-six', table(null, [['2026-01-05', '1.00', 'Example', 'memo', 'out', 'extra']]), 'six columns, headerless', false),
    mappingsCase('headerless-twelve', table(null, [['2026-01-05', '1.00', 'Example', 'memo', 'out', 'e5', 'e6', 'e7', 'e8', 'e9', 'e10', 'e11']]),
      'twelve columns: integer keys 10 and 11 sort after 9', false),
    mappingsCase('headerless-ragged', '2026-01-05,1.00\r\n2026-01-06,2.00,Example,memo\r\n', 'ragged headerless rows: the first row decides', false),
    mappingsCase('whitespace-values', table(['a', 'b', 'c'], [['  2026-01-05  ', ' 12.50 ', ' Example ']]), 'unquoted values are trimmed'),
    mappingsCase('quoted-padded-values', 'a,b,c\r\n" 2026-01-05 "," 12.50 ","Example"\r\n', 'quoted values keep their padding'),
    // Shape-only date and amount guesses.
    mappingsCase('shape-date-slash', table(['x', 'y'], [['1/5/2026', '12']]), 'slash date shape'),
    mappingsCase('shape-date-dash-two-digit', table(['x', 'y'], [['01-05-26', '12']]), 'dash date shape with a two-digit year'),
    mappingsCase('shape-date-dot', table(['x', 'y'], [['05.01.2026', '12']]), 'dots are not a date shape'),
    mappingsCase('shape-date-mixed', table(['x', 'y'], [['2026-01/05', '12']]), 'mixed separators match the shape'),
    mappingsCase('shape-date-time', table(['x', 'y'], [['2026-01-05 12:00', '12']]), 'a time suffix breaks the shape'),
    mappingsCase('shape-date-trailing-newline', table(['x', 'y'], [['2026-01-05\n', '12']]), 'a quoted trailing newline: $ matches only at the very end in JS'),
    mappingsCase('shape-date-trailing-newline-amount', table(['x', 'y'], [['2026-01-05', '12.50\n']]), 'a quoted trailing newline after an amount'),
    mappingsCase('shape-date-arabic', table(['x', 'y'], [['٢٠٢٦-٠١-٠٥', '12']]), 'non-ASCII digits are not \\d in JS'),
    mappingsCase('shape-amount-arabic', table(['x', 'y'], [['2026-01-05', '١٢٫٥٠']]), 'non-ASCII digits are not amounts'),
    mappingsCase('shape-amount-fullwidth', table(['x', 'y'], [['2026-01-05', '１２.５０']]), 'fullwidth digits are not \\d in JS'),
    mappingsCase('shape-amount-negative', table(['x', 'y'], [['2026-01-05', '-1,234.56']]), 'negative amount shape'),
    mappingsCase('shape-amount-comma-only', table(['x', 'y'], [['2026-01-05', ',,,']]), 'separators only count as an amount'),
    mappingsCase('shape-amount-currency', table(['x', 'y'], [['2026-01-05', '$12.50']]), 'a currency sign breaks the shape'),
    mappingsCase('shape-amount-plus', table(['x', 'y'], [['2026-01-05', '+12.50']]), 'a plus sign breaks the shape'),
    mappingsCase('shape-amount-minus-after', table(['x', 'y'], [['2026-01-05', '12.50-']]), 'a trailing minus breaks the shape'),
    mappingsCase('shape-amount-empty-first', table(['x', 'y', 'z'], [['', '12.50', '2026-01-05']]), 'an empty first value'),
    mappingsCase('shape-amount-wins-date-lookalike', table(['x', 'y'], [['12', '2026-01-05']]), 'integer first value is an amount shape'),
    mappingsCase('shape-name-wins', table(['Date', 'x', 'Amount'], [['hello', '2026-01-05', '12.50']]), 'a name match wins over a shape match'),
    mappingsCase('shape-four-columns-all-leftover', table(['a', 'b', 'c', 'd', 'e', 'f'], [['2026-01-05', '12.50', 'p', 'n', 'i', 'z']]),
      'leftover columns fill payee, notes and in/out in order'),
    mappingsCase('payee-by-name-notes-by-leftover', table(['Date', 'Amount', 'Payee', 'x', 'y'], [['2026-01-05', '1.00', 'P', 'N', 'I']]),
      'a payee match, leftovers for notes and in/out'),
    mappingsCase('category-only-name', table(['Date', 'Amount', 'Category'], [['2026-01-05', '1.00', 'Dining']]), 'category is matched by name only'),
    mappingsCase('category-named-in-middle', table(['Date', 'Category', 'Amount', 'Payee'], [['2026-01-05', 'Dining', '1.00', 'P']]),
      'category column before amount'),
    mappingsCase('internal-names-lookalike', table(['existing', 'ignored', 'selected_merge', 'tombstone', 'Date'], [['a', 'b', 'c', 'd', '2026-01-05']]),
      'bookkeeping names other than selected and trx_id are also stripped'),
    mappingsCase('selected-merge-only', table(['Date', 'selected_merge', 'Amount'], [['2026-01-05', 'x', '1.00']]), 'selected_merge is stripped'),
    mappingsCase('only-bookkeeping', table(['selected', 'trx_id'], [['a', 'b']]), 'only stripped columns remain: nothing is left to map'),
    mappingsCase('blank-line-skipped', 'Date,Amount\r\n\r\n2026-01-05,1.00\r\n', 'blank lines are skipped'),
    mappingsCase('lf-only', 'Date,Amount,Payee\n2026-01-05,1.00,Example\n', 'LF line endings'),
    mappingsCase('cr-only', 'Date,Amount,Payee\r2026-01-05,1.00,Example\r', 'CR line endings'),
    mappingsCase('no-trailing-newline', 'Date,Amount,Payee\r\n2026-01-05,1.00,Example', 'no final newline'),
    mappingsCase('spaces-in-header', table([' Date ', ' Amount '], [['2026-01-05', '1.00']]), 'unquoted headers are trimmed'),
    mappingsCase('quoted-padded-header', ' "Date " ,"Amount"\r\n2026-01-05,1.00\r\n', 'a quoted header keeps its inner padding'),
  ];
  return cases;
}

const FIRST_NAMES = ['Example Store', 'Sample Cafe', 'Test Market', 'Demo Fuel', 'Placeholder Books', 'Acme Utilities', 'Fictional Pharmacy', 'Synthetic Rent'];
const MEMOS = ['', 'memo text', 'card ending 0000', 'ref 12345', 'online order', 'monthly'];
const CATEGORY_NAMES = ['Dining', 'Groceries', 'Fuel', 'Rent', 'Books', 'dining', 'Utilities'];

const HEADER_POOL = [
  'Date', 'date', 'DATE', 'Posting Date', 'Transaction Date', 'Update', 'Amount', 'amount', 'Amount (USD)', 'Payee', 'payee',
  'Description', 'Notes', 'Memo', 'Category', 'Type', 'Balance', 'Debit', 'Credit', 'Check #', '2026', '0', '10', '01', '2',
  '', 'trx_id', 'selected', 'Dätum', 'İ', 'K', '__proto__', 'Account', 'Name', 'Ref', 'Daté',
];

function generatedDateValue(random) {
  return chance(random, 0.1) ? junkString(random) : dateString(random);
}

function generatedAmountValue(random) {
  return chance(random, 0.1) ? '' : generatedAmount(random).trim();
}

function genericValue(random) {
  const kind = between(random, 0, 5);
  if (kind === 0) return generatedDateValue(random);
  if (kind === 1) return generatedAmountValue(random);
  if (kind === 2) return pick(random, FIRST_NAMES);
  if (kind === 3) return pick(random, MEMOS);
  if (kind === 4) return pick(random, ['out', 'in', 'Debit', 'Credit', 'OUT']);
  return pick(random, CATEGORY_NAMES);
}

// A random table for the mapping families. The header sampling keeps names unique
// unless a duplicate is requested, so csv-parse never receives an invalid header.
function generatedTable(random) {
  const hasHeaderRow = chance(random, 0.8);
  const columnCount = between(random, 1, 8);
  const names = [];
  while (names.length < columnCount) {
    const name = pick(random, HEADER_POOL);
    if (chance(random, 0.04) || !names.includes(name)) names.push(name);
  }
  const rowCount = chance(random, 0.08) ? 0 : between(random, 1, 3);
  const rows = [];
  for (let rowIndex = 0; rowIndex < rowCount; rowIndex += 1) {
    const width = chance(random, 0.1) ? between(random, 1, columnCount + 2) : columnCount;
    const values = [];
    for (let columnIndex = 0; columnIndex < width; columnIndex += 1) {
      const name = names[columnIndex] ?? '';
      const lowered = String(name).toLowerCase();
      let value;
      if (lowered.includes('date')) value = generatedDateValue(random);
      else if (lowered.includes('amount') || lowered === 'debit' || lowered === 'credit' || lowered === 'balance') value = generatedAmountValue(random);
      else value = genericValue(random);
      if (chance(random, 0.03)) value = `${value}\n`;
      if (chance(random, 0.03)) value = `${value}, ${pick(random, FIRST_NAMES)}`;
      values.push(value);
    }
    rows.push(values);
  }
  const csv = table(hasHeaderRow ? names : null, rows, {
    newline: pick(random, ['\r\n', '\n']),
    trailing: chance(random, 0.8),
  });
  return { csv: chance(random, 0.04) ? `﻿${csv}` : csv, hasHeaderRow, names, rows };
}

// getInitialMappings: builds with the table's own hasHeaderRow flag.
function mappingsGeneratedCases(family, prefix, description, extend) {
  const random = mulberry32(SEEDS[family]);
  const cases = [];
  for (let index = 0; index < GENERATED_COUNTS[family]; index += 1) {
    const built = generatedTable(random);
    cases.push(generated(`${prefix}/gen-${pad(index, 3)}`, family, extend(random, built), description));
  }
  return cases;
}

function getInitialDateFormatNamed() {
  const dateCaseCsv = (id, csv, description, hasHeaderRow = true) =>
    named(`getInitialDateFormat/${id}`, csvInput(csv, hasHeaderRow), description);
  const dateRow = (value, header = 'Date') => table([header, 'Amount'], [[value, '1.00']]);
  const cases = [
    dateCaseCsv('iso', dateRow('2026-01-05'), 'yyyy-mm-dd date'),
    dateCaseCsv('day-first', dateRow('31/12/2026'), 'day first: only dd mm yyyy parses'),
    dateCaseCsv('month-first', dateRow('12/31/2026'), 'month first'),
    dateCaseCsv('two-digit-year-first', dateRow('26-01-05'), 'two-digit year first: yyyy mm dd also parses'),
    dateCaseCsv('unreadable', dateRow('abc'), 'no format parses'),
    dateCaseCsv('no-date-column', table(['Other', 'Amount'], [['2026-01-05', '1.00']]), 'mapped by shape: other columns'),
    dateCaseCsv('empty-file', '', 'no rows'),
    dateCaseCsv('no-date-mapping', table(['Payee', 'Notes'], [['Example', 'note']]), 'no date column mapped'),
    dateCaseCsv('indexed', '05.01.2026,1.00\r\n', 'headerless file keyed by index', false),
    dateCaseCsv('indexed-iso', '2026-01-05,1.00\r\n', 'headerless ISO date', false),
    dateCaseCsv('empty-date-value', dateRow(''), 'an empty date value'),
    dateCaseCsv('missing-date-value', 'Date,Amount\r\n', 'a header and no rows'),
    dateCaseCsv('short-row', 'Amount,Date\r\n1.00\r\n', 'the date cell is absent from a short row'),
    dateCaseCsv('month-names', dateRow('5 Jan 2026'), 'a month name'),
    dateCaseCsv('compact-eight', dateRow('20260105'), 'eight digits'),
    dateCaseCsv('compact-six', dateRow('050126'), 'six digits'),
    dateCaseCsv('time-suffix', dateRow('2026-01-05 12:30'), 'a time suffix'),
    dateCaseCsv('impossible-day', dateRow('2026-02-30'), 'an impossible day in every order'),
    dateCaseCsv('impossible-everywhere', dateRow('99/99/9999'), 'impossible in every order'),
    dateCaseCsv('ambiguous', dateRow('01/02/2026'), 'both orders read it: the format list order decides'),
    dateCaseCsv('ambiguous-short', dateRow('01/02/03'), 'readable as yy mm dd first'),
    dateCaseCsv('second-row-ignored', table(['Date'], [['abc'], ['2026-01-05']]), 'only the first row is used'),
    dateCaseCsv('posting-date', table(['Posting Date', 'Amount'], [['12/31/2026', '1.00']]), 'Posting Date header'),
    dateCaseCsv('lowercase-date', table(['date', 'amount'], [['2026-01-05', '1.00']]), 'lowercase date header'),
    dateCaseCsv('two-date-columns', table(['Posting Date', 'Transaction Date'], [['31/12/2026', '2026-01-05']]), 'the first date column decides'),
    dateCaseCsv('numeric-header', table(['0', 'Date'], [['12', '31/12/2026']]), 'an integer-like header sorts first but is not a date name'),
    dateCaseCsv('leap-valid', dateRow('29/02/2024'), 'a valid leap day'),
    dateCaseCsv('leap-invalid-only-mdy-year', dateRow('02/29/2023'), 'an invalid leap day'),
    dateCaseCsv('shape-date-in-second', table(['x', 'y'], [['hello', '12/31/2026']]), 'date found by shape'),
    dateCaseCsv('quoted-padded', 'Date,Amount\r\n" 2026-01-05 ",1.00\r\n', 'a quoted value keeps its padding'),
    dateCaseCsv('bom', `﻿${dateRow('2026-01-05')}`, 'a leading byte order mark'),
    dateCaseCsv('arabic-digits', dateRow('٢٠٢٦-٠١-٠٥'), 'non-ASCII digits'),
  ];
  return cases;
}

function getInitialDateFormatGenerated() {
  return mappingsGeneratedCases('dateFormat', 'getInitialDateFormat', 'seeded table with a random date column',
    (random, built) => {
      // Bias toward a readable first date so every format answer is reached.
      if (built.hasHeaderRow && built.rows.length > 0 && chance(random, 0.6)) {
        const column = built.names.findIndex(name => String(name).toLowerCase().includes('date'));
        if (column >= 0 && built.rows[0].length > column) {
          built.rows[0][column] = dateString(random);
          return csvInput(table(built.names, built.rows), true);
        }
      }
      return csvInput(built.csv, built.hasHeaderRow);
    });
}

// ---------------------------------------------------------------------------
// applyFieldMappings

const MAPPING_FIELDS = ['date', 'amount', 'payee', 'notes', 'inOut', 'category'];

// A mapping is [key, value] pairs in JSON.parse order, so a replay never relies on object key order.
function mappingObject(values) {
  return MAPPING_FIELDS.map(field => [field, values[field] ?? null]);
}

function applyNamed() {
  const apply = (id, csv, mappings, description, hasHeaderRow = true) =>
    named(`applyFieldMappings/${id}`, { ...csvInput(csv, hasHeaderRow), mappings: mappingObject(mappings) }, description);
  const standard = table(['Date', 'Amount', 'Payee', 'Notes', 'Category', 'Type'],
    [['2026-01-05', '-12.34', 'Example Store', 'memo', 'Dining', 'out'], ['2026-01-06', '5.00', 'Sample Cafe', '', 'Fuel', 'in']]);
  const full = { date: 'Date', amount: 'Amount', payee: 'Payee', notes: 'Notes', inOut: 'Type', category: 'Category' };
  return [
    apply('full', standard, full, 'every field mapped to its column'),
    apply('no-mappings', standard, {}, 'every target null: the field name is the column name'),
    apply('swapped', standard, { date: 'Amount', amount: 'Date', payee: 'Notes', notes: 'Payee' }, 'columns assigned to the wrong fields'),
    apply('missing-column', standard, { date: 'Posted', amount: 'Amount' }, 'a target naming no column is undefined'),
    apply('empty-target', standard, { date: '', amount: '', payee: '' }, 'an empty target falls back to the field name'),
    apply('case-sensitive-target', standard, { date: 'date', amount: 'AMOUNT' }, 'targets are case sensitive'),
    apply('payee-unmapped', standard, { date: 'Date' }, 'payee_name is read from a column named payee_name'),
    apply('payee-name-column', table(['Date', 'payee_name', 'Amount'], [['2026-01-05', 'Example Store', '1.00']]), { date: 'Date' },
      'a column literally named payee_name is the unmapped payee'),
    apply('field-name-columns', table(['date', 'amount', 'payee', 'notes', 'inOut', 'category'], [['2026-01-05', '1.00', 'P', 'N', 'I', 'C']]), {},
      'unmapped fields read the columns that carry their own names'),
    apply('trx-id-target', standard, { date: 'trx_id' }, 'trx_id is the row number the modal assigned'),
    apply('trx-id-column-replaced', table(['trx_id', 'Date'], [['abc', '2026-01-05'], ['def', '2026-01-06']]), { payee: 'trx_id' },
      'a trx_id column is overwritten by the parse step'),
    apply('existing-target', standard, { date: 'existing', amount: 'ignored', payee: 'tombstone' }, 'bookkeeping names read as undefined'),
    apply('proto-column', table(['__proto__', 'Date'], [['x', '2026-01-05']]), { date: 'Date', payee: '__proto__' }, 'a __proto__ header'),
    apply('headerless', table(null, [['2026-01-05', '-12.34', 'Example Store', 'memo', 'out'], ['2026-01-06', '5.00', 'Sample Cafe', 'memo2', 'in']]),
      { date: '0', amount: '1', payee: '2', notes: '3', inOut: '4' }, 'column indices as targets', false),
    apply('headerless-beyond', table(null, [['2026-01-05', '1.00']]), { date: '0', amount: '1', payee: '7' }, 'an index beyond the row is undefined', false),
    apply('headerless-names', table(null, [['2026-01-05', '1.00']]), { date: 'Date' }, 'a name on a headerless file', false),
    apply('numeric-headers', table(['0', '1', '2'], [['2026-01-05', '1.00', 'Example']]), { date: '0', amount: '1', payee: '2' }, 'numeric headers with a header row'),
    apply('numeric-leading-zero', table(['01', '1'], [['a', 'b']]), { date: '01', amount: '1' }, '01 and 1 are different keys'),
    apply('duplicate-headers', table(['Date', 'Date', 'Amount'], [['2026-01-05', '2026-02-06', '1.00']]), { date: 'Date', amount: 'Amount' }, 'duplicate header names'),
    apply('short-row', 'Date,Amount,Payee\r\n2026-01-05\r\n', full, 'a short row leaves later columns undefined'),
    apply('long-row', 'Date,Amount\r\n2026-01-05,1.00,Example,extra\r\n', { date: 'Date', amount: 'Amount', payee: 'Payee' }, 'a long row loses extra cells'),
    apply('quoted-values', table(['Date', 'Amount', 'Payee', 'Notes'], [['2026-01-05', '1.00', 'Store, Inc.', 'line one\nline two'], ['2026-01-06', '2.00', 'The "Best" Store', '']]),
      { date: 'Date', amount: 'Amount', payee: 'Payee', notes: 'Notes' }, 'quoted commas, newlines and quotes'),
    apply('padded-values', 'Date,Amount,Payee\r\n 2026-01-05 , 1.00 ," Example "\r\n', { date: 'Date', amount: 'Amount', payee: 'Payee' }, 'unquoted values are trimmed, quoted kept'),
    apply('bom', `﻿${standard}`, full, 'a leading byte order mark'),
    apply('non-ascii-values', table(['Date', 'Amount', 'Payee'], [['٢٠٢٦-٠١-٠٥', '١٢٫٥٠', 'Café Ñandú 😀']]), { date: 'Date', amount: 'Amount', payee: 'Payee' }, 'non-ASCII values pass through'),
    apply('non-ascii-headers', table(['Dätum', 'Betrag'], [['05.01.2026', '12,50']]), { date: 'Dätum', amount: 'Betrag' }, 'non-ASCII headers as targets'),
    apply('empty-header-target', table(['', 'Amount'], [['x', '1.00']]), { date: '' }, 'an empty target never selects an empty-named column'),
    apply('empty-header-column-field', table(['', 'Amount'], [['x', '1.00']]), { payee: 'Amount' }, 'an empty header name in the file'),
    apply('empty-file', '', full, 'no rows: an empty result'),
    apply('header-only', 'Date,Amount\r\n', full, 'no data rows: an empty result'),
    apply('single-row', table(['Date'], [['2026-01-05']]), full, 'one row, one column'),
    apply('combining-target', table(['Daté', 'Date'], [['a', 'b']]), { date: 'Daté' }, 'combining marks are distinct code points'),
    apply('precomposed-vs-decomposed', table(['ä', 'ä'], [['precomposed', 'decomposed']]), { date: 'ä', amount: 'ä' }, 'canonically equivalent keys differ in JS'),
    apply('inout-target', standard, { inOut: 'Type', amount: 'Amount' }, 'the inOut field'),
  ];
}

function applyGenerated() {
  return mappingsGeneratedCases('applyMappings', 'applyFieldMappings', 'seeded table with seeded field mappings', (random, built) => {
    // A target that reads an inherited member (__proto__) or the boolean `selected`
    // would not be a string; those are kept out of the contract on purpose.
    const targets = [...built.names.map(String), 'Date', 'Amount', 'Payee', 'trx_id', 'missing', '', '0', '1', 'existing', 'tombstone']
      .filter(name => name !== '__proto__' && name !== 'selected');
    const mappings = MAPPING_FIELDS.map(field => [field, chance(random, 0.35) ? null : pick(random, targets)]);
    return { ...csvInput(built.csv, built.hasHeaderRow), mappings };
  });
}

// ---------------------------------------------------------------------------
// parseCategoryFields

const CATEGORY_LIST = [
  { id: 'cat-0001', name: 'Dining' },
  { id: 'cat-0002', name: 'Groceries' },
  { id: 'cat-0003', name: 'Fuel' },
  { id: 'cat-0004', name: 'Dining' },
  { id: 'cat-0005', name: 'dining' },
  { id: 'Fuel', name: 'Rent' },
  { id: 'cat-0007', name: 'Dining ' },
  { id: 'cat-0008', name: '' },
  { id: 'cat-0009', name: 'cat-0002' },
  { id: 'Books', name: 'Books' },
];

function parseCategoryNamed() {
  const category = (id, text, categories, description) => named(`parseCategoryFields/${id}`, { category: text, categories }, description);
  return [
    category('exact', 'Groceries', CATEGORY_LIST, 'an exact name'),
    category('case-different', 'GROCERIES', CATEGORY_LIST, 'names are case sensitive'),
    category('lower', 'dining', CATEGORY_LIST, 'a lowercase name that exists only in lowercase'),
    category('duplicate-names', 'Dining', CATEGORY_LIST, 'duplicate names: the first in the list wins'),
    category('duplicate-names-reversed', 'Dining', [...CATEGORY_LIST].reverse(), 'the same list reversed'),
    category('trailing-space-name', 'Dining ', CATEGORY_LIST, 'a name with a trailing space'),
    category('trailing-space-text', 'Groceries ', CATEGORY_LIST, 'text with a trailing space'),
    category('equals-id', 'cat-0001', CATEGORY_LIST, 'text equal to a category id that is nobody\'s name'),
    category('equals-id-of-name', 'cat-0002', CATEGORY_LIST, 'text equal to an id and also to another category\'s name'),
    category('id-equals-name', 'Books', CATEGORY_LIST, 'a category whose id equals its own name is skipped'),
    category('name-is-other-id', 'Fuel', CATEGORY_LIST, 'text equal to one category\'s id and another\'s name'),
    category('empty-string', '', CATEGORY_LIST, 'an empty string matches an empty name'),
    category('empty-string-no-empty-name', '', CATEGORY_LIST.slice(0, 3), 'an empty string with no empty name'),
    category('null', null, CATEGORY_LIST, 'no category text'),
    category('null-with-empty-name', null, CATEGORY_LIST, 'null never equals an empty name'),
    category('no-categories', 'Dining', [], 'an empty category list'),
    category('unknown', 'Entertainment', CATEGORY_LIST, 'an unknown name'),
    category('unicode', 'Café', [{ id: 'cat-0010', name: 'Café' }, { id: 'cat-0011', name: 'Café' }], 'precomposed against decomposed'),
    category('unicode-decomposed', 'Café', [{ id: 'cat-0010', name: 'Café' }, { id: 'cat-0011', name: 'Café' }], 'decomposed text'),
    category('whitespace-only', '  ', [{ id: 'cat-0012', name: '  ' }], 'whitespace-only name'),
    category('first-and-only', 'Rent', [{ id: 'cat-0013', name: 'Rent' }], 'a single category'),
  ];
}

function parseCategoryGenerated() {
  const random = mulberry32(SEEDS.category);
  const names = ['Dining', 'dining', 'DINING', 'Groceries', 'Fuel', 'Rent', 'Books', 'Cafe', 'Café', 'Café', '', ' Dining', 'Dining ', 'Pets', 'Fun & Games'];
  return Array.from({ length: GENERATED_COUNTS.category }, (_, index) => {
    const count = between(random, 0, 6);
    const categories = Array.from({ length: count }, (__, position) => {
      const name = pick(random, names);
      return { id: chance(random, 0.15) ? pick(random, names) : `cat-${pad(index, 3)}-${position + 1}`, name };
    });
    const pool = [...names, ...categories.map(entry => entry.id)];
    const text = chance(random, 0.1) ? null : pick(random, pool);
    return generated(`parseCategoryFields/gen-${pad(index, 3)}`, 'category', { category: text, categories },
      'seeded category list and text, with ids and names that collide');
  });
}

// ---------------------------------------------------------------------------
// pipeline: the modal's default-settings CSV import

// A default-settings import: every saved setting absent, except a headerless file's saved flag.
const pipelineInput = (csv, hasHeaderRow = true, categories = PIPELINE_CATEGORIES) =>
  pipelineSettingsInput({ csv, prefs: hasHeaderRow ? [] : [[PREF.header, 'false']], categories });

function pipelineNamed() {
  const pipeline = (id, csv, description, hasHeaderRow = true, categories = PIPELINE_CATEGORIES) =>
    named(`pipeline/${id}`, pipelineInput(csv, hasHeaderRow, categories), description);
  const lower = ['date', 'amount', 'payee', 'notes', 'category'];
  return [
    pipeline('lowercase-date-sorted', table(lower, [
      ['2026-01-05', '-12.34', 'Example Store', 'a', 'Dining'],
      ['2026-03-01', '5.00', 'Sample Cafe', 'b', ''],
      ['2026-02-10', '-7.25', 'Test Market', 'c', 'Groceries'],
      ['2026-03-01', '1.00', 'Same Day', 'd', 'Fuel'],
    ]), 'a lowercase date column: rows come out newest first, ties in file order'),
    pipeline('titlecase-date-not-sorted', table(['Date', 'Amount', 'Payee', 'Notes', 'Category'], [
      ['2026-01-05', '-12.34', 'Example Store', 'a', 'Dining'],
      ['2026-03-01', '5.00', 'Sample Cafe', 'b', ''],
      ['2026-02-10', '-7.25', 'Test Market', 'c', 'Groceries'],
    ]), 'a Date column is not the raw date column: file order is kept'),
    pipeline('posting-date-plus-date', table(['Posting Date', 'date', 'Amount', 'Payee'], [
      ['2026-01-05', '2026-02-01', '-1.00', 'One'],
      ['2026-01-06', 'pending', '-2.00', 'Two'],
      ['2026-01-07', '2026-02-03', '-3.00', 'Three'],
      ['2026-01-08', '', '-4.00', 'Four'],
      ['2026-01-09', '2026-02-02', '-5.00', 'Five'],
    ]), 'the mapped date column differs from the sort column; the sort column has unreadable rows'),
    pipeline('sort-column-differs', table(['Posting Date', 'date', 'Amount', 'Payee'], [
      ['2026-01-05', '2026-02-01', '-1.00', 'One'],
      ['2026-01-06', '2026-02-03', '-2.00', 'Two'],
      ['2026-01-07', '2026-02-02', '-3.00', 'Three'],
    ]), 'sorted by the date column, mapped from Posting Date'),
    pipeline('unreadable-date', table(lower, [
      ['2026-01-05', '-12.34', 'Example Store', 'a', ''],
      ['not a date', '5.00', 'Sample Cafe', 'b', ''],
    ]), 'a date nobody can read stops the import'),
    pipeline('unreadable-date-titlecase', table(['Date', 'Amount', 'Payee'], [
      ['2026-01-05', '-12.34', 'Example Store'],
      ['', '5.00', 'Sample Cafe'],
    ]), 'an empty date in file order'),
    pipeline('unreadable-amount', table(['Date', 'Amount', 'Payee'], [['2026-01-05', 'abc', 'Example Store']]), 'an unreadable amount becomes 0'),
    pipeline('currency-amount', table(['Date', 'Amount', 'Payee'], [['2026-01-05', '$1,234.56', 'Example Store'], ['2026-01-06', '($25.00)', 'Sample Cafe']]), 'currency and parentheses'),
    pipeline('eu-amount', table(['Date', 'Amount', 'Payee'], [['05/01/2026', '1.234,56', 'Example Store'], ['06/01/2026', '-0,5', 'Sample Cafe']]), 'EU number format'),
    pipeline('us-dates', table(['Date', 'Amount', 'Payee'], [['12/31/2026', '1.00', 'A'], ['01/02/2026', '2.00', 'B']]), 'month-first dates'),
    pipeline('eu-dates', table(['Date', 'Amount', 'Payee'], [['31/12/2026', '1.00', 'A'], ['01/02/2026', '2.00', 'B']]), 'day-first dates'),
    pipeline('headerless', table(null, [['2026-01-05', '-12.34', 'Example Store', 'memo'], ['2026-01-06', '5.00', 'Sample Cafe', 'memo2']]),
      'a headerless file maps by position', false),
    pipeline('headerless-single-column', table(null, [['2026-01-05'], ['2026-01-06']]), 'one column, headerless', false),
    pipeline('category-exact', table(['Date', 'Amount', 'Payee', 'Category'], [['2026-01-05', '1.00', 'A', 'Dining']]), 'a category matches by exact name'),
    pipeline('category-case-different', table(['Date', 'Amount', 'Payee', 'Category'], [['2026-01-05', '1.00', 'A', 'dining']]), 'a different-case category does not match'),
    pipeline('category-unknown', table(['Date', 'Amount', 'Payee', 'Category'], [['2026-01-05', '1.00', 'A', 'Entertainment']]), 'an unknown category'),
    pipeline('category-is-id', table(['Date', 'Amount', 'Payee', 'Category'], [['2026-01-05', '1.00', 'A', 'cat-dining']]), 'text equal to an id'),
    pipeline('no-category-column', table(['Date', 'Amount', 'Payee'], [['2026-01-05', '1.00', 'A']]), 'no category column'),
    pipeline('no-categories', table(['Date', 'Amount', 'Payee', 'Category'], [['2026-01-05', '1.00', 'A', 'Dining']]), 'no categories in the budget', true, []),
    pipeline('shape-only', table(['a', 'b', 'c', 'd'], [['2026-01-05', '12.50', 'Example Store', 'memo']]), 'columns guessed by value shape'),
    pipeline('payee-missing', table(['Date', 'Amount'], [['2026-01-05', '1.00']]), 'no payee column: the payee is the unmapped payee_name, undefined'),
    pipeline('notes-leftover', table(['Date', 'Amount', 'Description', 'Memo'], [['2026-01-05', '1.00', 'Example Store', 'a note']]), 'description is the payee and memo becomes the notes by position'),
    pipeline('inout-leftover', table(['Date', 'Amount', 'Payee', 'Memo', 'Type'], [['2026-01-05', '1.00', 'A', 'm', 'out']]), 'a fifth column is only the in/out guess'),
    pipeline('empty-file', '', 'no rows'),
    pipeline('header-only', 'Date,Amount,Payee\r\n', 'a header and no rows'),
    pipeline('short-rows', 'Date,Amount,Payee\r\n2026-01-05,1.00\r\n2026-01-06\r\n', 'short rows: amount and payee undefined'),
    pipeline('bom', `﻿${table(['Date', 'Amount', 'Payee'], [['2026-01-05', '1.00', 'A']])}`, 'a byte order mark'),
    pipeline('quoted-fields', table(['Date', 'Amount', 'Payee', 'Notes'], [['2026-01-05', '1.00', 'Store, Inc.', 'line one\nline two']]), 'quoted commas and newlines'),
    pipeline('compact-dates', table(['Date', 'Amount', 'Payee'], [['20260105', '1.00', 'A'], ['20260106', '2.00', 'B']]), 'compact dates'),
    pipeline('month-name-dates', table(['Date', 'Amount', 'Payee'], [['5 Jan 2026', '1.00', 'A'], ['6 Feb 2026', '2.00', 'B']]), 'month-name dates'),
    pipeline('two-digit-year', table(['Date', 'Amount', 'Payee'], [['01/05/26', '1.00', 'A'], ['01/06/26', '2.00', 'B']]), 'two-digit years'),
    pipeline('first-row-decides-format', table(['Date', 'Amount', 'Payee'], [['31/12/2026', '1.00', 'A'], ['12/31/2026', '2.00', 'B']]), 'the first row decides the format, a later row fails'),
    pipeline('sorted-all-same-date', table(lower, [
      ['2026-01-05', '1.00', 'A', '', ''], ['2026-01-05', '2.00', 'B', '', ''], ['2026-01-05', '3.00', 'C', '', ''],
    ]), 'equal dates keep file order'),
    pipeline('sorted-unreadable-all', table(lower, [
      ['x', '1.00', 'A', '', ''], ['y', '2.00', 'B', '', ''],
    ]), 'every sort date unreadable: no reorder, then the date error'),
    pipeline('actual-export', table(['Account', 'Date', 'Payee', 'Notes', 'Category_Group', 'Category', 'Amount', 'Split_Amount', 'Cleared'], [
      ['Checking', '2026-01-05', 'Example Store', 'memo', 'Food', 'Dining', '-12.34', '0', 'Cleared'],
      ['Checking', '2026-01-06', 'Sample Cafe', '', 'Food', 'Groceries', '-7.25', '0', 'Not cleared'],
      ['Checking', '2026-01-07', 'Test Market', 'n', 'Bills', 'Fuel', '-30.00', '0', 'Reconciled'],
    ]), "the shape of Actual's own account export: first header containing category is Category_Group"),
    pipeline('actual-export-split', table(['Account', 'Date', 'Payee', 'Notes', 'Category_Group', 'Category', 'Amount', 'Split_Amount', 'Cleared'], [
      ['Checking', '2026-01-05', 'Example Store', '(SPLIT INTO 2) memo', '', '', '0', '-12.34', 'Cleared'],
      ['Checking', '2026-01-05', 'Example Store', 'memo', 'Food', 'Dining', '-5.00', '0', 'Cleared'],
      ['Checking', '2026-01-05', 'Example Store', 'memo', 'Food', 'Groceries', '-7.34', '0', 'Cleared'],
    ]), "an Actual split export: a zero-amount parent and two children"),
    pipeline('no-notes-header-cleared', table(['Date', 'Payee', 'Amount', 'Cleared'], [['2026-01-05', 'Example Store', '-12.34', 'Cleared']]), 'no Notes header: the leftover columns decide notes and in/out'),
    pipeline('imported-id-column', table(['Date', 'Payee', 'Notes', 'Amount', 'imported_id'], [['2026-01-05', 'Example Store', 'memo', '-12.34', 'id-0001']]), 'an imported_id column is only a leftover guess'),
    pipeline('large-amount', table(['Date', 'Amount', 'Payee'], [['2026-01-05', '22517998136852.47', 'A']]), 'near the safe limit'),
    pipeline('half-cent', table(['Date', 'Amount', 'Payee'], [['2026-01-05', '0.005', 'A'], ['2026-01-06', '-0.005', 'B'], ['2026-01-07', '1.005', 'C']]), 'rounding to cents'),
  ];
}

function pipelineRow(random, style) {
  const date = style.date(random);
  const amount = style.amount(random);
  return [date, amount, pick(random, FIRST_NAMES), pick(random, MEMOS), chance(random, 0.6) ? pick(random, [...CATEGORY_NAMES, 'Entertainment']) : ''];
}

function makeStyle(random, { forceReadable }) {
  const order = pick(random, ['ymd', 'mdy', 'dmy']);
  const separator = pick(random, ['-', '/', '.']);
  const shortYear = chance(random, 0.2);
  return {
    date(innerRandom) {
      if (!forceReadable && chance(innerRandom, 0.07)) return pick(innerRandom, ['', 'n/a', 'pending', '99/99/9999']);
      const year = between(innerRandom, 2020, 2027);
      const month = between(innerRandom, 1, 12);
      const day = between(innerRandom, 1, 28);
      const two = value => String(value).padStart(2, '0');
      const yearText = shortYear ? two(year % 100) : String(year);
      const parts = order === 'ymd' ? [yearText, two(month), two(day)]
        : order === 'mdy' ? [two(month), two(day), yearText] : [two(day), two(month), yearText];
      return parts.join(separator);
    },
    amount(innerRandom) {
      const kind = between(innerRandom, 0, 5);
      const whole = between(innerRandom, 0, 3000);
      const cents = String(between(innerRandom, 0, 99)).padStart(2, '0');
      if (kind === 0) return `-${whole}.${cents}`;
      if (kind === 1) return `${whole}.${cents}`;
      if (kind === 2) return `$${groupedInteger(innerRandom, String(whole), ',')}.${cents}`;
      if (kind === 3) return `(${whole}.${cents})`;
      if (kind === 4) return `${groupedInteger(innerRandom, String(whole), '.')},${cents}`;
      return chance(innerRandom, 0.5) ? 'abc' : `${whole}`;
    },
  };
}

const PIPELINE_HEADER_SETS = [
  ['date', 'amount', 'payee', 'notes', 'category'],
  ['Date', 'Amount', 'Payee', 'Notes', 'Category'],
  ['Posting Date', 'Amount', 'Description', 'Memo', 'Category'],
  ['date', 'Posting Date', 'Amount', 'Payee', 'Notes'],
  ['Transaction Date', 'Description', 'Amount'],
  ['date', 'amount', 'payee'],
];

function pipelineGenerated() {
  const random = mulberry32(SEEDS.pipeline);
  const cases = [];
  for (let index = 0; index < GENERATED_COUNTS.pipeline; index += 1) {
    const headerless = chance(random, 0.08);
    const header = pick(random, PIPELINE_HEADER_SETS);
    const style = makeStyle(random, { forceReadable: chance(random, 0.4) });
    const rowCount = between(random, 1, 12);
    const rows = Array.from({ length: rowCount }, () => {
      const row = pipelineRow(random, style);
      // The header sets are narrower than the row template; keep the leading columns.
      return headerless ? row : row.slice(0, header.length);
    });
    const categories = chance(random, 0.1) ? [] : PIPELINE_CATEGORIES;
    cases.push(generated(`pipeline/gen-${pad(index, 3)}`, 'pipeline', pipelineInput(table(headerless ? null : header, rows), !headerless, categories),
      'seeded small file with a consistent date layout and occasional unreadable values'));
  }
  return cases;
}

function pipelineLarge() {
  const random = mulberry32(SEEDS.pipelineLarge);
  return Array.from({ length: GENERATED_COUNTS.pipelineLarge }, (_, index) => {
    const style = makeStyle(random, { forceReadable: true });
    const header = index % 3 === 0 ? ['Date', 'Amount', 'Payee', 'Notes', 'Category'] : ['date', 'amount', 'payee', 'notes', 'category'];
    const rowCount = between(random, 70, 150);
    const dateCount = between(random, 5, rowCount);
    const pool = Array.from({ length: dateCount }, () => style.date(random));
    const rows = Array.from({ length: rowCount }, () => {
      const row = pipelineRow(random, style);
      row[0] = pick(random, pool);
      row[1] = `${between(random, 0, 900)}.${String(between(random, 0, 99)).padStart(2, '0')}`;
      return row;
    });
    return generated(`pipeline/large-${pad(index, 2)}`, 'pipelineLarge', pipelineInput(table(header, rows)),
      'seeded file of 70 to 150 rows with repeated, consistently formatted dates');
  });
}

// ---------------------------------------------------------------------------

// One builder per registry entry; the plan refuses an entry without one.
export const CASE_BUILDERS = {
  looselyParseAmount: () => [...looselyParseAmountNamed(), ...looselyParseAmountGenerated()],
  amountToInteger: ({ looselyParseAmount }) => amountToIntegerCases(looselyParseAmount),
  parseDate: () => [...parseDateNamed(), ...parseDateGenerated()],
  getInitialMappings: () => [
    ...getInitialMappingsNamed(),
    ...mappingsGeneratedCases('mappings', 'getInitialMappings', 'seeded table with a random header set',
      (random, built) => csvInput(built.csv, built.hasHeaderRow)),
  ],
  getInitialDateFormat: () => [...getInitialDateFormatNamed(), ...getInitialDateFormatGenerated(), ...savedGetInitialDateFormatCases()],
  applyFieldMappings: () => [...applyNamed(), ...applyGenerated(), ...savedApplyFieldMappingsCases()],
  parseCategoryFields: () => [...parseCategoryNamed(), ...parseCategoryGenerated()],
  parseAmountFields: parseAmountFieldsCases,
  pipeline: () => [...pipelineNamed(), ...pipelineGenerated(), ...pipelineLarge(), ...savedPipelineCases()],
  parseCsvRecords: parseCsvRecordsCases,
  decodeCsvBytes: decodeCsvBytesCases,
};

function checkRegexChecklist(cases) {
  const byId = new Map(cases.map(planCase => [planCase.id, planCase]));
  for (const entry of REGEX_ALTERNATIVE_CHECKLIST) {
    const planCase = byId.get(entry.caseId);
    if (!planCase) throw new Error(`Regex checklist: no case ${entry.caseId} for ${entry.label}`);
    const text = planCase.input[entry.field];
    if (typeof text !== 'string' || !entry.pattern.test(text)) {
      throw new Error(`Regex checklist: ${entry.caseId} does not exercise ${entry.label}`);
    }
  }
}

export function buildPlan() {
  REGEX_ALTERNATIVE_CHECKLIST.length = 0;
  const byFunction = {};
  for (const entry of REGISTRY) {
    const build = CASE_BUILDERS[entry.name];
    if (!build) throw new Error(`No case builder for registered function ${entry.name}`);
    byFunction[entry.name] = build(byFunction).map(planCase => ({ function: entry.name, ...planCase }));
    if (byFunction[entry.name].length === 0) throw new Error(`${entry.name} has no cases`);
  }
  const cases = REGISTRY.flatMap(entry => byFunction[entry.name]);
  checkRegexChecklist(cases);
  checkCsvParseChecklist(cases);
  checkDecodeChecklist(cases);
  return { seed: SEED, cases };
}

const isTagged = value => value !== null && typeof value === 'object' && typeof value.$js === 'string';
const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value) && !isTagged(value);
const isTextOrUndefined = value => typeof value === 'string' || (isTagged(value) && value.$js === 'undefined');
const MAPPING_VALUE_FIELDS = ['date', 'amount', 'payee', 'notes', 'inOut', 'category'];
const MAPPING_PAIR_KEYS = [...MAPPING_VALUE_FIELDS, 'outflow', 'inflow'];

function validPipelineError(error) {
  if (!isObject(error)) return false;
  // A date column that names `selected` holds the boolean true, which the message prints as true.
  if (error.kind === 'date') return error.text === null || error.text === true || typeof error.text === 'string';
  if (error.kind === 'parse') return typeof error.message === 'string';
  return error.kind === 'mappings-json' && (error.reason === 'syntax' || error.reason === 'null');
}

// Structural invariants of a recorded case. They never restate an expected value.
export function expectationFailures(record, planCase) {
  const failures = [];
  const output = record.output;
  if (record.function !== planCase.function) failures.push('function differs from the plan');
  if (isTagged(output) && output.$js === 'threw') failures.push(`Actual threw: ${output.message}`);
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
    case 'parseDate':
      if (output !== null && !/^\d+-\d\d-\d\d$/.test(output ?? '')) failures.push('output is neither null nor a date string');
      break;
    case 'getInitialMappings':
      if (!isObject(output)) failures.push('output is not an object');
      else {
        const keys = Object.keys(output);
        if (keys.length !== 0 && JSON.stringify([...keys].sort()) !== JSON.stringify([...MAPPING_VALUE_FIELDS].sort())) {
          failures.push('output is neither {} nor the six mapping fields');
        }
        if (Object.values(output).some(value => value !== null && typeof value !== 'string')) failures.push('a mapping value is not a string or null');
      }
      break;
    case 'getInitialDateFormat':
      if (typeof output !== 'string') failures.push('output is not a string');
      if (planCase.input.mappings !== undefined
        && (!Array.isArray(planCase.input.mappings) || planCase.input.mappings.some(pair => !Array.isArray(pair) || pair.length !== 2 || !MAPPING_PAIR_KEYS.includes(pair[0])))) {
        failures.push('mappings is not an array of [key, value] pairs with known keys');
      }
      break;
    case 'applyFieldMappings':
      if (!Array.isArray(output)) failures.push('output is not an array');
      else {
        for (const item of output) {
          if (!isObject(item) || JSON.stringify(Object.keys(item)) !== JSON.stringify(['date', 'amount', 'payee_name', 'notes', 'inOut', 'category', 'outflow', 'inflow'])) {
            failures.push('an item does not have exactly the eight mapped keys');
          } else if (Object.values(item).some(value => !isTextOrUndefined(value) && value !== true)) {
            // `true` is the preview's `selected` flag, which a mapping can name as a column.
            failures.push('a mapped value is neither a string, undefined nor the boolean true');
          }
        }
      }
      if (!Array.isArray(planCase.input.mappings) || planCase.input.mappings.some(pair => !Array.isArray(pair) || pair.length !== 2 || !MAPPING_PAIR_KEYS.includes(pair[0]))) {
        failures.push('mappings is not an array of [key, value] pairs with known keys');
      }
      break;
    case 'parseCategoryFields':
      if (output !== null && typeof output !== 'string') failures.push('output is neither null nor an id');
      break;
    case 'parseAmountFields':
      if (!isObject(output) || JSON.stringify(Object.keys(output)) !== JSON.stringify(['amount', 'outflow', 'inflow'])) failures.push('output is not { amount, outflow, inflow }');
      else if (!planCase.input.splitMode && (output.outflow !== null || output.inflow !== null)) failures.push('outside split mode outflow and inflow are null');
      else if (Object.values(output).some(value => value !== null && typeof value !== 'number' && !isTagged(value))) failures.push('a result is not a number');
      break;
    case 'decodeCsvBytes':
      if (!isObject(output)) failures.push('output is not an object');
      else if (typeof output.text === 'string' && Object.keys(output).length === 1) break;
      else if (typeof output.error === 'string' && Object.keys(output).length === 1) break;
      else failures.push('output is neither { text } nor { error }');
      break;
    case 'parseCsvRecords':
      if (!isObject(output)) failures.push('output is not an object');
      else if (typeof output.error === 'string' && Object.keys(output).length === 1) break;
      else if (!Array.isArray(output.records) || Object.keys(output).length !== 1) failures.push('output is neither { error } nor { records }');
      else if (planCase.input.hasHeaderRow) {
        if (output.records.some(record => !isObject(record) || !Array.isArray(record.entries) || record.entries.some(entry => !Array.isArray(entry) || entry.length !== 2 || typeof entry[0] !== 'string' || typeof entry[1] !== 'string'))) {
          failures.push('a header record is not { entries: [[name, value]] } of strings');
        }
      } else if (output.records.some(record => !Array.isArray(record) || record.some(field => typeof field !== 'string'))) {
        failures.push('a record is not an array of strings');
      }
      break;
    case 'pipeline':
      if (!isObject(output)) failures.push('output is not an object');
      else if (output.error === undefined && !Array.isArray(output.transactions)) failures.push('output has neither error nor transactions');
      else if (output.error !== undefined && !validPipelineError(output.error)) {
        failures.push('error is not a date, parse or mappings-json error');
      }
      break;
    default:
  }
  return failures;
}
