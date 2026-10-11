# Tracking fixtures

`ActualistTests/Fixtures/ActualCore26_10_0/Tracking/contract.json` holds
upstream tracking-budget cell results, generated from the Actual release pinned
in `config/parity/oracle-pin.json`. `tracking-manifest.json` records the pin,
source and helper hashes, and the case count.

Regenerate against a clean checkout of the pinned Actual tag (with
`yarn install` done). Set `ACTUALIST_PARITY_ORACLE_ROOT` to that checkout:

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/tracking-parity/generate.mjs
```

Check that committed fixtures match a fresh generation (needs the oracle; exits 2 without it):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/tracking-parity/generate.mjs --check
```

Verify the committed manifest and fixture without an oracle:

```sh
node scripts/tracking-parity/verify.mjs
```

Then run the consumer suites:

```sh
scripts/test.sh unit TrackingBudgetContractTests TrackingBudgetDatabaseContractTests
```

The generator executes upstream tracking callbacks in a minimal registry. Its
36 cases cover category calculations; they do not simulate the full server.
Read, write-safety, lifecycle, and consumer coverage lives in the other
`TrackingBudget*Tests` suites. Run `scripts/test.sh unit` for shared caller coverage.
