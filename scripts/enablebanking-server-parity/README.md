# Enable Banking server parity harness

Actualist never talks to Enable Banking. It calls the Actual server's
`POST /enablebanking/transactions` and `/enablebanking/status`, and the server
answers with JSON it has already normalized. This harness records those
answers from Actual's own server code at the pinned release
(`config/parity/oracle-pin.json`), so the client is tested against what the
server really sends rather than against a hand-written response.

- `scenarios.mjs`: the plan. Each scenario is a request a client sends and
  the raw Enable Banking API payloads the bank answers with (balances, one or
  more transaction pages, an HTTP error, a non-JSON body, or a timeout),
  shaped per Enable Banking's public API. Pure data with synthetic values;
  nothing in it is an expected value.
- `oracle-runner.template`: the vitest test copied into the oracle's
  `packages/sync-server/src/app-enablebanking/tests/` for one run and removed
  afterwards.
- `shape.mjs`: file names, the pinned source hashes, and the author's
  structural expectations (a download envelope, an error envelope, Express's
  404), never a computed value.
- `generate.mjs`: runs the runner under vitest and writes the fixture.
  `--check` regenerates into a temporary directory and diffs against the
  committed fixture.
- `verify.mjs`: checks the committed fixture against the manifest and the
  plan. Needs no oracle.
- Fixture: `ActualistTests/Fixtures/ActualCore26_11_0/EnableBankingServer/`
  (`enablebanking-server-contract.json`, `enablebanking-server-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/enablebanking-server-parity/generate.mjs [--check]
node scripts/enablebanking-server-parity/verify.mjs
```

The oracle checkout must be at the pinned commit with a clean tree and
`yarn install` done. It is checked before and after the run and is never
written to except for the temporary runner, which is removed in a `finally`.
The run uses its own vitest config without upstream's global setup, which
migrates an account database these routes never open.

## What runs and what is replaced

Runs as shipped: the Express routes in `app-enablebanking.ts` (`/transactions`,
`/status`), `enablebanking-service.ts` (request, pagination through
`continuation_key`, `normalizeTransaction`, `isImportableTransaction`,
`normalizeBalance`), `utils/errors.ts` (`handleEnableBankingError`), the
shared `handleError` wrapper and `isBlockedIp`.

Replaced at the edges only:
- `undici` `fetch`: answers each call to the Enable Banking API with the
  scenario's next payload, and records the method, path and PSU header names
  (`providerCalls`).
- `secrets-service`: reports credentials present or absent per scenario.
- `utils/jwt`: a fixed token instead of signing with a real key.
- `util/middlewares`: the session check passes, as in upstream's own
  `transactions.spec.ts`.

`Date` is faked to `today` (`2026-10-15`, noon UTC), so the `date_to` the
server asks the bank for is stable. `routes-missing` posts to an Express app
without the routes mounted, which is what an Actual server older than Enable
Banking answers.

## Record shape

Each scenario records `request` (path and JSON body), `provider` (the raw
payloads), `providerCalls`, and `response`: `status`, `contentType`,
`bodyText` (byte-for-byte what the server wrote) and `body` (the parsed JSON,
or `null`).

## Swift replay

`EnableBankingClientTests` serves each `bodyText` through a stub URL protocol
to `ActualServerEnableBankingClient` and checks the request it sent (path,
body, token, no file ID, 60 s timeout), the decoded rows and balance
evidence against the recorded body, error envelopes as per-account download
errors, and the durable status loot-core's `getBankSyncStatusFromError`
stores for each one.

The bank-sync-matching harness reads this fixture: its `enablebanking` cases
take their downloads from these recorded responses, so loot-core is fed what
the server really sends.

## Adding a captured sandbox response

A response captured from a real Enable Banking sandbox (Mock ASPSP) can be
added as a scenario: put its raw provider payloads (redacted, mock data only)
into `scenarios.mjs` and regenerate. The fixture then records what Actual's
server makes of it.
