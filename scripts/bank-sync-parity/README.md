# Bank Sync / import matching parity harness

Generates the BankSync fixture from Actual's own reconcile path at the pinned
release (`config/parity/oracle-pin.json`, v26.10.0). This directory holds only the generator side; the Swift replay
is separate.

- `generate.mjs`: runs the plan inside the oracle checkout under vitest and
  writes the fixture. `--check` regenerates into a temporary directory and
  diffs against the committed fixture.
- `verify.mjs`: checks the committed fixture against the manifest and the plan.
  Needs no oracle.
- `cases.mjs`: the plan (named and seeded cases). Pure data, no expectations.
- `oracle-runner.template`: the vitest test copied into the oracle for one run
  and removed afterwards.
- Fixture: `ActualistTests/Fixtures/ActualCore26_10_0/BankSync/`
  (`bank-sync-contract.json`, `bank-sync-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/bank-sync-parity/generate.mjs [--check]
node scripts/bank-sync-parity/verify.mjs
```

The oracle checkout must be at the pinned commit with a clean tree and
`yarn install` done. It is checked before and after the run and is never
written to except for the temporary runner, which is removed in a `finally`.
Generation takes about 7 seconds.

## What a case is

One synthetic budget, optional rules, and one reconcile call.

- **World** (`world`, once at the top of the contract): three accounts
  (checking, savings, off-budget brokerage, each linked as a SimpleFIN account
  with a provider id), category groups and categories (with an income
  category), payees (four plain, three transfer payees).
- **Setup** (`setup`): existing rows (`transactions`: plain, cleared and
  uncleared, reconciled, with `imported_id` / `imported_payee`, tombstoned,
  split parents and children, transfer legs), synced preferences (`prefs`: the
  `sync-reimport-deleted-*`, `sync-import-pending-*`, `sync-import-notes-*`,
  `sync-update-dates-*` and `custom-sync-mappings-*` keys, by their full id)
  and schedules. Everything goes through upstream's own `db.insert*`,
  `db.update('preferences', ...)` and `createSchedule`.
- **Rules** (`rules`): inserted with `insertRule` and loaded with `loadRules`.
  Ids are explicit so ranking ties are stable.
- **Call** (`call`): `kind`, `accountId`, `options`, `transactions`.
  - `csv`: `reconcileTransactions` with `isBankSyncAccount: false`. This is what
    `transactions-import` (file import) runs. `options` are the keys of
    upstream's options object (`isPreview`, `strictIdChecking`,
    `defaultCleared`, `updateDates`, `reimportDeleted`,
    `payeeNameNormalization`); an absent key was absent in the call.
  - `bank`: `reconcileTransactions` with `isBankSyncAccount: true`, the same
    option keys, and provider-shaped transactions (`transactionAmount.amount` as
    a decimal string, `transactionId`, `booked`, `payeeName`).
  - `simplefin`: `simpleFinBatchSync` over a mocked provider response. This is
    the whole bank-sync path: preference reads, the field mapping,
    `strictIdChecking` off (a SimpleFIN account), `updateDates` from the
    preference, and the first-sync Starting Balance row. `options.startingBalance`
    is the provider's current balance in minor units.
- **Expected** (`result`, `after`): the oracle's output.
  - `result`: `{ added, updated, updatedPreview }` for `csv` and `bank`, or the
    `simpleFinBatchSync` array `[{ accountId, res }]` for `simplefin`.
    `updatedPreview` entries are upstream's own: `{ transaction, existing }`,
    `{ transaction, ignored: true }` or `{ transaction, existing: false,
    tombstone: true }`. `existing.amount` is upstream's decimal amount
    (`integerToAmount`); every other amount is integer minor units.
  - `after`: the `accounts` (balance and sync columns only), `payees`, `rules`
    and `transactions` after the call. `input` holds the same tables
    (`payees`, `rules`, `transactions`) before it.
  - `error`: the message when the call threw, else `null`.
- **Transactions** are dumped from `v_transactions_internal` with public field
  names (`account`, `payee`, `imported_id`, `imported_payee`, `transfer_id`,
  `is_parent`, `is_child`, `parent_id`, `tombstone`, `cleared`, `reconciled`,
  `schedule`, `raw_synced_data`, `starting_balance_flag`), deleted rows and split
  children included, dates as ISO days.

## Environment

- `today` is `2026-10-15` for `Date`, `global.currentMonth` and
  `currentDay()`. Under `IS_TESTING` upstream's `currentDay()` is a constant
  and `IS_TESTING` gates only `months.ts` date functions, so the runner
  replaces `currentDay` and fakes `Date`. The only reader is the first-sync
  Starting Balance row of an empty download.
- `TZ=America/New_York` for the vitest run.
- A provider download into an account with no live rows is that account's first
  sync, which inserts a Starting Balance row. Only the `opening-balance` cases
  want that; every other `simplefin` case gets an old anchor row
  (`anchor-<account>`, 2020, 1.00) so it exercises matching alone. A reader of
  the fixture must skip rows whose id starts with `anchor-` when it seeds, or
  seed them like any other row.

## Normalization

- Ids upstream mints (new payees, new rows, split children, transfer legs) are
  renamed `uuid-N` by first appearance in `result`, then the `after` tables.
  Setup ids are explicit. A replay maps its own minted ids to these by the
  order of `result.added` (rows) and by payee name (payees).
- The joined lookups `_account`, `_account_name` and `_category_name` are
  dropped from every output.
- Rows of each dumped table are sorted by primary key. `_ts` and `sort_order`
  columns are dropped (`sort_order` derives from the fake clock).

## Cases

484 cases, seed `20261011`.

- **Named (104)**: from known upstream behavior.
  - Rules before matching: account-moving rules, no category learning, transfer
    payees from a rule (insert and matched plain row), off-budget category
    stripping (insert, match, split children), matched transfers keeping a nil
    category, rules seeing the resolved payee, imported-payee rules under
    title-case and original normalization, delete rules, schedule linking, rule
    stages, rules that change amount or date before matching.
  - `reimportDeleted`: preference unset/false/true, the option overriding the
    preference, a live row beating a deleted one, deleted rows never fuzzy
    matched.
  - Bank-sync details: opening balance (first sync, delete rule, amount rule,
    pending skipped, off-budget, empty download, account with history), pending
    and booked merges, `sync-import-pending`, `sync-import-notes`, `#` escaping,
    custom mappings, provider categories, zero amounts.
  - Matching: month, year and leap-day boundaries at +/-7 and 8 days, nearest
    date, equidistant tie, payee pass beating the nearer date, batch claiming
    order, duplicates, `strictIdChecking`, reconciled rows, `updateDates`,
    `defaultCleared`, import identity cleared or kept.
  - Splits: parent match cascading cleared and date, match by imported id,
    child-amount collisions, split inserts.
  - Preview vs commit pair, force-add, errors, payee creation and resolution.
- **Generated (380)** with `mulberry32(20261011 + n)`:
  - 110 fuzzy: date offsets -9..+9 (weighted to the window edge) from month and
    year ends, equal or different amount, payee same/different/missing,
    imported id none/duplicate/new, cleared, reconciled, deleted.
  - 60 multi-candidate: two to four same-amount rows, one to three downloads.
  - 48 boundary: month ends, year ends, a leap day at -8, -7, +7, +8.
  - 44 imported id: id match across accounts and dates, deleted or live,
    preference unset/true/false, duplicate ids in a batch.
  - 48 payee names: title-case and original, apostrophes, ampersands, digits,
    accents, padding.
  - 40 merge: matched row fields (payee, category, notes, cleared, identity)
    present or blank, with and without a filling rule.
  - 30 update-dates: `updateDates` or `sync-update-dates-*` on and off, with
    plain and split-parent rows (the only seeded cases that turn it on).

## Oracle-only cases (19)

Listed with their reasons in the manifest (`oracleOnly`). They stay in the
fixture and are skipped by the replay:

- account-moving rules (2): Actualist fails closed;
- imported splits (4): no import path supplies subtransactions;
- provider mapping (6): `named-import-pending-off`, `named-import-notes-off`,
  `named-import-notes-hash-escape`, `named-custom-mapping`,
  `named-provider-category-valid`, `named-provider-zero-amount` test only the
  provider-side mapping, which the replay takes from the oracle;
- a provider row without a payee, an `internalTransactionId`-only row,
  `forceAddTransaction`, a fractional CSV amount, a dateless CSV row, a CSV row
  that carries a payee id: no Actualist input equivalent;
- the opening balance of an empty download: its date reads the real clock.

## Swift replay

`BankSyncOracleReplayTests` (with `BankSyncOracleReplaySupport`,
`BankSyncOracleFixture`, `BankSyncOracleReplayCaseIDs`) replays the 465 other
cases through the production import reconcile CSV import and Bank Sync share.

- **Entry point.** A starter database seeded with the fixture's upstream rows
  (`worldTables` once, then the case's `rules`, `schedules` and raw
  `transactions` and its preferences), then:
  `ImportReconcileProjection.previewDraft` -> `BudgetDatabase.previewRules` ->
  `ImportReconcileProjection.project` -> `reconcileProjectedImport` ->
  `importReconcileWrites` (plus `BankSyncReconciliation.openingBalance` and
  `makeBankSyncOpeningBalanceMessages` for a first-sync `simplefin` case),
  committed with `commitLocalSyncMessagesAndEnqueue`, then the rows read back.
  A preview case stops after the plan.
- **Candidates.** `csv`: a `TransactionCSVImportRow` per upstream row (a known
  category id is given as its name), mapped by the production
  `TransactionCSVImportCandidates` with `ImportReconcileOptions.csv` and the
  call's upstream options laid over it; the candidates are also compared with
  the post-mapping transactions the oracle recorded. `bank` and `simplefin`:
  the oracle's recorded post-mapping transaction (`candidates`) becomes a
  `BankSyncReconciliation.Candidate`; options are `.bankSync`, except that a
  direct `bank` call uses upstream's default strict id checking (a non-SimpleFIN
  provider, which Actualist does not have).
- **Compared.** The plan classification (rows updated including split children,
  matches left alone, deleted IDs skipped, rows added), and the whole after
  state, with ids the call minted replaced by content-derived names: every
  transaction's account, date, amount, payee, imported payee, notes, category,
  cleared, reconciled, imported id, schedule, parent/child/split flags,
  tombstone, transfer link, opening-balance flag and error; the payees table
  (name, transfer account, tombstone); the rules table (ids, tombstone).
- **Not compared.** `raw_synced_data`; `sort_order`; the accounts table
  (balance and sync columns: Actualist sets them from the provider's balance
  evidence, which the fixture does not model); `updatedPreview` shapes beyond
  the ignored count; the order of added rows.
- **Not covered.** The provider-side mapping for `bank` and `simplefin` cases
  (`prepareDownload`: pending filter, ID and currency checks, field mapping,
  note escaping); a `bank`/`simplefin` candidate is the oracle's own. The CSV
  parser (rows start as parsed rows).
- **Divergences.** OP-54 to OP-69 (`config/parity/known-divergences.json`).
  Each is wrapped by exact field path; every other mismatch stays strict.

## Upstream facts worth knowing

Recorded as oracle behavior, not decided here.

- Opening balance is current balance minus the raw downloaded rows (SimpleFIN
  parses the decimal string), before rules and before the import-pending filter.
  A row a delete rule drops, or a pending row skipped by the preference, is
  still subtracted.
- The first-sync Starting Balance row is itself a candidate for the reconcile
  that follows it.
- The fuzzy query reads `v_transactions`, so split children are candidates.
- A matched transfer leg keeps its nil category even when a rule sets one.
- A download that a delete rule drops still matches and updates an existing
  row (the match branch runs before the delete branch); only an unmatched one
  is dropped.
- A bank-synced account counts only rows dated on or before today when it
  decides whether this is its first sync.
- An import with no `reimportDeleted` option reads the account's
  `sync-reimport-deleted-*` preference, and with it off matches deleted rows by
  ID and rewrites them.
