#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/actualist-testflight-wizard.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p \
  "$fixture_root/Actualist.xcodeproj" \
  "$fixture_root/config/testflight" \
  "$fixture_root/scripts" \
  "$fixture_root/.release/testflight/0.8-6/Actualist-0.8-6.xcarchive"

cp "$repo_root/scripts/testflight-release.sh" "$fixture_root/scripts/testflight-release.sh"

printf '%s\n' \
  'MARKETING_VERSION = 0.8;' \
  'CURRENT_PROJECT_VERSION = 6;' \
  > "$fixture_root/Actualist.xcodeproj/project.pbxproj"
printf '%s\n' 'Test the current beta.' > "$fixture_root/config/testflight/what-to-test.txt"
printf '%s\n' '.release/' > "$fixture_root/.gitignore"

git -C "$fixture_root" init -q
git -C "$fixture_root" add Actualist.xcodeproj config scripts .gitignore
git -C "$fixture_root" \
  -c user.name='Actualist Tests' \
  -c user.email='actualist-tests@example.invalid' \
  commit -qm 'test fixture'

capture_wizard_until_first_prompt() {
  local output
  if output="$(cd "$fixture_root" && bash scripts/testflight-release.sh wizard </dev/null 2>&1)"; then
    echo "expected the wizard to stop when test input reached EOF" >&2
    return 1
  fi
  printf '%s' "$output"
}

untagged_output="$(capture_wizard_until_first_prompt)"
grep -Fq 'Resume prepared release 0.8 (6)?' <<< "$untagged_output" || {
  echo "expected an untagged archive to remain resumable" >&2
  exit 1
}

git -C "$fixture_root" tag testflight/v0.8-b6

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

echo "TestFlight release wizard selection tests passed."
