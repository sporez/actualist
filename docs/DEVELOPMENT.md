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

## Demo budgets

Use the bundled offline demo for UI checks:

```sh
scripts/run-ios-simulator.sh --boot --reset --demo --screen budget --screenshot
```

For a tracking budget, replace `--demo` with `--tracking-demo`.
**`--reset` uninstalls the simulator app and removes its local data.** Without
it, a demo flag preserves any already-selected budget. Neither demo contacts a
server.

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
