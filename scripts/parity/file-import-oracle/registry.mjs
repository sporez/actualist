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
//   deps          { globalName: { from: frozen file, export: exportName } }, or { global: name } for
//                 a Node global the source uses (TextDecoder), or
//                 { from, constant } for a module-private top-level const, whose
//                 initializer text is extracted and evaluated after earlier deps
//                 { from, function, measure? } for a module-private top-level function, evaluated
//                 in the same context (`measure: true` gates its V8 coverage with the entry's); { module, namespace: true } for a package
//                 namespace import (`import * as d from 'date-fns'`), not frozen
//   crossCheck    for a function the source exports: { from, export }; the runner
//                 compares the real import with the extracted copy on every case
//   coverageGate  'report' prints uncovered blocks; 'enforce' fails the generator
//   waivers       [{ snippet, reason }] for blocks no case can reach; generate.mjs moves a
//                 block whose snippet starts with `snippet` from `uncovered` to
//                 `waived` in the manifest, with the reason
//   extraCheck    async (result, input, env) that throws when the extracted copy disagrees with
//                 another route to the same behavior (for a private function with no export)
//   reads         [file] frozen files a composite entry reads without importing them
//   call          (fn, input, env) => result, with `input` the fixture case input and
//                 env { parseCsv(input) }, which turns a case's CSV text into Actual's
//                 parsed transactions with the real parseFile, and env { parseRaw(input) },
//                 which returns parseFile's own { errors, transactions }; parseRaw also takes
//                 fileName (extension only), encoding, skipStartLines and skipEndLines
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

// A saved mapping arrives as [key, value] pairs in JSON.parse order; this is the object
// JSON.parse would have built (a repeated key keeps its last value at its first position).
const mappingFromPairs = pairs => Object.fromEntries(pairs);

// sha256 of every pinned Actual file the harness reads. Files the imports pull in
// transitively are covered by the clean-checkout-at-pinned-commit check instead.
export const FROZEN_SOURCES = {
  // Actual's own sample CSVs, which the `pipeline/actual-sample` cases record as bytes.
  'packages/desktop-client/e2e/data/test.csv': '89b9c8407d00496b23c98fc5ac1e4aef264c64cebd5d35fcfbfa3e061a291952',
  'packages/loot-core/src/mocks/files/windows-1252.csv': '6442e42b63036de26d42cde170de41d50d363a8f8a5eb18f28a8562ada7f63aa',
  'packages/loot-core/src/mocks/files/windows-1252-euro.csv': 'a741ae5f56ccba5f6b2533099ed5321188d7f8b543ff6879686e66844f49e9ae',
  'packages/loot-core/src/mocks/files/utf-8-bom.csv': '78d4d846138083677e3269b8b54ab208682c1b00077f872d7cddd4d14387c370',
  'packages/loot-core/src/mocks/files/utf-16be.csv': '40694c27e65fef069ce0c59d1f4b9dd10eec757b639d480aad5dd1679916f999',
  'packages/loot-core/src/mocks/files/utf-16le.csv': 'a01618ef337c254a2bd6019e4acdbba07ea56a6c2b8d0f9a7860116ae5342089',
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
    // The modal computes mappings from the same transactions (or reads the saved ones), then
    // guesses the format.
    call: async (fn, input, env) => {
      const transactions = await env.parseCsv(input);
      const mappings = input.mappings === undefined ? env.helpers.getInitialMappings(transactions) : mappingFromPairs(input.mappings);
      return fn(transactions, mappings);
    },
  },
  {
    name: 'applyFieldMappings',
    source: UTILS,
    deps: {},
    crossCheck: { from: UTILS, export: 'applyFieldMappings' },
    coverageGate: 'enforce',
    // Only the mapped fields are recorded; the preview bookkeeping fields are not. A field whose
    // key the mapping lacks is undefined.
    call: async (fn, input, env) => (await env.parseCsv(input)).map(transaction => {
      const mapped = fn(transaction, mappingFromPairs(input.mappings));
      return {
        date: mapped.date,
        amount: mapped.amount,
        payee_name: mapped.payee_name,
        notes: mapped.notes,
        inOut: mapped.inOut,
        category: mapped.category,
        outflow: mapped.outflow,
        inflow: mapped.inflow,
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
    name: 'parseAmountFields',
    source: UTILS,
    deps: {
      looselyParseAmount: { from: UTIL, export: 'looselyParseAmount' },
      parseAmount: { from: UTILS, function: 'parseAmount', measure: true },
    },
    crossCheck: { from: UTILS, export: 'parseAmountFields' },
    coverageGate: 'enforce',
    // A key absent from `trans` is absent in the call (undefined), which is not ''.
    call: (fn, input) => fn({ ...input.trans }, input.splitMode, input.inOutMode, input.outValue, input.flipAmount, input.multiplierAmount),
  },
  {
    // The modal's CSV import for one account: saved settings, parse, guess, sort, map, convert.
    name: 'pipeline',
    composite: true,
    uses: ['getInitialMappings', 'getInitialDateFormat'],
    imports: {
      isDateFormat: { from: UTILS, export: 'isDateFormat' },
      parseDate: { from: UTILS, export: 'parseDate' },
      applyFieldMappings: { from: UTILS, export: 'applyFieldMappings' },
      parseAmountFields: { from: UTILS, export: 'parseAmountFields' },
      parseCategoryFields: { from: UTILS, export: 'parseCategoryFields' },
      amountToInteger: { from: UTIL, export: 'amountToInteger' },
    },
    coverageGate: 'none',
    call: async (fns, input, env, real) => {
      // `prefs` are the account's synced preferences, strings as Actual stores them.
      const prefs = Object.fromEntries(input.prefs);
      const accountId = input.accountId;
      const filename = input.fileName;

      // ImportTransactionsModal.tsx 242-263: the initial state, read once from the preferences.
      // importNotes (235) stays true: nothing in the modal reads `import-notes-<account>-csv`.
      const delimiter = prefs[`csv-delimiter-${accountId}`] || (filename.endsWith('.tsv') ? '\t' : ',');
      const csvEncoding = prefs[`csv-encoding-${accountId}`] || 'auto';
      const skipStartLines = parseInt(prefs[`csv-skip-start-lines-${accountId}`], 10) || 0;
      const skipEndLines = parseInt(prefs[`csv-skip-end-lines-${accountId}`], 10) || 0;
      const inOutMode = String(prefs[`csv-in-out-mode-${accountId}`]) === 'true';
      const outValue = prefs[`csv-out-value-${accountId}`] ?? '';
      const hasHeaderRow = String(prefs[`csv-has-header-${accountId}`]) !== 'false';

      // 1398-1402: getParseOptions for a CSV; 391-397: parseFile.
      const parsed = await env.parseRaw({
        csv: input.csv,
        bytesBase64: input.bytesBase64,
        fileName: filename,
        delimiter,
        encoding: csvEncoding,
        hasHeaderRow,
        skipStartLines,
        skipEndLines,
      });
      // 413-417: the first error is shown and nothing else is set up.
      if (parsed.errors.length > 0) return { error: { kind: 'parse', message: parsed.errors[0].message || 'Internal error' } };

      // 399-408: parse() numbers the rows in file order and selects them.
      let index = 0;
      const transactions = parsed.transactions.map(trans => {
        trans.trx_id = String(index++);
        trans.selected = true;
        return trans;
      });

      // 423-425: flip comes from the preference.
      const flipAmount = String(prefs[`flip-amount-${accountId}-csv`]) === 'true';

      // 430-433: the saved mapping wins; JSON.parse throws on malformed text.
      let mappings = prefs[`csv-mappings-${accountId}`];
      if (mappings) {
        try {
          mappings = JSON.parse(mappings);
        } catch {
          return { error: { kind: 'mappings-json', reason: 'syntax' } };
        }
      } else {
        mappings = fns.getInitialMappings(transactions);
      }
      // 440: `mappings.outflow` throws a TypeError for the saved text `null`.
      if (mappings === null) return { error: { kind: 'mappings-json', reason: 'null' } };
      // 440: split mode is on when the saved mapping has an outflow or an inflow.
      const splitMode = !!(mappings.outflow || mappings.inflow);

      // 443-448: the saved format wins; anything outside the six formats becomes null.
      const savedFormat = prefs[`parse-date-${accountId}-csv`] || fns.getInitialDateFormat(transactions, mappings);
      const format = real.isDateFormat(savedFormat) ? savedFormat : null;

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
      // 637-722: onImport, reconcile on, every row selected, multiplier empty.
      for (const row of transactions) {
        const trans = real.applyFieldMappings(row, mappings); // 654
        const date = real.parseDate(trans.date, format); // 659
        if (date == null) {
          const error = { kind: 'date', text: trans.date ?? null };
          return engineDefinedOrder ? { error, engineDefinedOrder } : { error };
        }
        const { amount } = real.parseAmountFields(trans, splitMode, inOutMode, outValue, flipAmount, ''); // 668
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
  {
    // parse-file.ts keeps the decoder module-private: auto (a UTF-16 mark picks the endianness,
    // else UTF-8) or the label the modal saved, handed to TextDecoder as is.
    name: 'decodeCsvBytes',
    source: PARSE_FILE,
    deps: { TextDecoder: { global: 'TextDecoder' } },
    coverageGate: 'enforce',
    call: (fn, input) => {
      try {
        return { text: fn(Buffer.from(input.bytesBase64, 'base64'), input.encoding) };
      } catch (error) {
        return { error: String(error.message) };
      }
    },
    // The same bytes through the real parseFile must fail to decode exactly when the extracted
    // copy throws, with parseCSV's own message around the decoder's.
    extraCheck: async (result, input, env) => {
      const parsed = await env.parseRaw({ bytesBase64: input.bytesBase64, encoding: input.encoding, delimiter: ',', hasHeaderRow: false });
      const decodeFailed = result.error !== undefined && parsed.errors[0]?.message === `Failed parsing: ${result.error}`;
      if (result.error !== undefined && !decodeFailed) throw new Error('parseFile did not fail to decode where the extracted copy threw');
      if (result.error === undefined && parsed.errors[0]?.message?.includes('encoding')) throw new Error('parseFile failed to decode where the extracted copy did not');
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
