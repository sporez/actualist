#!/usr/bin/env bash
# App UI is SwiftUI only (AGENTS.md, Development Defaults). The one allowed
# UIKit view is the transaction share sheet: only UIActivityViewController
# lets an app hand Messages a finished link preview.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWED="Actualist/Features/Transactions/TransactionShareSheet.swift"
PATTERN='UIViewRepresentable|UIViewControllerRepresentable|UIHostingController|UIActivityViewController'

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required for the UIKit view lint but was not found on PATH." >&2
  exit 2
fi

rc=0
matches="$(cd "$ROOT_DIR" && rg --line-number --glob '*.swift' --glob "!${ALLOWED}" -e "$PATTERN" Actualist ActualistWidget)" || rc=$?
case "$rc" in
  0)
    echo "$matches"
    cat >&2 <<MSG

UIKit view lint failed.

App UI is SwiftUI only. The single allowed UIKit view is ${ALLOWED}.
Use a SwiftUI API instead, or get an explicit exception recorded in AGENTS.md.
MSG
    exit 1
    ;;
  1) echo "ok: UIKit views only in ${ALLOWED}" ;;
  *) echo "error: rg failed with exit ${rc}" >&2; exit 2 ;;
esac
