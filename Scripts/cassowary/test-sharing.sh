#!/bin/zsh
#
# End-to-end check of library sharing: one phone serving, one Apple TV
# borrowing.
#
# It starts a phone Simulator with sharing switched on (and the Allow prompt
# skipped), copies the demo Game Boy game into its library, then:
#
#   1. checks the phone's server directly with curl: info, pair, library,
#      a ranged download whose hash has to match, and a save round trip;
#   2. starts the Apple TV Simulator, asks it to connect to the first host it
#      sees, download the first game, and play it;
#   3. takes two screenshots a few seconds apart and checks that the picture
#      changed, which is the proof the game is running and input works.
#
# Usage:
#   Scripts/cassowary/test-sharing.sh            both halves
#   Scripts/cassowary/test-sharing.sh --host     only the phone's server
#   Scripts/cassowary/test-sharing.sh --tv       only the Apple TV half
#   Scripts/cassowary/test-sharing.sh --skip-build
#
# Exit status is 0 when every check passed.

set -euo pipefail
setopt NULL_GLOB 2>/dev/null || true

cd "${0:A:h}/../.."

MODE=all
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --host)       MODE=host ;;
    --tv)         MODE=tv ;;
    --skip-build) SKIP_BUILD=1 ;;
    *) print -u2 -- "unknown option: $arg"; exit 1 ;;
  esac
done

PHONE_NAME="Cassowary-iPhone-17"
PHONE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
PHONE_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
TV_NAME="Cassowary-TV"
TV_TYPE="com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p"
TV_RUNTIME="com.apple.CoreSimulator.SimRuntime.tvOS-26-5"
PORT=8765
SHOTS="build/sharing-test"
mkdir -p "$SHOTS"

PHONE_APP="build/cassowary-simulator/app/Build/Products/Debug-iphonesimulator/Cassowary.app"
TV_APP="build/cassowary-tvos-sim/app/Build/Products/Debug-appletvsimulator/Cassowary.app"

failures=()
pass() { print -- "PASS  $1" }
fail() { print -- "FAIL  $1"; failures+=("$1") }

# The UDID of a simulator, creating and booting it when needed.
simulator_udid() {
  local name=$1 type=$2 runtime=$3
  if ! xcrun simctl list devices | grep -q "$name"; then
    print -- "creating simulator $name"
    xcrun simctl create "$name" "$type" "$runtime" >/dev/null
  fi
  local udid
  udid=$(xcrun simctl list devices available | sed -n "s/.*$name (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1)
  [[ -n "$udid" ]] || { print -u2 -- "error: no simulator named $name"; exit 1; }
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  print -- "$udid"
}

# --- Build ---------------------------------------------------------------

if [[ $SKIP_BUILD -eq 0 ]]; then
  print -- "building the phone app..."
  ./Scripts/cassowary/build-cassowary.sh --app-only >/dev/null
fi

# --- The phone ------------------------------------------------------------

PHONE_UDID=$(simulator_udid "$PHONE_NAME" "$PHONE_TYPE" "$PHONE_RUNTIME")
print -- "phone simulator: $PHONE_UDID"

xcrun simctl terminate "$PHONE_UDID" org.cassowary.Cassowary 2>/dev/null || true
xcrun simctl install "$PHONE_UDID" "$PHONE_APP"

CONTAINER=$(xcrun simctl get_app_container "$PHONE_UDID" org.cassowary.Cassowary data)
mkdir -p "$CONTAINER/Documents"
cp Cassowary/Resources/TV/Demo.gb "$CONTAINER/Documents/SharedDemo.gb"

# Sharing on, the Allow prompt skipped, and a pinned port so curl can find it.
# The app has to stay in front: iOS stops serving when it is put away, which
# is exactly what the design says.
launch_phone() {
  xcrun simctl launch "$PHONE_UDID" org.cassowary.Cassowary \
    -cassowary.sharing.enabled YES \
    -cassowary.sharing.trustAll YES \
    -cassowary.sharing.port "$PORT" >/dev/null
}

print -- "launching the phone..."
launch_phone
sleep 4

if [[ "$MODE" == tv ]]; then
  print -- "phone ready"
else
  echo "== server checks"

  INFO=$(curl -s -m 10 -H "X-Cassowary-Protocol: 1" "http://127.0.0.1:$PORT/v1/info")
  if [[ "$INFO" == *'"protocolVersion":1'* ]]; then
    pass "info answers with protocol 1"
  else
    fail "info did not answer: $INFO"
    print -- ""; print -- "checks failed:"; for f in "${failures[@]}"; do print -- "  $f"; done; exit 1
  fi

  TOKEN=$(curl -s -m 10 -X POST -H "X-Cassowary-Protocol: 1" -H "Content-Type: application/json" \
    -d '{"deviceID":"sharing-test-tv","deviceName":"Test TV","platformName":"tvos"}' \
    "http://127.0.0.1:$PORT/v1/pair" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token") or "")')
  if [[ -n "$TOKEN" ]]; then
    pass "pairing returned a token"
  else
    fail "pairing returned no token"
  fi

  LIB=$(curl -s -m 10 -H "X-Cassowary-Protocol: 1" -H "X-Cassowary-Token: $TOKEN" \
    "http://127.0.0.1:$PORT/v1/library")
  GAME_ID=$(print -- "$LIB" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["games"][0]["id"] if d["games"] else "")')
  GAME_COUNT=$(print -- "$LIB" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["games"]))')

  if [[ "$GAME_COUNT" -ge 1 ]]; then
    pass "library lists $GAME_COUNT game(s)"
  else
    fail "library is empty"
  fi

  if [[ -n "$GAME_ID" ]]; then
    curl -s -m 20 -H "X-Cassowary-Protocol: 1" -H "X-Cassowary-Token: $TOKEN" \
      -H "Range: bytes=0-999" -o "$SHOTS/part1.bin" "http://127.0.0.1:$PORT/v1/games/$GAME_ID/file/0"
    curl -s -m 20 -H "X-Cassowary-Protocol: 1" -H "X-Cassowary-Token: $TOKEN" \
      -H "Range: bytes=1000-" -o "$SHOTS/part2.bin" "http://127.0.0.1:$PORT/v1/games/$GAME_ID/file/0"
    cat "$SHOTS/part1.bin" "$SHOTS/part2.bin" > "$SHOTS/rejoined.gb"

    if [[ "$(shasum -a 256 Cassowary/Resources/TV/Demo.gb | awk '{print $1}')" \
       == "$(shasum -a 256 "$SHOTS/rejoined.gb" | awk '{print $1}')" ]]; then
      pass "ranged download rejoins to the original bytes"
    else
      fail "ranged download did not match"
    fi

    printf 'sharing test save state' > "$SHOTS/test.oesavestate"
    PUT=$(curl -s -m 10 -X PUT -H "X-Cassowary-Protocol: 1" -H "X-Cassowary-Token: $TOKEN" \
      --data-binary @"$SHOTS/test.oesavestate" "http://127.0.0.1:$PORT/v1/saves/$GAME_ID/state")
    if [[ "$PUT" == *'"stored":true'* ]]; then
      pass "a save state uploads"
    else
      fail "save state upload answered: $PUT"
    fi

    BACK=$(curl -s -m 10 -H "X-Cassowary-Protocol: 1" -H "X-Cassowary-Token: $TOKEN" \
      "http://127.0.0.1:$PORT/v1/saves/$GAME_ID/state")
    if [[ "$BACK" == "sharing test save state" ]]; then
      pass "the save state reads back unchanged"
    else
      fail "save state read back as: $BACK"
    fi
  fi
fi

# --- The Apple TV ---------------------------------------------------------

if [[ "$MODE" != host ]]; then
  print -- "building the Apple TV app..."
  if [[ $SKIP_BUILD -eq 0 ]]; then
    xcodegen generate --spec Cassowary/project.yml --project Cassowary >/dev/null
    xcodebuild -project Cassowary/Cassowary.xcodeproj -scheme CassowaryTV -configuration Debug \
      -destination 'generic/platform=tvOS Simulator' -sdk appletvsimulator \
      -derivedDataPath "$PWD/build/cassowary-tvos-sim/app" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
      build >/dev/null
  fi

  TV_UDID=$(simulator_udid "$TV_NAME" "$TV_TYPE" "$TV_RUNTIME")
  print -- "apple tv simulator: $TV_UDID"

  xcrun simctl terminate "$TV_UDID" org.cassowary.CassowaryTV 2>/dev/null || true
  xcrun simctl install "$TV_UDID" "$TV_APP"

  # The phone may have been put away while the TV app was being built.
  launch_phone
  sleep 1

  print -- "launching the Apple TV app..."
  xcrun simctl launch "$TV_UDID" org.cassowary.CassowaryTV \
    -cassowary.tvAutoConnectFirstHost YES \
    -cassowary.autoPlayFirstGame YES \
    -cassowary.testHoldButton OEGBButtonRight >/dev/null

  print -- "waiting for the Apple TV to download a game (up to 120s)..."
  TV_CONTAINER=$(xcrun simctl get_app_container "$TV_UDID" org.cassowary.CassowaryTV data)
  downloaded=0
  for _ in {1..60}; do
    MEDIA=$(find "$TV_CONTAINER/Library/Caches/Media" -type f 2>/dev/null || true)
    if [[ -n "$MEDIA" ]]; then
      downloaded=1
      break
    fi
    sleep 2
  done

  if [[ $downloaded -eq 1 ]]; then
    pass "the Apple TV downloaded a game from the phone"
  else
    fail "the Apple TV downloaded nothing"
  fi

  print -- "checking the game started..."
  # The log is read into a variable first: `grep -q` closes the pipe as soon
  # as it matches, and with zsh's pipefail that turns a match into a failure.
  TV_LOG=$(xcrun simctl spawn "$TV_UDID" log show --last 10m --style compact \
    --predicate 'process == "Cassowary"' 2>/dev/null || true)
  if [[ "$TV_LOG" == *"gamepad bridged"* ]]; then
    pass "the game started on the Apple TV"
  else
    fail "the game never started on the Apple TV"
  fi

  # The TV syncs saves as soon as it connects; the phone logs each merge.
  PHONE_LOG=$(xcrun simctl spawn "$PHONE_UDID" log show --last 10m --style compact \
    --predicate 'process == "Cassowary"' 2>/dev/null || true)
  if [[ "$PHONE_LOG" == *"saves merge with"* ]]; then
    pass "the Apple TV merged saves with the phone"
  else
    fail "no save merge reached the phone"
  fi

  # The game is held for a few seconds a little after it starts, so a picture
  # that changes at any point in this window proves it is not frozen.
  if [[ $downloaded -eq 1 ]]; then
    for i in {1..6}; do
      xcrun simctl io "$TV_UDID" screenshot "$SHOTS/tv-$i.png" >/dev/null 2>&1
      sleep 1.5
    done

    moved=0
    for i in {1..5}; do
      j=$((i + 1))
      if [[ "$(md5 -q "$SHOTS/tv-$i.png")" != "$(md5 -q "$SHOTS/tv-$j.png")" ]]; then
        moved=1
        break
      fi
    done

    if [[ $moved -eq 1 ]]; then
      pass "the picture changed between frames (the game is running)"
    else
      fail "the picture never changed; the game may be frozen"
    fi
  fi

  print -- ""
  print -- "screenshots in $SHOTS"
fi

print -- ""
if [[ ${#failures[@]} -eq 0 ]]; then
  print -- "all checks passed"
  exit 0
fi

print -- "checks failed:"
for f in "${failures[@]}"; do
  print -- "  $f"
done
exit 1
