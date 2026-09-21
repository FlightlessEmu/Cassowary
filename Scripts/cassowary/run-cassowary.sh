#!/bin/zsh
#
# Build, install, launch and focus the iOS app in the Simulator.
#
# This is the development loop: one command that ends with the app running on
# screen.
#
# Usage:
#   Scripts/cassowary/run-cassowary.sh              build if needed, then run
#   Scripts/cassowary/run-cassowary.sh --rebuild    always rebuild first
#   Scripts/cassowary/run-cassowary.sh --game FILE  copy FILE into the app before launching
#   Scripts/cassowary/run-cassowary.sh --device     install and launch on a real iPhone
#   Scripts/cassowary/run-cassowary.sh --udid UDID  the iPhone to use, with --device
#   Scripts/cassowary/run-cassowary.sh --catalyst   run on the Mac (Mac Catalyst)
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

BUNDLE_ID=org.cassowary.Cassowary
APP="build/cassowary-simulator/app/Build/Products/Debug-iphonesimulator/Cassowary.app"
DEVICE_NAME="Cassowary-iPhone-17"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"

REBUILD=0
GAME=""
TARGET_MODE=simulator
DEVICE_UDID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift ;;
    --device) TARGET_MODE=device; shift ;;
    --udid) DEVICE_UDID=${2:?--udid needs a device UDID}; shift 2 ;;
    --catalyst) TARGET_MODE=catalyst; shift ;;
    --game) GAME="$2"; shift 2 ;;
    *) print -u2 -- "unknown option: $1"; exit 1 ;;
  esac
done

# --- A real iPhone --------------------------------------------------------
#
# The app is built, installed and launched with devicectl. This works over
# USB and over Wi-Fi: pair the phone once with a cable, tick "Connect via
# network" in Xcode's Devices and Simulators window, and the same commands
# keep working with the cable unplugged.
if [[ "$TARGET_MODE" == device ]]; then
  APP="build/cassowary-device/app/Build/Products/Debug-iphoneos/Cassowary.app"

  # One connected phone is the common case; with more than one, ask.
  if [[ -z "$DEVICE_UDID" ]]; then
    UDIDS=()
    while read -r udid; do
      if [[ -n "$udid" ]]; then
        UDIDS+=("$udid")
      fi
    done < <(xcrun devicectl list devices \
      --hide-default-columns --columns udid --hide-headers 2>/dev/null || true)

    if [[ ${#UDIDS[@]} -eq 0 ]]; then
      print -u2 -- "error: no iPhone found."
      print -u2 -- "Connect it, tap Trust, and turn on Settings → Privacy & Security"
      print -u2 -- "→ Developer Mode (iOS 16 and later), then run this again."
      exit 1
    fi
    if [[ ${#UDIDS[@]} -gt 1 ]]; then
      xcrun devicectl list devices
      print -u2 -- ""
      print -u2 -- "error: more than one device; pass --udid <UDID>"
      exit 1
    fi
    DEVICE_UDID="${UDIDS[1]}"
  fi

  if [[ $REBUILD -eq 1 || ! -d "$APP" ]]; then
    print -- "building for the iPhone..."
    ./Scripts/cassowary/build-cassowary.sh --device --udid "$DEVICE_UDID"
  fi
  [[ -d "$APP" ]] || { print -u2 -- "error: $APP was not built"; exit 1; }

  print -- "installing..."
  xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"

  if [[ -n "$GAME" ]]; then
    [[ -f "$GAME" ]] || { print -u2 -- "error: no such file: $GAME"; exit 1; }
    print -- "copying $(basename "$GAME")"
    xcrun devicectl device copy to \
      --device "$DEVICE_UDID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "$GAME" --destination Documents/
  else
    print -- "no game passed; add one with --game FILE, or in Finder"
    print -- "(the app shares its Documents folder over file sharing)."
  fi

  print -- "launching..."
  xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" >/dev/null

  print -- ""
  print -- "running. The app is on the iPhone."
  exit 0
fi

# --- Mac Catalyst ---------------------------------------------------------
#
# Catalyst runs the same iOS app natively on the Mac. It is the quicker loop:
# no Simulator to boot, and the window is a normal macOS window. The app is
# built with the catalyst SDK and lives in its own build directory.
if [[ "$TARGET_MODE" == catalyst ]]; then
  APP="build/cassowary-catalyst/app/Build/Products/Debug-maccatalyst/Cassowary.app"

  if [[ $REBUILD -eq 1 || ! -d "$APP" ]]; then
    print -- "building for Mac Catalyst..."
    ./Scripts/cassowary/build-cassowary.sh --catalyst
  fi

  [[ -d "$APP" ]] || { print -u2 -- "error: $APP was not built"; exit 1; }

  # The games directory is the app's own container, the same place the
  # Simulator build keeps its documents.
  CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data/Documents"
  mkdir -p "$CONTAINER"

  if [[ -n "$GAME" ]]; then
    [[ -f "$GAME" ]] || { print -u2 -- "error: no such file: $GAME"; exit 1; }
    print -- "copying $(basename "$GAME")"
    cp "$GAME" "$CONTAINER/"
  fi

  if ! ls "$CONTAINER"/*.gb(N) "$CONTAINER"/*.gbc(N) >/dev/null 2>&1; then
    print -- "no game found; adding the demo ROM"
    python3 Scripts/cassowary/make-demo-rom.py "$CONTAINER/cassowary-demo.gb" >/dev/null
  fi

  print -- "launching..."
  open "$APP"
  print -- ""
  print -- "running. the app is a normal window on the Mac."
  exit 0
fi

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
  ./Scripts/cassowary/build-cassowary.sh
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
  python3 Scripts/cassowary/make-demo-rom.py "$CONTAINER/Documents/cassowary-demo.gb" >/dev/null
fi

print -- "launching..."
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" >/dev/null

print -- ""
print -- "running. the app is in the Simulator window."
print -- "press Control-Command-Z to send the Simulator a shake, or use the"
print -- "Simulator's Device menu to rotate."
