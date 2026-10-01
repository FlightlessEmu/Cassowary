#!/bin/bash
#
# Checks that the NES Mic button reaches the game, in both NES cores.
#
# Builds a test ROM whose screen is white while the Famicom microphone is
# heard (make-nes-mic-rom.py), then, with Nestopia and then FCEU, launches it
# once as is and once with Mic held, and compares how bright the screen is.
# Uses the app the last simulator build made.
#
# Usage:
#   Scripts/cassowary/check-nes-microphone.sh [--device-id <simulator udid>]
#
# The simulator is the tests' own, Cassowary-Test-Phone, unless --device-id
# names another.
#
# The simulator's games are moved aside while it runs and put back after.
# A microphone prompt left unanswered on that simulator (by a DS check, say)
# can come back over the game and spoil the result; erase the simulator if
# the screenshots show one.
# Exit status is 0 when both cores passed.

set -uo pipefail
cd "$(dirname "$0")/../.."

if [[ ${1:-} == --device-id && -n ${2:-} ]]; then
  DEVICE=$2
elif [[ $# -eq 0 ]]; then
  NAME=Cassowary-Test-Phone
  xcrun simctl list devices | grep -qF "$NAME (" ||
    xcrun simctl create "$NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17 >/dev/null
  DEVICE=$(xcrun simctl list devices available | sed -n "s/^ *$NAME (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1)
  xcrun simctl boot "$DEVICE" 2>/dev/null
  xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1
else
  echo "usage: $0 [--device-id <udid>]" >&2; exit 2
fi
BUNDLE=org.cassowary.Cassowary
APP=build/cassowary-simulator/app/Build/Products/Debug-iphonesimulator/Cassowary.app
SHOTS=build/nes-microphone-check
mkdir -p "$SHOTS"

python3 Scripts/cassowary/make-nes-mic-rom.py "$SHOTS/mic-test.nes"
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null
xcrun simctl install "$DEVICE" "$APP" || exit 1
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
STASH="$CONTAINER/Documents/.nes-mic-check-stash"
mkdir -p "$STASH"
for f in "$CONTAINER/Documents"/*; do [[ -f $f ]] && mv "$f" "$STASH/"; done
cp "$SHOTS/mic-test.nes" "$CONTAINER/Documents/"

restore() {
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null
  rm -f "$CONTAINER/Documents/mic-test.nes"
  mv "$STASH"/* "$CONTAINER/Documents/" 2>/dev/null
  rmdir "$STASH" 2>/dev/null
  xcrun simctl spawn "$DEVICE" defaults delete "$BUNDLE" defaultCore.openemu.system.nes 2>/dev/null
}
trap restore EXIT

brightness() { # label core [launch arguments...]
  local label=$1 core=$2; shift 2
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null; sleep 2
  xcrun simctl spawn "$DEVICE" defaults write "$BUNDLE" defaultCore.openemu.system.nes "$core"
  xcrun simctl launch "$DEVICE" "$BUNDLE" -cassowary.autoPlayFirstGame YES "$@" >/dev/null
  sleep 14
  xcrun simctl io "$DEVICE" screenshot "$SHOTS/$label.png" >/dev/null 2>&1
  python3 Scripts/cassowary/screenshot-brightness.py "$SHOTS/$label.png"
}

failed=0
for core in org.openemu.Nestopia org.openemu.FCEU; do
  name=${core##*.}
  idle=$(brightness "$name-idle" "$core")
  held=$(brightness "$name-mic" "$core" -cassowary.testHoldButton OENESButtonMicrophone)
  if python3 -c "import sys; sys.exit(0 if float('$held') - float('$idle') > 100 else 1)"; then
    echo "PASS  $name hears the Mic button (brightness $idle -> $held)"
  else
    echo "FAIL  $name did not hear the Mic button (brightness $idle -> $held; see $SHOTS)"
    failed=1
  fi
done
exit $failed
