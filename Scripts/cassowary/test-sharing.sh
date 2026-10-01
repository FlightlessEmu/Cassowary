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
# It runs on simulators of its own, Cassowary-Test-Phone and Cassowary-Test-TV,
# created the first time; CASSOWARY_TEST_PHONE and CASSOWARY_TEST_TV name
# others. The phone's game folder is emptied first, so name spare ones. CASSOWARY_TEST_DIRECT=1 has the TV connect
# to the phone by address instead of finding it with Bonjour, for when the
# Mac's own name resolution is misbehaving (it is shared by the simulators).
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

# The simulators are shared by every worktree on this Mac, so a game left in
# one by other work can change what the test sees. Set these to run on a
# simulator of your own; it is created if it does not exist.
PHONE_NAME="${CASSOWARY_TEST_PHONE:-Cassowary-Test-Phone}"
PHONE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
PHONE_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
TV_NAME="${CASSOWARY_TEST_TV:-Cassowary-Test-TV}"
TV_TYPE="com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p"
TV_RUNTIME="com.apple.CoreSimulator.SimRuntime.tvOS-26-5"
PORT=8765
# How the Apple TV finds the phone: Bonjour, as a person's would, or straight
# to its address.
TV_FIND=(-cassowary.tvAutoConnectFirstHost YES)
if [[ "${CASSOWARY_TEST_DIRECT:-0}" == 1 ]]; then
  TV_FIND=(-cassowary.tvHostAddress "127.0.0.1:$PORT")
fi
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
  # Matched whole: Cassowary-TV is not Cassowary-TV-closecheck.
  if ! xcrun simctl list devices | grep -qF "$name ("; then
    print -u2 -- "creating simulator $name"
    xcrun simctl create "$name" "$type" "$runtime" >/dev/null
  fi
  local udid
  udid=$(xcrun simctl list devices available | sed -n "s/^ *$name (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1)
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
# Not the TV's own demo: the Apple TV ships that game, so it would already
# have it and never copy anything down. The generated input ROM with the time
# stamped into its last padding bytes is a game no device has yet — a new one
# every run, so a TV that downloaded the last one still has something to
# fetch — and it still boots.
python3 Scripts/cassowary/make-test-rom.py "$SHOTS/shared-base.gb" >/dev/null
python3 -c '
import sys, time
data = bytearray(open(sys.argv[1], "rb").read())
data[-8:] = int(time.time() * 1000).to_bytes(8, "big")
open(sys.argv[2], "wb").write(data)' "$SHOTS/shared-base.gb" "$SHOTS/SharedDemo.gb"
# Only this game: anything else left here (another test's game, last run's
# saves under the same name) changes what the TV picks and finds.
rm -rf "$CONTAINER/Documents/"*
cp "$SHOTS/SharedDemo.gb" "$CONTAINER/Documents/SharedDemo.gb"

# Sharing on, the Allow prompt skipped, and a pinned port so curl can find it.
# The app has to stay in front: iOS stops serving when it is put away, which
# is exactly what the design says.
launch_phone() {
  xcrun simctl launch "$PHONE_UDID" org.cassowary.Cassowary \
    -cassowary.sharing.enabled YES \
    -cassowary.sharing.trustAll YES \
    -cassowary.sharing.deviceName "Cassowary Test Phone" \
    -cassowary.sharing.port "$PORT" \
    -cassowary.testRetroAchievementsSignIn off >/dev/null
}

print -- "launching the phone..."
launch_phone

# Wait for the server to answer instead of guessing a delay: the app needs a
# moment to bring it up, and the Simulator can be slow right after a build.
for _ in {1..60}; do
  if curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/v1/info"; then
    break
  fi
  sleep 1
done

if [[ "$MODE" == tv ]]; then
  print -- "phone ready"
else
  echo "== server checks"

  INFO=$(curl -s -m 10 -H "X-Cassowary-Protocol: 2" "http://127.0.0.1:$PORT/v1/info")
  if [[ "$INFO" == *'"protocolVersion":2'* ]]; then
    pass "info answers with protocol 2"
  else
    fail "info did not answer: $INFO"
    print -- ""; print -- "checks failed:"; for f in "${failures[@]}"; do print -- "  $f"; done; exit 1
  fi

  TOKEN=$(curl -s -m 10 -X POST -H "X-Cassowary-Protocol: 2" -H "Content-Type: application/json" \
    -d '{"deviceID":"sharing-test-tv","deviceName":"Test TV","platformName":"tvos"}' \
    "http://127.0.0.1:$PORT/v1/pair" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token") or "")')
  if [[ -n "$TOKEN" ]]; then
    pass "pairing returned a token"
  else
    fail "pairing returned no token"
  fi

  LIB=$(curl -s -m 10 -H "X-Cassowary-Protocol: 2" -H "X-Cassowary-Token: $TOKEN" \
    "http://127.0.0.1:$PORT/v1/library")
  # Pick the demo this script copied in, not merely the first game: the phone
  # simulator is shared with test-cassowary.sh, which leaves its own ROM in
  # the same folder, and the checks below compare bytes and saves by identity.
  GAME_ID=$(print -- "$LIB" | python3 -c '
import sys, json
games = json.load(sys.stdin).get("games", [])
mine = [g for g in games
        if "SharedDemo" in (g.get("fileName") or "") or "SharedDemo" in (g.get("title") or "")]
print((mine or games)[0]["id"] if games else "")')
  GAME_COUNT=$(print -- "$LIB" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["games"]))')

  if [[ "$GAME_COUNT" -ge 1 ]]; then
    pass "library lists $GAME_COUNT game(s)"
  else
    fail "library is empty"
  fi

  if [[ -n "$GAME_ID" ]]; then
    curl -s -m 20 -H "X-Cassowary-Protocol: 2" -H "X-Cassowary-Token: $TOKEN" \
      -H "Range: bytes=0-999" -o "$SHOTS/part1.bin" "http://127.0.0.1:$PORT/v1/games/$GAME_ID/file/0"
    curl -s -m 20 -H "X-Cassowary-Protocol: 2" -H "X-Cassowary-Token: $TOKEN" \
      -H "Range: bytes=1000-" -o "$SHOTS/part2.bin" "http://127.0.0.1:$PORT/v1/games/$GAME_ID/file/0"
    cat "$SHOTS/part1.bin" "$SHOTS/part2.bin" > "$SHOTS/rejoined.gb"

    if [[ "$(shasum -a 256 "$SHOTS/SharedDemo.gb" | awk '{print $1}')" \
       == "$(shasum -a 256 "$SHOTS/rejoined.gb" | awk '{print $1}')" ]]; then
      pass "ranged download rejoins to the original bytes"
    else
      fail "ranged download did not match"
    fi

    printf 'sharing test save state' > "$SHOTS/test.oesavestate"
    PUT=$(curl -s -m 10 -X PUT -H "X-Cassowary-Protocol: 2" -H "X-Cassowary-Token: $TOKEN" \
      --data-binary @"$SHOTS/test.oesavestate" "http://127.0.0.1:$PORT/v1/saves/$GAME_ID/state")
    if [[ "$PUT" == *'"stored":true'* ]]; then
      pass "a save state uploads"
    else
      fail "save state upload answered: $PUT"
    fi

    BACK=$(curl -s -m 10 -H "X-Cassowary-Protocol: 2" -H "X-Cassowary-Token: $TOKEN" \
      "http://127.0.0.1:$PORT/v1/saves/$GAME_ID/state")
    if [[ "$BACK" == "sharing test save state" ]]; then
      pass "the save state reads back unchanged"
    else
      fail "save state read back as: $BACK"
    fi

    # A deletion from another device removes the save and is remembered as a
    # deletion, so the next sync does not bring the save back.
    DEL=$(curl -s -m 10 -X DELETE -H "X-Cassowary-Protocol: 2" -H "X-Cassowary-Token: $TOKEN" \
      -H "X-Cassowary-Version: 1000" "http://127.0.0.1:$PORT/v1/saves/$GAME_ID/state")
    GONE=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "X-Cassowary-Protocol: 2" \
      -H "X-Cassowary-Token: $TOKEN" "http://127.0.0.1:$PORT/v1/saves/$GAME_ID/state")
    LISTED=$(curl -s -m 10 -H "X-Cassowary-Protocol: 2" -H "X-Cassowary-Token: $TOKEN" \
      "http://127.0.0.1:$PORT/v1/saves/index" | GAME_ID="$GAME_ID" python3 -c '
import json, os, sys
blobs = json.load(sys.stdin).get("blobs", [])
print(any(b["gameID"] == os.environ["GAME_ID"] and b["kind"] == "state" and b.get("deleted") for b in blobs))')
    if [[ "$DEL" == *'"stored":true'* && "$GONE" == 404 && "$LISTED" == True ]]; then
      pass "a deleted save is gone and listed as deleted"
    else
      fail "deleting a save: answer $DEL, then $GONE, listed as deleted: $LISTED"
    fi
  fi

  # The sign-in only goes to a TV when the phone's Share With Apple TV is on,
  # and it is off unless someone turns it on.
  RA_STATUS=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "X-Cassowary-Protocol: 2" \
    -H "X-Cassowary-Token: $TOKEN" "http://127.0.0.1:$PORT/v1/retroachievements")
  if [[ "$RA_STATUS" == 404 ]]; then
    pass "the RetroAchievements sign-in is not shared unless switched on"
  else
    fail "the RetroAchievements sign-in answered $RA_STATUS without sharing switched on"
  fi
fi

# --- The Apple TV ---------------------------------------------------------

if [[ "$MODE" != host ]]; then
  print -- "building the Apple TV app..."
  if [[ $SKIP_BUILD -eq 0 ]]; then
    # Through the build script, not xcodebuild directly: it keeps each mode's
    # frameworks and plugins staged apart, so a phone or device build that ran
    # last cannot leave the wrong binaries behind for this one.
    ./Scripts/cassowary/build-cassowary.sh --tvos-sim --app-only >/dev/null
  fi

  TV_UDID=$(simulator_udid "$TV_NAME" "$TV_TYPE" "$TV_RUNTIME")
  print -- "apple tv simulator: $TV_UDID"

  xcrun simctl terminate "$TV_UDID" org.cassowary.CassowaryTV 2>/dev/null || true
  # A TV Settings left open by an earlier run would sit in front of the game.
  xcrun simctl terminate "$TV_UDID" com.apple.TVSettings 2>/dev/null || true
  xcrun simctl install "$TV_UDID" "$TV_APP"

  # The phone may have been put away while the TV app was being built.
  launch_phone
  sleep 1

  # Only files written from here on count as a download: a used simulator
  # keeps games copied down by earlier runs.
  touch "$SHOTS/tv-start"

  print -- "launching the Apple TV app..."
  xcrun simctl launch "$TV_UDID" org.cassowary.CassowaryTV \
    "${TV_FIND[@]}" \
    -cassowary.autoPlayFirstGame YES \
    -cassowary.sharing.deviceName "Cassowary Test Apple TV" \
    -cassowary.testHoldButton OEGBButtonA,OEGBButtonRight >/dev/null

  print -- "waiting for the Apple TV to download a game (up to 120s)..."
  TV_CONTAINER=$(xcrun simctl get_app_container "$TV_UDID" org.cassowary.CassowaryTV data)
  downloaded=0
  for _ in {1..60}; do
    MEDIA=$(find "$TV_CONTAINER/Library/Caches/Media" -type f -newer "$SHOTS/tv-start" 2>/dev/null || true)
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

  # Only a fresh autosave counts: an earlier run may have left one here.
  touch "$SHOTS/tv-background"
  if xcrun simctl launch "$TV_UDID" com.apple.TVSettings >/dev/null; then
    sleep 5
    AUTOSAVES=$(find "$TV_CONTAINER/Library/Application Support/Sharing/Saves" \
      -type f -name '*.autosave.oesavestate' -newer "$SHOTS/tv-background" 2>/dev/null || true)
    if [[ -n "$AUTOSAVES" ]]; then
      pass "backgrounding the Apple TV filed an autosave in its save vault"
    else
      fail "backgrounding the Apple TV left no fresh autosave in its save vault"
    fi
  else
    fail "could not launch TV Settings to check background autosaving"
  fi
  # Settings would otherwise stay in front of the TV app, here and in the
  # next run.
  xcrun simctl terminate "$TV_UDID" com.apple.TVSettings 2>/dev/null || true

  # A slot deleted on the TV is deleted on the phone too. The TV saves into
  # Slot 1, sends it, then deletes it; the phone can only record a deletion
  # of a save it had, so its record proves the slot arrived and then went.
  DELETE_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  xcrun simctl terminate "$TV_UDID" org.cassowary.CassowaryTV 2>/dev/null || true
  xcrun simctl launch "$TV_UDID" org.cassowary.CassowaryTV \
    "${TV_FIND[@]}" \
    -cassowary.autoPlayFirstGame YES \
    -cassowary.testDeleteSlot YES >/dev/null
  deleted=False
  for _ in {1..20}; do
    sleep 2
    deleted=$(DELETE_START="$DELETE_START" python3 -c '
import json, os, sys
try:
    records = json.load(open(sys.argv[1]))
except Exception:
    print(False); sys.exit()
start = os.environ["DELETE_START"]
print(any(key.endswith("|state:slot-1") and record.get("deleted") and record["modifiedAt"] >= start
          for key, record in records.items()))' "$CONTAINER/Library/Application Support/Sharing/saves.json")
    [[ "$deleted" == True ]] && break
  done
  LEFT=$(find "$CONTAINER/Documents" -name '*.slot-1.oesavestate' -newermt "$DELETE_START" 2>/dev/null || true)
  if [[ "$deleted" == True && -z "$LEFT" ]]; then
    pass "a slot deleted on the Apple TV is deleted on the phone"
  else
    fail "a slot deleted on the Apple TV is still on the phone (recorded as deleted: $deleted)"
  fi

  print -- ""
  print -- "screenshots in $SHOTS"
fi

# Leave nothing advertising. A Simulator shares the Mac's Wi-Fi, so a phone
# Simulator left serving shows up in a real Apple TV's Sources list — where
# the name "Cassowary Test Phone" makes clear it is not the owner's phone.
xcrun simctl terminate "$PHONE_UDID" org.cassowary.Cassowary 2>/dev/null || true
if [[ -n "${TV_UDID:-}" ]]; then
  xcrun simctl terminate "$TV_UDID" org.cassowary.CassowaryTV 2>/dev/null || true
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
