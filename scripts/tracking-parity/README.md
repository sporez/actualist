# Tracking fixtures

Regenerate the synthetic fixtures from an Actual checkout whose HEAD is pinned
to v26.9.0 commit `59fe126f637d858c061e1eeedbef5436c8f2225a`:

```sh
node scripts/tracking-parity/generate.mjs /path/to/actual
scripts/test.sh unit TrackingBudgetContractTests TrackingBudgetDatabaseContractTests
```

The generator executes upstream tracking callbacks in a minimal registry. Its
36 cases cover category calculations; they do not simulate the full server.
Read, write-safety, lifecycle, and consumer coverage lives in the other
`TrackingBudget*Tests` suites. Run `scripts/test.sh unit` for shared caller coverage.
