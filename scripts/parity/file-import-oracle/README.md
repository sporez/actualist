# File import oracle

Runs functions from the pinned Actual release (`config/parity/oracle-pin.json`)
and records `input -> output` for each case. A Swift replay suite
(`FileImportOracleReplayTests`) compares Actualist's ports with them. This
directory is the generator side only. Each phase adds functions and cases.

- `registry.mjs`: the function registry and the source freeze (sha256 of every
  pinned Actual file the harness reads). One entry per function.
- `cases.mjs`: the plan builder, the older families, and the structural
  invariants. It never holds an expected output. Seeded generators use
  `mulberry32`, shared with `scripts/parity/sync-merkle/cases.mjs`. Families
  added in Phase 2 live beside it: `case-kit.mjs` (shared draws, CSV text and
  byte encoders), `decode-cases.mjs` (`decodeCsvBytes`),
  `csv-file-option-cases.mjs` (skip lines and encodings for `parseCsvRecords`),
  `amount-fields-cases.mjs` (`parseAmountFields`) and
  `saved-settings-cases.mjs` (saved mappings and the pipeline with synced
  preferences), `actual-sample-cases.mjs` (Actual's own sample CSV files) and
  `bank-layout-cases.mjs` (reconstructed bank export layouts).
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
`applyFieldMappings`) take `{ csv, hasHeaderRow, delimiter }`. The runner writes
the text to a `.csv` file in a temporary directory outside the checkout and runs
Actual's real `parseFile` with the options the modal passes for a CSV
(`delimiter`, `encoding: 'auto'`, `hasHeaderRow`, no skipped lines), then the
modal's parse step (`trx_id = String(index)`, `selected = true`). A case where
`parseFile` reports an error fails the generator, so those corpora hold only
files Actual reads. Inputs never rely on JSON key order: a row's column order only
exists inside the CSV text, and a saved mapping is an array of `[key, value]`
pairs in the order `JSON.parse` would list them.

`applyFieldMappings` takes `mappings` as pairs whose keys are any of `date, amount,
payee, notes, inOut, category, outflow, inflow` (a key can be absent, which is not
`null`) and whose values are a string, `''`, `null`, a number (`0`, `3`) or a boolean.
It records `{ date, amount, payee_name, notes, inOut, category, outflow, inflow }`
per row; a field whose key the mapping lacks is `{"$js":"undefined"}`, and a value
can be the boolean `true` (a mapping that names the preview's `selected` flag).
`getInitialDateFormat` takes an optional `mappings` in the same shape (absent means
the guessed mappings, as before).

`pipeline` is the one composite entry: the modal's CSV import for one account. Its
input is `{ accountId, fileName, prefs, csv | bytesBase64, categories }`, where
`prefs` is `[[key, value], ...]` holding the account's synced preferences as the
strings Actual stores them: `csv-mappings-<account>`, `csv-delimiter-<account>`,
`csv-encoding-<account>`, `csv-has-header-<account>`, `csv-skip-start-lines-<account>`,
`csv-skip-end-lines-<account>`, `csv-in-out-mode-<account>`, `csv-out-value-<account>`,
`parse-date-<account>-csv`, `flip-amount-<account>-csv` and `import-notes-<account>-csv`.
Its `call` in `registry.mjs` writes the modal out literally, with modal line numbers:
state from the preferences (`delimiter = pref || (fileName.endsWith('.tsv') ? '\t' : ',')`,
`encoding = pref || 'auto'`, skips by `parseInt(pref, 10) || 0`, `inOutMode =
String(pref) === 'true'`, `outValue = pref ?? ''`, `hasHeaderRow = String(pref) !==
'false'`), `parseFile` with `getParseOptions`, the saved mapping (`JSON.parse`) or
`getInitialMappings`, split mode from `outflow || inflow`, the saved date format or
`getInitialDateFormat` (then `isDateFormat(x) ? x : null`), flip from its preference,
the preview sort of the raw rows by the column literally named `date`, then
`applyFieldMappings`, `parseDate`, `parseAmountFields`, `parseCategoryFields`,
`amountToInteger` per row. The `import-notes-<account>-csv` preference is written by
`onImport` but never read anywhere in v26.11.0 (only `sync-import-notes-` for Bank
Sync is), so importing notes stays on; cases with it set pin that. `fileName` supplies
the extension `parseFile` dispatches on and the `.tsv` test, which is case-sensitive
(`BANK.TSV` gets a comma delimiter).
Output is `{ transactions: [{ sourceIndex, date, amount, payee_name, notes,
category, cleared }] }` in import order, or one of `{ error: { kind: 'date', text } }`
(`text` is a string, `null`, or the boolean `true`), `{ error: { kind: 'parse',
message } }` (the first `parseFile` error) and `{ error: { kind: 'mappings-json',
reason } }`. `reason` is `syntax` when `JSON.parse` throws, and `null` for the saved text
`null`, where the modal's `mappings.outflow` throws a TypeError (an unhandled rejection
in the modal). Other JSON values (`[]`, `5`, `"x"`, `true`, nested values) do not throw;
the cases record what the code then does.
`engineDefinedOrder: true` marks a file whose `date`-column parse results mix
unreadable and readable rows: the comparator is then inconsistent and V8's order
is engine-defined, so a port cannot be expected to match it (a known divergence).
Such cases stay in the fixture.

`parseDate` takes `{ text, format }` where `format` is one of the six values, or
`null` (the modal passes null when a saved format is invalid; Actual then reads
`mm dd yyyy`).

`parseAmountFields` takes `{ trans, splitMode, inOutMode, outValue, flipAmount,
multiplierAmount }` with `trans` holding any of `amount`, `outflow`, `inflow`, `inOut`.
A key absent from `trans` is absent in the call (undefined), which is not the empty
string; a value is a string or the boolean `true`; JSON `null` appears once (the
legacy `amount: null`) and reads like absent. Output is `{ amount, outflow, inflow }`
(`outflow` and `inflow` are `null` outside split mode; `-0` and `NaN` are `$js`).
Its coverage is enforced, and the module-private helper `parseAmount` is gated with it
(a registry dependency marked `measure: true`).

## Actual's sample files and bank layouts (pipeline)

`pipeline/actual-sample/<file>[/<variant>]` (13 cases) runs the CSV fixtures the pinned
checkout ships (`e2e/data/test.csv` and `loot-core/src/mocks/files/{windows-1252,
windows-1252-euro,utf-8-bom,utf-16be,utf-16le}.csv`) as raw bytes (`bytesBase64`). The
generator reads them from the checkout; their sha256 is in `FROZEN_SOURCES` (a re-pin that
changes one fails the generator), and `verify.mjs`, which has no checkout, takes the bytes
from the committed contract and checks them against the same hash. They are Actual's public
test data and synthetic: invented payees, a masked account number, round amounts. Variants
mirror the options Actual's own `parse-file.test.ts` passes (a manual `windows-1252` or
`iso-8859-1` encoding, explicit `auto`, an unknown label, a headerless read that skips the
first line). Outputs are what the pipeline produces, not Actual's test expectations.

`pipeline/bank-layout/<bank>[/<variant>]` and `.../configured` (36 cases, 18 layouts in
`bank-layout-cases.mjs`) reproduce the export LAYOUT of common banks and card issuers as it is
commonly documented. They are reconstructions with synthetic values (made-up payees and
amounts, 2026 dates, zeroed account and card fields), not real exports, and a bank can change
its format at any time. The plain case is what a new user gets (no saved settings). The
`/configured` case adds the preferences a user would save in the import dialog for that layout
(delimiter, skipped lines, header row, encoding, mapping including Debit/Credit or in/out
columns, date format, flip). The `uk-money-in-out/ambiguous-dates` variant has every day
12 or less, so day-first dates also read month-first.

## `decodeCsvBytes`: bytes to text

The module-private decoder in `parse-file.ts`, extracted from the frozen source like
the other private functions (its global `TextDecoder` is the one dependency). Input is
`{ bytesBase64, encoding }` with `encoding` possibly absent (the default, `auto`); output
is `{ text }` or `{ error }` where `error` is the message of the error `TextDecoder`
threw, which only an unsupported label causes (decoding never throws; it substitutes
U+FFFD). The message is Node's, so a port only needs to know the label is refused.
Every V8 block is reached (`coverageGate: 'enforce'`), and `extraCheck` confirms that
real `parseFile` fails to decode exactly when the extracted copy throws.
`DECODE_CHECKLIST` in `decode-cases.mjs` names the case for each behavior: all 256 bytes
under each single-byte label (the tables), every byte-order-mark combination under every
modal label, invalid and truncated UTF-8, UTF-16 surrogate handling and odd lengths, and
the label variants a saved preference could hold.

## `parseCsvRecords`: the CSV reader on its own

A composite entry (cases in `csv-parse-cases.mjs`) that pins csv-parse 7.0.3 as
Actual calls it: `parseFile` -> `decodeCsvBytes` (`encoding: 'auto'`) -> `csv-parse`
with `bom: true`, `quote: '"'`, `trim: true`, `relax_column_count: true`,
`skip_empty_lines: true`, the modal's single-character delimiter (`, ; | tab ~`) and
`columns: hasHeaderRow`. Input is `{ csv, delimiter, hasHeaderRow }`, or
`{ bytesBase64, delimiter, hasHeaderRow }` for raw file bytes (byte order marks,
UTF-16, invalid UTF-8), plus the optional file options `skipStartLines`,
`skipEndLines` and `encoding` (defaults 0, 0 and `auto`) that `parseFile` also takes.
`parseFile` splits the decoded text on `/\r?\n/` (a lone CR is not a line break),
errors when the skips total at least the line count (the empty last line after a
trailing newline counts), clamps negative skips to zero, and rejoins the kept lines
with CRLF, which rewrites a line feed inside a quoted field; a skip that cuts through a
quoted multi-line field leaves its remainder to csv-parse. The cases are in
`csv-file-option-cases.mjs` (named skip and encoding cases, and 300 seeded files in a
random byte layout, label and skip setting). Output is `{ records }`, or `{ error }` holding the first
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
trimmed and untrimmed character, quote handling, delimiters, header shapes, and the
skip-line and encoding options, whose entries come from `CSV_OPTION_CHECKLIST`) and the
plan refuses a checklist entry whose case is missing or does not show it. The
seeded base family (1,500 files, seed `SEED + 8`) draws from an alphabet weighted toward
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
