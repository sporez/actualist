#!/usr/bin/env bash
# Produces actualist-export.zip, the committed input of direction B: Actualist's own exporter
# run on a fresh import of actual-export.zip. Runs one Swift test through scripts/test.sh
# (the test does nothing unless the flag below is set), then copies the ZIP into the fixture
# folder. Afterwards run generate.mjs so Actual reads the new ZIP. See README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROOT/.artifacts/portable-archive-parity"
FIXTURE_DIR="$ROOT/$(node "$ROOT/scripts/parity/lib/oracle-pin.mjs" fixtureDirectory)/PortableArchive"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/actualist-export.zip"

cd "$ROOT"
ACTUALIST_SCHEME="${ACTUALIST_SCHEME:-Actualist Dev}" \
TEST_RUNNER_ACTUALIST_PRODUCE_PORTABLE_EXPORT=1 \
TEST_RUNNER_ACTUALIST_PORTABLE_EXPORT_OUTPUT="$OUT_DIR/actualist-export.zip" \
  scripts/test.sh unit 'PortableArchiveOracleReplayTests/produceActualistExport()'

[ -s "$OUT_DIR/actualist-export.zip" ] || { echo "no export was written" >&2; exit 1; }
cp "$OUT_DIR/actualist-export.zip" "$FIXTURE_DIR/actualist-export.zip"
echo "Wrote $FIXTURE_DIR/actualist-export.zip; run generate.mjs next."
