#!/usr/bin/env bash
# Concurrency escape-hatch lint (concurrency remediation decision D18).
#
# Flags the constructs that switch off or sidestep compiler-enforced
# concurrency checking or cancellation, unless the author states why each
# use is safe:
#   @unchecked Sendable, nonisolated(unsafe), Task.detached,
#   and `try? await Task.sleep` (it swallows cancellation).
#
# Scope: Swift files under Actualist/ and ActualistWidget/. Test targets
# (ActualistTests/, ActualistUITests/) are exempt.
#
# A match passes only with an adjacent invariant comment, defined precisely as:
#   - the matching line itself contains `// Invariant:` (a trailing comment), or
#   - the block of contiguous comment lines (each starting with `//` or `///`
#     after optional whitespace) that ends on the line immediately above the
#     matching line contains a line beginning `// Invariant:` or
#     `/// Invariant:`. A blank line or any code line ends the block.
# Matches that sit on a comment line themselves are ignored.
#
# Violations print `path:line: message` and the script exits 1.
#
# ACTUALIST_LINT_ROOT overrides the repository root (used by harness checks).
set -euo pipefail

ROOT_DIR="${ACTUALIST_LINT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required for the concurrency escape-hatch lint but was not found on PATH." >&2
  exit 2
fi

SOURCE_DIRS=()
for dir in Actualist ActualistWidget; do
  [[ -d "${ROOT_DIR}/${dir}" ]] && SOURCE_DIRS+=("${ROOT_DIR}/${dir}")
done
if [[ "${#SOURCE_DIRS[@]}" -eq 0 ]]; then
  echo "error: no Actualist/ or ActualistWidget/ directory under ${ROOT_DIR}." >&2
  exit 2
fi

PATTERN='@unchecked[[:space:]]+Sendable|nonisolated\(unsafe\)|Task\.detached|try\?[[:space:]]+await[[:space:]]+Task\.sleep'

# rg exits 0 with candidates, 1 with none, 2 on error.
rc=0
files="$(rg --files-with-matches --glob '*.swift' -e "${PATTERN}" "${SOURCE_DIRS[@]}")" || rc=$?
case "${rc}" in
  0) ;;
  1) echo "Concurrency escape-hatch lint passed."; exit 0 ;;
  *) echo "error: rg failed with exit ${rc} while scanning for escape hatches." >&2; exit 2 ;;
esac

violations="$(
  printf '%s\n' "${files}" | sort | while IFS= read -r file; do
    awk -v file="${file#"${ROOT_DIR}"/}" '
      function kind(line) {
        if (line ~ /@unchecked[ \t]+Sendable/) return "@unchecked Sendable"
        if (line ~ /nonisolated\(unsafe\)/) return "nonisolated(unsafe)"
        if (line ~ /Task\.detached/) return "Task.detached"
        if (line ~ /try\?[ \t]+await[ \t]+Task\.sleep/) return "try? await Task.sleep"
        return ""
      }
      /^[ \t]*\/\// {
        if ($0 ~ /^[ \t]*\/\/\/?[ \t]*Invariant:/) documented = 1
        next
      }
      {
        k = kind($0)
        if (k != "" && !documented && $0 !~ /\/\/[ \t]*Invariant:/) {
          printf "%s:%d: %s needs an adjacent `// Invariant:` comment explaining why it is safe\n", file, NR, k
        }
        documented = 0
      }
    ' "${ROOT_DIR}/${file#"${ROOT_DIR}"/}"
  done
)"

if [[ -n "${violations}" ]]; then
  printf '%s\n' "${violations}" >&2
  cat >&2 <<'EOF2'

Concurrency escape-hatch lint failed.

@unchecked Sendable, nonisolated(unsafe), Task.detached and `try? await Task.sleep`
need a `// Invariant:` comment on the same line or in the comment block directly
above, stating the real protection (actor confinement, a lock, immutability,
single-shot use, a delivery queue) or why a swallowed cancellation is safe.
Prefer removing the escape hatch: use `do { try await Task.sleep(...) } catch { return }`.
EOF2
  exit 1
fi

echo "Concurrency escape-hatch lint passed."
