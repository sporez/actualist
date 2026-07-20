#!/usr/bin/env bash
set -euo pipefail

PROJECT="Actualist.xcodeproj"
SCHEME="Actualist"
CONFIGURATION="Release"
TEAM_ID="BJNL8CJWW6"
TAG_PREFIX="testflight/v"
RELEASE_ROOT=".release/testflight"
DERIVED_DATA_PATH=".derivedData/testflight"
TEST_DESTINATION="${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
GITHUB_REMOTE="${GITHUB_REMOTE:-origin}"

if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
  command="menu"
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
internal_only=0
notes_limit=80

usage() {
  cat <<'USAGE'
Usage:
  scripts/testflight-release.sh
  scripts/testflight-release.sh menu
  scripts/testflight-release.sh plan [options]
  scripts/testflight-release.sh prepare [options]
  scripts/testflight-release.sh archive [options]
  scripts/testflight-release.sh export [options]
  scripts/testflight-release.sh upload [options]
  scripts/testflight-release.sh all [options]
  scripts/testflight-release.sh tag [options]
  scripts/testflight-release.sh github-release [options]

Commands:
  menu       Walk through common release tasks with a basic Bash menu.
  plan       Show the next TestFlight release without changing files.
  prepare    Bump version/build if needed and write release notes/export options.
  archive    Run tests, then create an App Store Connect archive.
  export     Archive if needed, then export a local App Store Connect IPA.
  upload     Archive if needed, then upload to App Store Connect.
  all        prepare + archive + upload.
  tag        Create the TestFlight git tag for the selected version/build.
  github-release
             Push the current TestFlight tag and create a GitHub prerelease.

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
  --tag                  With upload, tag after a successful upload.
                         Tagging requires a clean worktree and no version
                         mutation in the same command.
  --github-release       With tag or upload, publish a GitHub prerelease after
                         confirming the current TestFlight tag exists.
  --dry-run              Print commands and intended edits without executing them.
  --notes-limit N        Max commit lines in what-to-test.txt. Default: 80.

App Store Connect auth:
  Upload can use the signed-in Xcode account, or these env vars:
    ASC_API_KEY_PATH / APP_STORE_CONNECT_API_KEY_PATH
    ASC_API_KEY_ID / APP_STORE_CONNECT_API_KEY_ID
    ASC_API_ISSUER_ID / APP_STORE_CONNECT_API_ISSUER_ID
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
  menu|plan|prepare|archive|export|upload|all|tag|github-release) ;;
  *)
    usage
    die "unknown command: $command"
    ;;
esac

if [[ "$github_release_after_tag" -eq 1 ]]; then
  case "$command" in
    upload|tag) ;;
    *) die "--github-release is only valid with upload or tag" ;;
  esac
fi

[[ -d "$PROJECT" ]] || die "run this from the Actualist repository root"
[[ -f "$PROJECT/project.pbxproj" ]] || die "missing $PROJECT/project.pbxproj"

if [[ -z "$bump" ]]; then
  case "$command" in
    plan|prepare|all)
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
  : > "$features"
  : > "$fixes"
  : > "$polish"
  : > "$docs_tests"
  : > "$other"
  : > "$full_log"

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

  mkdir -p "$release_dir"

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

  {
    echo "Actualist ${next_version} (${next_build})"
    echo
    if [[ "$has_commits" -eq 0 ]]; then
      echo "- Internal build with no committed changes in ${note_range}."
    else
      cat "$features" "$fixes" "$polish" "$other" "$docs_tests" | awk 'NF' | head -n "$notes_limit"
    fi
  } > "$what_to_test"

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
    die "git worktree is dirty; commit the release version before tagging"
  fi
  if git rev-parse --verify "refs/tags/$tag_name" >/dev/null 2>&1; then
    die "tag already exists: $tag_name"
  fi
  log "Creating tag $tag_name"
  run git tag -a "$tag_name" -m "TestFlight ${next_version} (${next_build})"
}

create_github_release() {
  if [[ "$dry_run" -ne 1 ]]; then
    command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required to create a GitHub Release"
    git remote get-url "$GITHUB_REMOTE" >/dev/null 2>&1 || die "git remote not found: $GITHUB_REMOTE"
    git rev-parse --verify "refs/tags/$tag_name" >/dev/null 2>&1 || die "tag not found: $tag_name; run the tag command first"
    [[ -f "$notes_markdown" ]] || die "release notes not found: $notes_markdown; run prepare first"
    if gh release view "$tag_name" >/dev/null 2>&1; then
      die "GitHub Release already exists: $tag_name"
    fi
  fi

  log "Pushing tag $tag_name to $GITHUB_REMOTE"
  run git push "$GITHUB_REMOTE" "refs/tags/$tag_name"

  log "Creating GitHub prerelease $tag_name"
  run gh release create "$tag_name" \
    --verify-tag \
    --prerelease \
    --title "Actualist ${next_version} (${next_build}) TestFlight" \
    --notes-file "$notes_markdown"
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
  scripts/testflight-release.sh prepare
  git add Actualist.xcodeproj/project.pbxproj
  git commit -m "chore: prepare TestFlight ${next_version} (${next_build})"
  scripts/testflight-release.sh upload
  scripts/testflight-release.sh tag
  scripts/testflight-release.sh github-release

For a single run:
  scripts/testflight-release.sh all
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
  menu_release_args=()

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
        menu_release_args+=(--bump build)
        return
        ;;
      2)
        menu_release_args+=(--bump patch)
        return
        ;;
      3)
        menu_release_args+=(--bump minor)
        return
        ;;
      4)
        menu_release_args+=(--bump major)
        return
        ;;
      5)
        custom_version="$(prompt_value "Marketing version" "$current_version")"
        custom_build="$(prompt_value "Build number" "$((current_build + 1))")"
        menu_release_args+=(--version "$custom_version" --build "$custom_build")
        return
        ;;
      *)
        echo "Choose 1-5." >&2
        ;;
    esac
  done
}

append_dirty_arg_or_cancel() {
  if [[ -z "$(git status --porcelain)" ]]; then
    return 0
  fi

  echo
  echo "The git worktree is dirty."
  if prompt_yes_no "Allow a dirty worktree for this command?" "n"; then
    menu_args+=(--allow-dirty)
    return 0
  fi

  echo "Cancelled."
  return 1
}

append_common_run_args() {
  if prompt_yes_no "Dry run only?" "n"; then
    menu_args+=(--dry-run)
  fi
}

append_archive_args() {
  if prompt_yes_no "Skip simulator tests before archive?" "n"; then
    menu_args+=(--skip-tests)
  fi
}

append_upload_args() {
  append_archive_args
  if prompt_yes_no "Internal TestFlight only?" "n"; then
    menu_args+=(--internal-only)
  fi
}

run_script_from_menu() {
  local subcommand="$1"
  shift

  echo
  printf "Running:"
  printf " %q" "$0" "$subcommand" "$@"
  printf "\n\n"

  bash "$0" "$subcommand" "$@"
}

run_menu_command() {
  local subcommand="$1"

  if [[ "${#menu_args[@]}" -gt 0 ]]; then
    run_script_from_menu "$subcommand" "${menu_args[@]}"
  else
    run_script_from_menu "$subcommand"
  fi
}

run_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "Actualist TestFlight Release"
    echo
    echo "Current project version: ${current_version} (${current_build})"
    echo "Next build release:      $(next_for_bump build)"
    echo "Previous TestFlight tag: ${last_tag:-none}"
    echo
    echo "  1) Show release plan"
    echo "  2) Prepare version + release notes"
    echo "  3) Archive current version"
    echo "  4) Export IPA for current version"
    echo "  5) Upload current version to App Store Connect"
    echo "  6) Prepare version + upload"
    echo "  7) Tag current committed release"
    echo "  8) Publish GitHub prerelease for current tag"
    echo "  9) Help"
    echo "  0) Quit"
    echo

    choice="$(prompt_value "Choose" "1")"
    menu_args=()

    case "$choice" in
      1)
        append_common_run_args
        run_menu_command plan
        ;;
      2)
        choose_release_args
        menu_args+=("${menu_release_args[@]}")
        append_dirty_arg_or_cancel || continue
        append_common_run_args
        run_menu_command prepare
        ;;
      3)
        append_dirty_arg_or_cancel || continue
        append_archive_args
        append_common_run_args
        run_menu_command archive
        ;;
      4)
        append_dirty_arg_or_cancel || continue
        append_archive_args
        append_common_run_args
        run_menu_command export
        ;;
      5)
        append_dirty_arg_or_cancel || continue
        append_upload_args
        append_common_run_args
        run_menu_command upload
        ;;
      6)
        choose_release_args
        menu_args+=("${menu_release_args[@]}")
        append_dirty_arg_or_cancel || continue
        append_upload_args
        append_common_run_args
        run_menu_command all
        ;;
      7)
        if [[ -n "$(git status --porcelain)" ]]; then
          echo
          echo "Tagging requires a clean worktree. Commit the release version first."
        else
          if prompt_yes_no "Publish a GitHub prerelease after tagging?" "n"; then
            menu_args+=(--github-release)
          fi
          append_common_run_args
          run_menu_command tag
        fi
        ;;
      8)
        if [[ -n "$(git status --porcelain)" ]]; then
          echo
          echo "Publishing requires a clean worktree."
        else
          append_common_run_args
          run_menu_command github-release
        fi
        ;;
      9)
        usage
        ;;
      0|q|Q)
        exit 0
        ;;
      *)
        echo "Choose 0-9." >&2
        ;;
    esac

    echo
    prompt_value "Press return to continue" "" >/dev/null
  done
}

case "$command" in
  menu)
    run_menu
    ;;
  plan)
    print_plan
    ;;
  prepare)
    require_clean_worktree
    update_project_version
    generate_notes
    log "Wrote $notes_markdown"
    log "Wrote $what_to_test"
    ;;
  archive)
    require_clean_worktree
    if [[ "$bump" != "none" || -n "$version_override" || -n "$build_override" ]]; then
      update_project_version
      generate_notes
    fi
    archive_app
    ;;
  export)
    require_clean_worktree
    if [[ "$bump" != "none" || -n "$version_override" || -n "$build_override" ]]; then
      update_project_version
      generate_notes
    fi
    export_app "export"
    ;;
  upload)
    require_clean_worktree
    if [[ "$tag_after_upload" -eq 1 && -n "$(git status --porcelain)" ]]; then
      die "--tag requires a clean worktree before upload"
    fi
    if [[ "$tag_after_upload" -eq 1 ]] && will_mutate_version; then
      die "cannot use --tag while changing version/build; prepare, commit, upload, then tag"
    fi
    if [[ "$github_release_after_tag" -eq 1 ]] && will_mutate_version; then
      die "cannot use --github-release while changing version/build; prepare and commit first"
    fi
    if [[ "$bump" != "none" || -n "$version_override" || -n "$build_override" ]]; then
      update_project_version
      generate_notes
    fi
    export_app "upload"
    if [[ "$tag_after_upload" -eq 1 ]]; then
      create_tag
    fi
    if [[ "$github_release_after_tag" -eq 1 ]]; then
      create_github_release
    fi
    ;;
  all)
    require_clean_worktree
    if [[ "$tag_after_upload" -eq 1 ]] && will_mutate_version; then
      die "cannot use --tag with all because all prepares a version bump; commit the bump, then run tag"
    fi
    update_project_version
    generate_notes
    export_app "upload"
    if [[ "$tag_after_upload" -eq 1 ]]; then
      create_tag
    fi
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
