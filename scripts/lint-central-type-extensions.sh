#!/usr/bin/env bash
# BudgetDatabase and LocalFirstActualStore must not gain extension files
# (AGENTS.md, File Size And Structural Maintainability). The existing files are
# listed in config/structure/central-type-extensions.txt. A new
# BudgetDatabase+X.swift or LocalFirstActualStore+X.swift fails, and so does a
# listed file that no longer exists, so the list only shrinks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="config/structure/central-type-extensions.txt"

if [[ ! -f "$ROOT_DIR/$LIST" ]]; then
  echo "error: $LIST is missing." >&2
  exit 2
fi

current="$(cd "$ROOT_DIR" && find Actualist \( -name 'BudgetDatabase+*.swift' -o -name 'LocalFirstActualStore+*.swift' \) | LC_ALL=C sort)"
allowed="$(grep -v '^[[:space:]]*#' "$ROOT_DIR/$LIST" | grep -v '^[[:space:]]*$' | LC_ALL=C sort)"

new_files="$(LC_ALL=C comm -23 <(printf '%s\n' "$current") <(printf '%s\n' "$allowed") | grep -v '^$' || true)"
stale_entries="$(LC_ALL=C comm -13 <(printf '%s\n' "$current") <(printf '%s\n' "$allowed") | grep -v '^$' || true)"

status=0
if [[ -n "$new_files" ]]; then
  echo "$new_files"
  cat >&2 <<MSG

Central-type extension lint failed: new extension file(s) above.

Another BudgetDatabase+X.swift or LocalFirstActualStore+X.swift is not an
extraction. Put the domain's logic in a focused type that keeps its helpers
private (for the database, a stateless type taking the GRDB handle), with a
thin entry point on the central type. See AGENTS.md, File Size And Structural
Maintainability.
MSG
  status=1
fi

if [[ -n "$stale_entries" ]]; then
  echo "$stale_entries"
  cat >&2 <<MSG

Central-type extension lint failed: the file(s) above are listed in $LIST
but no longer exist. Remove their lines so the list keeps shrinking.
MSG
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  count="$(printf '%s\n' "$allowed" | grep -c . || true)"
  echo "ok: no new central-type extension files ($count listed)"
fi
exit "$status"
