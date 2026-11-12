#!/usr/bin/env bash
# The Actual server auth header is written in one place so a client cannot send
# the token on a request that skipped the same-origin check (AGENTS.md,
# Canonical Owners: Server requests and auth header).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWED="Actualist/LocalFirst/Network/ActualServerRequestBuilder.swift"
PATTERN='X-ACTUAL-TOKEN'

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required for the server token header lint but was not found on PATH." >&2
  exit 2
fi

rc=0
matches="$(cd "$ROOT_DIR" && rg --line-number --glob '*.swift' --glob "!${ALLOWED}" -e "$PATTERN" Actualist)" || rc=$?
case "$rc" in
  0)
    echo "$matches"
    cat >&2 <<MSG

Server token header lint failed.

Only ${ALLOWED} may write X-ACTUAL-TOKEN.
Build the request with ActualServerRequestBuilder.makeRequest(token:) instead.
MSG
    exit 1
    ;;
  1) echo "ok: X-ACTUAL-TOKEN only in ${ALLOWED}" ;;
  *) echo "error: rg failed with exit ${rc}" >&2; exit 2 ;;
esac
