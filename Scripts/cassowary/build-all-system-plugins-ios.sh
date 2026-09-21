#!/bin/zsh
#
# Build every system plugin for iOS.
#
# System plugins are small bundles that describe a console: its controls, its
# file types, and the responder that turns HID events into button presses.
# Each one is built by Scripts/cassowary/build-system-plugin-ios.sh; this loops over
# every directory in OpenEmu/SystemPlugins and reports a summary.
#
# Usage:
#   Scripts/cassowary/build-all-system-plugins-ios.sh [--device | --catalyst] [--keep-going] [--quiet]

set -euo pipefail
setopt NULL_GLOB 2>/dev/null || true

cd "${0:A:h}/../.."

MODE=simulator
KEEP_GOING=0
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --device)   MODE=device ;;
    --catalyst) MODE=catalyst ;;
    --keep-going) KEEP_GOING=1 ;;
    --quiet) QUIET=1 ;;
    *) print -u2 -- "unknown option: $arg"; exit 1 ;;
  esac
done

case "$MODE" in
  simulator) MODE_FLAG="" ;;
  device)    MODE_FLAG="--device" ;;
  catalyst)  MODE_FLAG="--catalyst" ;;
esac

built=0
failed=()
skipped=()

for plugin_dir in OpenEmu/SystemPlugins/*/; do
  plugin="${plugin_dir%/}"
  plugin="${plugin##*/}"
  [[ -d "$plugin_dir" ]] || continue

  if output=$(./Scripts/cassowary/build-system-plugin-ios.sh "$plugin" ${MODE_FLAG} 2>&1); then
    built=$((built + 1))
    [[ $QUIET -eq 0 ]] && print -- "ok  $plugin"
  else
    # A plugin with no compilable sources is skipped, not failed.
    if print -- "$output" | grep -qiE "no sources|nothing to build|no such"; then
      skipped+=("$plugin")
      [[ $QUIET -eq 0 ]] && print -- "skip $plugin (no sources)"
    else
      failed+=("$plugin")
      print -u2 -- "### $plugin"
      # grep exits 1 when the output has no "error:" line; under
      # `set -euo pipefail` that would kill the loop, so tolerate it.
      print -u2 -- "$output" | grep -E "error:" | head -3 || true
      if [[ $KEEP_GOING -eq 0 ]]; then
        print -u2 -- ""
        print -u2 -- "stopping at the first failure; pass --keep-going to build everything"
        exit 1
      fi
    fi
  fi
done

print -- ""
print -- "system plugins: built $built, skipped ${#skipped[@]}, failed ${#failed[@]}"
if [[ ${#failed[@]} -gt 0 ]]; then
  print -- ""
  print -- "plugins that did not build:"
  for plugin in "${failed[@]}"; do
    print -- "  $plugin"
  done
  exit 1
fi
