#!/usr/bin/env bash
set -euo pipefail

PROJECT="Actualist.xcodeproj"
SCHEME="Actualist"
CONFIGURATION="Release"
TEAM_ID="BJNL8CJWW6"
TAG_PREFIX="testflight/v"
RELEASE_ROOT=".release/testflight"
WHAT_TO_TEST_TEMPLATE="config/testflight/what-to-test.txt"
DERIVED_DATA_PATH=".derivedData/testflight"
TEST_DESTINATION="${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
GITHUB_REMOTE="${GITHUB_REMOTE:-origin}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sporez.actualist}"
TESTFLIGHT_LOCALE="${TESTFLIGHT_LOCALE:-en-US}"
ASC_BUILD_WAIT_SECONDS="${ASC_BUILD_WAIT_SECONDS:-1200}"
ASC_BUILD_POLL_SECONDS="${ASC_BUILD_POLL_SECONDS:-20}"

if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
  command="wizard"
else
  command="plan"
fi

if [[ $# -gt 0 && "$1" != --* ]]; then
  command="$1"
  shift
fi

version_override=""
build_override=""
bump=""
since_ref=""
dry_run=0
skip_tests=0
allow_dirty=0
tag_after_upload=0
github_release_after_tag=0
upload_test_metadata=0
internal_only=0
preserve_test_notes=0
notes_limit=80

usage() {
  cat <<'USAGE'
Usage:
  scripts/testflight-release.sh
  scripts/testflight-release.sh wizard
  scripts/testflight-release.sh plan [options]
  scripts/testflight-release.sh notes [options]
  scripts/testflight-release.sh prepare [options]
  scripts/testflight-release.sh commit [options]
  scripts/testflight-release.sh archive [options]
  scripts/testflight-release.sh export [options]
  scripts/testflight-release.sh upload [options]
  scripts/testflight-release.sh all [options]
  scripts/testflight-release.sh metadata [options]
  scripts/testflight-release.sh tag [options]
  scripts/testflight-release.sh github-release [options]

Commands:
  wizard     Walk through one release from preflight to GitHub publication.
  menu       Legacy alias for wizard.
  plan       Show the next TestFlight release without changing files.
  notes      Generate consumer-facing What to Test and GitHub release notes.
  prepare    Bump version/build if needed and write release notes/export options.
  commit     Commit a prepared version/build change after validating its scope.
  archive    Run tests, then create an App Store Connect archive.
  export     Archive if needed, then export a local App Store Connect IPA.
  upload     Archive if needed, then upload to App Store Connect.
  all        Prepare, archive, and upload; with --tag, commit and tag the release.
  metadata   Upload What to Test for the current TestFlight build.
  tag        Create the TestFlight git tag for the selected version/build.
  github-release
             Push the current TestFlight tag, create or update a GitHub
             prerelease, and attach its exported IPA.

Options:
  --version X.Y[.Z]       Set MARKETING_VERSION.
  --build N              Set CURRENT_PROJECT_VERSION.
  --bump build|patch|minor|major
                           Default for plan/prepare/all is build.
                           Archive/export/upload use the current project version
                           unless a bump/version/build option is provided.
  --since REF            Generate notes from REF..HEAD instead of last TestFlight tag.
  --skip-tests           Do not run the simulator unit tests before archiving.
  --allow-dirty          Allow starting from a dirty git worktree.
  --internal-only        Mark uploaded build as TestFlight internal testing only.
  --upload-test-metadata
                         After upload, wait for processing and upload What to Test.
  --testflight-locale L  Locale for What to Test. Default: en-US.
  --tag                  With upload/all, safely commit a prepared version bump
                         when needed, then tag after a successful upload.
  --github-release       With tag/upload/all, publish a GitHub prerelease after
                         confirming the current TestFlight tag exists.
  --dry-run              Print commands and intended edits without executing them.
  --keep-test-notes      Preserve an already-reviewed what-to-test.txt when
                         regenerating the other release files.
  --notes-limit N        Max TestFlight-Note trailers included. Default: 80.

App Store Connect auth:
  Upload can use the signed-in Xcode account, or these env vars:
    ASC_API_KEY_PATH / APP_STORE_CONNECT_API_KEY_PATH
    ASC_API_KEY_ID / APP_STORE_CONNECT_API_KEY_ID
    ASC_API_ISSUER_ID / APP_STORE_CONNECT_API_ISSUER_ID
  Metadata upload requires all three API key variables.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version_override="${2:-}"
      [[ -n "$version_override" ]] || die "--version requires a value"
      shift 2
      ;;
    --build)
      build_override="${2:-}"
      [[ -n "$build_override" ]] || die "--build requires a value"
      shift 2
      ;;
    --bump)
      bump="${2:-}"
      [[ -n "$bump" ]] || die "--bump requires a value"
      shift 2
      ;;
    --since)
      since_ref="${2:-}"
      [[ -n "$since_ref" ]] || die "--since requires a value"
      shift 2
      ;;
    --skip-tests)
      skip_tests=1
      shift
      ;;
    --allow-dirty)
      allow_dirty=1
      shift
      ;;
    --internal-only)
      internal_only=1
      shift
      ;;
    --upload-test-metadata)
      upload_test_metadata=1
      shift
      ;;
    --testflight-locale)
      TESTFLIGHT_LOCALE="${2:-}"
      [[ -n "$TESTFLIGHT_LOCALE" ]] || die "--testflight-locale requires a value"
      shift 2
      ;;
    --tag)
      tag_after_upload=1
      shift
      ;;
    --github-release)
      github_release_after_tag=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --keep-test-notes)
      preserve_test_notes=1
      shift
      ;;
    --notes-limit)
      notes_limit="${2:-}"
      [[ -n "$notes_limit" ]] || die "--notes-limit requires a value"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

case "$command" in
  wizard|menu|plan|notes|prepare|commit|archive|export|upload|all|metadata|tag|github-release) ;;
  *)
    usage
    die "unknown command: $command"
    ;;
esac

if [[ "$github_release_after_tag" -eq 1 ]]; then
  case "$command" in
    upload|all|tag) ;;
    *) die "--github-release is only valid with upload, all, or tag" ;;
  esac
fi

if [[ "$command" == "all" && "$github_release_after_tag" -eq 1 && "$tag_after_upload" -ne 1 ]]; then
  die "--github-release with all requires --tag"
fi

if [[ "$upload_test_metadata" -eq 1 ]]; then
  case "$command" in
    upload|all) ;;
    *) die "--upload-test-metadata is only valid with upload or all" ;;
  esac
fi

[[ -d "$PROJECT" ]] || die "run this from the Actualist repository root"
[[ -f "$PROJECT/project.pbxproj" ]] || die "missing $PROJECT/project.pbxproj"
[[ -f "$WHAT_TO_TEST_TEMPLATE" ]] || die "missing $WHAT_TO_TEST_TEMPLATE"

if [[ -z "$bump" ]]; then
  case "$command" in
    plan|notes|prepare|all)
      bump="build"
      ;;
    *)
      bump="none"
      ;;
  esac
fi

case "$bump" in
  none|build|patch|minor|major) ;;
  *) die "--bump must be one of build, patch, minor, major" ;;
esac

[[ "$build_override" =~ ^[0-9]+$ || -z "$build_override" ]] || die "--build must be an integer"
[[ "$notes_limit" =~ ^[0-9]+$ ]] || die "--notes-limit must be an integer"
[[ "$ASC_BUILD_WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "ASC_BUILD_WAIT_SECONDS must be an integer"
[[ "$ASC_BUILD_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "ASC_BUILD_POLL_SECONDS must be a positive integer"

current_version="$(awk -F'= ' '/MARKETING_VERSION =/ { gsub(/[ ;]/, "", $2); print $2; exit }' "$PROJECT/project.pbxproj")"
current_build="$(awk -F'= ' '/CURRENT_PROJECT_VERSION =/ { gsub(/[ ;]/, "", $2); print $2; exit }' "$PROJECT/project.pbxproj")"

[[ -n "$current_version" ]] || die "could not read MARKETING_VERSION"
[[ "$current_build" =~ ^[0-9]+$ ]] || die "could not read numeric CURRENT_PROJECT_VERSION"

split_version() {
  local version="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$version"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || die "version must be numeric dot-separated"
  echo "$major $minor $patch"
}

next_version="$current_version"
next_build="$current_build"

case "$bump" in
  build)
    next_build="$((current_build + 1))"
    ;;
  patch|minor|major)
    read -r major minor patch <<< "$(split_version "$current_version")"
    case "$bump" in
      patch) patch="$((patch + 1))" ;;
      minor) minor="$((minor + 1))"; patch=0 ;;
      major) major="$((major + 1))"; minor=0; patch=0 ;;
    esac
    next_version="$major.$minor.$patch"
    next_build=1
    ;;
esac

if [[ -n "$version_override" ]]; then
  split_version "$version_override" >/dev/null
  next_version="$version_override"
  if [[ -z "$build_override" && "$next_version" != "$current_version" ]]; then
    next_build=1
  fi
fi

if [[ -n "$build_override" ]]; then
  next_build="$build_override"
fi

release_id="${next_version}-${next_build}"
release_dir="$RELEASE_ROOT/$release_id"
archive_path="$release_dir/Actualist-${release_id}.xcarchive"
export_path="$release_dir/export"
notes_markdown="$release_dir/release-notes.md"
what_to_test="$release_dir/what-to-test.txt"
export_options_export="$release_dir/exportOptions-export.plist"
export_options_upload="$release_dir/exportOptions-upload.plist"
tag_name="${TAG_PREFIX}${next_version}-b${next_build}"

latest_testflight_tag() {
  git for-each-ref --sort=-creatordate --format='%(refname:short)' "refs/tags/${TAG_PREFIX}*" | head -n 1
}

last_tag="$(latest_testflight_tag)"
if [[ -n "$since_ref" ]]; then
  note_base="$since_ref"
elif [[ -n "$last_tag" ]]; then
  note_base="$last_tag"
else
  note_base=""
fi

if [[ -n "$note_base" ]]; then
  git rev-parse --verify "${note_base}^{commit}" >/dev/null 2>&1 || die "could not resolve --since ref/tag: $note_base"
  note_range="${note_base}..HEAD"
else
  note_range="HEAD"
fi

require_clean_worktree() {
  if [[ "$allow_dirty" -eq 1 ]]; then
    return
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    die "git worktree is dirty; commit/stash first or pass --allow-dirty"
  fi
}

worktree_has_only_release_version_changes() {
  local project_file="$PROJECT/project.pbxproj"
  local status_line path
  local status
  status="$(git status --porcelain)"
  [[ -n "$status" ]] || return 1

  while IFS= read -r status_line; do
    path="${status_line:3}"
    [[ "$path" == "$project_file" ]] || return 1
  done <<< "$status"

  git diff HEAD --unified=0 -- "$project_file" | awk '
    /^[+-]/ && !/^(---|\+\+\+)/ {
      line = substr($0, 2)
      if (line !~ /^[[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = [^;]+;$/) {
        invalid = 1
      }
      found = 1
    }
    END {
      exit (!found || invalid)
    }
  '
}

commit_release_version() {
  local commit_message="chore: prepare TestFlight ${next_version} (${next_build})"

  if [[ "$dry_run" -eq 1 ]] && will_mutate_version; then
    run git add -- "$PROJECT/project.pbxproj"
    run git commit -m "$commit_message" -- "$PROJECT/project.pbxproj"
    return
  fi

  if [[ -z "$(git status --porcelain)" ]]; then
    log "No prepared release version changes to commit"
    return
  fi

  worktree_has_only_release_version_changes || \
    die "refusing to commit: worktree contains changes beyond release version/build lines"

  log "Committing prepared release version ${next_version} (${next_build})"
  run git add -- "$PROJECT/project.pbxproj"
  run git commit -m "$commit_message" -- "$PROJECT/project.pbxproj"
}

require_build_worktree() {
  if [[ "$allow_dirty" -eq 1 || -z "$(git status --porcelain)" ]]; then
    return
  fi
  if worktree_has_only_release_version_changes; then
    log "Using prepared release version changes from $PROJECT/project.pbxproj"
    return
  fi
  die "git worktree has changes beyond the prepared release version; commit/stash first or pass --allow-dirty"
}

will_mutate_version() {
  [[ "$next_version" != "$current_version" || "$next_build" != "$current_build" ]]
}

write_export_options() {
  local path="$1"
  local destination="$2"
  local internal_value="false"
  if [[ "$internal_only" -eq 1 ]]; then
    internal_value="true"
  fi

  mkdir -p "$release_dir"
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>${destination}</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>testFlightInternalTestingOnly</key>
  <${internal_value}/>
</dict>
</plist>
PLIST
}

append_section() {
  local title="$1"
  local file="$2"
  local output="$3"
  if [[ -s "$file" ]]; then
    {
      echo
      echo "### $title"
      cat "$file"
    } >> "$output"
  fi
}

what_to_test_character_count() {
  wc -m < "$1" | tr -d '[:space:]'
}

validate_what_to_test() {
  local path="$1"
  local character_count
  character_count="$(what_to_test_character_count "$path")"
  [[ "$character_count" -le 4000 ]] \
    || die "What to Test is $character_count characters; App Store Connect allows 4000"
}

write_what_to_test() {
  local focus_file="$1"
  local rendered_template="${focus_file}.template"

  awk -v version="$next_version" -v build="$next_build" '
    {
      gsub(/\{\{VERSION\}\}/, version)
      gsub(/\{\{BUILD\}\}/, build)
      print
    }
  ' "$WHAT_TO_TEST_TEMPLATE" > "$rendered_template"

  if [[ -s "$focus_file" ]]; then
    {
      sed -n '1p' "$rendered_template"
      echo
      echo "Focus for this build:"
      sed 's/^/- /' "$focus_file"
      sed -n '2,$p' "$rendered_template"
    } > "$what_to_test"
  else
    cp "$rendered_template" "$what_to_test"
  fi

  validate_what_to_test "$what_to_test"
}

sync_release_notes_what_to_test() {
  local release_notes_path="${1:-$notes_markdown}"
  local what_to_test_path="${2:-$what_to_test}"
  [[ -f "$release_notes_path" ]] || die "release notes not found: $release_notes_path"
  [[ -f "$what_to_test_path" ]] || die "What to Test file not found: $what_to_test_path"
  grep -Fxq "## What To Test" "$release_notes_path" \
    || die "What to Test section not found in $release_notes_path"
  grep -Fxq "## Changes Since Previous Build" "$release_notes_path" \
    || die "changes section not found in $release_notes_path"

  local tmp_file
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/actualist-release-notes-sync.XXXXXX")"
  if awk -v replacement="$what_to_test_path" '
    $0 == "## What To Test" {
      print
      print ""
      while ((getline line < replacement) > 0) {
        print line
      }
      close(replacement)
      replacing = 1
      next
    }
    replacing && $0 == "## Changes Since Previous Build" {
      print ""
      print
      replacing = 0
      next
    }
    !replacing { print }
  ' "$release_notes_path" > "$tmp_file"; then
    mv "$tmp_file" "$release_notes_path"
  else
    rm -f "$tmp_file"
    die "could not update What to Test in $release_notes_path"
  fi
}

generate_notes() {
  if [[ "$dry_run" -eq 1 ]]; then
    echo "+ write $notes_markdown"
    echo "+ write $what_to_test"
    echo "+ write $export_options_export"
    echo "+ write $export_options_upload"
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/actualist-release-notes.XXXXXX")"
  trap 'rm -rf "$tmp_dir"; trap - RETURN' RETURN

  local features="$tmp_dir/features"
  local fixes="$tmp_dir/fixes"
  local polish="$tmp_dir/polish"
  local docs_tests="$tmp_dir/docs-tests"
  local other="$tmp_dir/other"
  local full_log="$tmp_dir/full-log"
  local focus="$tmp_dir/focus"
  : > "$features"
  : > "$fixes"
  : > "$polish"
  : > "$docs_tests"
  : > "$other"
  : > "$full_log"
  : > "$focus"

  local has_commits=0
  while IFS=$'\t' read -r hash subject; do
    [[ -n "${hash:-}" ]] || continue
    has_commits=1
    clean_subject="$(printf '%s' "$subject" | sed -E 's/^([A-Za-z]+)(\([^)]+\))?!?:[[:space:]]*//')"
    printf -- "- %s (%s)\n" "$clean_subject" "$hash" >> "$full_log"
    case "$subject" in
      feat:*|feat\(*)
        printf -- "- %s\n" "$clean_subject" >> "$features"
        ;;
      fix:*|fix\(*)
        printf -- "- %s\n" "$clean_subject" >> "$fixes"
        ;;
      ui:*|ui\(*|design:*|design\(*|refactor:*|refactor\(*|perf:*|perf\(*)
        printf -- "- %s\n" "$clean_subject" >> "$polish"
        ;;
      docs:*|docs\(*|test:*|test\(*|tests:*|tests\(*|chore:*|chore\(*)
        printf -- "- %s\n" "$clean_subject" >> "$docs_tests"
        ;;
      *)
        printf -- "- %s\n" "$clean_subject" >> "$other"
        ;;
    esac
  done < <(git log --no-merges --reverse --format='%h%x09%s' "$note_range")

  git log --no-merges --reverse --format='%B' "$note_range" | awk \
    -v limit="$notes_limit" '
      match($0, /^[[:space:]]*TestFlight-Note:[[:space:]]*/) {
        note = substr($0, RLENGTH + 1)
        sub(/[[:space:]]+$/, "", note)
        if (note != "" && !seen[note]++ && count < limit) {
          print note
          count++
        }
      }
    ' > "$focus"

  mkdir -p "$release_dir"

  if [[ "$preserve_test_notes" -eq 1 && -f "$what_to_test" ]]; then
    log "Keeping reviewed $what_to_test"
    validate_what_to_test "$what_to_test"
  else
    write_what_to_test "$focus"
  fi

  {
    echo "# TestFlight ${next_version} (${next_build})"
    echo
    echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- Current project version: ${current_version} (${current_build})"
    echo "- Release version: ${next_version} (${next_build})"
    echo "- Previous TestFlight tag: ${last_tag:-none}"
    echo "- Change range: ${note_range}"
    echo "- Tag to create: ${tag_name}"
    echo
    echo "## What To Test"
    echo
    cat "$what_to_test"
    echo
    echo "## Changes Since Previous Build"
  } > "$notes_markdown"

  if [[ "$has_commits" -eq 0 ]]; then
    echo "- Internal build with no committed changes in ${note_range}." >> "$notes_markdown"
  else
    append_section "Features" "$features" "$notes_markdown"
    append_section "Fixes" "$fixes" "$notes_markdown"
    append_section "Polish And Performance" "$polish" "$notes_markdown"
    append_section "Docs, Tests, And Maintenance" "$docs_tests" "$notes_markdown"
    append_section "Other Changes" "$other" "$notes_markdown"
    {
      echo
      echo "## Full Git Log"
      cat "$full_log"
    } >> "$notes_markdown"
  fi

  write_export_options "$export_options_export" "export"
  write_export_options "$export_options_upload" "upload"
}

update_project_version() {
  if [[ "$next_version" == "$current_version" && "$next_build" == "$current_build" ]]; then
    log "Project already at ${next_version} (${next_build})"
    return
  fi

  log "Updating project version ${current_version} (${current_build}) -> ${next_version} (${next_build})"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "+ update $PROJECT/project.pbxproj MARKETING_VERSION=${next_version} CURRENT_PROJECT_VERSION=${next_build}"
  else
    perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${next_version};/g; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = ${next_build};/g;" "$PROJECT/project.pbxproj"
  fi
}

run_tests() {
  if [[ "$skip_tests" -eq 1 ]]; then
    log "Skipping tests"
    return
  fi
  log "Running unit tests"
  run xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$TEST_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    test
}

archive_app() {
  if [[ -d "$archive_path" ]]; then
    log "Using existing archive: $archive_path"
    return
  fi
  run_tests
  log "Archiving ${next_version} (${next_build})"
  run xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -archivePath "$archive_path" \
    -allowProvisioningUpdates \
    archive
}

auth_args=()
asc_key_path="${ASC_API_KEY_PATH:-${APP_STORE_CONNECT_API_KEY_PATH:-}}"
asc_key_id="${ASC_API_KEY_ID:-${APP_STORE_CONNECT_API_KEY_ID:-}}"
asc_issuer_id="${ASC_API_ISSUER_ID:-${APP_STORE_CONNECT_API_ISSUER_ID:-}}"
if [[ -n "$asc_key_path" || -n "$asc_key_id" || -n "$asc_issuer_id" ]]; then
  [[ -n "$asc_key_path" && -n "$asc_key_id" && -n "$asc_issuer_id" ]] || die "set all App Store Connect API key env vars, or none"
  auth_args=(-authenticationKeyPath "$asc_key_path" -authenticationKeyID "$asc_key_id" -authenticationKeyIssuerID "$asc_issuer_id")
fi

require_asc_api_auth() {
  command -v xcrun >/dev/null 2>&1 || die "xcrun is required for App Store Connect API authentication"
  command -v curl >/dev/null 2>&1 || die "curl is required for App Store Connect metadata upload"
  command -v jq >/dev/null 2>&1 || die "jq is required for App Store Connect metadata upload"
  [[ -n "$asc_key_path" && -n "$asc_key_id" && -n "$asc_issuer_id" ]] \
    || die "metadata upload requires ASC_API_KEY_PATH, ASC_API_KEY_ID, and ASC_API_ISSUER_ID"
  [[ -f "$asc_key_path" ]] || die "App Store Connect API key not found: $asc_key_path"
}

asc_api_token() {
  local token
  token="$(
    xcrun altool \
      --generate-jwt \
      --apiKey "$asc_key_id" \
      --apiIssuer "$asc_issuer_id" \
      --p8-file-path "$asc_key_path" \
      2>/dev/null
  )" || die "could not generate an App Store Connect API token"
  token="$(printf '%s\n' "$token" | awk 'NF { value = $0 } END { print value }')"
  [[ "$token" == *.*.* ]] || die "xcrun altool returned an invalid App Store Connect API token"
  printf '%s' "$token"
}

asc_api_request() {
  local method="$1"
  local url="$2"
  local payload="${3:-}"
  local token
  token="$(asc_api_token)"

  if [[ -n "$payload" ]]; then
    curl --globoff --fail-with-body --silent --show-error \
      --request "$method" \
      --header "Authorization: Bearer $token" \
      --header "Content-Type: application/json" \
      --data "$payload" \
      "$url"
  else
    curl --globoff --fail-with-body --silent --show-error \
      --request "$method" \
      --header "Authorization: Bearer $token" \
      "$url"
  fi
}

asc_app_id() {
  local response count app_id
  response="$(asc_api_request GET \
    "https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=$APP_BUNDLE_ID&limit=2")"
  count="$(printf '%s' "$response" | jq '.data | length')"
  [[ "$count" -eq 1 ]] || die "expected one App Store Connect app for $APP_BUNDLE_ID; found $count"
  app_id="$(printf '%s' "$response" | jq -r '.data[0].id')"
  [[ -n "$app_id" && "$app_id" != "null" ]] || die "App Store Connect app ID is missing"
  printf '%s' "$app_id"
}

asc_build_record() {
  local app_id="$1"
  local response
  response="$(asc_api_request GET \
    "https://api.appstoreconnect.apple.com/v1/builds?filter[app]=$app_id&filter[version]=$next_build&include=preReleaseVersion&sort=-uploadedDate&limit=20")"

  printf '%s' "$response" | jq -r \
    --arg marketing_version "$next_version" \
    --arg build_number "$next_build" '
      [.included[]?
        | select(
            .type == "preReleaseVersions"
            and .attributes.version == $marketing_version
          )
        | .id
      ] as $version_ids
      | [
          .data[]?
          | select(
              .attributes.version == $build_number
              and (.relationships.preReleaseVersion.data.id as $id | $version_ids | index($id))
            )
        ][0]
      | if . == null then empty else [.id, .attributes.processingState] | @tsv end
    '
}

wait_for_asc_build() {
  local app_id="$1"
  local started_at now record build_id processing_state
  started_at="$(date +%s)"

  while true; do
    record="$(asc_build_record "$app_id")"
    if [[ -n "$record" ]]; then
      IFS=$'\t' read -r build_id processing_state <<< "$record"
      case "$processing_state" in
        VALID)
          printf '%s' "$build_id"
          return
          ;;
        FAILED|INVALID)
          die "App Store Connect build ${next_version} (${next_build}) is $processing_state"
          ;;
        *)
          log "Waiting for App Store Connect build ${next_version} (${next_build}): ${processing_state:-processing}" >&2
          ;;
      esac
    else
      log "Waiting for App Store Connect to discover build ${next_version} (${next_build})" >&2
    fi

    now="$(date +%s)"
    if [[ "$((now - started_at))" -ge "$ASC_BUILD_WAIT_SECONDS" ]]; then
      die "timed out waiting for App Store Connect build ${next_version} (${next_build})"
    fi
    sleep "$ASC_BUILD_POLL_SECONDS"
  done
}

upload_testflight_metadata() {
  [[ -f "$what_to_test" ]] || die "What to Test file not found: $what_to_test; run prepare first"
  validate_what_to_test "$what_to_test"

  if [[ "$dry_run" -eq 1 ]]; then
    log "Would upload $what_to_test to TestFlight build ${next_version} (${next_build}) for $TESTFLIGHT_LOCALE"
    return
  fi

  require_asc_api_auth

  local app_id build_id localizations localization_id whats_new payload
  app_id="$(asc_app_id)"
  build_id="$(wait_for_asc_build "$app_id")"
  localizations="$(asc_api_request GET \
    "https://api.appstoreconnect.apple.com/v1/builds/$build_id/betaBuildLocalizations")"
  localization_id="$(
    printf '%s' "$localizations" | jq -r \
      --arg locale "$TESTFLIGHT_LOCALE" \
      '[.data[]? | select(.attributes.locale == $locale)][0].id // empty'
  )"
  whats_new="$(<"$what_to_test")"

  if [[ -n "$localization_id" ]]; then
    payload="$(
      jq -n \
        --arg id "$localization_id" \
        --arg whats_new "$whats_new" \
        '{
          data: {
            type: "betaBuildLocalizations",
            id: $id,
            attributes: { whatsNew: $whats_new }
          }
        }'
    )"
    asc_api_request PATCH \
      "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations/$localization_id" \
      "$payload" >/dev/null
    log "Updated What to Test for ${next_version} (${next_build}) [$TESTFLIGHT_LOCALE]"
  else
    payload="$(
      jq -n \
        --arg build_id "$build_id" \
        --arg locale "$TESTFLIGHT_LOCALE" \
        --arg whats_new "$whats_new" \
        '{
          data: {
            type: "betaBuildLocalizations",
            attributes: {
              locale: $locale,
              whatsNew: $whats_new
            },
            relationships: {
              build: {
                data: {
                  type: "builds",
                  id: $build_id
                }
              }
            }
          }
        }'
    )"
    asc_api_request POST \
      "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations" \
      "$payload" >/dev/null
    log "Created What to Test for ${next_version} (${next_build}) [$TESTFLIGHT_LOCALE]"
  fi
}

export_app() {
  local destination="$1"
  local plist="$export_options_export"
  if [[ "$destination" == "upload" ]]; then
    plist="$export_options_upload"
  fi

  [[ -f "$plist" ]] || generate_notes
  archive_app

  log "Export destination: $destination"
  if [[ "${#auth_args[@]}" -gt 0 ]]; then
    run xcodebuild \
      -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$export_path" \
      -exportOptionsPlist "$plist" \
      -allowProvisioningUpdates \
      "${auth_args[@]}"
  else
    run xcodebuild \
      -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$export_path" \
      -exportOptionsPlist "$plist" \
      -allowProvisioningUpdates
  fi
}

create_tag() {
  if [[ -n "$(git status --porcelain)" ]]; then
    if [[ "$dry_run" -eq 1 ]] && worktree_has_only_release_version_changes; then
      log "Dry run assumes the prepared release version is committed before tagging"
    else
      die "git worktree is dirty; commit the release version before tagging"
    fi
  fi
  if git rev-parse --verify "refs/tags/$tag_name" >/dev/null 2>&1; then
    die "tag already exists: $tag_name"
  fi
  log "Creating tag $tag_name"
  run git tag -a "$tag_name" -m "TestFlight ${next_version} (${next_build})"
}

github_release_ipa=""

resolve_github_release_ipa() {
  github_release_ipa=""
  [[ -d "$export_path" ]] || return 0

  local candidate
  for candidate in "$export_path"/*.ipa; do
    [[ -f "$candidate" ]] || continue
    if [[ -n "$github_release_ipa" ]]; then
      die "multiple IPA files found in $export_path; keep only the release IPA"
    fi
    github_release_ipa="$candidate"
  done

  return 0
}

ensure_github_release_ipa() {
  resolve_github_release_ipa
  if [[ -n "$github_release_ipa" ]]; then
    return
  fi

  log "No exported IPA found for $tag_name; exporting one from the archive"
  export_app "export"
  if [[ "$dry_run" -eq 1 ]]; then
    github_release_ipa="$export_path/$SCHEME.ipa"
    return
  fi

  resolve_github_release_ipa
  [[ -n "$github_release_ipa" ]] || die "IPA export completed without an IPA in $export_path"
}

ensure_github_auth() {
  command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required to create a GitHub Release"
  if gh auth status -h github.com >/dev/null 2>&1; then
    return
  fi

  echo
  log "GitHub authentication is required; follow the browser login prompts"
  gh auth login -h github.com -p https -w
  gh auth status -h github.com >/dev/null 2>&1 || die "GitHub authentication did not complete"
}

create_github_release() {
  local release_exists=0
  if [[ "$dry_run" -ne 1 ]]; then
    ensure_github_auth
    git remote get-url "$GITHUB_REMOTE" >/dev/null 2>&1 || die "git remote not found: $GITHUB_REMOTE"
    git rev-parse --verify "refs/tags/$tag_name" >/dev/null 2>&1 || die "tag not found: $tag_name; run the tag command first"
    if gh release view "$tag_name" >/dev/null 2>&1; then
      release_exists=1
    fi
    [[ -f "$notes_markdown" ]] || die "release notes not found: $notes_markdown; run notes first"
  fi

  ensure_github_release_ipa

  log "Pushing tag $tag_name to $GITHUB_REMOTE"
  run git push "$GITHUB_REMOTE" "refs/tags/$tag_name"

  if [[ "$release_exists" -eq 1 ]]; then
    log "Updating existing GitHub prerelease $tag_name and uploading its IPA"
    run gh release edit "$tag_name" --notes-file "$notes_markdown"
    run gh release upload "$tag_name" "$github_release_ipa" --clobber
  else
    log "Creating GitHub prerelease $tag_name with IPA"
    run gh release create "$tag_name" "$github_release_ipa" \
      --verify-tag \
      --prerelease \
      --title "Actualist ${next_version} (${next_build}) TestFlight" \
      --notes-file "$notes_markdown"
  fi
}

print_plan() {
  cat <<PLAN
Current project version: ${current_version} (${current_build})
Selected release:        ${next_version} (${next_build})
Previous TestFlight tag: ${last_tag:-none}
Change range:            ${note_range}
Release directory:       ${release_dir}
Archive path:            ${archive_path}
Tag to create:           ${tag_name}

Next commands:
  scripts/testflight-release.sh notes
  scripts/testflight-release.sh prepare
  scripts/testflight-release.sh commit
  scripts/testflight-release.sh upload
  scripts/testflight-release.sh metadata
  scripts/testflight-release.sh tag
  scripts/testflight-release.sh github-release

For a single upload + tag + GitHub prerelease run:
  scripts/testflight-release.sh all --tag --github-release
PLAN
}

prompt_value() {
  local prompt="$1"
  local default="${2:-}"
  local value

  if [[ -n "$default" ]]; then
    printf "%s [%s]: " "$prompt" "$default" >&2
  else
    printf "%s: " "$prompt" >&2
  fi
  read -r value
  echo "${value:-$default}"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  local value

  if [[ "$default" == "y" ]]; then
    suffix="[Y/n]"
  fi

  while true; do
    printf "%s %s " "$prompt" "$suffix" >&2
    read -r value
    value="${value:-$default}"
    case "$value" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo "Please answer y or n." >&2 ;;
    esac
  done
}

next_for_bump() {
  local bump_name="$1"
  local version="$current_version"
  local build="$current_build"

  case "$bump_name" in
    build)
      build="$((current_build + 1))"
      ;;
    patch|minor|major)
      read -r major minor patch <<< "$(split_version "$current_version")"
      case "$bump_name" in
        patch) patch="$((patch + 1))" ;;
        minor) minor="$((minor + 1))"; patch=0 ;;
        major) major="$((major + 1))"; minor=0; patch=0 ;;
      esac
      version="$major.$minor.$patch"
      build=1
      ;;
  esac

  echo "$version ($build)"
}

choose_release_args() {
  local choice custom_version custom_build major minor patch
  chosen_release_args=()

  echo
  echo "Version bump"
  echo "  1) Build number: $(next_for_bump build)"
  echo "  2) Patch version: $(next_for_bump patch)"
  echo "  3) Minor version: $(next_for_bump minor)"
  echo "  4) Major version: $(next_for_bump major)"
  echo "  5) Custom version/build"

  while true; do
    choice="$(prompt_value "Choose bump" "1")"
    case "$choice" in
      1)
        selected_version="$current_version"
        selected_build="$((current_build + 1))"
        chosen_release_args+=(--bump build)
        return
        ;;
      2)
        read -r major minor patch <<< "$(split_version "$current_version")"
        selected_version="$major.$minor.$((patch + 1))"
        selected_build=1
        chosen_release_args+=(--bump patch)
        return
        ;;
      3)
        read -r major minor patch <<< "$(split_version "$current_version")"
        selected_version="$major.$((minor + 1)).0"
        selected_build=1
        chosen_release_args+=(--bump minor)
        return
        ;;
      4)
        read -r major minor patch <<< "$(split_version "$current_version")"
        selected_version="$((major + 1)).0.0"
        selected_build=1
        chosen_release_args+=(--bump major)
        return
        ;;
      5)
        custom_version="$(prompt_value "Marketing version" "$current_version")"
        custom_build="$(prompt_value "Build number" "$((current_build + 1))")"
        split_version "$custom_version" >/dev/null
        [[ "$custom_build" =~ ^[0-9]+$ ]] || die "build number must be an integer"
        selected_version="$custom_version"
        selected_build="$custom_build"
        chosen_release_args+=(--version "$custom_version" --build "$custom_build")
        return
        ;;
      *)
        echo "Choose 1-5." >&2
        ;;
    esac
  done
}

append_archive_args() {
  if prompt_yes_no "Skip simulator tests before archive?" "n"; then
    prompted_args+=(--skip-tests)
  fi
}

append_upload_args() {
  append_archive_args
  if prompt_yes_no "Internal TestFlight only?" "n"; then
    prompted_args+=(--internal-only)
  fi
}

run_release_step() {
  local subcommand="$1"
  shift

  echo
  printf "Running:"
  printf " %q" "$0" "$subcommand" "$@"
  printf "\n\n"

  bash "$0" "$subcommand" "$@"
}

add_testflight_focus_item() {
  local path="$1"
  local item="$2"
  local tmp_file

  item="${item#- }"
  [[ -n "$item" ]] || return
  if grep -Fxq -- "- $item" "$path"; then
    echo "That focus item is already present."
    return
  fi

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/actualist-what-to-test.XXXXXX")"
  if grep -Fxq "Focus for this build:" "$path"; then
    awk -v item="$item" '
      { print }
      !inserted && $0 == "Focus for this build:" {
        print "- " item
        inserted = 1
      }
    ' "$path" > "$tmp_file"
  else
    awk -v item="$item" '
      NR == 1 {
        print
        print ""
        print "Focus for this build:"
        print "- " item
        next
      }
      { print }
    ' "$path" > "$tmp_file"
  fi
  mv "$tmp_file" "$path"
}

review_testflight_notes() {
  local what_to_test_path="$1"
  local release_notes_path="$2"
  local choice item editor character_count
  local -a editor_parts

  while true; do
    echo
    echo "What to Test preview"
    echo "--------------------"
    cat "$what_to_test_path"
    echo "--------------------"
    character_count="$(what_to_test_character_count "$what_to_test_path")"
    echo "$character_count / 4000 characters"
    echo
    echo "  1) Keep these notes"
    echo "  2) Add a focus item"
    echo "  3) Edit the complete notes in an editor"
    choice="$(prompt_value "Choose notes action" "1")"

    case "$choice" in
      1)
        if [[ "$character_count" -gt 4000 ]]; then
          echo "The notes must be shortened to 4000 characters before continuing." >&2
          continue
        fi
        sync_release_notes_what_to_test "$release_notes_path" "$what_to_test_path"
        return
        ;;
      2)
        item="$(prompt_value "Tester-facing action (without a bullet)" "")"
        if [[ -z "$item" ]]; then
          echo "No focus item added."
        else
          add_testflight_focus_item "$what_to_test_path" "$item"
          sync_release_notes_what_to_test "$release_notes_path" "$what_to_test_path"
        fi
        ;;
      3)
        editor="${VISUAL:-${EDITOR:-vi}}"
        read -r -a editor_parts <<< "$editor"
        command -v "${editor_parts[0]}" >/dev/null 2>&1 \
          || die "editor not found: ${editor_parts[0]}; set EDITOR or VISUAL"
        "${editor_parts[@]}" "$what_to_test_path"
        sync_release_notes_what_to_test "$release_notes_path" "$what_to_test_path"
        ;;
      *)
        echo "Choose 1-3." >&2
        ;;
    esac
  done
}

run_release_wizard() {
  local status prepared_version=0 resume_current=0 upload_release=1 upload_notes=1
  local tag_release=0 publish_github=0 dry_run_release=0
  local current_release_dir current_archive current_export current_tag
  local selected_release_dir selected_what_to_test selected_release_notes
  local selected_version="$current_version" selected_build="$current_build"
  local release_summary
  local -a release_args upload_args command_args prompted_args chosen_release_args
  release_args=()
  upload_args=()
  command_args=()
  prompted_args=()
  chosen_release_args=()

  echo
  echo "Actualist release"
  echo "================="
  echo
  echo "1/6  Preflight"
  echo "     Branch:  $(git branch --show-current)"
  echo "     Version: ${current_version} (${current_build})"

  status="$(git status --porcelain)"
  if [[ -n "$status" ]]; then
    if worktree_has_only_release_version_changes; then
      prepared_version=1
      echo "     A prepared version/build change is ready to commit."
    else
      echo
      echo "Release is blocked by these working-tree changes:"
      git status --short
      echo
      die "commit or stash those changes, then run the release wizard again"
    fi
  else
    echo "     Working tree is clean."
  fi

  current_release_dir="$RELEASE_ROOT/${current_version}-${current_build}"
  current_archive="$current_release_dir/Actualist-${current_version}-${current_build}.xcarchive"
  current_export="$current_release_dir/export"
  current_tag="${TAG_PREFIX}${current_version}-b${current_build}"

  echo
  echo "2/6  Select release"
  if [[ -d "$current_archive" || -f "$current_export/$SCHEME.ipa" ]]; then
    if prompt_yes_no "Resume prepared release ${current_version} (${current_build})?" "y"; then
      resume_current=1
      selected_version="$current_version"
      selected_build="$current_build"
      release_summary="${current_version} (${current_build}), using existing local artifacts"
    fi
  fi

  if [[ "$resume_current" -ne 1 ]]; then
    choose_release_args
    release_args=("${chosen_release_args[@]}")
    release_summary="${selected_version} (${selected_build}), newly selected"
  fi

  if prompt_yes_no "Dry run release operations only?" "n"; then
    dry_run_release=1
  fi

  selected_release_dir="$RELEASE_ROOT/${selected_version}-${selected_build}"
  selected_what_to_test="$selected_release_dir/what-to-test.txt"
  selected_release_notes="$selected_release_dir/release-notes.md"

  echo
  echo "3/6  What to Test"
  echo "     Notes are prepared locally now so you can review them before release operations."
  command_args=("${release_args[@]}")
  [[ "$resume_current" -eq 1 ]] && command_args+=(--bump none)
  if [[ -f "$selected_what_to_test" ]]; then
    if ! prompt_yes_no "Regenerate What to Test from the consumer template and commit trailers?" "y"; then
      command_args+=(--keep-test-notes)
    fi
  fi
  run_release_step notes "${command_args[@]}"
  review_testflight_notes "$selected_what_to_test" "$selected_release_notes"

  echo
  echo "4/6  TestFlight"
  if [[ "$resume_current" -eq 1 ]]; then
    if prompt_yes_no "Upload or re-upload ${current_version} (${current_build}) to App Store Connect?" "n"; then
      upload_release=1
    else
      upload_release=0
    fi
  fi

  if [[ "$upload_release" -eq 1 ]]; then
    append_upload_args
    upload_args=("${prompted_args[@]}")
    prompted_args=()
  fi

  if [[ "$upload_release" -eq 1 ]]; then
    if ! prompt_yes_no "Upload the reviewed What to Test after build processing?" "y"; then
      upload_notes=0
    fi
  else
    if ! prompt_yes_no "Update What to Test on the existing TestFlight build?" "y"; then
      upload_notes=0
    fi
  fi

  echo
  echo "5/6  GitHub"
  if [[ "$resume_current" -eq 1 ]] && git rev-parse --verify "refs/tags/$current_tag" >/dev/null 2>&1; then
    echo "     Tag already exists: $current_tag"
  else
    if prompt_yes_no "Create the TestFlight tag after the release is ready?" "y"; then
      tag_release=1
    fi
  fi

  if [[ "$tag_release" -eq 1 ]] || { [[ "$resume_current" -eq 1 ]] && git rev-parse --verify "refs/tags/$current_tag" >/dev/null 2>&1; }; then
    if prompt_yes_no "Publish the GitHub prerelease and attach the IPA?" "y"; then
      publish_github=1
    fi
  fi

  echo
  echo "6/6  Confirm"
  echo "     Release: $release_summary"
  if [[ "$upload_release" -eq 1 ]]; then
    echo "     TestFlight upload: yes"
  else
    echo "     TestFlight upload: skipped (already uploaded)"
  fi
  echo "     What to Test upload: $([[ "$upload_notes" -eq 1 ]] && echo yes || echo no)"
  echo "     Create tag: $([[ "$tag_release" -eq 1 ]] && echo yes || echo no)"
  echo "     GitHub prerelease: $([[ "$publish_github" -eq 1 ]] && echo yes || echo no)"
  echo "     Dry run: $([[ "$dry_run_release" -eq 1 ]] && echo yes || echo no)"
  echo
  prompt_yes_no "Proceed with this release?" "y" || die "release cancelled"

  if [[ "$resume_current" -eq 1 ]]; then
    if [[ "$prepared_version" -eq 1 ]]; then
      command_args=()
      [[ "$dry_run_release" -eq 1 ]] && command_args+=(--dry-run)
      run_release_step commit "${command_args[@]}"
    fi

    command_args=()
    [[ "$dry_run_release" -eq 1 ]] && command_args+=(--dry-run)
    if [[ "$upload_release" -eq 1 ]]; then
      command_args+=(--bump none --keep-test-notes)
      command_args+=("${upload_args[@]}")
      [[ "$upload_notes" -eq 1 ]] && command_args+=(--upload-test-metadata)
      [[ "$tag_release" -eq 1 ]] && command_args+=(--tag)
      [[ "$publish_github" -eq 1 ]] && command_args+=(--github-release)
      run_release_step upload "${command_args[@]}"
    else
      if [[ "$upload_notes" -eq 1 ]]; then
        run_release_step metadata "${command_args[@]}"
      fi
      if [[ "$tag_release" -eq 1 ]]; then
        [[ "$publish_github" -eq 1 ]] && command_args+=(--github-release)
        run_release_step tag "${command_args[@]}"
      elif [[ "$publish_github" -eq 1 ]]; then
        run_release_step github-release "${command_args[@]}"
      elif [[ "$upload_notes" -ne 1 ]]; then
        log "Notes were reviewed locally; no release operation was selected"
      fi
    fi
  else
    command_args=("${release_args[@]}")
    command_args+=("${upload_args[@]}")
    command_args+=(--keep-test-notes)
    [[ "$upload_notes" -eq 1 ]] && command_args+=(--upload-test-metadata)
    [[ "$tag_release" -eq 1 ]] && command_args+=(--tag)
    [[ "$publish_github" -eq 1 ]] && command_args+=(--github-release)
    [[ "$dry_run_release" -eq 1 ]] && command_args+=(--dry-run)
    run_release_step all "${command_args[@]}"
    if [[ "$tag_release" -ne 1 && "$dry_run_release" -ne 1 ]]; then
      run_release_step commit
    fi
  fi

  echo
  log "Release workflow finished"
}

case "$command" in
  wizard|menu)
    run_release_wizard
    ;;
  plan)
    print_plan
    ;;
  notes)
    generate_notes
    if [[ "$dry_run" -ne 1 ]]; then
      log "Wrote $notes_markdown"
      log "Wrote $what_to_test"
    fi
    ;;
  prepare)
    require_clean_worktree
    update_project_version
    generate_notes
    log "Wrote $notes_markdown"
    log "Wrote $what_to_test"
    ;;
  commit)
    commit_release_version
    ;;
  archive)
    require_build_worktree
    if [[ "$bump" != "none" || -n "$version_override" || -n "$build_override" ]]; then
      update_project_version
      generate_notes
    fi
    archive_app
    ;;
  export)
    require_build_worktree
    if [[ "$bump" != "none" || -n "$version_override" || -n "$build_override" ]]; then
      update_project_version
      generate_notes
    fi
    export_app "export"
    ;;
  upload)
    require_build_worktree
    if [[ "$github_release_after_tag" -eq 1 ]] && will_mutate_version; then
      [[ "$tag_after_upload" -eq 1 ]] || die "--github-release while changing version/build requires --tag"
    fi
    if [[ "$bump" != "none" || -n "$version_override" || -n "$build_override" ]]; then
      update_project_version
      generate_notes
    fi
    if [[ "$tag_after_upload" -eq 1 ]]; then
      commit_release_version
    fi
    export_app "upload"
    if [[ "$upload_test_metadata" -eq 1 ]]; then
      upload_testflight_metadata
    fi
    if [[ "$tag_after_upload" -eq 1 ]]; then
      create_tag
    fi
    if [[ "$github_release_after_tag" -eq 1 ]]; then
      create_github_release
    fi
    ;;
  all)
    require_clean_worktree
    update_project_version
    generate_notes
    if [[ "$tag_after_upload" -eq 1 ]]; then
      commit_release_version
    fi
    export_app "upload"
    if [[ "$upload_test_metadata" -eq 1 ]]; then
      upload_testflight_metadata
    fi
    if [[ "$tag_after_upload" -eq 1 ]]; then
      create_tag
    fi
    if [[ "$github_release_after_tag" -eq 1 ]]; then
      create_github_release
    fi
    ;;
  metadata)
    upload_testflight_metadata
    ;;
  tag)
    create_tag
    if [[ "$github_release_after_tag" -eq 1 ]]; then
      create_github_release
    fi
    ;;
  github-release)
    require_clean_worktree
    create_github_release
    ;;
esac
