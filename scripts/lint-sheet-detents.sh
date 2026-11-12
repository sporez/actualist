#!/usr/bin/env bash
# Sheet detents go through the helpers in Actualist/DesignSystem/ReviewSheetForm.swift
# (reviewSheetPresentation, reviewSheetDetents, toolbarlessSheetDetents). They force
# `.large` at accessibility text sizes and handle iPhone Duo's vertical bar
# (AGENTS.md, Sheets And iPhone Duo). A direct `.presentationDetents(` call is
# allowed only in DesignSystem/ and in the EXCEPTIONS below, whose sizing
# would change through the helper.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATTERN='\.presentationDetents\('

# Each entry needs a reason: the exact difference the helper would introduce.
EXCEPTIONS=(
  # [.medium, .large]: the helper forces [.large] at accessibility sizes and
  # disables the Duo vertical bar for a sheet that can sit below full height.
  "Actualist/Features/Transactions/TransactionCategorySelectionView.swift"
)

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required for the sheet detents lint but was not found on PATH." >&2
  exit 2
fi

globs=(--glob '*.swift' --glob '!Actualist/DesignSystem/**')
for path in "${EXCEPTIONS[@]}"; do
  globs+=(--glob "!${path}")
done

rc=0
matches="$(cd "$ROOT_DIR" && rg --line-number "${globs[@]}" -e "$PATTERN" Actualist)" || rc=$?
case "$rc" in
  0)
    echo "$matches"
    cat >&2 <<MSG

Sheet detents lint failed.

Set detents with reviewSheetPresentation(detents:appState:), reviewSheetDetents
or toolbarlessSheetDetents (Actualist/DesignSystem/ReviewSheetForm.swift). If the
helper would change the sheet's Duo or accessibility sizing, add the file to
EXCEPTIONS in scripts/lint-sheet-detents.sh with the reason.
MSG
    exit 1
    ;;
  1) echo "ok: direct presentationDetents only in DesignSystem and the listed exceptions" ;;
  *) echo "error: rg failed with exit ${rc}" >&2; exit 2 ;;
esac
