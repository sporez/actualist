# Development

Actualist is a SwiftUI app for iPhone and iPad, targeting iOS 26+.
Use macOS and Xcode 26 or later.

## Build and run

Open `Actualist.xcodeproj`, select the `Actualist` scheme, and run in Xcode.

For the command-line helpers, copy `scripts/lib/destinations.example.sh` to
`scripts/lib/destinations.sh` and set `ACTUALIST_SIMULATOR_ID` using an ID from
`xcrun simctl list devices available`. This machine-specific file is gitignored.

```sh
scripts/run-ios-simulator.sh --boot
```

The helper builds, installs, and launches the app. `--no-launch` builds and
installs without launching; `--help` lists the options.

## Side-by-side development app

Use the shared `Actualist Dev` scheme for a development build that can be
installed beside the regular app:

```sh
ACTUALIST_SCHEME='Actualist Dev' scripts/run-ios-simulator.sh --boot
```

The Dev scheme uses the `Dev` build configuration for every action, including
Archive. It builds `com.sporez.actualist.dev` with the display name
`Actualist Dev`, the Dev app icon, a separate widget identifier, and the
`group.com.sporez.actualist.dev` App Group. The regular `Actualist` scheme and
its Debug and Release identities remain the defaults.

Physical-device installation requires an Apple developer account in Xcode and
provisioning for both `com.sporez.actualist.dev` and
`com.sporez.actualist.dev.widgets`, each using the Dev App Group. A wildcard
profile cannot authorize App Groups. Select `Actualist Dev` and automatic
signing with your team to create the separate profiles; keep the regular app's
identifiers and App Group unchanged.

Wallet transaction import is not provisioned in the Dev app because its
transaction-picker entitlement is intentionally omitted. Use the regular app
for Wallet import development.

Select the same scheme explicitly when running tests against the Dev app:

```sh
ACTUALIST_SCHEME='Actualist Dev' scripts/test.sh unit BankSyncReconcilerTests
```

`ACTUALIST_SCHEME` accepts only `Actualist` and `Actualist Dev`. The simulator
helper derives the matching bundle identifier and refuses conflicting bundle
or configuration overrides before uninstalling or installing an app.

## Demo budgets

Use the bundled offline demo for UI checks:

```sh
scripts/run-ios-simulator.sh --boot --reset --demo --screen budget --screenshot
```

For a tracking budget, replace `--demo` with `--tracking-demo`.
**`--reset` uninstalls the simulator app and removes its local data.** Run this
example only on a confirmed disposable installation. Without reset, a demo
flag preserves an existing real selected budget, which can resume normal
server sync and appear in screenshots. Once entered, the bundled demos
themselves are offline; a demo flag alone does not guarantee demo mode.

Screens include `budget`, `spending`, `accounts`, `reports`, `settings`, and
`uncategorized`. Settings paths can be nested, such as `settings/appearance`.
Screenshots are saved under `.artifacts/screenshots/`.

The tracking fixture contains July–September 2026. Past months show Saved or
Overspent; current/future months show Projected Savings. Regenerate it with
`python3 scripts/generate-demo-budget/generate_tracking_demo.py`.

## Checks

Run the mechanical check and tests appropriate to the change:

```sh
scripts/check.sh

# Affected unit suite
scripts/test.sh unit BankSyncReconcilerTests

# All unit tests
scripts/test.sh unit

# Affected UI test
scripts/test.sh ui AdaptiveSettingsUITests/testCompactSettingsCategoriesOpenByTappingRows

# Full unit and UI suites
scripts/test.sh all
```

Use focused tests for contained changes, full unit coverage for shared money,
database, or sync changes, and inspect affected screens for UI changes. Releases
require full unit and UI coverage. Documentation-only changes need no app tests.
Avoid repeating passing checks when the relevant code is unchanged.

Helpers use the configured simulator UDID and `.derivedData`.
`scripts/test.sh --dry-run unit` prints the command without running Xcode.

UI tests run in parallel on four clones of the configured simulator
(`ACTUALIST_UI_TEST_WORKERS` changes the count), and the
suites listed in `serial_ui_suites` at the top of `scripts/test.sh` run after
them in a serial pass. `ACTUALIST_TEST_PARALLEL=0` forces one serial pass for
diagnosis. Every UI test starts from a fresh demo with default preferences
(`-actualist-replace-demo-for-ui-testing` on its first launch), so tests do
not depend on their order.
Detailed agent verification rules live in
[AGENTS.md](../AGENTS.md#testing-scope-and-reuse).

## Parity oracles

The parity harnesses run real Actual code to produce the expected values that
Actualist's oracle tests compare against.

- **Pin:** `config/parity/oracle-pin.json` names the pinned Actual release
  (tag, full commit, package version, fixture folder). No harness keeps its
  own copy.
- **Domains:** `config/parity/domains.json` maps each Actual-compatible area to
  its production paths, harness, fixture folder, Swift oracle suites and
  coverage status.
- **Fixtures:** generated fixtures live in one folder per pin, such as
  `ActualistTests/Fixtures/ActualCore26_10_0/`. Their expected values are never
  edited by hand.

### Oracle checkout

Clone Actual at the pinned tag outside this repository, run
`yarn install --immutable`, and point the harnesses at it:

```sh
export ACTUALIST_PARITY_ORACLE_ROOT=/path/to/actual
```

`scripts/parity.sh` also reads it from the gitignored `scripts/lib/lab.env`
(copied from `scripts/lib/lab.example.env`) when it is not already set.
Running a generator directly still needs the variable in the environment.

Every generator refuses to run unless that checkout is at the pinned commit
and tag with a clean tree, and checks again afterwards. Generators that write
into the checkout need their own clone when run in parallel. Nothing in
`scripts/check.sh` needs the oracle, so a clone without one still passes.

### Everyday use

```sh
scripts/parity.sh status            # domains, coverage, open divergences
scripts/parity.sh touched           # domains the working tree touches
scripts/parity.sh touched main..HEAD
scripts/parity.sh verify tracking   # hash check, regenerate-and-diff, Swift suites
scripts/parity.sh --dry-run verify tracking
scripts/parity.sh verify-all        # every domain, one Swift test run
```

`verify` runs the domain's fixture hash check. When
`ACTUALIST_PARITY_ORACLE_ROOT` is set, it then regenerates the fixture into a
temporary folder and diffs it against the committed copy. Finally it runs the
domain's Swift oracle suites through `scripts/test.sh`. Without the oracle it
says the regenerate step was skipped.

`verify-all` runs every domain's hash check and regenerate-and-diff in turn,
then one `scripts/test.sh` run with all of their Swift oracle suites, so Xcode
starts once. A failing suite fails every domain in that run; use `verify
<domain>` to find which one. It is for a re-pin or a release check. For an
ordinary change, run `verify` for each touched domain.

### Known divergences

When an oracle test finds that Actualist differs from Actual and the fix is not
done yet:

1. Add an entry to `config/parity/known-divergences.json` with its `OP-nn`, domain,
   test cases, summary, opened date and review-by date. When one parameterized
   test carries several divergences, each entry also lists its `fixtureCases`.
   These are the fixture case IDs it covers, and two entries can't claim the
   same one.
2. Wrap that case's comparison in `withKnownIssue("OP-nn: ...")`.
   `isIntermittent` is not allowed. When the fix lands the test fails until the
   marker and the entry are removed together.

When the maintainer decides to keep a difference, its entry gets
`"status": "intended"`, a `decided` date and a `reason`, and keeps its marker. If
Actualist's behavior later changes, the test goes red.

`scripts/lint-known-divergences.sh`, run by `scripts/check.sh`, enforces this
and lists open and intended entries. `scripts/parity.sh gate <range>` fails while an open
entry sits in a domain the range touches, unless it is acknowledged with
`--ack OP-nn`; intended entries never block. The TestFlight release script and the dev-to-main merge use it.

### Adding a harness

Each harness has:

- a generator that takes the oracle only from `ACTUALIST_PARITY_ORACLE_ROOT`
  through `scripts/parity/lib/oracle-pin.mjs`, writes the fixture plus a manifest
  (pin, oracle source hashes, generator hash, seed, case count, fixture hashes),
  and supports `--check` (regenerate into a temp folder and diff);
- a `verify.mjs` that checks the manifest and hashes without the oracle;
- a README that lists every normalization rule (only IDs, timestamps and
  ordering Actual leaves unspecified; never amounts);
- one Swift oracle suite that replays every case through production code and
  compares the whole normalized output;
- an entry in `config/parity/domains.json`.

### Moving to a new Actual release

1. Clone Actual at the new tag and run `yarn install --immutable`.
2. Update `config/parity/oracle-pin.json`, then `git mv` the fixture folder to
   the new name so the regenerated diff stays reviewable.
3. Run each harness's `generate` command from `config/parity/domains.json`.
   The csv-export-interop source-freeze hashes need recomputing.
4. If an upstream source a generator reads has moved, update its source list.
5. Run `scripts/check.sh`, then `scripts/parity.sh verify <domain>` for each
   covered or partial domain.
6. Review every changed expected value. Each one is either an upstream change
   Actualist already matches or a divergence: record it as an `OP-nn` finding
   and fix it separately. Map changed case IDs; never drop them.

## Code basics

Keep reads and writes behind `LocalFirstActualStore`, financial logic outside
SwiftUI views, and stored money in integer minor units. Use native SwiftUI
controls and Liquid Glass. New Swift files inside the existing synchronized
Xcode groups are picked up automatically.

Use synthetic or throwaway budgets for testing, and keep credentials and
personal financial data out of the repository.

## TestFlight

Standing tester guidance lives in `config/testflight/what-to-test.txt`;
build highlights come from `TestFlight-Note` commit trailers. The trailer format
is documented in [AGENTS.md](../AGENTS.md#commit-and-testflight-notes).
Do not prepare or bump a release just to validate documentation.
