# File import oracle

Runs functions from the pinned Actual release (`config/parity/oracle-pin.json`)
and records `input -> output` for each case. A Swift replay suite
(`FileImportOracleReplayTests`) compares Actualist's ports with them. This
directory is the generator side only. The first phase wires the pipeline end to
end; later phases add functions and cases.

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

## Fixture format

`cases[]` entries are `{ id, function, source, description, seed?, derivedFrom?,
input, output }`; `source` is `named`, `generated` or `derived`. A derived case
(`amountToInteger/after-*`) takes its input from the output of the case named in
`derivedFrom` and exists only when that output is not null. A JS value JSON
cannot carry is `{ "$js": "undefined" | "NaN" | "-0" | "Infinity" | "-Infinity" }`,
or `{ "$js": "threw", "message": ... }`. All data is synthetic. Two consecutive
generations are byte-identical.
