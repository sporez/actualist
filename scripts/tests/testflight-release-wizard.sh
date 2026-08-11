#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/actualist-testflight-wizard.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p \
  "$fixture_root/Actualist.xcodeproj" \
  "$fixture_root/config/testflight" \
  "$fixture_root/scripts" \
  "$fixture_root/fake-bin" \
  "$fixture_root/.release/testflight/0.8-6/Actualist-0.8-6.xcarchive"

cp "$repo_root/scripts/testflight-release.sh" "$fixture_root/scripts/testflight-release.sh"

printf '%s\n' \
  'MARKETING_VERSION = 0.8;' \
  'CURRENT_PROJECT_VERSION = 6;' \
  > "$fixture_root/Actualist.xcodeproj/project.pbxproj"
printf '%s\n' 'Test the current beta.' > "$fixture_root/config/testflight/what-to-test.txt"
printf '%s\n' '.release/' 'fake-bin/' > "$fixture_root/.gitignore"

git -C "$fixture_root" init -q
git -C "$fixture_root" add Actualist.xcodeproj config scripts .gitignore
git -C "$fixture_root" \
  -c user.name='Actualist Tests' \
  -c user.email='actualist-tests@example.invalid' \
  commit -qm 'test fixture' \
  -m 'TestFlight-Note: Do not carry forward build four.'

fixture_commit() {
  local subject="$1"
  local note="$2"
  printf '%s\n' "$subject" >> "$fixture_root/history.txt"
  git -C "$fixture_root" add history.txt
  git -C "$fixture_root" \
    -c user.name='Actualist Tests' \
    -c user.email='actualist-tests@example.invalid' \
    commit -qm "$subject" -m "TestFlight-Note: $note"
}

capture_wizard_until_first_prompt() {
  local output
  output="$(
    cd "$fixture_root"
    TESTFLIGHT_RELEASE_SELECTION_ONLY=1 \
      bash scripts/testflight-release.sh wizard </dev/null 2>&1
  )"
  printf '%s' "$output"
}

untagged_output="$(capture_wizard_until_first_prompt)"
grep -Fq 'Resume prepared release 0.8 (6)?' <<< "$untagged_output" || {
  echo "expected an untagged archive to remain resumable" >&2
  exit 1
}

git -C "$fixture_root" tag testflight/v0.8-b4
fixture_commit 'build five' 'Verify behavior introduced in build five.'
oversized_note="Oversized old note $(awk 'BEGIN { for (i = 0; i < 4500; i++) printf "x" }')"
fixture_commit 'oversized build five note' "$oversized_note"
git -C "$fixture_root" tag testflight/v0.8-b5
fixture_commit 'build six' 'Verify behavior introduced in build six.'
git -C "$fixture_root" tag testflight/v0.8-b6
fixture_commit 'build seven' 'Verify behavior introduced in build seven.'

tagged_output="$(capture_wizard_until_first_prompt)"
grep -Fq 'Completed release 0.8 (6) is already tagged.' <<< "$tagged_output" || {
  echo "expected the completed release to be recognized" >&2
  exit 1
}
grep -Fq '1) Build number: 0.8 (7)' <<< "$tagged_output" || {
  echo "expected the next release choice to default to build 7" >&2
  exit 1
}
if grep -Fq 'Resume prepared release 0.8 (6)?' <<< "$tagged_output"; then
  echo "did not expect a tagged release to be offered for resume" >&2
  exit 1
fi

(cd "$fixture_root" && bash scripts/testflight-release.sh notes --bump build >/dev/null)
what_to_test="$fixture_root/.release/testflight/0.8-7/what-to-test.txt"

grep -Fq 'Focus for this build:' "$what_to_test" || {
  echo "expected a current-build focus section" >&2
  exit 1
}
grep -Fq -- '- Verify behavior introduced in build seven.' "$what_to_test" || {
  echo "expected build seven notes" >&2
  exit 1
}
grep -Fq 'Carry-forward from 0.8 (6):' "$what_to_test" || {
  echo "expected a build six carry-forward section" >&2
  exit 1
}
grep -Fq -- '- Verify behavior introduced in build six.' "$what_to_test" || {
  echo "expected build six notes" >&2
  exit 1
}
grep -Fq 'Carry-forward from 0.8 (5):' "$what_to_test" || {
  echo "expected a build five carry-forward section" >&2
  exit 1
}
grep -Fq -- '- Verify behavior introduced in build five.' "$what_to_test" || {
  echo "expected build five notes" >&2
  exit 1
}
if grep -Fq 'Do not carry forward build four.' "$what_to_test"; then
  echo "did not expect notes older than the three-build window" >&2
  exit 1
fi
if grep -Fq 'Oversized old note' "$what_to_test"; then
  echo "did not expect an older note that exceeds the character budget" >&2
  exit 1
fi
if [[ -e "$fixture_root/.release/testflight/0.8-7/release-notes.md" ]]; then
  echo "did not expect a redundant release-notes.md artifact" >&2
  exit 1
fi
if [[ "$(wc -m < "$what_to_test" | tr -d '[:space:]')" -gt 4000 ]]; then
  echo "expected What to Test to stay within App Store Connect's limit" >&2
  exit 1
fi

github_output="$(cd "$fixture_root" && bash scripts/testflight-release.sh github-release --build 7 --dry-run 2>&1)"
grep -Fq -- '--notes-file .release/testflight/0.8-7/what-to-test.txt' <<< "$github_output" || {
  echo "expected GitHub prereleases to use the reviewed What to Test file" >&2
  exit 1
}

archive_toolchain_output="$(
  cd "$fixture_root"
  bash scripts/testflight-release.sh archive --build 7 --skip-tests --allow-dirty --dry-run 2>&1
)"
grep -Fq 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild' \
  <<< "$archive_toolchain_output" || {
  echo "expected archives to use stable Xcode" >&2
  exit 1
}

distribution_toolchain_output="$(
  cd "$fixture_root"
  bash scripts/testflight-release.sh upload --bump none --skip-tests --allow-dirty --dry-run 2>&1
)"
grep -Fq 'DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild' \
  <<< "$distribution_toolchain_output" || {
  echo "expected distribution to use the signed-in Xcode beta" >&2
  exit 1
}

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "error: exportArchive Failed to Use Accounts"' \
  'echo "error: No signing certificate \"iOS Distribution\" found"' \
  'exit 70' \
  > "$fixture_root/fake-bin/xcodebuild"
chmod +x "$fixture_root/fake-bin/xcodebuild"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "  1) 1111111111111111111111111111111111111111 \"Apple Development: Test User (TESTTEAM)\""' \
  'echo "     1 valid identities found"' \
  > "$fixture_root/fake-bin/security"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "codesign: errSecInternalComponent" >&2' \
  'exit 1' \
  > "$fixture_root/fake-bin/codesign"
chmod +x "$fixture_root/fake-bin/security" "$fixture_root/fake-bin/codesign"

if signing_failure_output="$(
  cd "$fixture_root"
  PATH="$fixture_root/fake-bin:$PATH" \
    bash scripts/testflight-release.sh doctor --bump none 2>&1
)"; then
  echo "expected an inaccessible signing private key to fail doctor" >&2
  exit 1
fi
grep -Fq 'Archive signing is unavailable from this shell.' <<< "$signing_failure_output" || {
  echo "expected signing preflight to explain the inaccessible private key" >&2
  exit 1
}
grep -Fq 'security unlock-keychain' <<< "$signing_failure_output" || {
  echo "expected signing preflight to provide keychain recovery" >&2
  exit 1
}

if missing_metadata_auth_output="$(
  cd "$fixture_root"
  PATH="$fixture_root/fake-bin:$PATH" \
    bash scripts/testflight-release.sh upload --bump none --skip-tests \
      --upload-test-metadata --allow-dirty 2>&1
)"; then
  echo "expected metadata upload without an API key to fail preflight" >&2
  exit 1
fi
grep -Fq -- '--upload-test-metadata requires ASC_API_KEY_PATH' <<< "$missing_metadata_auth_output" || {
  echo "expected missing metadata auth to fail before export" >&2
  exit 1
}
if grep -Fq 'Failed to Use Accounts' <<< "$missing_metadata_auth_output"; then
  echo "did not expect xcodebuild to run before metadata auth preflight" >&2
  exit 1
fi

if auth_failure_output="$(
  cd "$fixture_root"
  PATH="$fixture_root/fake-bin:$PATH" \
    bash scripts/testflight-release.sh upload --bump none --skip-tests --allow-dirty 2>&1
)"; then
  echo "expected an App Store Connect account failure" >&2
  exit 1
fi
grep -Fq 'The archive is intact at:' <<< "$auth_failure_output" || {
  echo "expected upload failure to preserve and identify the archive" >&2
  exit 1
}
grep -Fq 'Apple account is signed into the distribution Xcode' <<< "$auth_failure_output" || {
  echo "expected upload failure to explain Xcode account recovery" >&2
  exit 1
}
grep -Fq 'organizer --bump none' <<< "$auth_failure_output" || {
  echo "expected upload failure to offer Organizer recovery" >&2
  exit 1
}

organizer_output="$(
  cd "$fixture_root"
  bash scripts/testflight-release.sh organizer --bump none --dry-run 2>&1
)"
grep -Fq -- 'open .release/testflight/0.8-6/Actualist-0.8-6.xcarchive' <<< "$organizer_output" || {
  echo "expected Organizer recovery to reuse the existing archive" >&2
  exit 1
}

perl -0pi -e 's/CURRENT_PROJECT_VERSION = 6;/CURRENT_PROJECT_VERSION = 7;/g' \
  "$fixture_root/Actualist.xcodeproj/project.pbxproj"
git -C "$fixture_root" add Actualist.xcodeproj/project.pbxproj
git -C "$fixture_root" \
  -c user.name='Actualist Tests' \
  -c user.email='actualist-tests@example.invalid' \
  commit -qm 'chore: prepare TestFlight 0.8 (7)'

prepared_without_archive_output="$(capture_wizard_until_first_prompt)"
grep -Fq 'Resume prepared release 0.8 (7)?' <<< "$prepared_without_archive_output" || {
  echo "expected a prepared build to remain resumable after archive failure" >&2
  exit 1
}
if grep -Fq '1) Build number: 0.8 (8)' <<< "$prepared_without_archive_output"; then
  echo "did not expect archive failure recovery to advance to build eight" >&2
  exit 1
fi

echo "TestFlight release wizard and notes tests passed."
