#!/bin/zsh
# Check the iPhone's Library swipe navigation without changing its game files.
set -euo pipefail
cd "${0:A:h}/../.."

APP="$PWD/build/cassowary-simulator/app/Build/Products/Debug-iphonesimulator/Cassowary.app"
[[ -d "$APP" ]] || ./Scripts/cassowary/build-cassowary.sh

DEVICE_ID=${SIMULATOR_UDID:-}
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["name"] == "Cassowary-Navigation-Test-iPhone":
            print(device["udid"])
            sys.exit()
')
  if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID=$(xcrun simctl create Cassowary-Navigation-Test-iPhone \
      com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
      com.apple.CoreSimulator.SimRuntime.iOS-26-5)
  fi
fi
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$APP"

CHECK_DIR="$PWD/build/library-navigation-check"
mkdir -p "$CHECK_DIR"
cat > "$CHECK_DIR/project.yml" <<'YAML'
name: LibraryNavigationCheck
targets:
  LibraryNavigationCheck:
    type: bundle.ui-testing
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: ../../Scripts/cassowary/tests/LibraryNavigationCheck.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.cassowary.LibraryNavigationCheck
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_VERSION: "5.0"
        CODE_SIGNING_ALLOWED: NO
schemes:
  LibraryNavigationCheck:
    build:
      targets:
        LibraryNavigationCheck: [test]
    test:
      targets: [LibraryNavigationCheck]
YAML
xcodegen generate --spec "$CHECK_DIR/project.yml" --project "$CHECK_DIR"
xcodebuild -project "$CHECK_DIR/LibraryNavigationCheck.xcodeproj" \
  -scheme LibraryNavigationCheck -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "$CHECK_DIR/DerivedData" -parallel-testing-enabled NO test
