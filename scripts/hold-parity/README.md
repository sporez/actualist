# Hold parity harness

`generate.mjs` runs Actual's pinned hold-for-next-month handlers against a
synthetic SQLite budget and replays the resulting CRDT messages. It writes
`hold-contract.json`, `hold-baseline.sqlite`, and `hold-manifest.json` into
`ActualistTests/Fixtures/ActualCore26_10_0/Holds/`.

Status: **no Holds fixture is committed yet**, and no Swift suite reads one. The
generator has not been run. `--check` will report `committed fixture is missing`
until a reviewed fixture is generated.

Generate against a clean checkout of the pinned Actual tag (with `yarn install`
done):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/hold-parity/generate.mjs
```

Check committed fixtures against a fresh generation (needs the oracle; exits 2 without it):

```sh
ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual-oracle node scripts/hold-parity/generate.mjs --check
```

Scope:

- Synthetic data only: account `checking`, categories `salary` and `groceries`,
  months `2026-06` through `2027-02`.
- Amounts are integer minor units.
- Runs Actual core handlers offline. There is no live server roundtrip.
- Open before generating a fixture: the SQLite baseline's byte-for-byte
  determinism under `--check` has not been verified.
