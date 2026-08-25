#!/usr/bin/env bash
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/testflight-notes.sh
source "$_script_dir/lib/testflight-notes.sh"

range=""
message_file=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/lint-testflight-notes.sh
  scripts/lint-testflight-notes.sh --range A..B
  scripts/lint-testflight-notes.sh --message-file FILE

Lint TestFlight-Note trailers. Default is HEAD.

Every tester-visible note must be:
  TestFlight-Note: [topic] Added a Rules screen under Settings → Budget & Data.

See AGENTS.md and config/testflight/topics.txt.
USAGE
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

if [[ -n "$message_file" && -n "$range" ]]; then
  echo "error: use --range or --message-file, not both" >&2
  exit 2
fi

[[ -f "$TESTFLIGHT_TOPICS_FILE" ]] || {
  echo "error: missing $TESTFLIGHT_TOPICS_FILE" >&2
  exit 2
}

status=0
checked=0

if [[ -n "$message_file" ]]; then
  [[ -f "$message_file" ]] || {
    echo "error: message file not found: $message_file" >&2
    exit 2
  }
  checked=1
  testflight_lint_message "$message_file" "$(cat "$message_file")" || status=1
else
  if [[ -z "$range" ]]; then
    range="HEAD^!"
  fi
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    checked=1
    testflight_lint_message "$commit" "$(git log -1 --format='%B' "$commit")" || status=1
  done < <(git rev-list --no-merges "$range")
fi

if [[ "$checked" -eq 0 ]]; then
  echo "error: no commits to lint in $range" >&2
  exit 2
fi

if [[ "$status" -ne 0 ]]; then
  echo >&2
  echo "TestFlight-Note lint failed. Rewrite notes as complete [topic] summaries." >&2
  echo "Do not write Try/confirm test scripts. See AGENTS.md." >&2
  exit 1
fi

echo "TestFlight-Note lint passed."
