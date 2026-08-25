# Source local destinations.sh when present; otherwise the public example.
# scripts/lib/destinations.sh is gitignored and may contain device UDIDs.

_actualist_destinations_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_actualist_destinations_dir/destinations.sh" ]]; then
  # shellcheck source=destinations.sh
  source "$_actualist_destinations_dir/destinations.sh"
elif [[ -f "$_actualist_destinations_dir/destinations.example.sh" ]]; then
  # shellcheck source=destinations.example.sh
  source "$_actualist_destinations_dir/destinations.example.sh"
fi
unset _actualist_destinations_dir
