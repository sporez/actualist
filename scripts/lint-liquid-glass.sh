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

status=0

for pattern in "${DISALLOWED_PATTERNS[@]}"; do
  if rg --line-number --glob '*.swift' "${pattern}" "${SOURCE_DIRS[@]}"; then
    status=1
  fi
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
