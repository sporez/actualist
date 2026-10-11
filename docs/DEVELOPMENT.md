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
Detailed agent verification rules live in
[AGENTS.md](../AGENTS.md#testing-scope-and-reuse).

## Parity oracles

The parity harnesses under `scripts/*-parity/` and `scripts/parity/` run real
Actual code to produce the expected values in the oracle fixtures. Every
harness reads the pinned Actual release from `config/parity/oracle-pin.json`
(tag, full commit, package version, and fixture folder). No harness keeps its
own copy of the pin. Generated fixtures live in one folder per pin, such as
`ActualistTests/Fixtures/ActualCore26_10_0/`. Expected values in them are
never edited by hand.

Each generator needs a clean checkout of the pinned tag with
`yarn install` done, and refuses any other commit. Generators that write into
the checkout need their own clone.

To move to a new Actual release:

1. Clone Actual at the new tag outside this repository and run
   `yarn install --immutable`.
2. Update `config/parity/oracle-pin.json`. Then `git mv` the fixture folder
   to the new folder name so the regenerated diff stays reviewable.
3. Regenerate every harness against the checkout:

   ```sh
   node scripts/split-parity/generate.mjs --actual-checkout <actual>
   node scripts/template-parity/generate.mjs <actual>
   node scripts/reconciliation-parity/generate.mjs --actual-checkout <actual>
   node scripts/tracking-parity/generate.mjs <actual>
   node scripts/account-lifecycle-parity/generate.mjs --actual-checkout <actual> --evidence <dir>
   ACTUAL_UPSTREAM_DIR=<actual> scripts/parity/new-budget-schema/run.sh generate
   ```

   Then re-run the transaction command and query runners (each README names a
   new single-use run label). Also recompute the csv-export-interop
   `source-freeze.sha256` entries.
4. If an upstream source file a generator reads has moved, update the
   generator's source list. Keep each recorded hash list exact.
5. Run `scripts/check.sh` for the hash checks. Then run the oracle suites
   named in each harness README with `scripts/test.sh unit <Suite>...`.
6. Review every changed expected value. Each one is either an upstream change
   that Actualist already matches, or a divergence to record as a finding and
   fix separately. Map any changed case IDs; never drop them.

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
