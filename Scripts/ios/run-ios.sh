#!/bin/zsh
#
# Build, install, launch and focus the iOS app in the Simulator.
#
# This is the development loop: one command that ends with the app running on
# screen.
#
# Usage:
#   Scripts/ios/run-ios.sh              build if needed, then run
#   Scripts/ios/run-ios.sh --rebuild    always rebuild first
#   Scripts/ios/run-ios.sh --game FILE  copy FILE into the app before launching
#
# Notes on running the app on the Mac itself:
#
#   Mac Catalyst would build this app natively for macOS, but Xcode does not
#   offer a Catalyst destination for the framework schemes this depends on.
#   Enabling it means changing how the SDK, OpenEmuKit and OpenEmuShaders
#   declare their supported platforms, which would put the working macOS and
#   iOS builds at risk. The Simulator runs the same binary natively on Apple
#   Silicon, so that is the loop for now.

set -euo pipefail

cd "${0:A:h}/../.."
setopt NULL_GLOB 2>/dev/null || true

BUNDLE_ID=org.openemu.OpenEmu
APP="build/ios-derived-simulator/Build/Products/Debug-iphonesimulator/OpenEmu.app"
DEVICE_NAME="OE-iPhone-17"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"

REBUILD=0
GAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift ;;
    --game) GAME="$2"; shift 2 ;;
    *) print -u2 -- "unknown option: $1"; exit 1 ;;
  esac
done

# --- Simulator ------------------------------------------------------------

if ! xcrun simctl list devices | grep -q "$DEVICE_NAME"; then
  print -- "creating simulator $DEVICE_NAME"
  xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME" >/dev/null
fi

DEVICE_ID=$(xcrun simctl list devices available \
  | sed -n "s/.*$DEVICE_NAME (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1)

if [[ -z "$DEVICE_ID" ]]; then
  print -u2 -- "error: could not find the simulator"
  exit 1
fi

if ! xcrun simctl list devices | grep -q "$DEVICE_ID) (Booted)"; then
  print -- "booting $DEVICE_NAME"
  xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
fi
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null 2>&1 || true

# Show the window so the app is actually visible.
open -a Simulator

# --- Build ----------------------------------------------------------------

if [[ $REBUILD -eq 1 || ! -d "$APP" ]]; then
  print -- "building..."
  ./Scripts/ios/build-ios.sh
fi

# --- Install and run ------------------------------------------------------

xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
print -- "installing..."
xcrun simctl install "$DEVICE_ID" "$APP"

CONTAINER=$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)
mkdir -p "$CONTAINER/Documents"

if [[ -n "$GAME" ]]; then
  [[ -f "$GAME" ]] || { print -u2 -- "error: no such file: $GAME"; exit 1; }
  print -- "copying $(basename "$GAME")"
  cp "$GAME" "$CONTAINER/Documents/"
fi

if ! ls "$CONTAINER/Documents"/*.gb(N) "$CONTAINER/Documents"/*.gbc(N) >/dev/null 2>&1; then
  print -- "no game found; adding the demo ROM"
  python3 Scripts/ios/make-demo-rom.py "$CONTAINER/Documents/openemu-demo.gb" >/dev/null
fi

print -- "launching..."
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" >/dev/null

print -- ""
print -- "running. the app is in the Simulator window."
print -- "press Control-Command-Z to send the Simulator a shake, or use the"
print -- "Simulator's Device menu to rotate."
