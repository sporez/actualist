# File import oracle

Runs functions from the pinned Actual release (`config/parity/oracle-pin.json`)
and records `input -> output` for each case. A Swift replay suite
(`FileImportOracleReplayTests`) compares Actualist's ports with them. This
directory is the generator side only. Each phase adds functions and cases.

- `registry.mjs`: the function registry and the source freeze (sha256 of every
  pinned Actual file the harness reads). One entry per function.
- `cases.mjs`: named cases, seeded generated cases (`mulberry32`, shared with
  `scripts/parity/sync-merkle/cases.mjs`), and structural invariants. It never
  holds an expected output.
- `generate.mjs`: checks the freeze, runs the plan, prints the coverage report,
  writes the fixture. `--check` regenerates into a temporary directory and diffs
  it against the committed fixture.
- `verify.mjs`: checks the committed fixture without an oracle.
- `oracle-runner.test.ts`, `oracle.vitest.config.mjs`: the vitest run.
- `readonly-oracle.sb`: sandbox profile; generate.mjs runs vitest under it with
  network access denied and every write below the checkout denied. Nothing is
  copied into, installed into or written to the Actual checkout. The Vite cache
  lives in a temporary directory.
- Fixture: `ActualistTests/Fixtures/ActualCore26_11_0/FileImport/`
  (`file-import-contract.json`, `file-import-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/parity/file-import-oracle/generate.mjs [--check]
node scripts/parity/file-import-oracle/verify.mjs
```

## Adding a function

1. Add a `REGISTRY` entry in `registry.mjs` (source file, `deps`, `call`,
   `coverageGate`). Add the file to `FROZEN_SOURCES` if it is new.
2. Add a builder in `CASE_BUILDERS` in `cases.mjs`.
3. Regenerate, then add the Swift replay.

## How a function is reached

The runner parses the frozen source with the checkout's TypeScript, takes the
text of the one top-level function declaration with that name, strips its types
with `node:module` `stripTypeScriptTypes` (which keeps every character in place),
and evaluates it in a fresh `vm` context. The context's globals are the entry's
`deps`: real exports imported from the checkout, or a module-private top-level
`const` extracted the same way (`MIN_SAFE_NUMBER`). A missing or duplicated
declaration fails the run. Module-private functions such as `getInitialMappings`
need nothing else, and no function body is copied into this repository. For a
function the source exports, the runner also calls the real export and fails if
it disagrees with the extracted copy.

## Coverage gate

The runner turns on V8 precise block coverage (`node:inspector`, `detailed`)
before evaluating the extracted text. Positions in the extracted text equal
positions in the source, so uncovered blocks print as source line ranges and
snippets, and are stored in the manifest. Each registry entry sets
`coverageGate`: `report` prints and records them; `enforce` also fails the
generator and `verify.mjs`. Limits: V8 covers statements, branches, `||`/`&&`/`?.`
operands, and functions, but not alternatives inside a regular expression.

## CSV cases and the pipeline

Functions that read a file (`getInitialMappings`, `getInitialDateFormat`,
`applyFieldMappings`, `pipeline`) take `{ csv, hasHeaderRow, delimiter }`. The
runner writes the text to a `.csv` file in a temporary directory outside the
checkout and runs Actual's real `parseFile` with the options the modal passes for
a CSV (`delimiter`, `encoding: 'auto'`, `hasHeaderRow`, no skipped lines), then the
modal's parse step (`trx_id = String(index)`, `selected = true`). A case where
`parseFile` reports an error fails the generator, so the corpus holds only files
Actual reads. Inputs never rely on JSON key order: a mapping is an object with
the six fixed keys, and a row's column order only exists inside the CSV text.

`pipeline` is the one composite entry. Its `call` in `registry.mjs` is the
modal's default-settings CSV import written out literally, with modal line
numbers: parse, `getInitialMappings`, `getInitialDateFormat`, the preview sort of
the raw rows by the column literally named `date`, then `applyFieldMappings`,
`parseDate`, `parseAmountFields`, `parseCategoryFields`, `amountToInteger` per row.
Output is `{ transactions: [{ sourceIndex, date, amount, payee_name, notes,
category, cleared }] }` in import order, or `{ error: { kind: 'date', text } }`.
`engineDefinedOrder: true` marks a file whose `date`-column parse results mix
unreadable and readable rows: the comparator is then inconsistent and V8's order
is engine-defined, so a port cannot be expected to match it (a known divergence).
Such cases stay in the fixture.

`parseDate` takes `{ text, format }` where `format` is one of the six values, or
`null` (the modal passes null when a saved format is invalid; Actual then reads
`mm dd yyyy`). `applyFieldMappings` outputs one object per row with exactly
`date, amount, payee_name, notes, inOut, category`. `parseAmountFields` is called
with the default settings and has `coverageGate: 'report'` until Phase 2.

## `parseCsvRecords`: the CSV reader on its own

A composite entry (cases in `csv-parse-cases.mjs`) that pins csv-parse 7.0.3 as
Actual calls it: `parseFile` -> `decodeCsvBytes` (`encoding: 'auto'`) -> `csv-parse`
with `bom: true`, `quote: '"'`, `trim: true`, `relax_column_count: true`,
`skip_empty_lines: true`, the modal's single-character delimiter (`, ; | tab ~`) and
`columns: hasHeaderRow`. Input is `{ csv, delimiter, hasHeaderRow }`, or
`{ bytesBase64, delimiter, hasHeaderRow }` for raw file bytes (byte order marks,
UTF-16, invalid UTF-8). Output is `{ records }`, or `{ error }` holding the first
`parseFile` error message (csv-parse messages embed line numbers and field text).
Without a header row a record is an array of strings. With one it is
`{ entries: [[name, value], ...] }`, the record's `Object.entries` in order, so
duplicate (last value wins, first position), empty, `__proto__` and integer-like
names (JS lists those first, ascending) are pinned; short rows omit keys and long
rows drop extra fields. Errors are recorded, never filtered. Unlike the other CSV
families, `parseCsvRecords` does not require `parseFile` to succeed.

csv-parse lives in `node_modules`, so V8 coverage is not measured (`coverageGate:
'report'`) and its five library files are source-frozen in `registry.mjs`.
`CSV_PARSE_CHECKLIST` in `csv-parse-cases.mjs` names the case for every behavior
(line endings and which one decides, blank and whitespace-only lines, BOMs, each
trimmed and untrimmed character, quote handling, delimiters, header shapes) and the
plan refuses a checklist entry whose case is missing or does not show it. The
seeded family (1,500 files, seed `SEED + 8`) draws from an alphabet weighted toward
quotes, delimiters, `\r`, `\n`, padding and look-alike characters.

## Coverage waivers and regex alternatives

A registry `waivers` entry moves a block no case can reach into the manifest's
`waived` list with its reason; a stale waiver fails the generator. V8 does not see
regular-expression alternatives, so `REGEX_ALTERNATIVE_CHECKLIST` in `cases.mjs`
names the case that exercises each month-word alternative and the structural
branches of `parseDate`; the plan refuses an entry whose case is missing or whose
input does not match the alternative's pattern.

## Fixture format

`cases[]` entries are `{ id, function, source, description, seed?, derivedFrom?,
input, output }`; `source` is `named`, `generated` or `derived`. A derived case
(`amountToInteger/after-*`) takes its input from the output of the case named in
`derivedFrom` and exists only when that output is not null. A JS value JSON
cannot carry is `{ "$js": "undefined" | "NaN" | "-0" | "Infinity" | "-Infinity" }`,
or `{ "$js": "threw", "message": ... }`. All data is synthetic. Two consecutive
generations are byte-identical.
