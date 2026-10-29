# Copy to destinations.sh (gitignored) and fill in ids for this machine.
#
#   cp scripts/lib/destinations.example.sh scripts/lib/destinations.sh
#
# List simulators:  xcrun simctl list devices available
# List devices:     xcrun devicectl list devices
#
# scripts/lib/simulator.sh resolves the simulator from ACTUALIST_SIMULATOR_ID
# (optional pin) or from name, device type and runtime, and creates it when it
# is missing. Leave any of them empty to use its defaults. Xcode always gets
# a UDID, never a display name. Do not commit destinations.sh.

: "${ACTUALIST_SIMULATOR_ID:=}"
: "${ACTUALIST_SIMULATOR_NAME:=iPhone 17 Pro}"
: "${ACTUALIST_SIMULATOR_DEVICE_TYPE:=}"
: "${ACTUALIST_SIMULATOR_RUNTIME:=}"
: "${ACTUALIST_DEVICE_UDID:=}"
: "${ACTUALIST_DEVICE_COREDEVICE_ID:=}"
: "${ACTUALIST_BUNDLE_ID:=com.sporez.actualist}"

actualist_simulator_destination() {
  printf 'platform=iOS Simulator,id=%s' "$ACTUALIST_SIMULATOR_ID"
}

actualist_device_destination() {
  printf 'platform=iOS,id=%s' "$ACTUALIST_DEVICE_UDID"
}
