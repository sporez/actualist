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

Upload to App Store Connect:

```sh
scripts/testflight-release.sh upload
```

The upload uses `xcodebuild -exportArchive` with:

- `method = app-store-connect`
- `destination = upload`
- automatic signing
- team `BJNL8CJWW6`

After App Store Connect accepts the build, tag the release:

```sh
scripts/testflight-release.sh tag
```

The tag format is `testflight/v<marketing-version>-b<build-number>`. Future
release notes are generated from the latest tag to `HEAD`. Tagging requires a
clean worktree so the tag points at the committed release version.

Optionally push that tag and create a GitHub prerelease:

```sh
scripts/testflight-release.sh github-release
```

This pushes the current TestFlight tag to `origin`, then uses the GitHub CLI
with `--verify-tag`, `--prerelease`, and the generated `release-notes.md`. It
requires `gh` to be installed and authenticated. Set `GITHUB_REMOTE` to push to
a remote other than `origin`; set `GH_REPO=owner/repository` when `gh` should
target a repository other than the one inferred from the checkout.

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
