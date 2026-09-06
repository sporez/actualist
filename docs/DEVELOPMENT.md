# Development

Actualist is an iPhone and iPad SwiftUI app targeting iOS 26+. Use Xcode 26 or later.

## Build And Run

The simulator helper builds, installs, and launches the app. Pin the
simulator by UDID: copy `scripts/lib/destinations.example.sh` to
`scripts/lib/destinations.sh` (gitignored) and set `ACTUALIST_SIMULATOR_ID`.
Environment overrides are documented by `--help`.

```sh
scripts/run-ios-simulator.sh --boot
```

Open the bundled demo budget on a screen and capture a screenshot:

```sh
scripts/run-ios-simulator.sh --boot --reset --demo --screen accounts --screenshot
```

`--screen` is a slash path forwarded to the app. Roots are `budget`,
`spending`, `accounts`, `reports`, `settings`, and `uncategorized`. Settings
pages can be nested (`settings/appearance`) or used as a unique shorthand
(`appearance`, `privacy`, `connection`). `--reset` uninstalls first so demo
always starts from onboarding. Screenshots write to `.artifacts/screenshots/`.

To build without launching:

```sh
scripts/run-ios-simulator.sh --no-launch
```

## Mechanical Check

Run the cheap pre-handoff gate before a commit. It does not build or test:

```sh
scripts/check.sh
```

That covers `git diff --check`, Liquid Glass lint, TestFlight-note lint when
trailers are present, split and template fixture provenance,
synchronized-group integrity (auto file registration), and
file-size warnings for touched sources.

## Tests

Use the smallest test scope that covers the changed behavior and its callers.
The authoritative requirements are in [AGENTS.md](../AGENTS.md#testing-scope-and-reuse).

```sh
# Focused unit suites (multiple suites or Suite/testMethod selectors allowed)
scripts/test.sh unit BankSyncReconcilerTests BankSyncDeletedTransactionsTests

# All unit tests, excluding UI tests
scripts/test.sh unit

# Affected UI interactions only
scripts/test.sh ui AdaptiveSettingsUITests/testCompactSettingsCategoriesOpenByTappingRows

# Full unit and UI suites for releases or broad UI changes
scripts/test.sh all
```

The helper uses the pinned UDID from `scripts/lib/destinations.sh` (or
`ACTUALIST_SIMULATOR_ID` in the environment) and `.derivedData`. Set
`DERIVED_DATA_PATH` to use a different build directory. `--dry-run` before the
mode prints the command without building or testing.

Contained logic changes need affected unit suites. Shared database, sync, money
logic, broad refactors, and project/target changes need the full unit suite.
UI work needs inspection of affected screens and relevant interaction tests;
backend-only work does not need UI automation. Docs/comments need no app tests;
tooling needs syntax and focused behavior checks.

A successful test build counts as compilation for the targets it builds; do not
add an identical standalone build. Normal builds must have zero warnings. Run
`SWIFT_STRICT_CONCURRENCY=complete` for concurrency-related changes and releases,
with no new diagnostics in changed code. This remains a command-line overlay,
not a project-wide Swift 6 migration.

For a commit or push, reuse passing results for unchanged source, tests, project
configuration, and relevant toolchain. Report the reused evidence. Rerun affected
checks after relevant edits or merges, or when prior evidence is missing. Keep
`scripts/check.sh` and diff review; do not restart a full validation cycle simply
because the user asks to push.

The TestFlight helper retains the full shared-scheme unit and UI gate (its
current log/help calls these “unit tests”). An unfiltered `xcodebuild test`
includes both targets. Release validation also requires the strict-concurrency
build described in AGENTS.md. Do not run a separate full suite immediately
before the release helper repeats it.

For test scheduling/reliability changes, check the affected tests with Xcode's
default parallel execution and `-parallel-testing-enabled NO`; expand to the
full unit suite in both modes only for suite-wide scheduling problems. Async
tests should wait for observable completion rather than race short sleep
deadlines. Query-scaling tests should count queries instead of using
shared-machine elapsed time as app performance.

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

The wizard generates one What to Test file from the consumer checklist in
`config/testflight/what-to-test.txt`, previews it, and pauses for review. By
default, `TestFlight-Note` trailers from the upcoming build and two previous
tagged builds are grouped by build. The newest note for each `[topic]` replaces
earlier notes with that topic. Only tagged, public-facing summaries are
included: the note must have a `[topic]`, start with Added/Fixed/Improved/
Moved/Renamed/Removed/Combined, and must not read as a Try/confirm test
script. Untagged, instructional, and verb-less notes are omitted, with a
warning when they appear in the upcoming build. Newer notes take priority when
trimming to App Store Connect's 4,000-character limit. At review, keep the
notes, add a focus item, or edit the complete text in `$VISUAL`/`$EDITOR`.
The reviewed file is used for both TestFlight metadata and the GitHub
prerelease body. The template contains only standing testing guidance and current
limitations; keep build-specific highlights in trailers. Review for plain
language, accurate Settings paths, and stale limitations before each release.
For an already prepared build, edit its existing
`.release/testflight/<version>-<build>/what-to-test.txt` directly. Use
`--keep-test-notes` with subsequent helper commands that would regenerate notes
to preserve that reviewed copy. Do not prepare or bump a release just to check
documentation.

Write trailers as the What to Test changelog, not QA scripts. Decide in this
order:

1. Internal (docs, tests, refactor, TestFlight prepare, no user-visible change)?
   Omit the trailer. Never write a placeholder.
2. Same product surface as an earlier unreleased commit? Rewrite that topic's
   full note. Do not add a second topic or a delta line.
3. New tester-visible surface? Add exactly one trailer using a topic from
   `config/testflight/topics.txt`. Add a topic there only when this commit
   introduces a new surface.

```text
TestFlight-Note: [rules] Added a Rules screen under Settings → Budget & Data. Rules apply in Actual's order and can split a match, link it to a schedule, or stop a matching new transaction from being saved.
```

A commit has zero or one trailer. Two trailers only if it ships two unrelated
surfaces. The newest note for a topic replaces earlier ones. The text must be
the complete current summary, start with Added/Fixed/Improved/Moved/Renamed/
Removed/Combined, and describe what changed and where to find it. Do not tell
the tester what to tap, say, search, try, confirm, or verify. Omit layout-only
and developer-only notes.

Wrong: `Try Import Transaction from Text with "spent 12.50 on coffee".`
Wrong: `Added split rule actions.`
Wrong: `[shortcuts-siri] Say “Open spending” and confirm the tab comes forward.`

Lint new trailers with `scripts/lint-testflight-notes.sh --range <base>..HEAD`.
The standing consumer checklist remains the fallback, and the wizard still
offers an interactive focus-item step.

Run `scripts/testflight-release.sh --help` for non-interactive commands and
authentication options.

Before a release, `scripts/testflight-release.sh doctor` verifies that the
Apple Development private key is usable from the current shell. This catches a
locked login keychain before a long archive begins. Uploads use the Apple
account signed into the distribution Xcode, while the generated What to Test
text is copied into App Store Connect manually. If Xcode's command-line process
cannot access that account, the archive remains reusable and
`scripts/testflight-release.sh organizer --bump none` opens it for upload in
Xcode Organizer without changing the project version or build number.

The helper deliberately uses separate toolchains. It archives with stable Xcode
at `/Applications/Xcode.app/Contents/Developer`, keeping App Store Connect's
embedded SDK validation on a supported release. It exports and uploads with
`/Applications/Xcode-beta.app/Contents/Developer`, preserving access to the
Apple account and distribution certificate configured in Xcode beta. Override
those paths for one release with `ACTUALIST_ARCHIVE_DEVELOPER_DIR` and
`ACTUALIST_DISTRIBUTION_DEVELOPER_DIR` respectively.

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

Liquid Glass lint runs within `scripts/check.sh`; no separate repeat is needed.
Inspect the affected screen and states, selecting relevant checks below:

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
