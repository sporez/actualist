#!/usr/bin/env bash
# Mechanical pre-handoff gate. Cheap on purpose: whitespace, Liquid Glass,
# TestFlight notes, pbxproj membership, and file-size signals.
# Does not build, test, or archive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

status=0

section() {
  printf '\n== %s ==\n' "$1"
}

section "Whitespace (git diff --check)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git diff --check || status=1
  git diff --cached --check || status=1
else
  echo "skip: not a git work tree"
fi

section "Liquid Glass"
"$ROOT/scripts/lint-liquid-glass.sh" || status=1

section "TestFlight notes"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  note_range=""
  if git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
    if [[ "$(git rev-list --count '@{upstream}..HEAD')" -gt 0 ]]; then
      note_range='@{upstream}..HEAD'
    fi
  fi
  if [[ -z "$note_range" ]]; then
    if git rev-parse --verify HEAD^ >/dev/null 2>&1; then
      note_range='HEAD^!'
    fi
  fi
  if [[ -n "$note_range" ]] && git log --format='%B' "$note_range" | grep -q '^[[:space:]]*TestFlight-Note:'; then
    "$ROOT/scripts/lint-testflight-notes.sh" --range "$note_range" || status=1
  else
    echo "skip: no TestFlight-Note trailers in range"
  fi
else
  echo "skip: not a git work tree"
fi

section "Actual 26.8.1 split oracle"
"$ROOT/scripts/split-parity/verify.mjs" || status=1

section "Xcode synchronized groups"
# Sources are auto-registered: Actualist/, ActualistTests/, and
# ActualistWidget/ are file system synchronized root groups, so any file on
# disk is compiled without a pbxproj edit. The check only guards that the
# project still uses synchronized groups.
if grep -q 'PBXFileSystemSynchronizedRootGroup' Actualist.xcodeproj/project.pbxproj \
  && grep -q 'path = Actualist;' Actualist.xcodeproj/project.pbxproj \
  && grep -q 'path = ActualistTests;' Actualist.xcodeproj/project.pbxproj \
  && grep -q 'path = ActualistWidget;' Actualist.xcodeproj/project.pbxproj; then
  echo "Synchronized root groups present; Swift files auto-register."
else
  echo "error: project.pbxproj no longer uses synchronized root groups for Actualist/ActualistTests/ActualistWidget"
  status=1
fi

section "Touched Swift size"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  touched=()
  while IFS= read -r path; do
    [[ "$path" == *.swift ]] || continue
    [[ -f "$path" ]] || continue
    touched+=("$path")
  done < <({
    git diff --name-only HEAD
    git diff --cached --name-only
    git ls-files --others --exclude-standard
  } | sort -u)

  if [[ "${#touched[@]}" -eq 0 ]]; then
    echo "No touched Swift files."
  else
    wc -l "${touched[@]}"
    echo
    git diff --numstat HEAD || true
    for path in "${touched[@]}"; do
      lines="$(wc -l < "$path" | tr -d ' ')"
      if [[ "$lines" -ge 1000 && "$path" == Actualist/* ]]; then
        echo "error: $path is $lines lines; do not add production code to a file at or above 1,000."
        status=1
      elif [[ "$lines" -ge 800 ]]; then
        echo "warning: $path is $lines lines; reassess keep-or-split before adding responsibility."
      fi
    done
  fi
else
  echo "skip: not a git work tree"
fi

section "Largest Swift files"
rg --files -0 Actualist -g '*.swift' | xargs -0 wc -l | sort -nr | head -20

echo
if [[ "$status" -ne 0 ]]; then
  echo "check failed."
  exit 1
fi
echo "check passed."
