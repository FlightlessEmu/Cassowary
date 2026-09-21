#!/bin/zsh
#
# Build, install and boot a game in the iOS Simulator, then check the result.
#
# This is the end-to-end test for the iOS port. It:
#
#   1. builds a Game Boy test ROM whose screen colour reflects whether the A
#      button is held
#   2. builds and installs the app
#   3. copies the ROM into the app's Documents folder
#   4. launches the app with the first game auto-booting
#   5. screenshots, then repeats with A held, with the key the plugin binds to
#      A held, and with the gamepad button it binds to A held
#   6. checks that the screenshots differ, which proves input reached the
#      emulator — through the touch, keyboard and controller paths — and that
#      the video pipeline is live
#
# Usage:
#   Scripts/cassowary/test-cassowary.sh [--device-id <udid>] [--skip-build]

set -euo pipefail

cd "${0:A:h}/../.."
setopt NULL_GLOB 2>/dev/null || true

BUNDLE_ID=org.cassowary.Cassowary
DEVICE_ID=""
SKIP_BUILD=0
APP="build/cassowary-simulator/app/Build/Products/Debug-iphonesimulator/Cassowary.app"
SHOTS="build/cassowary-test-shots"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-id) DEVICE_ID="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    *) print -u2 -- "unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID=$(xcrun simctl list devices available \
    | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' \
    | head -1)
  if [[ -z "$DEVICE_ID" ]]; then
    print -u2 -- "error: no booted simulator; boot one or pass --device-id"
    exit 1
  fi
fi

print -- "using simulator $DEVICE_ID"

if [[ $SKIP_BUILD -eq 0 ]]; then
  print -- "building the app..."
  ./Scripts/cassowary/build-cassowary.sh >/dev/null
fi

if [[ ! -d "$APP" ]]; then
  print -u2 -- "error: no app at $APP"
  exit 1
fi

mkdir -p "$SHOTS"

print -- "building the test ROM..."
python3 Scripts/cassowary/make-test-rom.py "$SHOTS/input-test.gb" >/dev/null

print -- "installing..."
xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP"

CONTAINER=$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)
rm -f "$CONTAINER/Documents/"*.gb
cp "$SHOTS/input-test.gb" "$CONTAINER/Documents/"

# Average brightness of the middle of the screen, which is where the game is.
average_brightness() {
  python3 Scripts/cassowary/screenshot-brightness.py "$1"
}

capture() {
  local label=$1
  local extra=${2:-}

  # Terminate and wait for the process to actually go away. Launching again
  # too soon attaches to the instance that is still shutting down, which
  # silently ignores the launch arguments.
  xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
  for _ in {1..20}; do
    if ! xcrun simctl spawn "$DEVICE_ID" launchctl list 2>/dev/null \
        | grep -q "UIKitApplication:$BUNDLE_ID"; then
      break
    fi
    sleep 0.5
  done
  sleep 1

  # ${=extra} forces word splitting. zsh does not split unquoted parameters
  # the way bash does, so without it the two arguments arrive as one string
  # and the app never sees the second one.
  xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" \
    -cassowary.autoPlayFirstGame YES ${=extra} >/dev/null

  # The app takes a moment to launch, boot the core and hold the button.
  sleep 16
  xcrun simctl io "$DEVICE_ID" screenshot "$SHOTS/$label.png" >/dev/null 2>&1
}

print -- "capturing idle screen..."
capture idle

print -- "capturing screen with A held..."
capture held "-cassowary.testHoldButton OEGBButtonA"

# The key the Game Boy plugin binds to A, pressed through the keyboard path,
# and the gamepad button it binds to A, pressed through the device path. A
# hardware keyboard or controller cannot be attached to the Simulator from a
# script, so the app presses the bound input itself; the mapping, the session
# and the core are the real ones.
print -- "capturing screen with the key bound to A held..."
capture keyboard "-cassowary.testKeyboardButton OEGBButtonA"

print -- "capturing screen with the gamepad button bound to A held..."
capture gamepad "-cassowary.testGamepadUsage 1"

IDLE=$(average_brightness "$SHOTS/idle.png")
HELD=$(average_brightness "$SHOTS/held.png")
KEYBOARD=$(average_brightness "$SHOTS/keyboard.png")
GAMEPAD=$(average_brightness "$SHOTS/gamepad.png")

print -- ""
print -- "idle brightness:     $IDLE"
print -- "held brightness:     $HELD"
print -- "keyboard brightness: $KEYBOARD"
print -- "gamepad brightness:  $GAMEPAD"

if [[ "$IDLE" == "$HELD" ]]; then
  print -u2 -- "FAIL: the screen did not change when A was pressed"
  print -u2 -- "      input is not reaching the emulator"
  exit 1
fi

if [[ "$IDLE" == "$KEYBOARD" ]]; then
  print -u2 -- "FAIL: the screen did not change when the key bound to A was pressed"
  print -u2 -- "      keyboard input is not reaching the emulator"
  exit 1
fi

if [[ "$IDLE" == "$GAMEPAD" ]]; then
  print -u2 -- "FAIL: the screen did not change when the gamepad button bound to A was held"
  print -u2 -- "      controller input is not reaching the emulator"
  exit 1
fi

print -- ""
print -- "PASS: the screen changed when A, its keyboard key and its gamepad button were pressed"
print -- "      screenshots in $SHOTS"
