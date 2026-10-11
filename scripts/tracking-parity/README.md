# Tracking fixtures

Regenerate the synthetic fixtures from an Actual checkout whose HEAD is the
release pinned in `config/parity/oracle-pin.json` (tag and commit):

```sh
node scripts/tracking-parity/generate.mjs /path/to/actual
scripts/test.sh unit TrackingBudgetContractTests TrackingBudgetDatabaseContractTests
```

The generator executes upstream tracking callbacks in a minimal registry. Its
36 cases cover category calculations; they do not simulate the full server.
Read, write-safety, lifecycle, and consumer coverage lives in the other
`TrackingBudget*Tests` suites. Run `scripts/test.sh unit` for shared caller coverage.
