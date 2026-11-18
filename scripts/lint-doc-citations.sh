#!/usr/bin/env bash
# Code citations in docs (AGENTS.md, Duplication And Complexity Discipline).
# Every `Name.swift` a guidance doc names must exist somewhere in the
# repository, so a commit that deletes or renames a file also fixes the docs
# that cite it. Checked: tracked Markdown (except third-party notices),
# config/parity/known-divergences.json, and, when the private reference/ folder
# is present, its undated top-level notes (the living checklists). Dated
# audits and plans are records of their time and are not checked.
# A `+Name.swift` shorthand matches any file ending in it.
# Skipped tokens: globs and placeholders (`*Presentation.swift`,
# `<Type>+<Name>.swift`, `BudgetDatabase+X.swift`), lowercase argument
# placeholders (`[target.swift]`) and names in fixtures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

known="$(git ls-files '*.swift' | awk -F/ '{print $NF}' | LC_ALL=C sort -u)"

docs=()
while IFS= read -r doc; do
  docs+=("$doc")
done < <(git ls-files '*.md' | grep -v -E '(^|/)THIRD_PARTY_NOTICES\.md$|/Fixtures/|/fixtures/')
docs+=("config/parity/known-divergences.json")
for private_doc in reference/*.md; do
  [[ -f "$private_doc" ]] || continue
  [[ "$(basename "$private_doc")" =~ [0-9]{4}-[0-9]{2} ]] && continue
  docs+=("$private_doc")
done

status=0
checked=0
for doc in "${docs[@]}"; do
  [[ -f "$doc" ]] || continue
  # Whole tokens, so a glob or placeholder keeps its `*`, `<`, `...` or `+X`.
  while IFS=: read -r line token; do
    case "$token" in
      *'*'*|*'<'*|*'>'*|*'...'*|*'…'*|*+X.swift|X.swift) continue ;;
    esac
    name="${token##*/}"
    # A lowercase name is a command-line placeholder (`[target.swift]`).
    [[ "$name" =~ ^[a-z] ]] && continue
    checked=$((checked + 1))
    if [[ "$name" == +* ]]; then
      grep -qF -- "$name" <<<"$known" && continue
    else
      grep -qxF -- "$name" <<<"$known" && continue
    fi
    echo "error: $doc:$line cites $token, which no longer exists. Name the current type and member instead." >&2
    status=1
  done < <(rg -n -o -e '[A-Za-z0-9_./*<>…+-]*[A-Za-z0-9_*>]\.swift\b' "$doc" || true)
done

if [[ "$status" -eq 0 ]]; then
  echo "ok: $checked file citations in ${#docs[@]} docs name existing files"
fi
exit "$status"
