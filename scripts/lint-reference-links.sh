#!/usr/bin/env bash
# Reference doc link lint. Archiving a plan into reference/plans/done/ changes
# its relative depth; outgoing relative links silently break (see
# reference/mistakes.md, "Archiving a plan changes its relative evidence
# paths"). reference/ is fully gitignored, so git-based touch detection does
# not work here; scans the whole tree instead.
#
# - reference-internal links (targets that resolve inside reference/) must
#   exist: wrong-plan-relative-depth is the recurring defect.
# - links pointing outside reference/ (docs/, .artifacts/, Actualist/) only
#   warn when missing: they can legitimately reference temporary or removed
#   evidence, including historical archive links kept as record.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

status=0
broken_internal=0
missing_external=0
checked_links=0

[[ -d reference ]] || { echo "skip: no reference/ directory"; exit 0; }

while IFS= read -r md; do
  dir="$(dirname "$md")"
  # Extract markdown link targets: ](target) and ](target#fragment).
  # Links containing spaces are skipped by the whitespace terminator, same as
  # the extractor used in prior audits.
  while IFS= read -r target; do
    target="${target%%#*}"
    [[ -z "$target" ]] && continue
    case "$target" in
      http://*|https://*|mailto:*|/*) continue ;;
    esac
    checked_links=$((checked_links + 1))
    resolved="$dir/$target"
    if [[ -e "$resolved" ]]; then
      continue
    fi
    # Normalize ./ segments for the reference-internal classification.
    norm="$(python3 -c 'import os,sys; print(os.path.normpath(sys.argv[1]))' "$resolved")"
    if [[ "$norm" == reference/* ]]; then
      echo "error: $md -> $target (missing, resolves inside reference/)"
      broken_internal=$((broken_internal + 1))
      status=1
    else
      echo "warning: $md -> $target (missing; left as historical evidence)"
      missing_external=$((missing_external + 1))
    fi
  done < <(grep -oE '\]\([^)#[:space:]]+(#[^)]*)?\)' "$md" | sed 's/^](\(.*\))$/\1/' || true)
done < <(find reference -type f -name '*.md' | sort)

echo "Checked $checked_links links across reference/:" \
  "$broken_internal broken internal, $missing_external missing external."

exit "$status"
