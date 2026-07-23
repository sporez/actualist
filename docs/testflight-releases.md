# TestFlight Release Workflow

Use `scripts/testflight-release.sh` to prepare and upload Actualist builds for
TestFlight without adding Fastlane or another release dependency. Run it with no
arguments for the interactive menu.

## Recommended Flow

Start the menu:

```sh
scripts/testflight-release.sh
```

The menu covers the normal paths:

- Show the next release plan.
- Prepare a build-number, patch, minor, major, or custom version bump.
- Generate release notes and TestFlight "What to Test" text.
- Archive, export, or upload the current version.
- Prepare and upload in one run.
- Tag the committed release.
- Optionally publish the tag and generated notes as a GitHub prerelease.

Tagging still requires a clean worktree so the tag points at the committed
release version.

## Command Line Flow

The same workflow is available with explicit commands for automation or repeat
use.

Preview the next release:

```sh
scripts/testflight-release.sh plan
```

Prepare the version bump and release notes:

```sh
scripts/testflight-release.sh prepare
```

This increments `CURRENT_PROJECT_VERSION`, keeps `MARKETING_VERSION` unchanged,
and writes generated files under `.release/testflight/<version>-<build>/`.

Commit the version bump before tagging the release:

```sh
git add Actualist.xcodeproj/project.pbxproj
git commit -m "chore: prepare TestFlight <version> (<build>)"
```

You may archive, export, or upload before committing when the only worktree
changes are the version fields written by `prepare`. The helper recognizes that
prepared state automatically. Any unrelated change still requires a commit,
stash, or explicit `--allow-dirty`. Tagging and GitHub publication always
require a clean worktree.

Upload to App Store Connect:

```sh
scripts/testflight-release.sh upload
```

The upload uses `xcodebuild -exportArchive` with:

- `method = app-store-connect`
- `destination = upload`
- automatic signing
- team `BJNL8CJWW6`

The menu optionally asks whether to upload the generated `what-to-test.txt`
after the build finishes processing. The equivalent command-line flow is:

```sh
scripts/testflight-release.sh upload --upload-test-metadata
```

To upload or replace What to Test for a build that is already in TestFlight:

```sh
scripts/testflight-release.sh metadata
```

Metadata upload uses the App Store Connect API, waits for the matching marketing
version and build number to become valid, then creates or updates the `en-US`
beta build localization. Set `TESTFLIGHT_LOCALE` or pass
`--testflight-locale <locale>` to use another localization. The metadata step
requires the API key variables documented below; a signed-in Xcode account by
itself can upload the binary but cannot authenticate this API step.

After App Store Connect accepts the build, tag the release:

```sh
scripts/testflight-release.sh tag
```

The tag format is `testflight/v<marketing-version>-b<build-number>`. Future
release notes are generated from the latest tag to `HEAD`. Tagging requires a
clean worktree so the tag points at the committed release version.

Optionally push that tag and create a GitHub prerelease with the exported IPA
attached as a downloadable release asset:

```sh
scripts/testflight-release.sh github-release
```

This pushes the current TestFlight tag to `origin`, then uses the GitHub CLI
with `--verify-tag`, `--prerelease`, the generated `release-notes.md`, and the
IPA under `.release/testflight/<version>-<build>/export/`. If the IPA does not
exist yet, the helper exports it from the archive. Running the command again
updates the existing prerelease and replaces an asset with the same filename.
It requires `gh` to be installed and authenticated. Set `GITHUB_REMOTE` to push
to a remote other than `origin`; set `GH_REPO=owner/repository` when `gh`
should target a repository other than the one inferred from the checkout.
The App Store Connect IPA is downloadable for tools that re-sign sideloaded
apps; it is not a universal direct-install package for unsigned devices.

The tagging command can perform the same optional follow-on step:

```sh
scripts/testflight-release.sh tag --github-release
```

GitHub release creation remains separate from `all` because the prepared
version bump must be committed before its tag and release are published.

## One Command Upload

For a full prepare-and-upload run from the command line:

```sh
scripts/testflight-release.sh all
```

After `all` succeeds, commit the version bump and run
`scripts/testflight-release.sh tag`.

## Versioning

Default behavior for `plan`, `prepare`, and `all` is `--bump build`.

Examples:

```sh
scripts/testflight-release.sh prepare --bump patch
scripts/testflight-release.sh prepare --version 0.9 --build 1
scripts/testflight-release.sh prepare --build 42
```

`archive`, `export`, and `upload` use the current project version by default.
Pass a version or bump option only when you want those commands to mutate the
project before building.

## Release Notes

The script writes:

- `release-notes.md`: full generated notes and git log.
- `what-to-test.txt`: shorter TestFlight text for App Store Connect.
- `exportOptions-export.plist`: local IPA export options.
- `exportOptions-upload.plist`: App Store Connect upload options.

If no prior TestFlight tag exists, notes include the full history up to `HEAD`.
Use `--since <ref>` to override the range.

## App Store Connect Authentication

Uploads can use the Apple account already signed in to Xcode. Alternatively set
all three App Store Connect API key variables before running `upload` or `all`:

```sh
export ASC_API_KEY_PATH=/path/to/AuthKey_ABC123.p8
export ASC_API_KEY_ID=ABC123
export ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000
```

The script also accepts the longer `APP_STORE_CONNECT_API_KEY_PATH`,
`APP_STORE_CONNECT_API_KEY_ID`, and `APP_STORE_CONNECT_API_ISSUER_ID` names.

`ASC_BUILD_WAIT_SECONDS` controls how long metadata upload waits for App Store
Connect processing (default: 1200 seconds), and `ASC_BUILD_POLL_SECONDS`
controls the polling interval (default: 20 seconds).

## TestFlight Screenshots

Screenshots are not required to submit a build for TestFlight testing. TestFlight
can optionally show screenshots and the app category from the latest approved
App Store version in its invitation experience. A first build has no approved
App Store screenshots to reuse, which does not block internal or external beta
testing.

App Store product-page screenshots are separate Distribution metadata and are
required later for the public App Store submission. Prepare those before
submitting the App Store version for review, not before starting TestFlight.
