# Template editor parity fixtures

`ActualistTests/Fixtures/ActualCore26_10_0/Templates/` holds the template editor
oracle: the pinned Actual reducer, migration, and validation bodies run on
synthetic templates. `template-editor-manifest.json` records the pinned release,
source and helper hashes, the fixture hash, and the case count.

Regenerate against a clean checkout of the pinned Actual tag (with
`yarn install` done):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/template-parity/generate.mjs
```

Check that the committed fixture and manifest match a fresh generation (needs
the oracle; exits 2 without it):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/template-parity/generate.mjs --check
```

Verify the committed manifest and fixture without an oracle:

```sh
node scripts/template-parity/verify.mjs
```

Consumer suite: `BudgetTemplateEditorOracleTests`.

Scope and conventions:

- Synthetic UTC-noon calendar adapters and a fixed `today` of `2026-09-04`
  (`2026-09-04T12:00:00.000Z`).
- Schedule hydration and the engine oracle are not executed. Preview, Apply, and
  currency parity are tested separately through SQLite.
- Values are JSON display units. Previews and Apply use integer minor units.
