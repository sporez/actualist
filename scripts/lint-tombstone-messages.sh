#!/usr/bin/env bash
# A delete mark is one sync message: the `tombstone` column set to a boolean.
# LocalFirstSyncMessageBuilder.tombstone and .revive build it, so the column
# name and the value encoding exist once. A hand-written message elsewhere
# can drift from them, for example by writing an integer instead of a boolean.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWED="Actualist/LocalFirst/Sync/LocalFirstSyncMessageBuilder.swift"
PATTERN='column:\s*"tombstone"'

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required for the tombstone message lint but was not found on PATH." >&2
  exit 2
fi

rc=0
matches="$(cd "$ROOT_DIR" && rg --line-number --glob '*.swift' --glob "!${ALLOWED}" -e "$PATTERN" Actualist)" || rc=$?
case "$rc" in
  0)
    echo "$matches"
    cat >&2 <<MSG

Tombstone message lint failed.

Build delete marks with LocalFirstSyncMessageBuilder.tombstone(dataset:row:)
and revive(dataset:row:), both in ${ALLOWED}.
MSG
    exit 1
    ;;
  1) echo "ok: tombstone messages are built only in ${ALLOWED}" ;;
  *) echo "error: rg failed with exit ${rc}" >&2; exit 2 ;;
esac
