#!/usr/bin/env bash
# Fails when a commit message leans on an internal tracking ID that an outside
# developer cannot look up: a parity divergence (OP-nn), an audit finding
# (CA-nn, F-nn), a Decision Register entry (Dnn), a roadmap or cleanup ID (Pn),
# a plan phase ("Phase 3") or a plan item ("item 2.4"). AGENTS.md, Commit And
# TestFlight Notes, says to describe the behavior instead.
#
# Usage:
#   scripts/lint-commit-messages.sh                   # HEAD
#   scripts/lint-commit-messages.sh --range A..B
#   scripts/lint-commit-messages.sh --unpushed       # commits on no remote
#   scripts/lint-commit-messages.sh --message-file FILE
set -euo pipefail

range=""
message_file=""
unpushed=0

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --range)
      range="${2:-}"
      [[ -n "$range" ]] || { echo "error: --range requires a value" >&2; exit 2; }
      shift 2
      ;;
    --message-file)
      message_file="${2:-}"
      [[ -n "$message_file" ]] || { echo "error: --message-file requires a value" >&2; exit 2; }
      shift 2
      ;;
    --unpushed)
      unpushed=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if (( (${#message_file} > 0) + (${#range} > 0) + unpushed > 1 )); then
  echo "error: use only one of --range, --unpushed and --message-file" >&2
  exit 2
fi

# Each ID must stand alone: not inside a longer word, so UTF-8, ISO-8601,
# SHA-256 and V8 never match.
before='(^|[^A-Za-z0-9_-])'
after='([^A-Za-z0-9_]|$)'
internal_ids=(
  "OP-[0-9]+"
  "CA-[0-9]+"
  "F-[0-9]+"
  "D[0-9]{1,2}"
  "P[0-9](\.[0-9]+)?"
  "[Pp]hase [0-9]+"
  "[Ii]tem [0-9]+\.[0-9]+"
)
pattern="${before}($(IFS='|'; echo "${internal_ids[*]}"))${after}"

status=0
checked=0

lint_message() {
  local label="$1"
  local message="$2"
  local matches
  # Comment lines are what git strips from an editor message.
  matches="$(printf '%s\n' "$message" | grep -v '^#' | grep -nE "$pattern" || true)"
  if [[ -n "$matches" ]]; then
    echo "error: $label: commit message cites an internal ID; describe the behavior instead:" >&2
    printf '%s\n' "$matches" | sed 's/^/  line /' >&2
    status=1
  fi
}

if [[ -n "$message_file" ]]; then
  [[ -f "$message_file" ]] || { echo "error: message file not found: $message_file" >&2; exit 2; }
  checked=1
  lint_message "$message_file" "$(cat "$message_file")"
else
  if [[ "$unpushed" -eq 1 ]]; then
    # Published history is not rewritten, so only commits no remote has yet
    # are checked. A checkout without a remote checks HEAD alone.
    if [[ -n "$(git remote)" ]]; then
      rev_args=(HEAD --not --remotes)
    else
      rev_args=("HEAD^!")
    fi
  else
    [[ -n "$range" ]] || range="HEAD^!"
    rev_args=("$range")
  fi
  commits="$(git rev-list --no-merges "${rev_args[@]}")"
  if [[ -z "$commits" && "$unpushed" -eq 1 ]]; then
    echo "skip: no unpushed commits"
    exit 0
  fi
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    checked=1
    lint_message "$(git log -1 --format='%h' "$commit")" "$(git log -1 --format='%B' "$commit")"
  done <<< "$commits"
fi

if [[ "$checked" -eq 0 ]]; then
  echo "error: no commits to lint in $range" >&2
  exit 2
fi

if [[ "$status" -ne 0 ]]; then
  echo >&2
  echo "Commit message lint failed. An outside developer must understand every" >&2
  echo "sentence without the project's internal records. See AGENTS.md." >&2
  exit 1
fi

echo "Commit message lint passed."
