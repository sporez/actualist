# Split parity fixtures

`ActualistTests/Fixtures/ActualCore26_10_0/Splits/` holds split-transaction
family and rule outputs produced by running Actual's pinned split code. The
`manifest.json` in that folder records the pinned release, source and helper
hashes, the fixture hashes, and the case count.

Regenerate against a clean checkout of the pinned Actual tag (with
`yarn install` done):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/split-parity/generate.mjs
```

Check that the three generated fixtures and `manifest.json` match a fresh
generation (needs the oracle; exits 2 without it):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/split-parity/generate.mjs --check
```

Verify the committed manifest and fixtures without an oracle:

```sh
node scripts/split-parity/verify.mjs
```

Consumer suites: `SplitTransactionFamilyTests`, `RuleSplitActionExecutorTests`,
and `ActualCoreSplitOracleFixtureTests`.

Conventions:

- Amounts are integer minor units. Percent rounding uses JavaScript
  `Math.round`, so ties go toward positive infinity.
- Synthetic transaction dates are fixed (`2026-08-15`, `2026-08-20`), so output
  does not depend on the current day.
- `grouped-query-cases.json` in this folder is hand-written, not generator-owned,
  and is not covered by `--check`.
