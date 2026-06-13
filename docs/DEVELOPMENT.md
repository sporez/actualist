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
- Storage: none for the first pass
- Tests: include unit tests

Keep dependencies light:

- Use Apple frameworks first: SwiftUI, Observation, Foundation, Security, os.log.
- Add packages only when they clearly reduce maintenance cost.
- Avoid UIKit entirely for application UI.
- Avoid a database until offline support or large local caching becomes necessary.

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

## Liquid Glass Lint

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

Run this after UI/design-system work:

```sh
scripts/lint-liquid-glass.sh
```

## Fast Simulator Loop

Keep Simulator running while iterating. The default script path does not boot or
shut down the simulator and does not take screenshots:

1. Build the app.
2. Install the built app into the already-booted simulator.
3. Launch `Actualist`.

Use:

```sh
scripts/run-ios-simulator.sh
```

If no simulator is already booted, either start one from Simulator/Xcode or use:

```sh
scripts/run-ios-simulator.sh --boot
```

For visual QA, request a screenshot explicitly:

```sh
scripts/run-ios-simulator.sh --screenshot
```

For build/install without launch:

```sh
scripts/run-ios-simulator.sh --no-launch
```

The script assumes:

- Scheme: `Actualist`
- Project: `Actualist.xcodeproj`
- Bundle ID: `com.sporez.actualist`
- Simulator: `iPhone 17 Pro`
- Runtime OS: `26.3.1`

Override values when needed:

```sh
SIMULATOR_NAME='iPhone 17 Pro Max' scripts/run-ios-simulator.sh
```

The simulator commands may require full local permissions outside Codex's filesystem sandbox because CoreSimulator writes under `~/Library/Developer/CoreSimulator` and `~/Library/Logs/CoreSimulator`.

## Iteration Standards

For each meaningful UI change:

- Build with `xcodebuild`.
- Run `scripts/lint-liquid-glass.sh`.
- Launch in the already-running simulator.
- Capture a screenshot only when visual layout changed or needs verification.
- Check compact and tall content states.
- Check first-launch onboarding, loading, error, and populated states when applicable.
- Keep screenshot artifacts out of git unless intentionally adding reference images.

For each API/data change:

- Add or update decoding fixtures.
- Test money formatting and date grouping.
- Verify API key redaction in logs.
- Verify failures produce actionable settings/onboarding errors.

## Future CI

When the project is ready for remote CI:

- Add a shared Xcode scheme.
- Run unit tests with `xcodebuild test`.
- Keep UI screenshots as optional artifacts, not required for every commit.
- Consider Xcode Cloud or GitHub Actions with macOS runners once signing and simulator availability are settled.
