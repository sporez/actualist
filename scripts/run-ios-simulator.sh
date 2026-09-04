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
RESET_APP="${RESET_APP:-0}"
ENTER_DEMO="${ENTER_DEMO:-0}"
SCREEN_NAME="${SCREEN_NAME:-}"
LAUNCH_WAIT_SECONDS="${LAUNCH_WAIT_SECONDS:-}"

DESTINATION="platform=iOS Simulator,id=${SIMULATOR_ID}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-iphonesimulator/${SCHEME}.app"

usage() {
  cat <<'EOF'
Usage: scripts/run-ios-simulator.sh [options]

Build, install into the UDID-pinned simulator, and launch the app.

Options:
  --boot              Boot the pinned simulator if none is booted.
  --demo              Launch into the bundled demo budget (onboarding only).
  --screen PATH       Open a screen after launch. Slash paths are allowed
                      (settings/appearance). Unique settings pages also work
                      as shorthand (appearance, privacy, connection).
  --reset             Uninstall first so demo starts from a clean onboarding.
  --screenshot        Capture a screenshot after the settle delay.
  --settle SECONDS    Wait after launch before screenshot (default 3, 5 with --demo).
  --no-launch         Build and install without launching.
  -h, --help          Show this help.

Environment overrides:
  PROJECT, SCHEME, CONFIGURATION, SIMULATOR_ID, SIMULATOR_NAME, BUNDLE_ID,
  DERIVED_DATA_PATH, SCREENSHOT_DIR, LAUNCH_WAIT_SECONDS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot)
      BOOT_IF_NEEDED=1
      ;;
    --demo)
      ENTER_DEMO=1
      ;;
    --screen)
      SCREEN_NAME="${2:-}"
      [[ -n "$SCREEN_NAME" ]] || { echo "error: --screen requires a name" >&2; exit 2; }
      shift
      ;;
    --reset)
      RESET_APP=1
      ;;
    --screenshot)
      CAPTURE_SCREENSHOT=1
      ;;
    --settle)
      LAUNCH_WAIT_SECONDS="${2:-}"
      [[ -n "$LAUNCH_WAIT_SECONDS" ]] || { echo "error: --settle requires seconds" >&2; exit 2; }
      shift
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

if [[ -z "$LAUNCH_WAIT_SECONDS" ]]; then
  if [[ "$ENTER_DEMO" == "1" ]]; then
    LAUNCH_WAIT_SECONDS=5
  else
    LAUNCH_WAIT_SECONDS=3
  fi
fi

echo "Building ${SCHEME} for ${DESTINATION}"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

if ! xcrun simctl list devices booted | grep -Fq "${SIMULATOR_ID}"; then
  if [[ "${BOOT_IF_NEEDED}" == "1" ]]; then
    echo "Booting ${SIMULATOR_NAME} (${SIMULATOR_ID})"
    xcrun simctl boot "${SIMULATOR_ID}" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "${SIMULATOR_ID}" -b
  else
    echo "The pinned simulator is not booted. Start it in Simulator, or rerun with --boot." >&2
    exit 1
  fi
fi

if [[ "${RESET_APP}" == "1" ]]; then
  echo "Uninstalling ${BUNDLE_ID}"
  xcrun simctl uninstall "${SIMULATOR_ID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
fi

echo "Installing ${APP_PATH}"
xcrun simctl install "${SIMULATOR_ID}" "${APP_PATH}"

if [[ "${LAUNCH_APP}" == "1" ]]; then
  xcrun simctl terminate "${SIMULATOR_ID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
  launch_args=()
  if [[ "${ENTER_DEMO}" == "1" ]]; then
    launch_args+=(-actualist-demo)
  fi
  if [[ -n "${SCREEN_NAME}" ]]; then
    launch_args+=(-actualist-screen "${SCREEN_NAME}")
  fi
  echo "Launching ${BUNDLE_ID} ${launch_args[*]:-}"
  xcrun simctl launch "${SIMULATOR_ID}" "${BUNDLE_ID}" "${launch_args[@]+"${launch_args[@]}"}"
fi

if [[ "${CAPTURE_SCREENSHOT}" == "1" ]]; then
  mkdir -p "${SCREENSHOT_DIR}"
  sleep "${LAUNCH_WAIT_SECONDS}"
  screen_slug="${SCREEN_NAME:-app}"
  screen_slug="${screen_slug//\//-}"
  SCREENSHOT_PATH="${SCREENSHOT_DIR}/actualist-${screen_slug}-$(date +%Y%m%d-%H%M%S).png"
  echo "Capturing ${SCREENSHOT_PATH}"
  xcrun simctl io "${SIMULATOR_ID}" screenshot "${SCREENSHOT_PATH}"
  echo "Done: ${SCREENSHOT_PATH}"
else
  echo "Done."
fi
