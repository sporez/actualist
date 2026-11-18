#!/usr/bin/env bash
# Structure ownership lint (AGENTS.md, Domain Ownership And Central Types).
# Each check compares the tree with a tracked list in config/structure/ that
# only shrinks:
#   1. Members on BudgetDatabase and LocalFirstActualStore, per file
#      (central-type-members.txt).
#   2. <Type>+<Name>.swift files for types the app declares
#      (type-extension-files.txt).
#   3. LocalFirstActualStore adopting a repository protocol (never allowed).
#   4. Repository requirements with a protocol-extension default
#      (repository-requirement-defaults.txt).
#   5. Listed size exceptions at their recorded length
#      (large-file-exceptions.txt).
# The Swift scanning is text-level (scripts/lib/swift_structure.py).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIG="config/structure"
SCANNER="scripts/lib/swift_structure.py"
status=0

entries() {
  grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' | LC_ALL=C sort || true
}

fail() {
  echo "error: $*" >&2
  status=1
}

for list in central-type-members.txt type-extension-files.txt \
  repository-requirement-defaults.txt large-file-exceptions.txt; do
  if [[ ! -f "$CONFIG/$list" ]]; then
    echo "error: $CONFIG/$list is missing." >&2
    exit 2
  fi
done

# 1. Central-type members.
members="$(python3 -I "$SCANNER" members BudgetDatabase LocalFirstActualStore | awk '{print $2, $3}' | LC_ALL=C sort)"
recorded="$(entries "$CONFIG/central-type-members.txt")"
while read -r path count; do
  [[ -z "$path" ]] && continue
  baseline="$(awk -v p="$path" '$1 == p {print $2}' <<<"$recorded")"
  if [[ -z "$baseline" ]]; then
    fail "$path declares $count member(s) on BudgetDatabase or LocalFirstActualStore and is not in $CONFIG/central-type-members.txt. Put domain code in a <Concept>SQL type or a <Domain>Workflows collaborator."
  elif (( count > baseline )); then
    fail "$path has $count members on a central type; $CONFIG/central-type-members.txt allows $baseline. Domain members go in a <Concept>SQL type or a <Domain>Workflows collaborator, never on BudgetDatabase or LocalFirstActualStore."
  elif (( count < baseline )); then
    fail "$path now has $count members on a central type, fewer than the $baseline recorded. Lower its number in $CONFIG/central-type-members.txt to $count in this commit."
  fi
done <<<"$members"
while read -r path baseline; do
  [[ -z "$path" ]] && continue
  if ! awk -v p="$path" '$1 == p {found = 1} END {exit !found}' <<<"$members"; then
    fail "$CONFIG/central-type-members.txt lists $path, which no longer declares central-type members. Remove its line."
  fi
done <<<"$recorded"

# 2. +X files on app-declared types. The central types have their own lint.
declared_types="$(rg --no-filename -o -e '\b(class|struct|enum|actor|protocol)\s+[A-Z]\w*' -g '*.swift' Actualist ActualistWidget \
  | awk '{print $2}' | LC_ALL=C sort -u)"
plus_files="$(find Actualist ActualistWidget -name '*+*.swift' \
  ! -name 'BudgetDatabase+*' ! -name 'LocalFirstActualStore+*' | LC_ALL=C sort)"
allowed_plus="$(entries "$CONFIG/type-extension-files.txt")"
while read -r path; do
  [[ -z "$path" ]] && continue
  type_name="$(basename "$path")"
  type_name="${type_name%%+*}"
  grep -qx -- "$type_name" <<<"$declared_types" || continue
  if ! grep -qx -- "$path" <<<"$allowed_plus"; then
    fail "$path adds members to $type_name, which the app declares, in a +X file. Split along a responsibility into a new type with its own private helpers."
  fi
done <<<"$plus_files"
while read -r path; do
  [[ -z "$path" ]] && continue
  [[ -f "$path" ]] || fail "$CONFIG/type-extension-files.txt lists $path, which no longer exists. Remove its line."
done <<<"$allowed_plus"

# 3. The store adopts no repository protocol.
conformances="$(python3 -I "$SCANNER" store-conformances)"
if [[ -n "$conformances" ]]; then
  while read -r proto path; do
    fail "$path makes LocalFirstActualStore conform to $proto. Each repository protocol has one <Domain>Workflows conformer; the store conforms to none."
  done <<<"$conformances"
fi

# 4. Repository requirement defaults.
defaults="$(python3 -I "$SCANNER" requirement-defaults)"
allowed_defaults="$(entries "$CONFIG/repository-requirement-defaults.txt")"
while read -r key path; do
  [[ -z "$key" ]] && continue
  if ! grep -qxF -- "$key" <<<"$allowed_defaults"; then
    fail "$path gives the requirement $key a protocol-extension default. A missing or drifted witness would silently run it; give every conformer a witness instead."
  fi
done <<<"$defaults"
while read -r key; do
  [[ -z "$key" ]] && continue
  if ! awk -v k="$key" '$1 == k {found = 1} END {exit !found}' <<<"$defaults"; then
    fail "$CONFIG/repository-requirement-defaults.txt lists $key, which no longer has a default. Remove its line."
  fi
done <<<"$allowed_defaults"

# 5. Size exceptions stay at their recorded length.
while read -r path cap; do
  [[ -z "$path" ]] && continue
  if [[ ! -f "$path" ]]; then
    fail "$CONFIG/large-file-exceptions.txt lists $path, which no longer exists. Remove its entry."
    continue
  fi
  if [[ ! "$cap" =~ ^[0-9]+$ ]]; then
    fail "$CONFIG/large-file-exceptions.txt: $path needs its current line count after the path."
    continue
  fi
  lines="$(wc -l < "$path" | tr -d ' ')"
  if (( lines > cap )); then
    fail "$path is $lines lines; its size exception is frozen at $cap. Move code out instead of adding to it."
  elif (( lines < 1000 )); then
    fail "$path is $lines lines, below 1,000. Remove its entry from $CONFIG/large-file-exceptions.txt."
  elif (( lines < cap )); then
    fail "$path shrank to $lines lines. Lower its number in $CONFIG/large-file-exceptions.txt to $lines in this commit."
  fi
done < <(entries "$CONFIG/large-file-exceptions.txt")

if [[ "$status" -eq 0 ]]; then
  member_total="$(awk '{sum += $2} END {print sum + 0}' <<<"$members")"
  default_count="$(grep -c . <<<"$allowed_defaults" || true)"
  plus_count="$(grep -c . <<<"$allowed_plus" || true)"
  echo "ok: $member_total central-type members as recorded, $plus_count listed +X files, no store repository conformance, $default_count listed requirement defaults, size exceptions at their recorded length"
fi
exit "$status"
