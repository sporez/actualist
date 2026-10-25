# Resolves the test simulator from its specification. Simulators are
# disposable: when the pinned or previously created one is gone, this creates
# a new one with the same name, device type and runtime. Source it after
# load-destinations.sh.
#
#   ACTUALIST_SIMULATOR_ID           optional pin, used while it is available
#   ACTUALIST_SIMULATOR_NAME         name of the simulator the spec creates
#   ACTUALIST_SIMULATOR_DEVICE_TYPE  simctl device type identifier
#   ACTUALIST_SIMULATOR_RUNTIME      simctl runtime identifier
#
# The resolved simulator still reaches xcodebuild by UDID: a name-only
# destination can match a duplicate and hang xcodebuild for minutes.

: "${ACTUALIST_SIMULATOR_NAME:=iPhone 17 Pro}"
: "${ACTUALIST_SIMULATOR_DEVICE_TYPE:=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
: "${ACTUALIST_SIMULATOR_RUNTIME:=com.apple.CoreSimulator.SimRuntime.iOS-26-3}"

# Prints "<state> <udid>": pinned, found, create (no udid), no-runtime or
# unsupported-device.
_actualist_find_simulator() {
  xcrun simctl list --json | python3 -I -c '
import json, sys
pin, name, device_type, runtime = sys.argv[1:5]
data = json.load(sys.stdin)
devices = [
    dict(device, runtime=runtime_id)
    for runtime_id, entries in data.get("devices", {}).items()
    for device in entries
    if device.get("isAvailable")
]
if pin and any(device["udid"] == pin for device in devices):
    print("pinned", pin)
    sys.exit()
matches = sorted(
    device["udid"] for device in devices
    if device.get("name") == name
    and device.get("deviceTypeIdentifier") == device_type
    and device["runtime"] == runtime
)
if matches:
    print("found", matches[0])
    sys.exit()
runtimes = [
    entry for entry in data.get("runtimes", [])
    if entry.get("identifier") == runtime and entry.get("isAvailable")
]
if not runtimes:
    print("no-runtime")
elif not any(t.get("identifier") == device_type for t in runtimes[0].get("supportedDeviceTypes", [])):
    print("unsupported-device")
else:
    print("create")
' "${ACTUALIST_SIMULATOR_ID:-}" "$ACTUALIST_SIMULATOR_NAME" \
    "$ACTUALIST_SIMULATOR_DEVICE_TYPE" "$ACTUALIST_SIMULATOR_RUNTIME"
}

# Usage: actualist_resolve_simulator [--no-create]
# Sets ACTUALIST_SIMULATOR_ID and reports the choice on stderr. With
# --no-create (dry runs), a simulator that would be created leaves the ID
# empty. Returns 1 when no simulator matching the spec can exist.
actualist_resolve_simulator() {
  local create=1 result state udid
  [[ "${1:-}" != --no-create ]] || create=0
  local spec="$ACTUALIST_SIMULATOR_NAME ($ACTUALIST_SIMULATOR_DEVICE_TYPE, $ACTUALIST_SIMULATOR_RUNTIME)"

  result="$(_actualist_find_simulator)" || {
    echo "error: could not list simulators with xcrun simctl" >&2
    return 1
  }
  state="${result%% *}"
  udid=""
  [[ "$result" != *" "* ]] || udid="${result#* }"

  if [[ -n "${ACTUALIST_SIMULATOR_ID:-}" && "$state" != pinned ]]; then
    echo "note: pinned simulator $ACTUALIST_SIMULATOR_ID is gone; using the spec $spec" >&2
  fi

  case "$state" in
    pinned|found)
      ACTUALIST_SIMULATOR_ID="$udid"
      echo "Simulator: $ACTUALIST_SIMULATOR_ID ($state)" >&2
      ;;
    create)
      ACTUALIST_SIMULATOR_ID=""
      if [[ "$create" -eq 0 ]]; then
        echo "Simulator: none matches $spec; a real run creates it" >&2
        return 0
      fi
      ACTUALIST_SIMULATOR_ID="$(xcrun simctl create "$ACTUALIST_SIMULATOR_NAME" \
        "$ACTUALIST_SIMULATOR_DEVICE_TYPE" "$ACTUALIST_SIMULATOR_RUNTIME")" || {
        echo "error: could not create simulator $spec" >&2
        return 1
      }
      echo "Simulator: created $ACTUALIST_SIMULATOR_ID for $spec" >&2
      ;;
    no-runtime)
      echo "error: simulator runtime $ACTUALIST_SIMULATOR_RUNTIME is not installed." >&2
      echo "error: install it in Xcode > Settings > Components, or set ACTUALIST_SIMULATOR_RUNTIME (xcrun simctl list runtimes)" >&2
      return 1
      ;;
    unsupported-device)
      echo "error: runtime $ACTUALIST_SIMULATOR_RUNTIME does not support $ACTUALIST_SIMULATOR_DEVICE_TYPE (xcrun simctl list devicetypes)" >&2
      return 1
      ;;
    *)
      echo "error: unexpected simulator lookup result: $result" >&2
      return 1
      ;;
  esac
  export ACTUALIST_SIMULATOR_ID
}
