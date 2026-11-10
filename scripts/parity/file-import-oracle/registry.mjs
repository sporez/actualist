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
//   crossCheck    for a function the source exports: { from, export }; the runner
//                 compares the real import with the extracted copy on every case
//   coverageGate  'report' prints uncovered blocks; 'enforce' fails the generator
//   call          (fn, input) => result, with `input` the fixture case input

const UTIL = 'packages/loot-core/src/shared/util.ts';
const MODAL_DIRECTORY = 'packages/desktop-client/src/components/modals/ImportTransactionsModal';
const UTILS = `${MODAL_DIRECTORY}/utils.ts`;
const MODAL = `${MODAL_DIRECTORY}/ImportTransactionsModal.tsx`;

// sha256 of every pinned Actual file the harness reads. Files the imports pull in
// transitively are covered by the clean-checkout-at-pinned-commit check instead.
export const FROZEN_SOURCES = {
  [UTIL]: '976e0d398a1074dfc7f4909e17be73754396ab189f961c7f1341eda19620bdbe',
  [UTILS]: 'fba1908a04fe623ae0944275c368452151679f66137593b3018d7a068f7150f8',
  [MODAL]: 'c8f82d687ae2711c06d905384c3f1519ed62d63d97875082155403780e2eec64',
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
    coverageGate: 'report',
    call: (fn, input) => fn(input.text),
  },
  {
    name: 'amountToInteger',
    source: UTIL,
    deps: {},
    crossCheck: { from: UTIL, export: 'amountToInteger' },
    coverageGate: 'report',
    call: (fn, input) => (input.decimalPlaces === undefined ? fn(input.amount) : fn(input.amount, input.decimalPlaces)),
  },
  {
    name: 'getInitialMappings',
    source: MODAL,
    deps: { stripCsvImportTransaction: { from: UTILS, export: 'stripCsvImportTransaction' } },
    coverageGate: 'report',
    call: (fn, input) => fn(input.transactions),
  },
  {
    name: 'getInitialDateFormat',
    source: MODAL,
    deps: {
      dateFormats: { from: UTILS, export: 'dateFormats' },
      parseDate: { from: UTILS, export: 'parseDate' },
    },
    coverageGate: 'report',
    call: (fn, input) => fn(input.transactions, input.mappings),
  },
];

// Every frozen file a registry entry reads, so a new entry cannot go unfrozen.
export function registryFiles() {
  const files = new Set();
  for (const entry of REGISTRY) {
    files.add(entry.source);
    for (const dependency of Object.values(entry.deps)) files.add(dependency.from);
    if (entry.crossCheck) files.add(entry.crossCheck.from);
  }
  return [...files].sort();
}
