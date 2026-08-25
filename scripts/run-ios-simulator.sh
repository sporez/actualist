#!/usr/bin/env bash
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/load-destinations.sh
source "$_script_dir/lib/load-destinations.sh"

PROJECT="${PROJECT:-Actualist.xcodeproj}"
SCHEME="${SCHEME:-Actualist}"
CONFIGURATION="${CONFIGURATION:-Debug}"
SIMULATOR_ID="${SIMULATOR_ID:-${ACTUALIST_SIMULATOR_ID:-}}"
SIMULATOR_NAME="${SIMULATOR_NAME:-${ACTUALIST_SIMULATOR_NAME:-iPhone 17 Pro}}"
BUNDLE_ID="${BUNDLE_ID:-${ACTUALIST_BUNDLE_ID:-com.sporez.actualist}}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.derivedData}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-.artifacts/screenshots}"
BOOT_IF_NEEDED="${BOOT_IF_NEEDED:-0}"
CAPTURE_SCREENSHOT="${CAPTURE_SCREENSHOT:-0}"
LAUNCH_APP="${LAUNCH_APP:-1}"

DESTINATION="platform=iOS Simulator,id=${SIMULATOR_ID}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-iphonesimulator/${SCHEME}.app"

usage() {
  cat <<'EOF'
Usage: scripts/run-ios-simulator.sh [options]

Fast default:
  Build, install into the already-booted simulator, and launch the app.

Options:
  --boot          Boot SIMULATOR_NAME if no simulator is already booted.
  --screenshot    Capture a screenshot after launch.
  --no-launch     Build and install without launching the app.
  -h, --help      Show this help.

Environment overrides:
  PROJECT, SCHEME, CONFIGURATION, SIMULATOR_ID, SIMULATOR_NAME, BUNDLE_ID,
  DERIVED_DATA_PATH, SCREENSHOT_DIR, BOOT_IF_NEEDED, CAPTURE_SCREENSHOT,
  LAUNCH_APP, LAUNCH_WAIT_SECONDS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot)
      BOOT_IF_NEEDED=1
      ;;
    --screenshot)
      CAPTURE_SCREENSHOT=1
      ;;
    --no-launch)
      LAUNCH_APP=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "${SIMULATOR_ID}" ]]; then
  echo "error: set ACTUALIST_SIMULATOR_ID, or copy scripts/lib/destinations.example.sh to scripts/lib/destinations.sh" >&2
  exit 2
fi

echo "Building ${SCHEME} for ${DESTINATION}"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

if ! xcrun simctl list devices booted | grep -q "(Booted)"; then
  if [[ "${BOOT_IF_NEEDED}" == "1" ]]; then
    echo "Booting ${SIMULATOR_NAME} (${SIMULATOR_ID})"
    xcrun simctl boot "${SIMULATOR_ID}" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "${SIMULATOR_ID}" -b
  else
    echo "No simulator is booted. Start one in Simulator, or rerun with --boot." >&2
    exit 1
  fi
fi

echo "Installing ${APP_PATH}"
xcrun simctl install booted "${APP_PATH}"

if [[ "${LAUNCH_APP}" == "1" ]]; then
  echo "Launching ${BUNDLE_ID}"
  xcrun simctl launch booted "${BUNDLE_ID}"
fi

if [[ "${CAPTURE_SCREENSHOT}" == "1" ]]; then
  mkdir -p "${SCREENSHOT_DIR}"
  sleep "${LAUNCH_WAIT_SECONDS:-2}"
  SCREENSHOT_PATH="${SCREENSHOT_DIR}/actualist-$(date +%Y%m%d-%H%M%S).png"
  echo "Capturing ${SCREENSHOT_PATH}"
  xcrun simctl io booted screenshot "${SCREENSHOT_PATH}"
  echo "Done: ${SCREENSHOT_PATH}"
else
  echo "Done."
fi
