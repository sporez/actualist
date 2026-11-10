// Cases that depend on settings Actual saves per account: saved field mappings (applyFieldMappings,
// getInitialDateFormat) and the whole modal flow with synced preferences (pipeline). Pure data:
// no expected output lives here.
//
// A mapping is an array of [key, value] pairs in the order JSON.parse would list them, so a
// replay never depends on object key order. Keys are any of date, amount, payee, notes, inOut,
// category, outflow, inflow (a key can be absent, which is not null); a value is a string, '',
// null, a number, or a boolean, the shapes a hand-edited or old preference could hold.
//
// A pipeline input is { accountId, fileName, prefs, csv | bytesBase64, categories }: `prefs` holds
// the account's synced preferences as the strings Actual stores them, as [key, value] pairs.
import { mulberry32 } from '../sync-merkle/cases.mjs';
import { base64, between, chance, delimitedText, encodeText, named, pad, pick, table } from './case-kit.mjs';

export const ACCOUNT_ID = 'acct-sample-01';
export const PREF = {
  mappings: `csv-mappings-${ACCOUNT_ID}`,
  delimiter: `csv-delimiter-${ACCOUNT_ID}`,
  encoding: `csv-encoding-${ACCOUNT_ID}`,
  header: `csv-has-header-${ACCOUNT_ID}`,
  skipStart: `csv-skip-start-lines-${ACCOUNT_ID}`,
  skipEnd: `csv-skip-end-lines-${ACCOUNT_ID}`,
  inOutMode: `csv-in-out-mode-${ACCOUNT_ID}`,
  outValue: `csv-out-value-${ACCOUNT_ID}`,
  parseDate: `parse-date-${ACCOUNT_ID}-csv`,
  flip: `flip-amount-${ACCOUNT_ID}-csv`,
  importNotes: `import-notes-${ACCOUNT_ID}-csv`,
};
const OTHER_ACCOUNT = 'acct-other-02';

export const PIPELINE_CATEGORIES = [
  { id: 'cat-dining', name: 'Dining' },
  { id: 'cat-groceries', name: 'Groceries' },
  { id: 'cat-fuel', name: 'Fuel' },
  { id: 'cat-books', name: 'Books' },
];

export const SAVED_SEEDS = {
  applyMappings: 20261109 + 14,
  dateFormat: 20261109 + 11,
  pipeline: 20261109 + 10,
};
export const SAVED_COUNTS = { applyMappings: 200, dateFormat: 120, pipeline: 300 };

const generatedCase = (id, seed, input, description) => ({ id, source: 'generated', description, seed, input });

const MAPPING_KEYS = ['date', 'amount', 'payee', 'notes', 'inOut', 'category', 'outflow', 'inflow'];
const csvInput = (csv, hasHeaderRow = true) => ({ csv, hasHeaderRow, delimiter: ',' });
const pairs = object => Object.entries(object);

// The mapping Actual saves for a header file: every key present, unused ones null.
const savedMapping = values => Object.fromEntries(MAPPING_KEYS.map(key => [key, values[key] ?? null]));

function shuffled(random, list) {
  const copy = [...list];
  for (let index = copy.length - 1; index > 0; index -= 1) {
    const other = between(random, 0, index);
    [copy[index], copy[other]] = [copy[other], copy[index]];
  }
  return copy;
}

// ---------------------------------------------------------------------------
// applyFieldMappings with saved mapping shapes

const SAVED_HEADER = ['Date', 'Amount', 'Payee', 'Notes', 'Category', 'Type', 'Debit', 'Credit'];
const SAVED_ROW = ['2026-01-05', '-12.34', 'Example Store', 'memo', 'Dining', 'out', '12.34', ''];
const SAVED_TABLE = table(SAVED_HEADER, [SAVED_ROW, ['2026-01-06', '5.00', 'Sample Cafe', '', 'Fuel', 'in', '', '5.00']]);
const SPLIT_MAPPING = { date: 'Date', payee: 'Payee', notes: 'Notes', outflow: 'Debit', inflow: 'Credit' };

function applySavedNamed() {
  const apply = (id, csv, mappings, description, hasHeaderRow = true) =>
    named(`applyFieldMappings/saved/${id}`, { ...csvInput(csv, hasHeaderRow), mappings }, description);
  const numericTable = table(['0', '1', '2', '3', 'true', 'false', ''], [['d0', 'a1', 'p2', 'n3', 'tr', 'fa', 'em']]);
  const headerless = table(null, [['2026-01-05', '-12.34', 'Example Store', 'memo', 'out'], ['2026-01-06', '5.00', 'Sample Cafe', '', 'in']]);
  const cases = [
    apply('split-mapping', SAVED_TABLE, pairs(savedMapping(SPLIT_MAPPING)), 'a saved Debit/Credit mapping fills outflow and inflow'),
    apply('split-inflow-only', SAVED_TABLE, pairs(savedMapping({ date: 'Date', inflow: 'Credit' })), 'only an inflow column saved'),
    apply('split-columns-missing', SAVED_TABLE, pairs(savedMapping({ date: 'Date', outflow: 'Out', inflow: 'In' })), 'outflow and inflow naming columns the file lacks'),
    apply('split-empty-targets', SAVED_TABLE, pairs(savedMapping({ date: 'Date', outflow: '', inflow: '' })), 'empty outflow and inflow targets read columns named outflow and inflow'),
    apply('split-columns-named-for-fields', table(['date', 'outflow', 'inflow'], [['2026-01-05', '1.00', '2.00']]), pairs(savedMapping({})),
      'null outflow and inflow targets read columns that carry those names'),
    apply('absent-keys', SAVED_TABLE, [['date', 'Date']], 'keys absent from the mapping are not read at all: every other field is undefined'),
    apply('absent-keys-field-named-columns', table(['date', 'amount', 'payee_name', 'notes'], [['2026-01-05', '1.00', 'P', 'N']]), [['date', 'date']],
      'a column named like an unmapped field is still not read'),
    apply('empty-mapping', SAVED_TABLE, [], 'an empty mapping reads nothing'),
    apply('only-split-keys', SAVED_TABLE, [['outflow', 'Debit'], ['inflow', 'Credit']], 'only outflow and inflow'),
    apply('order-a', SAVED_TABLE, [['amount', 'Amount'], ['date', 'Date'], ['payee', 'Payee']], 'keys in one order'),
    apply('order-b', SAVED_TABLE, [['payee', 'Payee'], ['date', 'Date'], ['amount', 'Amount']], 'the same keys in another order give the same result'),
    apply('duplicate-key', SAVED_TABLE, [['date', 'Amount'], ['payee', 'Payee'], ['date', 'Date']], 'JSON.parse keeps the last value of a repeated key'),
    apply('duplicate-key-null-last', SAVED_TABLE, [['date', 'Amount'], ['date', null]], 'a repeated key whose last value is null'),
    apply('value-empty', SAVED_TABLE, [['date', ''], ['amount', ''], ['payee', ''], ['notes', ''], ['inOut', ''], ['category', '']], 'empty strings fall back to the field name'),
    apply('value-null', SAVED_TABLE, [['date', null], ['amount', null]], 'null falls back to the field name'),
    apply('value-zero-header-file', numericTable, [['date', 0], ['amount', 1], ['payee', 2], ['notes', 3]], 'the number 0 is falsy: it falls back to the field name; others index a column'),
    apply('value-numbers-headerless', headerless, [['date', 0], ['amount', 1], ['payee', 2], ['notes', 3], ['inOut', 4]], 'numbers index a headerless row; zero falls back', false),
    apply('value-three', numericTable, [['date', 3], ['amount', 3]], 'the number 3 reads the column named 3'),
    apply('value-true', numericTable, [['date', true], ['amount', true]], 'true reads the column named true'),
    apply('value-false', numericTable, [['date', false], ['amount', false], ['payee', false]], 'false is falsy: it falls back to the field name'),
    apply('value-true-no-column', SAVED_TABLE, [['date', true]], 'true with no column named true'),
    apply('value-selected', SAVED_TABLE, [['date', 'selected'], ['amount', 'selected'], ['payee', 'selected'], ['notes', 'selected'], ['inOut', 'selected'],
      ['category', 'selected'], ['outflow', 'selected'], ['inflow', 'selected']], 'every field naming selected reads the boolean true set by the preview'),
    apply('value-trx-id', SAVED_TABLE, [['date', 'trx_id'], ['payee', 'trx_id']], 'trx_id reads the row number string'),
    apply('value-tombstone', SAVED_TABLE, [['date', 'tombstone'], ['payee', 'existing'], ['notes', 'ignored'], ['category', 'selected_merge']], 'bookkeeping names read undefined'),
    apply('value-selected-headerless', headerless, [['date', 'selected'], ['amount', 'trx_id']], 'selected and trx_id on a headerless row', false),
    apply('value-missing', SAVED_TABLE, [['date', 'Posted'], ['amount', 'Amt'], ['payee', 'Payee']], 'targets naming columns the file lacks'),
    apply('value-case', SAVED_TABLE, [['date', 'date'], ['amount', 'AMOUNT'], ['payee', 'payee']], 'targets are case sensitive'),
    apply('header-file-index-mapping', SAVED_TABLE, [['date', '0'], ['amount', '1'], ['payee', '2']], 'indices saved from a headerless file applied to a header file'),
    apply('headerless-name-mapping', headerless, [['date', 'Date'], ['amount', 'Amount']], 'names saved from a header file applied to a headerless one', false),
    apply('headerless-split', headerless, [['date', '0'], ['outflow', '1'], ['inflow', '2']], 'a split mapping on a headerless file', false),
    apply('headerless-beyond', headerless, [['date', '0'], ['amount', '9'], ['payee', 9]], 'an index beyond the row', false),
    apply('extra-mapped-twice', SAVED_TABLE, [['date', 'Date'], ['amount', 'Date'], ['payee', 'Date']], 'one column mapped to several fields'),
  ];
  return cases;
}

const SAVED_NAMES = ['Date', 'Amount', 'Payee', 'Notes', 'Category', 'Type', 'Debit', 'Credit', 'date', 'amount', '3', '0', 'true', 'false', '', 'trx_id',
  'selected', 'Posted', 'Memo', 'Balance', 'outflow', 'inflow', 'inOut'];
const SAVED_CELLS = ['2026-01-05', '12.34', '-5.00', 'Example Store', 'memo', '', 'Dining', 'DEBIT', 'x', '31/12/2026'];

function savedTable(random) {
  const hasHeaderRow = chance(random, 0.75);
  const columnCount = between(random, 1, 6);
  const names = [];
  while (names.length < columnCount) {
    const name = pick(random, SAVED_NAMES);
    if (!names.includes(name)) names.push(name);
  }
  const rows = Array.from({ length: between(random, 1, 2) }, () => Array.from({ length: columnCount }, () => pick(random, SAVED_CELLS)));
  return { csv: table(hasHeaderRow ? names : null, rows, { newline: pick(random, ['\r\n', '\n']) }), hasHeaderRow, names };
}

function randomTarget(random, names, hasHeaderRow) {
  const roll = random();
  if (roll < 0.45) return hasHeaderRow ? pick(random, names) : String(between(random, 0, 5));
  if (roll < 0.52) return '';
  if (roll < 0.62) return null;
  if (roll < 0.68) return 0;
  if (roll < 0.76) return between(random, 1, 4);
  if (roll < 0.8) return true;
  if (roll < 0.84) return false;
  if (roll < 0.9) return pick(random, ['missing', 'Posted', 'DATE']);
  if (roll < 0.94) return pick(random, ['selected', 'trx_id', 'tombstone', 'existing']);
  return pick(random, ['0', '1', '2', '3']);
}

function randomMappingPairs(random, names, hasHeaderRow) {
  const keys = shuffled(random, MAPPING_KEYS.filter(() => chance(random, 0.78)));
  return keys.map(key => [key, randomTarget(random, names, hasHeaderRow)]);
}

function applySavedGenerated() {
  const random = mulberry32(SAVED_SEEDS.applyMappings);
  return Array.from({ length: SAVED_COUNTS.applyMappings }, (_, index) => {
    const built = savedTable(random);
    return generatedCase(`applyFieldMappings/saved-gen-${pad(index, 3)}`, SAVED_SEEDS.applyMappings,
      { ...csvInput(built.csv, built.hasHeaderRow), mappings: randomMappingPairs(random, built.names, built.hasHeaderRow) },
      'seeded table with a saved mapping of random keys, order and value shapes');
  });
}

// ---------------------------------------------------------------------------
// getInitialDateFormat with an explicit mapping

function dateFormatSavedNamed() {
  const dated = (id, csv, mappings, description, hasHeaderRow = true) =>
    named(`getInitialDateFormat/saved/${id}`, { ...csvInput(csv, hasHeaderRow), mappings }, description);
  const iso = table(['Date', 'Amount'], [['2026-01-05', '1.00']]);
  const dmy = table(['Date', 'Amount'], [['31/12/2026', '12/31/2026']]);
  const numeric = table(['0', 'true', '', 'x'], [['31/12/2026', '2026-01-05', '12/31/2026', 'abc']]);
  return [
    dated('named-column', iso, pairs(savedMapping({ date: 'Date' })), 'a saved date column that holds a readable date'),
    dated('other-column', dmy, pairs(savedMapping({ date: 'Amount' })), 'a saved date column other than the guessed one'),
    dated('missing-column', iso, pairs(savedMapping({ date: 'Posted' })), 'a saved date column the file lacks: the cell is undefined'),
    dated('empty-string', iso, pairs(savedMapping({ date: '' })), 'date "" reads no column: not null, so the cell is undefined'),
    dated('empty-string-empty-column', numeric, [['date', '']], 'date "" reads a column whose header is empty'),
    dated('zero', numeric, [['date', 0]], 'the number 0 reads the column named 0'),
    dated('zero-headerless', '31/12/2026,1.00\r\n', [['date', 0]], 'the number 0 on a headerless file', false),
    dated('three-headerless', '1,2,3,12/31/2026\r\n', [['date', 3]], 'the number 3 on a headerless file', false),
    dated('null', iso, pairs(savedMapping({ date: null })), 'date null is the default year-first format'),
    dated('absent', iso, [['amount', 'Amount']], 'no date key: the default year-first format'),
    dated('empty-mapping', iso, [], 'an empty mapping'),
    dated('true', numeric, [['date', true]], 'date true reads the column named true'),
    dated('false', numeric, [['date', false]], 'date false reads the column named false: absent'),
    dated('selected', iso, [['date', 'selected']], 'the boolean true is not a string: no format reads it'),
    dated('trx-id', iso, [['date', 'trx_id']], 'the row number "0" is not a date'),
    dated('unreadable-value', table(['Date'], [['abc']]), [['date', 'Date']], 'an unreadable saved date value'),
    dated('empty-value', table(['Date', 'Amount'], [['', '1.00']]), [['date', 'Date']], 'an empty saved date value'),
    dated('day-first', table(['Date'], [['31/12/2026']]), [['date', 'Date']], 'day-first value'),
    dated('month-first', table(['Date'], [['12/31/2026']]), [['date', 'Date']], 'month-first value'),
    dated('empty-file', '', [['date', 'Date']], 'an empty file with a saved mapping'),
    dated('header-only', 'Date,Amount\r\n', [['date', 'Date']], 'no rows'),
    dated('indexed-string', '05.01.2026,1.00\r\n', [['date', '0']], 'a string index on a headerless file', false),
    dated('indexed-string-missing', '05.01.2026,1.00\r\n', [['date', '5']], 'a string index beyond the row', false),
  ];
}

const DATE_VALUES = ['2026-01-05', '31/12/2026', '12/31/2026', '05.01.2026', '20260105', 'abc', '', '2026-02-30', '5 Jan 2026', '01/02/26', '12-31-26'];

function dateFormatSavedGenerated() {
  const random = mulberry32(SAVED_SEEDS.dateFormat);
  return Array.from({ length: SAVED_COUNTS.dateFormat }, (_, index) => {
    const hasHeaderRow = chance(random, 0.8);
    const names = ['Date', 'Posted', '0', '1', 'true', '', 'Amount', 'x'].filter(() => chance(random, 0.6));
    if (names.length === 0) names.push('Date');
    const row = names.map(() => pick(random, DATE_VALUES));
    const target = hasHeaderRow
      ? randomTarget(random, names, true)
      : (chance(random, 0.5) ? String(between(random, 0, names.length)) : between(random, 0, names.length));
    const mappings = chance(random, 0.15)
      ? [['amount', 'Amount']]
      : [['date', target], ...MAPPING_KEYS.filter(key => key !== 'date' && chance(random, 0.3)).map(key => [key, pick(random, names)])];
    return generatedCase(`getInitialDateFormat/saved-gen-${pad(index, 3)}`, SAVED_SEEDS.dateFormat,
      { ...csvInput(table(hasHeaderRow ? names : null, [row]), hasHeaderRow), mappings },
      'seeded one-row table with a saved date mapping of a random shape');
  });
}

// ---------------------------------------------------------------------------
// pipeline with synced preferences

export function pipelineSettingsInput({ csv, bytes, fileName = 'bank.csv', prefs = [], categories = PIPELINE_CATEGORIES }) {
  const source = bytes === undefined ? { csv } : { bytesBase64: base64(bytes) };
  return { accountId: ACCOUNT_ID, fileName, prefs, ...source, categories };
}

const STD_HEADER = ['Date', 'Amount', 'Payee', 'Notes', 'Category'];
const STD_ROWS = [
  ['2026-01-05', '-12.34', 'Example Store', 'memo a', 'Dining'],
  ['2026-01-06', '5.00', 'Sample Cafe', '', 'Fuel'],
  ['2026-01-07', '-7.25', 'Test Market', 'memo c', 'Groceries'],
];
const SPLIT_HEADER = ['Date', 'Payee', 'Debit', 'Credit', 'Notes'];
const SPLIT_ROWS = [
  ['2026-01-05', 'Example Store', '12.34', '', 'a'],
  ['2026-01-06', 'Sample Cafe', '', '5.00', 'b'],
  ['2026-01-07', 'Test Market', '7.25', '', 'c'],
  ['2026-01-08', 'Both Filled', '1.00', '2.00', 'd'],
  ['2026-01-09', 'Neither', '', '', 'e'],
  ['2026-01-10', 'Negative Debit', '-3.00', '', 'f'],
  ['2026-01-11', 'Zero Debit', '0', '4.00', 'g'],
];
const INOUT_HEADER = ['Date', 'Payee', 'Amount', 'Type', 'Notes'];
const INOUT_ROWS = [
  ['2026-01-05', 'Example Store', '12.34', 'DEBIT', 'a'],
  ['2026-01-06', 'Sample Cafe', '5.00', 'CREDIT', 'b'],
  ['2026-01-07', 'Test Market', '-7.25', 'DEBIT', 'c'],
  ['2026-01-08', 'Refund', '-2.00', 'CREDIT', 'd'],
  ['2026-01-09', 'Blank Type', '3.00', '', 'e'],
  ['2026-01-10', 'Padded Type', '4.00', ' DEBIT ', 'f'],
];
const STD_MAPPING = { date: 'Date', amount: 'Amount', payee: 'Payee', notes: 'Notes', category: 'Category' };
const SPLIT_SAVED = { date: 'Date', payee: 'Payee', notes: 'Notes', outflow: 'Debit', inflow: 'Credit' };
const INOUT_SAVED = { date: 'Date', amount: 'Amount', payee: 'Payee', notes: 'Notes', inOut: 'Type' };
const HEADERLESS_MAPPING = { date: '0', amount: '1', payee: '2', notes: '3', category: '4' };
const json = object => JSON.stringify(savedMapping(object));
const pref = (key, value) => [PREF[key], value];

function pipelineSavedNamed() {
  const pipeline = (id, description, fields) => named(`pipeline/saved/${id}`, pipelineSettingsInput(fields), description);
  const std = table(STD_HEADER, STD_ROWS);
  const split = table(SPLIT_HEADER, SPLIT_ROWS);
  const inOut = table(INOUT_HEADER, INOUT_ROWS);
  const lower = table(['date', 'amount', 'payee', 'notes'], [['2026-01-05', '-1.00', 'One', ''], ['2026-03-01', '2.00', 'Two', ''], ['2026-02-10', '-3.00', 'Three', '']]);
  const preamble = 'Account: 0000\r\nExported: 2026-01-31\r\n\r\n';
  const dmy = table(['Date', 'Amount', 'Payee'], [['31/12/2026', '1.00', 'A'], ['01/02/2026', '2.00', 'B']]);
  const semicolon = delimitedText([['Date', 'Amount', 'Payee'], ['05/01/2026', '-12,34', 'Example Store'], ['06/01/2026', '5,00', 'Sample Cafe']], ';');
  const tab = delimitedText([['Date', 'Amount', 'Payee'], ['2026-01-05', '-12.34', 'Example Store'], ['2026-01-06', '5.00', 'Sample Cafe']], '\t');
  const german = 'Date;Amount;Payee\r\n05.01.2026;-12,34;Café Ñandú\r\n06.01.2026;5,00;Sample Store\r\n';
  const cases = [
    pipeline('no-prefs', 'no saved settings: the same as the default-settings import', { csv: std }),
    pipeline('unrelated-prefs', 'preferences of another account and another file type are not read', {
      csv: std,
      prefs: [[`csv-delimiter-${OTHER_ACCOUNT}`, ';'], [`csv-has-header-${OTHER_ACCOUNT}`, 'false'], [`flip-amount-${ACCOUNT_ID}-qif`, 'true'], [`parse-date-${ACCOUNT_ID}-qif`, 'dd mm yyyy'], ['csv-mappings', json(HEADERLESS_MAPPING)]],
    }),

    // Delimiter and file name.
    pipeline('delimiter-pref-semicolon', 'a saved semicolon delimiter', { csv: semicolon, prefs: [pref('delimiter', ';')] }),
    pipeline('delimiter-pref-missing', 'a semicolon file without the saved delimiter reads as one column', { csv: semicolon }),
    pipeline('delimiter-pref-pipe', 'a saved pipe delimiter', { csv: delimitedText([['Date', 'Amount', 'Payee'], ['2026-01-05', '1.00', 'A|B']], '|'), prefs: [pref('delimiter', '|')] }),
    pipeline('delimiter-pref-tilde', 'a saved tilde delimiter', { csv: delimitedText([['Date', 'Amount', 'Payee'], ['2026-01-05', '1.00', 'A']], '~'), prefs: [pref('delimiter', '~')] }),
    pipeline('tsv-default-delimiter', 'a .tsv file defaults to a tab delimiter', { csv: tab, fileName: 'bank.tsv' }),
    pipeline('tsv-uppercase', 'BANK.TSV is a tsv to parseFile but the modal tests endsWith(".tsv") case-sensitively: comma delimiter', { csv: tab, fileName: 'BANK.TSV' }),
    pipeline('tsv-uppercase-with-pref', 'BANK.TSV with a saved tab delimiter', { csv: tab, fileName: 'BANK.TSV', prefs: [pref('delimiter', '\t')] }),
    pipeline('tsv-with-comma-pref', 'a saved comma overrides the .tsv default', { csv: std, fileName: 'bank.tsv', prefs: [pref('delimiter', ',')] }),
    pipeline('tsv-empty-delimiter-pref', 'an empty saved delimiter falls back to the .tsv default', { csv: tab, fileName: 'bank.tsv', prefs: [pref('delimiter', '')] }),
    pipeline('csv-uppercase-extension', 'an uppercase .CSV extension', { csv: std, fileName: 'BANK.CSV' }),
    pipeline('csv-comma-pref-redundant', 'a saved comma on a .csv file', { csv: std, prefs: [pref('delimiter', ',')] }),
    pipeline('tsv-in-name-only', 'a name containing .tsv in the middle is a csv', { csv: std, fileName: 'bank.tsv.csv' }),

    // Encoding.
    pipeline('encoding-windows-1252', 'a saved windows-1252 encoding on accented bytes', { bytes: encodeText(german, 'latin1'), prefs: [pref('delimiter', ';'), pref('encoding', 'windows-1252')] }),
    pipeline('encoding-none-on-latin1-bytes', 'the same bytes under auto decode as UTF-8 with replacement characters', { bytes: encodeText(german, 'latin1'), prefs: [pref('delimiter', ';')] }),
    pipeline('encoding-iso-8859-2', 'a saved ISO-8859-2 encoding', { bytes: Buffer.from('Date;Amount;Payee\r\n05.01.2026;-12,34;£ód¿ ¦\r\n', 'latin1'), prefs: [pref('delimiter', ';'), pref('encoding', 'iso-8859-2')] }),
    pipeline('encoding-windows-1250', 'a saved windows-1250 encoding', { bytes: Buffer.from('Date;Amount;Payee\r\n05.01.2026;-12,34;£ód¿ \u008a\r\n', 'latin1'), prefs: [pref('delimiter', ';'), pref('encoding', 'windows-1250')] }),
    pipeline('encoding-utf16le-explicit', 'a saved UTF-16LE encoding on a file without a mark', { bytes: encodeText(std, 'utf16le'), prefs: [pref('encoding', 'utf-16le')] }),
    pipeline('encoding-utf16be-explicit', 'a saved UTF-16BE encoding on a file without a mark', { bytes: encodeText(std, 'utf16be'), prefs: [pref('encoding', 'utf-16be')] }),
    pipeline('encoding-utf16le-bom-auto', 'a UTF-16LE file with a mark needs no saved encoding', { bytes: encodeText(std, 'utf16le-bom') }),
    pipeline('encoding-utf16be-bom-auto', 'a UTF-16BE file with a mark needs no saved encoding', { bytes: encodeText(std, 'utf16be-bom') }),
    pipeline('encoding-utf16le-bom-explicit', 'a saved UTF-16LE encoding on a file with a mark', { bytes: encodeText(std, 'utf16le-bom'), prefs: [pref('encoding', 'utf-16le')] }),
    pipeline('encoding-utf16le-no-pref', 'UTF-16LE without a mark and without a saved encoding is read as UTF-8', { bytes: encodeText(std, 'utf16le') }),
    pipeline('encoding-utf8-explicit', 'a saved UTF-8 encoding on a file with a mark', { bytes: encodeText(std, 'utf8-bom'), prefs: [pref('encoding', 'utf-8')] }),
    pipeline('encoding-auto-explicit', 'a saved auto encoding', { csv: std, prefs: [pref('encoding', 'auto')] }),
    pipeline('encoding-empty-pref', 'an empty saved encoding is auto', { csv: std, prefs: [pref('encoding', '')] }),
    pipeline('encoding-unknown', 'a saved label TextDecoder refuses is a read error', { csv: std, prefs: [pref('encoding', 'klingon')] }),
    pipeline('encoding-uppercase-label', 'a saved UTF-8 label in uppercase', { csv: std, prefs: [pref('encoding', 'UTF-8')] }),

    // Skipped lines.
    pipeline('skip-start-preamble', 'a bank preamble skipped by a saved start count', { csv: `${preamble}${std}`, prefs: [pref('skipStart', '3')] }),
    pipeline('skip-start-missing-preamble', 'the preamble without the saved count breaks the header', { csv: `${preamble}${std}` }),
    pipeline('skip-start-too-many', 'a start count above the line count is a read error', { csv: std, prefs: [pref('skipStart', '30')] }),
    pipeline('skip-end-summary', 'summary lines skipped by a saved end count', { csv: `${std}Total,-14.59,,,\r\n`, prefs: [pref('skipEnd', '2')] }),
    pipeline('skip-end-blank-only', 'an end count of one removes only the blank last line', { csv: std, prefs: [pref('skipEnd', '1')] }),
    pipeline('skip-both', 'preamble and summary skipped together', { csv: `${preamble}${std}Total,-14.59,,,\r\n`, prefs: [pref('skipStart', '3'), pref('skipEnd', '2')] }),
    pipeline('skip-both-too-many', 'start and end counts that together reach the line count', { csv: std, prefs: [pref('skipStart', '3'), pref('skipEnd', '2')] }),
    pipeline('skip-negative', 'negative saved counts', { csv: std, prefs: [pref('skipStart', '-2'), pref('skipEnd', '-1')] }),
    pipeline('skip-text', 'non-numeric saved counts read as zero', { csv: std, prefs: [pref('skipStart', 'abc'), pref('skipEnd', '')] }),
    pipeline('skip-padded', 'parseInt skips leading whitespace', { csv: `${preamble}${std}`, prefs: [pref('skipStart', ' 3')] }),
    pipeline('skip-decimal', 'parseInt reads the integer prefix', { csv: `junk\r\n${std}`, prefs: [pref('skipStart', '1.9')] }),
    pipeline('skip-exponent', 'parseInt stops at an exponent', { csv: `junk\r\n${std}`, prefs: [pref('skipStart', '1e3')] }),
    pipeline('skip-hex', 'radix 10: 0x1 reads as zero', { csv: `junk\r\n${std}`, prefs: [pref('skipStart', '0x1')] }),
    pipeline('skip-plus', 'a plus sign is read', { csv: `junk\r\n${std}`, prefs: [pref('skipStart', '+1')] }),
    pipeline('skip-trailing-text', 'trailing text is ignored', { csv: `junk\r\n${std}`, prefs: [pref('skipStart', '1 line')] }),
    pipeline('skip-zero', 'a saved zero', { csv: std, prefs: [pref('skipStart', '0'), pref('skipEnd', '0')] }),
    pipeline('skip-through-quoted-field', 'a start count that ends inside a quoted multi-line field', {
      csv: 'junk\r\n"note\r\nmore",1.00\r\n', prefs: [pref('skipStart', '2'), pref('header', 'false')],
    }),
    pipeline('skip-rewrites-quoted-lf', 'skipping rewrites a quoted line feed in a note as CRLF', {
      csv: table(STD_HEADER, [['2026-01-05', '1.00', 'Example Store', 'line one\nline two', '']], { newline: '\n' }).replace(/^/, 'junk\n'),
      prefs: [pref('skipStart', '1')],
    }),
    pipeline('skip-with-saved-mapping', 'skip lines and a saved mapping together', { csv: `${preamble}${std}`, prefs: [pref('skipStart', '3'), pref('mappings', json(STD_MAPPING))] }),

    // Header row.
    pipeline('header-false-guessed', 'no header row saved: columns are guessed by index', { csv: table(null, STD_ROWS), prefs: [pref('header', 'false')] }),
    pipeline('header-false-saved-index-mapping', 'a headerless file with a saved index mapping', {
      csv: table(null, STD_ROWS), prefs: [pref('header', 'false'), pref('mappings', json(HEADERLESS_MAPPING))],
    }),
    pipeline('header-false-saved-name-mapping', 'a headerless file with a saved mapping of header names', {
      csv: table(null, STD_ROWS), prefs: [pref('header', 'false'), pref('mappings', json(STD_MAPPING))],
    }),
    pipeline('header-true-index-mapping', 'a header file with a saved index mapping', { csv: std, prefs: [pref('mappings', json(HEADERLESS_MAPPING))] }),
    pipeline('header-explicit-true', 'a saved true header flag', { csv: std, prefs: [pref('header', 'true')] }),
    pipeline('header-upper-false', 'only the exact text false turns the header off: False keeps it on', { csv: std, prefs: [pref('header', 'False')] }),
    pipeline('header-garbage', 'any other text keeps the header on', { csv: std, prefs: [pref('header', 'no')] }),
    pipeline('header-empty-pref', 'an empty header flag keeps the header on', { csv: std, prefs: [pref('header', '')] }),
    pipeline('header-false-with-skip', 'no header row after skipped lines', { csv: `${preamble}${table(null, STD_ROWS)}`, prefs: [pref('header', 'false'), pref('skipStart', '3'), pref('mappings', json(HEADERLESS_MAPPING))] }),

    // Saved mappings.
    pipeline('mapping-saved-standard', 'a saved mapping equal to the guess', { csv: std, prefs: [pref('mappings', json(STD_MAPPING))] }),
    pipeline('mapping-saved-differs-from-guess', 'a saved mapping that swaps payee and notes beats the guess', {
      csv: std, prefs: [pref('mappings', json({ ...STD_MAPPING, payee: 'Notes', notes: 'Payee' }))],
    }),
    pipeline('mapping-saved-missing-columns', 'a saved mapping naming columns the file lacks: the date cell is undefined', {
      csv: std, prefs: [pref('mappings', json({ date: 'Posted', amount: 'Amt', payee: 'Who', notes: 'Memo', category: 'Cat' }))],
    }),
    pipeline('mapping-saved-partly-missing', 'only the payee column is missing', {
      csv: std, prefs: [pref('mappings', json({ ...STD_MAPPING, payee: 'Who' }))],
    }),
    pipeline('mapping-saved-amount-missing', 'the amount column is missing: every amount is zero', {
      csv: std, prefs: [pref('mappings', json({ ...STD_MAPPING, amount: 'Amt' }))],
    }),
    pipeline('mapping-saved-empty-object', 'an empty saved object reads nothing: no date', { csv: std, prefs: [pref('mappings', '{}')] }),
    pipeline('mapping-saved-partial', 'a saved object with date and amount only', { csv: std, prefs: [pref('mappings', '{"date":"Date","amount":"Amount"}')] }),
    pipeline('mapping-saved-spaces', 'JSON with surrounding whitespace', { csv: std, prefs: [pref('mappings', ` \n${json(STD_MAPPING)}\n `)] }),
    pipeline('mapping-saved-category-only', 'a saved mapping that names only the category', { csv: std, prefs: [pref('mappings', '{"category":"Category"}')] }),
    pipeline('mapping-saved-zero-numbers', 'saved numbers: 0 is falsy and reads the field name; 1 reads column 1', {
      csv: std, prefs: [pref('mappings', '{"date":"Date","amount":0,"payee":1,"notes":null,"inOut":null,"category":null}')],
    }),
    pipeline('mapping-saved-headerless-numbers', 'saved numbers index a headerless row', {
      csv: table(null, STD_ROWS), prefs: [pref('header', 'false'), pref('mappings', '{"date":0,"amount":1,"payee":2,"notes":3,"inOut":null,"category":4}')],
    }),
    pipeline('mapping-saved-booleans', 'saved booleans', { csv: std, prefs: [pref('mappings', '{"date":"Date","amount":true,"payee":false,"notes":null}')] }),
    pipeline('mapping-saved-selected', 'a saved mapping that names selected reads the boolean true for the payee', {
      csv: std, prefs: [pref('mappings', json({ ...STD_MAPPING, payee: 'selected' }))],
    }),
    pipeline('mapping-saved-selected-amount', 'a saved mapping that names selected reads the boolean true as the amount', {
      csv: std, prefs: [pref('mappings', json({ ...STD_MAPPING, amount: 'selected' }))],
    }),
    pipeline('mapping-saved-selected-date', 'a saved mapping that names selected as the date: no date format reads true', {
      csv: std, prefs: [pref('mappings', json({ ...STD_MAPPING, date: 'selected' }))],
    }),
    pipeline('mapping-saved-trx-id-payee', 'a saved mapping that names trx_id reads the row number', {
      csv: std, prefs: [pref('mappings', json({ ...STD_MAPPING, payee: 'trx_id' }))],
    }),
    pipeline('mapping-saved-trx-id-date', 'a saved mapping that names trx_id as the date reads "0"', {
      csv: std, prefs: [pref('mappings', json({ ...STD_MAPPING, date: 'trx_id' }))],
    }),
    pipeline('mapping-saved-duplicate-key', 'a repeated key in the saved JSON keeps its last value', {
      csv: std, prefs: [pref('mappings', '{"date":"Amount","date":"Date","amount":"Amount","payee":"Payee"}')],
    }),
    pipeline('mapping-saved-lowercase-sort-column', 'the preview sorts by a raw column named date while the mapping reads Posting Date', {
      csv: table(['Posting Date', 'date', 'Amount', 'Payee'], [['2026-01-05', '2026-02-01', '-1.00', 'One'], ['2026-01-06', '2026-02-03', '-2.00', 'Two'], ['2026-01-07', '2026-02-02', '-3.00', 'Three']]),
      prefs: [pref('mappings', json({ date: 'Posting Date', amount: 'Amount', payee: 'Payee' }))],
    }),

    // Malformed or unusable saved mappings.
    pipeline('mapping-malformed-brace', 'malformed JSON in the saved mapping', { csv: std, prefs: [pref('mappings', '{"date":')] }),
    pipeline('mapping-malformed-text', 'plain text in the saved mapping', { csv: std, prefs: [pref('mappings', 'Date,Amount')] }),
    pipeline('mapping-malformed-single-quotes', 'single-quoted JSON', { csv: std, prefs: [pref('mappings', "{'date':'Date'}")] }),
    pipeline('mapping-malformed-trailing-comma', 'a trailing comma', { csv: std, prefs: [pref('mappings', '{"date":"Date",}')] }),
    pipeline('mapping-malformed-bom', 'a U+FEFF before the JSON is not JSON whitespace', { csv: std, prefs: [pref('mappings', `﻿${json(STD_MAPPING)}`)] }),
    pipeline('mapping-malformed-nan', 'NaN is not JSON', { csv: std, prefs: [pref('mappings', 'NaN')] }),
    pipeline('mapping-empty-string', 'an empty saved mapping is falsy: the guess is used', { csv: std, prefs: [pref('mappings', '')] }),
    pipeline('mapping-null', 'saved JSON null: reading mappings.outflow throws a TypeError', { csv: std, prefs: [pref('mappings', 'null')] }),
    pipeline('mapping-null-spaces', 'saved JSON null with whitespace', { csv: std, prefs: [pref('mappings', ' null ')] }),
    pipeline('mapping-array', 'a saved empty array reads nothing', { csv: std, prefs: [pref('mappings', '[]')] }),
    pipeline('mapping-array-entries', 'a saved array: its indices are the field names', { csv: std, prefs: [pref('mappings', '["Date","Amount"]')] }),
    pipeline('mapping-number', 'a saved number reads nothing', { csv: std, prefs: [pref('mappings', '5')] }),
    pipeline('mapping-zero', 'the text 0 is truthy and parses to the number 0', { csv: std, prefs: [pref('mappings', '0')] }),
    pipeline('mapping-string', 'a saved string: Object.entries lists its characters', { csv: std, prefs: [pref('mappings', '"Date"')] }),
    pipeline('mapping-true', 'a saved true', { csv: std, prefs: [pref('mappings', 'true')] }),
    pipeline('mapping-false', 'a saved false', { csv: std, prefs: [pref('mappings', 'false')] }),
    pipeline('mapping-nested', 'saved values that are objects and arrays', { csv: std, prefs: [pref('mappings', '{"date":{"a":1},"amount":["Amount"],"payee":"Payee"}')] }),

    // Split (Debit/Credit) files.
    pipeline('split-saved', 'a Debit/Credit file with a saved outflow/inflow mapping', { csv: split, prefs: [pref('mappings', json(SPLIT_SAVED))] }),
    pipeline('split-saved-outflow-only', 'only an outflow column saved', { csv: split, prefs: [pref('mappings', json({ ...SPLIT_SAVED, inflow: null }))] }),
    pipeline('split-saved-inflow-only', 'only an inflow column saved', { csv: split, prefs: [pref('mappings', json({ ...SPLIT_SAVED, outflow: null }))] }),
    pipeline('split-saved-empty-targets', 'empty outflow and inflow targets leave split mode off', { csv: split, prefs: [pref('mappings', json({ ...SPLIT_SAVED, outflow: '', inflow: '' }))] }),
    pipeline('split-saved-missing-columns', 'a split mapping naming columns the file lacks: split mode on, amounts zero', { csv: split, prefs: [pref('mappings', json({ ...SPLIT_SAVED, outflow: 'Out', inflow: 'In' }))] }),
    pipeline('split-saved-with-amount', 'a split mapping that also keeps an amount column', { csv: split, prefs: [pref('mappings', json({ ...SPLIT_SAVED, amount: 'Debit' }))] }),
    pipeline('split-not-saved', 'the same file without a saved mapping: the guess has no split', { csv: split }),
    pipeline('split-saved-flip', 'a split mapping with flip', { csv: split, prefs: [pref('mappings', json(SPLIT_SAVED)), pref('flip', 'true')] }),
    pipeline('split-saved-in-out-mode', 'in/out mode wins over a saved split mapping', { csv: split, prefs: [pref('mappings', json(SPLIT_SAVED)), pref('inOutMode', 'true'), pref('outValue', 'Debit')] }),
    pipeline('split-saved-lowercase-date', 'a split file whose date column is sorted', {
      csv: table(['date', 'Payee', 'Debit', 'Credit'], [['2026-01-05', 'A', '1.00', ''], ['2026-03-01', 'B', '', '2.00'], ['2026-02-10', 'C', '3.00', '']]),
      prefs: [pref('mappings', json({ date: 'date', payee: 'Payee', outflow: 'Debit', inflow: 'Credit' }))],
    }),
    pipeline('split-saved-multiplied-values', 'split mode with currency and parentheses', {
      csv: table(SPLIT_HEADER, [['2026-01-05', 'A', '$1,234.56', '', ''], ['2026-01-06', 'B', '', '(5.00)', ''], ['2026-01-07', 'C', 'abc', '3.00', '']]),
      prefs: [pref('mappings', json(SPLIT_SAVED))],
    }),

    // In/out files.
    pipeline('inout-saved', 'a Type column with DEBIT out, saved in/out preferences', {
      csv: inOut, prefs: [pref('mappings', json(INOUT_SAVED)), pref('inOutMode', 'true'), pref('outValue', 'DEBIT')],
    }),
    pipeline('inout-guessed-mapping', 'in/out preferences with the guessed mapping', { csv: inOut, prefs: [pref('inOutMode', 'true'), pref('outValue', 'DEBIT')] }),
    pipeline('inout-wrong-case', 'an out value of different case never matches: everything is an inflow', {
      csv: inOut, prefs: [pref('mappings', json(INOUT_SAVED)), pref('inOutMode', 'true'), pref('outValue', 'debit')],
    }),
    pipeline('inout-padded-out-value', 'an out value with padding matches only the padded cell', {
      csv: inOut, prefs: [pref('mappings', json(INOUT_SAVED)), pref('inOutMode', 'true'), pref('outValue', ' DEBIT ')],
    }),
    pipeline('inout-no-out-value', 'no saved out value: the empty string matches only the empty Type cell', {
      csv: inOut, prefs: [pref('mappings', json(INOUT_SAVED)), pref('inOutMode', 'true')],
    }),
    pipeline('inout-empty-out-value', 'an empty saved out value', {
      csv: inOut, prefs: [pref('mappings', json(INOUT_SAVED)), pref('inOutMode', 'true'), pref('outValue', '')],
    }),
    pipeline('inout-mode-uppercase', 'TRUE is not true: in/out stays off', {
      csv: inOut, prefs: [pref('mappings', json(INOUT_SAVED)), pref('inOutMode', 'TRUE'), pref('outValue', 'DEBIT')],
    }),
    pipeline('inout-mode-false', 'a saved false', { csv: inOut, prefs: [pref('mappings', json(INOUT_SAVED)), pref('inOutMode', 'false'), pref('outValue', 'DEBIT')] }),
    pipeline('inout-no-inout-mapping', 'in/out on but no inOut column mapped: the cell reads a column named inOut', {
      csv: inOut, prefs: [pref('mappings', json({ ...INOUT_SAVED, inOut: null })), pref('inOutMode', 'true'), pref('outValue', 'DEBIT')],
    }),
    pipeline('inout-flip', 'in/out then flip', {
      csv: inOut, prefs: [pref('mappings', json(INOUT_SAVED)), pref('inOutMode', 'true'), pref('outValue', 'DEBIT'), pref('flip', 'true')],
    }),
    pipeline('inout-out-value-without-mode', 'a saved out value with in/out off is ignored', { csv: inOut, prefs: [pref('mappings', json(INOUT_SAVED)), pref('outValue', 'DEBIT')] }),
    pipeline('inout-selected-column', 'the in/out column naming selected: the boolean true never equals the out value', {
      csv: inOut, prefs: [pref('mappings', json({ ...INOUT_SAVED, inOut: 'selected' })), pref('inOutMode', 'true'), pref('outValue', 'true')],
    }),

    // Flip.
    pipeline('flip-true', 'a saved flip', { csv: std, prefs: [pref('flip', 'true')] }),
    pipeline('flip-false', 'a saved false flip', { csv: std, prefs: [pref('flip', 'false')] }),
    pipeline('flip-capitalised', 'True is not true: no flip', { csv: std, prefs: [pref('flip', 'True')] }),
    pipeline('flip-empty', 'an empty flip is off', { csv: std, prefs: [pref('flip', '')] }),
    pipeline('flip-zero-and-text', 'flip with zero and unreadable amounts', {
      csv: table(['Date', 'Amount', 'Payee'], [['2026-01-05', '0', 'A'], ['2026-01-06', 'abc', 'B'], ['2026-01-07', '-0.00', 'C']]), prefs: [pref('flip', 'true')],
    }),

    // Date format.
    pipeline('date-pref-valid', 'a saved day-first format on a day-first file', { csv: dmy, prefs: [pref('parseDate', 'dd mm yyyy')] }),
    pipeline('date-pref-contradicts-file', 'a saved month-first format on a day-first file: later rows fail', { csv: dmy, prefs: [pref('parseDate', 'mm dd yyyy')] }),
    pipeline('date-pref-two-digit-year', 'a saved two-digit-year format', { csv: table(['Date', 'Amount', 'Payee'], [['31/12/26', '1.00', 'A']]), prefs: [pref('parseDate', 'dd mm yy')] }),
    pipeline('date-pref-year-first', 'a saved year-first format on an ISO file', { csv: std, prefs: [pref('parseDate', 'yyyy mm dd')] }),
    pipeline('date-pref-invalid-slashes', 'a saved format outside the six values reads as mm dd yyyy', { csv: dmy, prefs: [pref('parseDate', 'dd/mm/yyyy')] }),
    pipeline('date-pref-invalid-slashes-iso', 'the invalid format on an ISO file', { csv: std, prefs: [pref('parseDate', 'dd/mm/yyyy')] }),
    pipeline('date-pref-invalid-case', 'a saved format with different case is not one of the six', { csv: dmy, prefs: [pref('parseDate', 'DD MM YYYY')] }),
    pipeline('date-pref-invalid-padded', 'a saved format with padding is not one of the six', { csv: dmy, prefs: [pref('parseDate', ' dd mm yyyy')] }),
    pipeline('date-pref-empty', 'an empty saved format is falsy: the format is guessed', { csv: dmy, prefs: [pref('parseDate', '')] }),
    pipeline('date-pref-invalid-lowercase-sort', 'the invalid format and a raw date column that the preview sorts by', { csv: lower, prefs: [pref('parseDate', 'yyyy-mm-dd')] }),
    pipeline('date-pref-valid-lowercase-sort', 'a valid format and a raw date column that the preview sorts by', { csv: lower, prefs: [pref('parseDate', 'yyyy mm dd')] }),

    // Import notes: the preference is written by the modal but never read.
    pipeline('import-notes-false', 'a saved import-notes false does not drop notes: nothing reads the preference', { csv: std, prefs: [pref('importNotes', 'false')] }),
    pipeline('import-notes-true', 'a saved import-notes true', { csv: std, prefs: [pref('importNotes', 'true')] }),

    // Combinations.
    pipeline('bank-preamble-all-settings', 'preamble, semicolon, Windows-1252, split columns, flip and a saved date format', {
      bytes: encodeText('Account: 0000\r\nExported: 2026-01-31\r\n\r\nDatum;Beschreibung;Soll;Haben\r\n31.12.2026;Café;12,34;\r\n01.02.2026;Gehalt;;1.000,00\r\nSumme;;12,34;1.000,00\r\n', 'latin1'),
      prefs: [pref('skipStart', '3'), pref('skipEnd', '2'), pref('delimiter', ';'), pref('encoding', 'windows-1252'), pref('flip', 'true'), pref('parseDate', 'dd mm yyyy'),
        pref('mappings', json({ date: 'Datum', payee: 'Beschreibung', outflow: 'Soll', inflow: 'Haben' }))],
    }),
    pipeline('tsv-in-out-flip', 'a tab file with in/out, an out value, flip and a date format', {
      csv: delimitedText([['date', 'payee', 'amount', 'type'], ['05/01/2026', 'A', '10.00', 'out'], ['06/01/2026', 'B', '4.00', 'in']], '\t'), fileName: 'bank.tsv',
      prefs: [pref('inOutMode', 'true'), pref('outValue', 'out'), pref('flip', 'true'), pref('parseDate', 'dd mm yyyy'),
        pref('mappings', json({ date: 'date', payee: 'payee', amount: 'amount', inOut: 'type' }))],
    }),
    pipeline('every-pref-defaults', 'every saved setting at its default value', {
      csv: std,
      prefs: [pref('mappings', json(STD_MAPPING)), pref('delimiter', ','), pref('encoding', 'auto'), pref('header', 'true'), pref('skipStart', '0'), pref('skipEnd', '0'),
        pref('inOutMode', 'false'), pref('outValue', ''), pref('parseDate', 'yyyy mm dd'), pref('flip', 'false'), pref('importNotes', 'true')],
    }),
    pipeline('no-categories-with-prefs', 'no categories in the budget', { csv: std, prefs: [pref('mappings', json(STD_MAPPING))], categories: [] }),
  ];
  return cases;
}

// A random bank file: its style fixes the headers, and saved settings usually match it but are
// sometimes wrong, missing or malformed.
const STYLE_HEADERS = {
  plain: STD_HEADER,
  split: SPLIT_HEADER,
  inout: INOUT_HEADER,
  headerless: null,
};
const PAYEES = ['Example Store', 'Sample Café', 'Test Market', 'Demo Fuel', 'Fictional Pharmacy', 'Synthetic Rent', 'A, B & C', 'Ñandú Books'];
const AMOUNTS = ['12.34', '-12.34', '1,234.56', '(5.00)', '$7', '5', '0', '0.005', 'abc', '', '-0.00', '1.234,56'];
const NOTES = ['', 'memo', 'card 0000', 'two words', 'quote "x"', 'line\nbreak'];
const SPLIT_COLUMNS = ['', '', '12.34', '5.00', '7', '(3.00)', '-4.00', '0', 'abc'];

function pickDateLayout(random) {
  const order = pick(random, ['ymd', 'mdy', 'dmy']);
  const separator = pick(random, ['-', '/', '.']);
  const shortYear = chance(random, 0.15);
  const two = value => String(value).padStart(2, '0');
  // The format is guessed from the first row, so most files open with a day above 12 that only
  // one layout can read.
  let first = true;
  return () => {
    const bigDay = first && chance(random, 0.75);
    first = false;
    if (chance(random, 0.012)) return pick(random, ['', 'n/a', '99/99/9999']);
    const year = between(random, 2022, 2027);
    const month = between(random, 1, 12);
    const day = bigDay ? between(random, 13, 28) : between(random, 1, 28);
    const yearText = shortYear ? two(year % 100) : String(year);
    const parts = order === 'ymd' ? [yearText, two(month), two(day)] : order === 'mdy' ? [two(month), two(day), yearText] : [two(day), two(month), yearText];
    return parts.join(separator);
  };
}

function dataRow(random, style, nextDate) {
  const date = nextDate();
  const payee = pick(random, PAYEES);
  const note = pick(random, NOTES);
  const category = chance(random, 0.6) ? pick(random, ['Dining', 'Groceries', 'Fuel', 'Entertainment']) : '';
  const amount = pick(random, AMOUNTS);
  if (style === 'split') return [date, payee, pick(random, SPLIT_COLUMNS), pick(random, SPLIT_COLUMNS), note];
  if (style === 'inout') return [date, payee, amount, pick(random, ['DEBIT', 'CREDIT', 'DEBIT', 'CREDIT', '', 'debit', ' DEBIT ']), note];
  return [date, amount, payee, note, category];
}

function savedMappingFor(random, style) {
  const base = style === 'split' ? SPLIT_SAVED : style === 'inout' ? INOUT_SAVED : style === 'headerless' ? HEADERLESS_MAPPING : STD_MAPPING;
  const mapping = savedMapping(base);
  if (chance(random, 0.2)) {
    const key = pick(random, MAPPING_KEYS);
    mapping[key] = pick(random, [null, '', 'Missing', 0, 1, true, 'selected', 'trx_id', pick(random, Object.values(base))]);
  }
  return mapping;
}

function mappingText(random, style) {
  if (chance(random, 0.04)) return pick(random, ['{"date":', 'null', '[]', '5', '"Date"', 'true', 'Date', '{}']);
  const mapping = savedMappingFor(random, style);
  // Sometimes drop keys, as an older or hand-edited preference would.
  const entries = Object.entries(mapping).filter(([key]) => !(chance(random, 0.1) && mapping[key] === null));
  return JSON.stringify(Object.fromEntries(chance(random, 0.15) ? shuffled(random, entries) : entries));
}

function pipelineSavedGenerated() {
  const random = mulberry32(SAVED_SEEDS.pipeline);
  return Array.from({ length: SAVED_COUNTS.pipeline }, (_, index) => {
    const style = pick(random, ['plain', 'plain', 'split', 'inout', 'headerless']);
    const delimiter = chance(random, 0.5) ? ',' : pick(random, [';', '\t', '|', '~']);
    const fileName = delimiter === '\t' ? pick(random, ['bank.tsv', 'bank.tsv', 'BANK.TSV', 'bank.csv']) : pick(random, ['bank.csv', 'bank.csv', 'Bank.CSV', 'bank.tsv']);
    const defaultDelimiter = fileName.endsWith('.tsv') ? '\t' : ',';
    const prefs = [];
    if (delimiter !== defaultDelimiter ? chance(random, 0.9) : chance(random, 0.2)) prefs.push(pref('delimiter', delimiter));

    const nextDate = pickDateLayout(random);
    const rows = Array.from({ length: between(random, 1, 7) }, () => dataRow(random, style, nextDate));
    const header = STYLE_HEADERS[style];
    const preambleLines = chance(random, 0.35) ? between(random, 1, 3) : 0;
    const summaryLines = chance(random, 0.3) ? between(random, 1, 2) : 0;
    const lines = [
      ...Array.from({ length: preambleLines }, (_, line) => [['Account: 0000'], ['Exported: 2026-01-31'], ['']][line]),
      ...(header ? [header] : []),
      ...rows,
      ...Array.from({ length: summaryLines }, (_, line) => [['Total', '0', '', ''], ['Balance', '1']][line]),
    ];
    const text = delimitedText(lines, delimiter, { newline: pick(random, ['\r\n', '\n']), trailing: chance(random, 0.75) });
    if (preambleLines > 0 || chance(random, 0.1)) prefs.push(pref('skipStart', chance(random, 0.75) ? String(preambleLines) : pick(random, ['0', String(preambleLines + 1), ' 2', 'x', '-1', '1.5'])));
    if (summaryLines > 0 || chance(random, 0.1)) prefs.push(pref('skipEnd', chance(random, 0.75) ? String(summaryLines + (text.endsWith('\n') ? 1 : 0)) : pick(random, ['0', '1', '3', '', 'abc'])));
    if (style === 'headerless' ? chance(random, 0.9) : chance(random, 0.1)) prefs.push(pref('header', style === 'headerless' ? 'false' : pick(random, ['true', 'false', 'False', ''])));

    const kind = pick(random, ['utf8', 'utf8', 'utf8', 'utf8-bom', 'utf16le-bom', 'utf16be-bom', 'utf16le', 'latin1']);
    if (kind === 'latin1') prefs.push(pref('encoding', chance(random, 0.9) ? pick(random, ['windows-1252', 'windows-1250', 'iso-8859-2']) : pick(random, ['auto', 'utf-8', 'klingon'])));
    else if (kind === 'utf16le') prefs.push(pref('encoding', chance(random, 0.85) ? 'utf-16le' : pick(random, ['auto', 'utf-16be'])));
    else if (chance(random, 0.15)) prefs.push(pref('encoding', pick(random, ['auto', 'utf-8', kind.startsWith('utf16le') ? 'utf-16le' : 'utf-16be', 'UTF-8'])));

    if (chance(random, 0.55)) prefs.push(pref('mappings', mappingText(random, style)));
    if (chance(random, 0.35)) {
      prefs.push(pref('parseDate', chance(random, 0.9)
        ? pick(random, ['yyyy mm dd', 'yy mm dd', 'mm dd yyyy', 'mm dd yy', 'dd mm yyyy', 'dd mm yy'])
        : pick(random, ['dd/mm/yyyy', 'YYYY MM DD', ' yyyy mm dd', '', 'mm-dd-yyyy'])));
    }
    if (chance(random, 0.25)) prefs.push(pref('flip', pick(random, ['true', 'true', 'false', 'True', ''])));
    if (style === 'inout' ? chance(random, 0.85) : chance(random, 0.1)) {
      prefs.push(pref('inOutMode', pick(random, ['true', 'true', 'true', 'false', 'TRUE'])));
      if (chance(random, 0.85)) prefs.push(pref('outValue', pick(random, ['DEBIT', 'DEBIT', 'debit', ' DEBIT ', 'CREDIT', '', 'out'])));
    }
    if (chance(random, 0.25)) {
      prefs.push(pick(random, [
        pref('importNotes', pick(random, ['true', 'false'])),
        [`csv-delimiter-${OTHER_ACCOUNT}`, ';'],
        [`flip-amount-${ACCOUNT_ID}-qif`, 'true'],
        [`csv-has-header-${OTHER_ACCOUNT}`, 'false'],
      ]));
    }
    const categories = chance(random, 0.1) ? [] : PIPELINE_CATEGORIES;
    const input = kind === 'utf8'
      ? pipelineSettingsInput({ csv: text, fileName, prefs: shuffled(random, prefs), categories })
      : pipelineSettingsInput({ bytes: encodeText(text, kind), fileName, prefs: shuffled(random, prefs), categories });
    return generatedCase(`pipeline/saved-gen-${pad(index, 3)}`, SAVED_SEEDS.pipeline, input,
      'seeded bank file with saved settings that usually match it and sometimes do not');
  });
}

export const savedApplyFieldMappingsCases = () => [...applySavedNamed(), ...applySavedGenerated()];
export const savedGetInitialDateFormatCases = () => [...dateFormatSavedNamed(), ...dateFormatSavedGenerated()];
export const savedPipelineCases = () => [...pipelineSavedNamed(), ...pipelineSavedGenerated()];
