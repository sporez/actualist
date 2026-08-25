# Shared TestFlight-Note parsing and validation. Sourced, not executed.

_testflight_notes_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTFLIGHT_NOTES_ROOT="$(cd "${_testflight_notes_lib_dir}/../.." && pwd)"
TESTFLIGHT_TOPICS_FILE="${TESTFLIGHT_TOPICS_FILE:-$TESTFLIGHT_NOTES_ROOT/config/testflight/topics.txt}"
TESTFLIGHT_NOTE_MAX_CHARS="${TESTFLIGHT_NOTE_MAX_CHARS:-400}"

testflight_load_topics() {
  [[ -f "$TESTFLIGHT_TOPICS_FILE" ]] || return 1
  grep -E '^[a-z][a-z0-9-]*$' "$TESTFLIGHT_TOPICS_FILE"
}

testflight_topic_is_allowed() {
  local topic="$1"
  [[ -n "$topic" ]] || return 1
  testflight_load_topics | grep -Fxq -- "$topic"
}

# Reads commit-message bodies on stdin. Prints "topic<TAB>note".
# Topic is empty when the trailer has no valid [lowercase-kebab] prefix.
testflight_extract_notes() {
  awk '
    match($0, /^[[:space:]]*TestFlight-Note:[[:space:]]*/) {
      note = substr($0, RLENGTH + 1)
      sub(/[[:space:]]+$/, "", note)
      if (note == "") next
      topic = ""
      if (match(note, /^\[[a-z][a-z0-9-]*\][[:space:]]+/)) {
        topic = substr(note, 2, index(note, "]") - 2)
        note = substr(note, RLENGTH + 1)
      }
      print topic "\t" note
    }
  '
}

testflight_note_lines() {
  git log --no-merges --format='%B' "$1" | testflight_extract_notes
}

# Split an extract line without using `read` IFS, which strips a leading tab
# and would drop untagged notes printed as "\\tthe note".
testflight_split_note_line() {
  local line="$1"
  if [[ "$line" == *$'\t'* ]]; then
    _tf_topic="${line%%$'\t'*}"
    _tf_note="${line#*$'\t'}"
  else
    _tf_topic=""
    _tf_note="$line"
  fi
}

testflight_note_is_instructional() {
  local note="$1"
  printf '%s\n' "$note" | grep -Eq \
    '^(Try|Say|Search|Open|In Shortcuts|Confirm|Verify|Force-quit|Tap)[[:space:]]' \
    && return 0
  printf '%s\n' "$note" | grep -Eiq \
    '(^|[[:space:]])(and |then )?confirm[[:space:]]' \
    && return 0
  printf '%s\n' "$note" | grep -Eiq \
    '(^|[[:space:]])verify (the|that|it)[[:space:]]' \
    && return 0
  return 1
}

testflight_note_has_required_verb() {
  case "$1" in
    Added\ *|Fixed\ *|Improved\ *|Moved\ *|Renamed\ *|Removed\ *|Combined\ *)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

testflight_lint_extracted_note() {
  local source_label="$1"
  local topic="$2"
  local note="$3"
  local status=0

  if [[ -z "$topic" ]]; then
    if [[ "$note" == \[* ]]; then
      echo "error: $source_label: topic prefix must be [lowercase-kebab] from config/testflight/topics.txt: $note" >&2
    else
      echo "error: $source_label: TestFlight-Note must start with [topic] from config/testflight/topics.txt: $note" >&2
    fi
    status=1
  elif ! testflight_topic_is_allowed "$topic"; then
    echo "error: $source_label: unknown TestFlight topic [$topic]; add a product surface to config/testflight/topics.txt or use an existing one" >&2
    status=1
  fi

  if ! testflight_note_has_required_verb "$note"; then
    echo "error: $source_label: note must start with Added, Fixed, Improved, Moved, Renamed, Removed, or Combined: $note" >&2
    status=1
  fi

  if testflight_note_is_instructional "$note"; then
    echo "error: $source_label: note describes a test script; write what changed, not Try/confirm/verify: $note" >&2
    status=1
  fi

  if [[ "${#note}" -gt "$TESTFLIGHT_NOTE_MAX_CHARS" ]]; then
    echo "error: $source_label: note is ${#note} characters; keep it at or under $TESTFLIGHT_NOTE_MAX_CHARS: $note" >&2
    status=1
  fi

  return "$status"
}

# Lint one commit message. Empty notes are allowed (internal commit).
testflight_lint_message() {
  local source_label="$1"
  local message="$2"
  local status=0
  local topic note seen_topics="" line

  while IFS= read -r line; do
    testflight_split_note_line "$line"
    topic="$_tf_topic"
    note="$_tf_note"
    [[ -n "$note" ]] || continue
    if [[ -n "$topic" ]] && printf '%s\n' "$seen_topics" | grep -Fxq -- "$topic"; then
      echo "error: $source_label: more than one [$topic] note; rewrite the single complete summary" >&2
      status=1
    fi
    if [[ -n "$topic" ]]; then
      seen_topics="${seen_topics}${topic}
"
    fi
    testflight_lint_extracted_note "$source_label" "$topic" "$note" || status=1
  done < <(printf '%s\n' "$message" | testflight_extract_notes)

  return "$status"
}
