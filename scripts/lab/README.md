# Lab budget tool

Create, list, delete, download and reset **test budgets on the disposable lab
Actual server**, so test data can be rebuilt whenever you test. The client is
upstream Actual's own code (`@actual-app/api` over loot-core, run through
vitest like `scripts/parity/live-lab-interop/`), so every budget is written
through the real client and uploaded the way Actual does it. It appears in
Actualist's budget picker.

```sh
scripts/lab/budgets.sh list
scripts/lab/budgets.sh create <profile> [--name <suffix>] [--anchor YYYY-MM] [--months N] [--per-month N]
scripts/lab/budgets.sh delete "<name>"        # a managed name only
scripts/lab/budgets.sh delete --all-managed
scripts/lab/budgets.sh reset                  # delete all managed, create standard + tracking + the templates set + pair
scripts/lab/budgets.sh wipe --yes             # delete EVERY budget on the server (empty-server flows)
scripts/lab/budgets.sh download "<name>" <dir>
scripts/lab/budgets.sh month "<name>" YYYY-MM   # read a month through Actual's own client
scripts/lab/budgets.sh apply "<name>" YYYY-MM "<cat>,<cat>"   # run Actual's engine on those categories
```

## Configuration

Nothing secret or address-like is tracked.

- `ACTUAL_LAB_URL` (required) and `ACTUAL_LAB_PASSWORD`: environment variables,
  or put them in the gitignored `scripts/lib/lab.env` (copy
  `scripts/lib/lab.example.env`). The environment wins over the file.
- `ACTUALIST_PARITY_ORACLE_ROOT`: the pinned, read-only Actual checkout (tag and
  commit in `config/parity/oracle-pin.json`) with `node_modules`. The script
  refuses to run unless `scripts/parity/lib/oracle-pin.mjs oracle-root` accepts
  it (HEAD at the pin, pinned tag, clean tree), and checks again afterwards. Nothing is installed into
  it. Required; set it in the environment or in `scripts/lib/lab.env`.

The target URL is printed before any write. The script refuses to run without
`ACTUAL_LAB_URL`. Scratch (client data dirs, vite cache, `last-run.log`) lives
under `.artifacts/lab/`. Vitest output is noisy; the full log of the last run is
`.artifacts/lab/last-run.log` and is summarized only on failure.

## Safety

- Only budgets whose name starts with `Lab · ` are managed. `delete` and
  `reset` never touch anything else, and `delete <name>` refuses an unmanaged
  name.
- `wipe --yes` is the one exception: it deletes every budget on the server,
  managed or not. Use it to reach an empty server (the Import / Create New
  Budget picker flow appears only when the account has no budgets), then
  `reset` to restore the standard set.
- `create` refuses a name that already exists. A failed create removes its own
  half-built budget.
- Budgets are deleted with the server's `/sync/delete-user-file`.

## Profiles

All profiles are deterministic (fixed seeds) and dated relative to the current
month. Budgets are built with syncing on, so `messages_crdt` is populated, then
the file is re-uploaded so a fresh download already contains the data.

| Profile | Name | Contents |
| --- | --- | --- |
| `standard` | `Lab · Standard` | In-depth household budget (envelope): 10 accounts (two checking, savings, high-yield savings, two credit cards, cash, off-budget brokerage and auto loan, one closed account with history); 9 category groups (one hidden group, one hidden category) and ~45 categories with 3 income categories; 24 months (`--months`) of paychecks, mortgage, utilities, groceries, dining, fuel, subscriptions, seasonal big items, refunds, transfers and card payments, splits, notes, a cleared/uncleared mix, reconciled older months; monthly assignments with intentional overspending, carryover, a hold for next month, `#template` goal notes (simple, by-date, schedule); 7 schedules (auto-post and manual, a transfer, an ended one); payee rename and category rules on imported-style payees. `--anchor YYYY-MM` makes the newest month fixed so reruns are identical. |
| `basic` | `Lab · Basic` | Lighter envelope budget: 4 accounts (one off-budget), 4 groups, ~10 categories + income, 3 months, transfer, split, cleared/uncleared, budgets per month, one schedule and one rule. |
| `tracking` | `Lab · Tracking` | Same shape as `basic`, tracking (report) budget type. |
| `pair` | `Lab · Pair A`, `Lab · Pair B` | Two small budgets for budget-switching checks. |
| `large` | `Lab · Large <months>m x <per-month>` | Multi-year history for upgrade timing. `--months` (default 36), `--per-month` (default 150). Prints the `messages_crdt` count. |
| `templates` | `Lab · Templates` | Fixed Apply Templates scenario (envelope): 6,000 income, a mix of empty and budgeted categories, a Save by Date, a Remainder, and one template whose target month has passed. |
| `templates-tracking` | `Lab · Templates Tracking` | The same scenario in a tracking budget, plus an income template. |
| `templates-notes` | `Lab · Templates Notes` | The envelope scenario written as note templates in Actual's own syntax, plus one category whose note changed after Actual stored it, so it really is out of date. |
| `empty` | `Lab · Empty` | A new, empty budget. |

`--name <suffix>` names the budget `Lab · <suffix>` (not for `pair`).
`--anchor YYYY-MM` applies to every profile.

## download

`download "<name>" <dir>` fetches the server file (`/sync/download-user-file`)
and unzips `db.sqlite` and `metadata.json` into `<dir>`, e.g. to feed the app's
upgrade-timing harness:

```sh
scripts/lab/budgets.sh download "Lab · Standard" .artifacts/lab/dl
sqlite3 .artifacts/lab/dl/db.sqlite 'SELECT COUNT(*) FROM messages_crdt'
```

## Comparing an Apply Templates run with Actual

Create the scenario twice, apply in Actualist to one copy and with `apply` to
the other, then compare `month` output. `month` syncs a fresh upstream client,
so it sees what Actualist uploaded; `download` does not, because the server
file only changes on a full upload.

```sh
scripts/lab/budgets.sh create templates
scripts/lab/budgets.sh create templates --name "Templates Twin"
# Apply in Actualist to "Lab · Templates", then:
scripts/lab/budgets.sh apply "Lab · Templates Twin" 2026-10 "Rent,Car Fund,Savings"
scripts/lab/budgets.sh month "Lab · Templates" 2026-10
scripts/lab/budgets.sh month "Lab · Templates Twin" 2026-10
```

Upstream's subset handler always overwrites. For a Fill Empty comparison, list
only the categories Fill Empty would touch.

## Notes on the implementation

- `NODE_ENV=production` is set for the run: under vitest's default `test` mode
  upstream awaits a full sync after every write, which is orders of magnitude
  slower.
- Transfers are written outside upstream's batch wrapper because their
  counterpart rows are created by reading back the inserted rows.
- Files: `budgets.sh` (entry point, env, oracle checks), `lab.test.mjs`
  (commands), `profiles.mjs` (shared helpers, basic/pair/large),
  `standard.mjs`, `vitest.config.mjs`.
