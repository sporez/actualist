#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIRS=(
  "${ROOT_DIR}/Actualist"
  "${ROOT_DIR}/ActualistWidget"
)

DISALLOWED_PATTERNS=(
  "\\.regularMaterial"
  "\\.thinMaterial"
  "\\.ultraThinMaterial"
  "\\.ultraThickMaterial"
  "\\.thickMaterial"
  "UIBlurEffect"
  "VisualEffectBlur"
  "GlassEffectContainer"
  "FloatingTabBar"
  "\\.buttonStyle\\(\\.glass\\(\\.clear\\)\\)"
)

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required for the Liquid Glass lint but was not found on PATH." >&2
  exit 2
fi

status=0

for pattern in "${DISALLOWED_PATTERNS[@]}"; do
  # rg exits 0 on a match (violation), 1 on no match (clean), 2 on error.
  rc=0
  rg --line-number --glob '*.swift' "${pattern}" "${SOURCE_DIRS[@]}" || rc=$?
  case "${rc}" in
    0) status=1 ;;
    1) ;;
    *)
      echo "error: rg failed with exit ${rc} while checking pattern ${pattern}" >&2
      exit 2
      ;;
  esac
done

if [[ "${status}" -ne 0 ]]; then
  cat >&2 <<'EOF'

Liquid Glass lint failed.

Use public iOS 26 SwiftUI Liquid Glass APIs for glass-like UI:
- .buttonStyle(.glass)
- .buttonStyle(.glassProminent)
- .buttonStyle(.glass(...))
- .glassEffect(_:in:)

Do not use Material or blur effects to fake Liquid Glass.
Do not use GlassEffectContainer until it is re-tested on a physical device.
Do not build a custom FloatingTabBar; use native TabView with .tabItem.
Do not use .buttonStyle(.glass(.clear)); it creates nested glass chrome in toolbars and custom bars.
EOF
  exit "${status}"
fi

echo "Liquid Glass lint passed."
