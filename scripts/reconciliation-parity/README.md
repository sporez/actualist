# Reconciliation parity fixtures

`ActualistTests/Fixtures/ActualCore26_10_0/Reconciliation/` holds the outputs of
Actual's pinned reconciliation code, run under vitest in the oracle checkout.
`reconciliation-manifest.json` records the pinned release, source and helper
hashes, the fixture hash, and the case count. `reconciliation-contract.json`
holds six reviewed cases: `cleared-balance`, `finish`,
`adjustment-rule-projection`, `adjustment-rule-delete`, `lock`, and `unlock`.

Regenerate against a clean checkout of the pinned Actual tag (with
`yarn install` done):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/reconciliation-parity/generate.mjs
```

Check that the committed fixture and manifest match a fresh generation (needs
the oracle; exits 2 without it):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/reconciliation-parity/generate.mjs --check
```

Verify the committed manifest and fixture without an oracle:

```sh
node scripts/reconciliation-parity/verify.mjs
```

Consumer suite: `ActualCoreReconciliationOracleFixtureTests`.

## Normalization rules

The generator's `selected()` helper normalizes what depends on runtime identity
or the current day. Nothing else is changed.

| Field | Rule |
| --- | --- |
| `id` | `child-a` and `child-b` are kept. Any other non-null id becomes `<generated>`. Null stays null. |
| `parentID` | Any non-null value becomes `<generated>`. This is a uuid-derived id, like `id`. |
| `date` | Becomes `<current-day>` when normalized. The realized and split outputs normalize. `added` and `deleted` in `adjustment-rule-projection` keep raw dates. |
| `amount` | Never normalized. Amounts are integer minor units. |

Known quirk, kept as-is: in `adjustment-rule-delete`, `batch.deleted.map(selected)`
passes the array index as `normalizeDate`. Index 0 is falsy, so its raw date is
kept (`2017-01-01`, fixed under `IS_TESTING`). Later indexes normalize. Changing
this would change an expected value, so it is recorded here instead of fixed.

The `2026-09-01` date in `adjustment-rule-projection` is raw because it is a
rule-produced value that the case keeps verbatim.
