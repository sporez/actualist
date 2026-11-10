// The function registry. Adding an Actual function to the oracle is one entry here
// plus one case builder in cases.mjs; the runner, generator and verifier read
// this list and need no other change.
//
// An entry names a top-level function declaration in a frozen Actual source file.
// The runner extracts that declaration's text with the TypeScript parser, strips
// its types without moving any character, and evaluates it in a fresh context
// whose globals are the entry's `deps` (real exports imported from the checkout).
// Extraction fails when the declaration is missing or appears twice. Evaluating
// the extracted text is also what makes V8 coverage line up with the source.
//
//   name          function name in the source file (also the fixture section)
//   source        frozen file that declares it
//   deps          { globalName: { from: frozen file, export: exportName } }, or
//                 { from, constant } for a module-private top-level const, whose
//                 initializer text is extracted and evaluated after earlier deps
//                 { from, function } for a module-private top-level function, evaluated
//                 in the same context; { module, namespace: true } for a package
//                 namespace import (`import * as d from 'date-fns'`), not frozen
//   crossCheck    for a function the source exports: { from, export }; the runner
//                 compares the real import with the extracted copy on every case
//   coverageGate  'report' prints uncovered blocks; 'enforce' fails the generator
//   waivers       [{ snippet, reason }] for blocks no case can reach; generate.mjs moves a
//                 block whose snippet starts with `snippet` from `uncovered` to
//                 `waived` in the manifest, with the reason
//   reads         [file] frozen files a composite entry reads without importing them
//   call          (fn, input, env) => result, with `input` the fixture case input and
//                 env { parseCsv(input) }, which turns a case's CSV text into Actual's
//                 parsed transactions with the real parseFile, and env { parseRaw(input) },
//                 which returns parseFile's own { errors, transactions }
//
// A composite entry (`composite: true`) has no source function of its own. It
// names `uses` (registered functions, passed to `call` as `fns`) and `imports`
// (real exports, same shape as deps, passed as `real`), and its call is the
// literal glue of a flow in Actual's modal. Its coverageGate is 'none'.

const UTIL = 'packages/loot-core/src/shared/util.ts';
const MODAL_DIRECTORY = 'packages/desktop-client/src/components/modals/ImportTransactionsModal';
const UTILS = `${MODAL_DIRECTORY}/utils.ts`;
const MODAL = `${MODAL_DIRECTORY}/ImportTransactionsModal.tsx`;
export const PARSE_FILE = 'packages/loot-core/src/server/transactions/import/parse-file.ts';
const CSV_PARSE = 'node_modules/csv-parse/lib';

// sha256 of every pinned Actual file the harness reads. Files the imports pull in
// transitively are covered by the clean-checkout-at-pinned-commit check instead.
export const FROZEN_SOURCES = {
  [UTIL]: '976e0d398a1074dfc7f4909e17be73754396ab189f961c7f1341eda19620bdbe',
  [UTILS]: 'fba1908a04fe623ae0944275c368452151679f66137593b3018d7a068f7150f8',
  [MODAL]: 'c8f82d687ae2711c06d905384c3f1519ed62d63d97875082155403780e2eec64',
  [PARSE_FILE]: 'd42416f6611d5c210096fa1e48e21163c5847f9b8c6bbff672369a6e0d81c5a9',
  // csv-parse 7.0.3, which parseFile calls. Frozen because node_modules is not part of the
  // pinned commit; `parseCsvRecords` records its behavior on Actual's option set.
  [`${CSV_PARSE}/sync.js`]: '9ed8d621ef0dcbd64ba216e9ea60173a59ff9960af8194e15532feed1a365ec5',
  [`${CSV_PARSE}/api/index.js`]: '07d98c0146bcce7d085c9e70a871342abf6ea4e7069d115d41c5eb37bed871e1',
  [`${CSV_PARSE}/api/init_state.js`]: 'e2b37718e99061da3926a2a0840b4fd4202082fd69595c6d304aeeaf424eaeca',
  [`${CSV_PARSE}/api/normalize_options.js`]: 'b313f205641060f9ba0e1f5d364564c1cef992d8ecbf7cf4b2540b368137ef62',
  [`${CSV_PARSE}/api/normalize_columns_array.js`]: '8ee28e9345c33fd1f435f1219c5579b30cc18d26b4a5c845a846befb48dedb22',
};

export const REGISTRY = [
  {
    name: 'looselyParseAmount',
    source: UTIL,
    deps: {
      MAX_SAFE_NUMBER: { from: UTIL, export: 'MAX_SAFE_NUMBER' },
      MIN_SAFE_NUMBER: { from: UTIL, constant: 'MIN_SAFE_NUMBER' },
    },
    crossCheck: { from: UTIL, export: 'looselyParseAmount' },
    coverageGate: 'enforce',
    call: (fn, input) => fn(input.text),
  },
  {
    name: 'amountToInteger',
    source: UTIL,
    deps: {},
    crossCheck: { from: UTIL, export: 'amountToInteger' },
    coverageGate: 'enforce',
    call: (fn, input) => (input.decimalPlaces === undefined ? fn(input.amount) : fn(input.amount, input.decimalPlaces)),
  },
  {
    name: 'parseDate',
    source: UTILS,
    deps: { d: { module: 'node_modules/date-fns/index.js', namespace: true } },
    crossCheck: { from: UTILS, export: 'parseDate' },
    coverageGate: 'enforce',
    call: (fn, input) => fn(input.text, input.format),
  },
  {
    name: 'getInitialMappings',
    source: MODAL,
    deps: { stripCsvImportTransaction: { from: UTILS, export: 'stripCsvImportTransaction' } },
    coverageGate: 'enforce',
    call: async (fn, input, env) => fn(await env.parseCsv(input)),
  },
  {
    name: 'getInitialDateFormat',
    source: MODAL,
    deps: {
      dateFormats: { from: UTILS, export: 'dateFormats' },
      parseDate: { from: UTILS, export: 'parseDate' },
      // Module-private; evaluated from the frozen source like getInitialDateFormat.
      stripCsvImportTransaction: { from: UTILS, export: 'stripCsvImportTransaction' },
      getInitialMappings: { from: MODAL, function: 'getInitialMappings' },
    },
    coverageGate: 'enforce',
    waivers: [{
      snippet: '? null',
      reason: 'a CSV cell is never null or undefined once its column was chosen from the first row (csv-parse omits absent cells, so the column is not guessed); only the QIF caller, which passes { date: \'date\' }, can reach it',
    }],
    // The modal computes mappings from the same transactions, then guesses the format.
    call: async (fn, input, env) => {
      const transactions = await env.parseCsv(input);
      return fn(transactions, env.helpers.getInitialMappings(transactions));
    },
  },
  {
    name: 'applyFieldMappings',
    source: UTILS,
    deps: {},
    crossCheck: { from: UTILS, export: 'applyFieldMappings' },
    coverageGate: 'enforce',
    // Only the mapped fields are recorded; the preview bookkeeping fields are not.
    call: async (fn, input, env) => (await env.parseCsv(input)).map(transaction => {
      const mapped = fn(transaction, input.mappings);
      return {
        date: mapped.date,
        amount: mapped.amount,
        payee_name: mapped.payee_name,
        notes: mapped.notes,
        inOut: mapped.inOut,
        category: mapped.category,
      };
    }),
  },
  {
    name: 'parseCategoryFields',
    source: UTILS,
    deps: {},
    crossCheck: { from: UTILS, export: 'parseCategoryFields' },
    coverageGate: 'enforce',
    call: (fn, input) => fn({ category: input.category }, input.categories),
  },
  {
    // Phase 2 enforces its coverage; Phase 1 only calls it with the default settings.
    name: 'parseAmountFields',
    source: UTILS,
    deps: {
      looselyParseAmount: { from: UTIL, export: 'looselyParseAmount' },
      parseAmount: { from: UTILS, function: 'parseAmount' },
    },
    crossCheck: { from: UTILS, export: 'parseAmountFields' },
    coverageGate: 'report',
    call: (fn, input) => fn({ amount: input.amount }, false, false, '', false, ''),
  },
  {
    // The modal's default-settings CSV import: parse, guess, sort, map, convert.
    name: 'pipeline',
    composite: true,
    uses: ['getInitialMappings', 'getInitialDateFormat'],
    imports: {
      parseDate: { from: UTILS, export: 'parseDate' },
      applyFieldMappings: { from: UTILS, export: 'applyFieldMappings' },
      parseAmountFields: { from: UTILS, export: 'parseAmountFields' },
      parseCategoryFields: { from: UTILS, export: 'parseCategoryFields' },
      amountToInteger: { from: UTIL, export: 'amountToInteger' },
    },
    coverageGate: 'none',
    call: async (fns, input, env, real) => {
      // ImportTransactionsModal.tsx 397-406: parseFile, then parse() numbers the rows in file order.
      const transactions = await env.parseCsv(input);
      // 433, 445: the initial mappings and date format for the new file.
      const mappings = fns.getInitialMappings(transactions);
      const format = fns.getInitialDateFormat(transactions, mappings);

      // 302-313: getImportPreview sorts the RAW parsed rows in place, newest first,
      // by the column literally named `date`, not the mapped one.
      const rawDate = transaction => real.parseDate(transaction.date, format);
      const rawResults = transactions.map(rawDate);
      const engineDefinedOrder = rawResults.some(date => date === null) && rawResults.some(date => date !== null);
      transactions.sort((a, b) => {
        const aDate = rawDate(a);
        const bDate = rawDate(b);
        return aDate < bDate ? 1 : aDate === bDate ? 0 : -1;
      });

      const imported = [];
      // 637-722: onImport, reconcile on, every row selected.
      for (const row of transactions) {
        const trans = real.applyFieldMappings(row, mappings); // 654
        const date = real.parseDate(trans.date, format); // 659
        if (date == null) {
          const error = { kind: 'date', text: trans.date ?? null };
          return engineDefinedOrder ? { error, engineDefinedOrder } : { error };
        }
        const { amount } = real.parseAmountFields(trans, false, false, '', false, ''); // 668
        const category = real.parseCategoryFields(trans, input.categories); // 683
        imported.push({
          sourceIndex: Number(row.trx_id),
          date,
          amount: real.amountToInteger(amount), // 718
          payee_name: trans.payee_name,
          notes: trans.notes, // 720, importNotes on
          category,
          cleared: true, // 719, clearOnImport on
        });
      }
      return engineDefinedOrder ? { transactions: imported, engineDefinedOrder } : { transactions: imported };
    },
  },
  {
    // Actual's CSV reader on its option set: parseFile -> decodeCsvBytes -> csv-parse. Records
    // keep csv-parse's key order by listing Object.entries, so duplicate, empty and numeric
    // header names are pinned. V8 coverage of node_modules is not measured; the behaviors are
    // listed in CSV_PARSE_CHECKLIST in csv-parse-cases.mjs instead.
    name: 'parseCsvRecords',
    composite: true,
    uses: [],
    imports: {},
    reads: [PARSE_FILE],
    coverageGate: 'report',
    coverageNote: 'csv-parse lives in node_modules and is not measured; CSV_PARSE_CHECKLIST names the case for each behavior',
    call: async (fns, input, env) => {
      const parsed = await env.parseRaw(input);
      if (parsed.errors.length > 0) return { error: parsed.errors[0].message };
      return {
        records: input.hasHeaderRow
          ? parsed.transactions.map(record => ({ entries: Object.entries(record) }))
          : parsed.transactions,
      };
    },
  },
];

// Every frozen file a registry entry reads, so a new entry cannot go unfrozen.
export function registryFiles() {
  const files = new Set();
  for (const entry of REGISTRY) {
    if (entry.source) files.add(entry.source);
    for (const file of entry.reads ?? []) files.add(file);
    for (const dependency of [...Object.values(entry.deps ?? {}), ...Object.values(entry.imports ?? {})]) {
      if (dependency.from) files.add(dependency.from);
    }
    if (entry.crossCheck) files.add(entry.crossCheck.from);
  }
  return [...files].sort();
}
