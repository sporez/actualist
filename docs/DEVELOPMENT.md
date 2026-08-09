# Development

Actualist is an iPhone SwiftUI app targeting iOS 26+. Use Xcode 26 or later.

## Build And Run

The simulator helper builds, installs, and launches the app. It uses an iPhone
17 Pro by default and accepts environment overrides documented by `--help`.

```sh
scripts/run-ios-simulator.sh --boot
```

To build without launching:

```sh
scripts/run-ios-simulator.sh --no-launch
```

## Tests

Run the unit tests with an installed iOS 26 simulator:

```sh
xcodebuild \
  -project Actualist.xcodeproj \
  -scheme Actualist \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .derivedData \
  test
```

## TestFlight

Use the release helper for versioning, notes, archives, App Store Connect
uploads, tags, and optional GitHub prereleases:

```sh
scripts/testflight-release.sh
```

With no arguments, the helper runs one guided release from preflight through
GitHub publication. It can resume a locally prepared build, skip a completed
TestFlight upload, create the guarded release commit and tag, repair an expired
GitHub CLI login, and attach the IPA to a prerelease. Unrelated working-tree
changes are listed explicitly and stop the release.

The wizard generates What to Test from the consumer checklist in
`config/testflight/what-to-test.txt`, previews the result, and pauses for review.
At that point, keep the notes, add one or more tester-facing focus items, or edit
the complete text in `$VISUAL`/`$EDITOR`. The reviewed file is preserved through
the upload and is also placed in the GitHub prerelease body; commit subjects stay
in a separate Full Git Log section.

Tester-visible changes can supply focused instructions before release by adding
one or more commit trailers. The value should describe an action and an expected
result in language a tester can follow:

```text
TestFlight-Note: Force-quit with a budget open, relaunch, and verify the budget appears immediately.
```

Trailers are optional. Without them, the stable consumer checklist remains the
What to Test content, and the wizard still offers an interactive focus-item step.

Run `scripts/testflight-release.sh --help` for non-interactive commands and
authentication options.

## Engineering Boundaries

- Keep sync transport, SQLite/CRDT handling, domain models, feature view models,
  and SwiftUI views separated.
- Route production reads and writes through `LocalFirstActualStore` and the
  repository protocols.
- Keep financial calculations and mutation values out of SwiftUI views.
- Keep money as integer minor units; do not use `Double` for stored amounts.
- Store tokens and encryption keys in Keychain and keep personal budget data out
  of logs and source control.
- Add dependencies only when they remove meaningful complexity.

## UI Verification

Actualist uses native SwiftUI Liquid Glass. Native tab bars, toolbars,
navigation, sheets, menus, and alerts should own their chrome. Do not fake glass
with `Material`, blur, or custom translucent capsules, and do not stack glass
surfaces.

After UI or design-system work:

```sh
scripts/lint-liquid-glass.sh
```

Also verify:

- An iPhone-sized simulator or preview.
- Dark mode and any affected light themes.
- Dynamic Type and long content.
- Loading, empty, error, and populated states.
- No nested rounded control that looks like a button inside another button.

## Data And Sync Verification

For local-first changes:

- Add or update SQLite/CRDT fixtures.
- Test affected budget, account, transaction, report, and cache behavior.
- Verify local writes reload SQLite-backed state before returning success.
- Verify failed pushes remain queued and retry later.
- Verify passwords, tokens, encryption keys, budget identifiers, and financial
  data are redacted.
- Compare financial behavior with a throwaway budget in Actual before enabling a
  new write for normal use.
