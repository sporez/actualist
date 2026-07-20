# Development Pipeline

Actualist should use a standard Xcode Swift/SwiftUI project with an app target named `Actualist`, a unit test target named `ActualistTests`, and a UI test target only when user-flow automation becomes useful.

Current local tooling check:

- Xcode: `26.3`
- Available simulator runtime: `iOS 26.3.1`
- Preferred simulator: `iPhone 17 Pro`

## Project Shape

Use Xcode's standard iOS App template:

- Product Name: `Actualist`
- Bundle Identifier: `com.sporez.actualist`
- Interface: `SwiftUI`
- Language: `Swift`
- Minimum Deployment: `iOS 26.0`
- Storage: local SQLite budget files managed by the local-first store
- Tests: include unit tests

Keep dependencies light:

- Use Apple frameworks first: SwiftUI, Observation, Foundation, Security, os.log.
- Add packages only when they clearly reduce maintenance cost.
- Avoid UIKit entirely for application UI.
- Keep database access inside `Actualist/LocalFirst/Database`; views and feature
  view models should stay behind repository/store seams.

## Build

Once the Xcode project exists:

```sh
xcodebuild \
  -project Actualist.xcodeproj \
  -scheme Actualist \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath .derivedData \
  build
```

## Test

```sh
xcodebuild \
  -project Actualist.xcodeproj \
  -scheme Actualist \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath .derivedData \
  test
```

## TestFlight Releases

Use the local release helper menu for TestFlight versioning, release-note
generation, archives, and App Store Connect uploads:

```sh
scripts/testflight-release.sh
```

The same flow is available with explicit commands:

```sh
scripts/testflight-release.sh plan
scripts/testflight-release.sh prepare
git add Actualist.xcodeproj/project.pbxproj
git commit -m "chore: prepare TestFlight <version> (<build>)"
scripts/testflight-release.sh upload
scripts/testflight-release.sh tag
scripts/testflight-release.sh github-release
```

See `docs/testflight-releases.md` for version bump options, generated artifact
paths, optional GitHub prereleases, and App Store Connect authentication
environment variables.

## Liquid Glass Checks

Actualist targets iOS 26+ and uses real SwiftUI Liquid Glass APIs for glass-like
controls, floating navigation, toolbars, and panels. Do not use Material or blur
effects to fake glass.

Allowed glass APIs for now:

- `.buttonStyle(.glass)`
- `.buttonStyle(.glassProminent)`
- `.buttonStyle(.glass(...))`
- `.glassEffect(_:in:)`

Do not use `GlassEffectContainer` until it is explicitly re-tested on a physical
iOS 26 device. The first device run after adding it crashed before app code.

After UI/design-system work, inspect the diff for accidental custom material or
nested glass usage:

```sh
git diff -- '*.swift' | rg 'Material|\\.regularMaterial|\\.thinMaterial|\\.ultraThinMaterial|GlassEffectContainer|buttonStyle\\(\\.glass|glassEffect'
```

## Fast Simulator Loop

Keep Simulator running while iterating:

1. Build the app.
2. Install the built app into the already-booted simulator.
3. Launch `Actualist`.

Example:

```sh
xcodebuild \
  -project Actualist.xcodeproj \
  -scheme Actualist \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -derivedDataPath .derivedData \
  build

xcrun simctl install booted .derivedData/Build/Products/Debug-iphonesimulator/Actualist.app
xcrun simctl launch booted com.sporez.actualist
```

For visual QA, capture a screenshot explicitly:

```sh
xcrun simctl io booted screenshot /tmp/actualist.png
```

The simulator commands may require full local permissions outside Codex's filesystem sandbox because CoreSimulator writes under `~/Library/Developer/CoreSimulator` and `~/Library/Logs/CoreSimulator`.

## Iteration Standards

For each meaningful UI change:

- Build with `xcodebuild`.
- Check the SwiftUI diff for custom material or nested glass usage.
- Launch in the already-running simulator.
- Capture a screenshot only when visual layout changed or needs verification.
- Check compact and tall content states.
- Check first-launch onboarding, loading, error, and populated states when applicable.
- Keep screenshot artifacts out of git unless intentionally adding reference images.

For each sync/data change:

- Add or update SQLite/CRDT fixtures.
- Test money formatting and date grouping.
- Keep money as integer minor units internally. Do not use `Double` for money.
- Verify sync token, password, encryption-key, and budget-data redaction in logs.
- Verify failures produce actionable settings/onboarding errors.
- For write actions, test the conservative flow: draft, submitting, local reload, clean, and failed/retry.
- After successful writes, verify the affected account/month/category data is reloaded from SQLite before the UI returns to clean state.

## Future CI

When the project is ready for remote CI:

- Add a shared Xcode scheme.
- Run unit tests with `xcodebuild test`.
- Keep UI screenshots as optional artifacts, not required for every commit.
- Consider Xcode Cloud or GitHub Actions with macOS runners once signing and simulator availability are settled.
