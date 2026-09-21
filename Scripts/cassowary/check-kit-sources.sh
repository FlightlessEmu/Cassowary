#!/bin/zsh
#
# Report which OpenEmuKit sources can compile for iOS.
#
# The framework was written for macOS and contains AppKit views, OpenGL
# renderers and XPC plumbing that have no iOS equivalent. Rather than guess
# which files are portable, this compiles each one against the iOS SDK and
# prints the ones that fail.
#
# Usage:
#   Scripts/cassowary/check-kit-sources.sh [--verbose]

set -euo pipefail

cd "${0:A:h}/../.."

VERBOSE=${1:-}
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET=arm64-apple-ios17.0-simulator
OUT=build/cassowary-kit-check
mkdir -p "$OUT"

# The SDK frameworks have to be built for iOS first.
SDK_BUILD="OpenEmu-SDK/build/Debug-iphonesimulator"
if [[ ! -d "$SDK_BUILD/OpenEmuBase.framework" ]]; then
  print -u2 -- "building the SDK for iOS first..."
  xcodebuild -project OpenEmu-SDK/OpenEmu-SDK.xcodeproj \
    -target OpenEmuBase -target OpenEmuSystem \
    -configuration Debug -sdk iphonesimulator \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build >/dev/null
fi

# OpenEmuShaders is built through the workspace, which resolves its Swift
# package dependencies.
SHADERS_BUILD=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name 'OpenEmu-metal-*' 2>/dev/null | head -1)/Build/Products/Debug-iphonesimulator

ok=0
failed=()

for source in OpenEmuKit/Source/*.swift; do
  [[ -f "$source" ]] || continue
  object="$OUT/${source:t}.o"
  output=$(xcrun -sdk iphonesimulator swiftc \
    -c "$source" \
    -o "$object" \
    -target "$TARGET" \
    -sdk "$SDK" \
    -swift-version 5 \
    -I "$SDK_BUILD" \
    -I "$SHADERS_BUILD" \
    -F "$SDK_BUILD" \
    -F "$SHADERS_BUILD" \
    2>&1) && { ok=$((ok + 1)); continue; }

  failed+=("$source")
  if [[ "$VERBOSE" == "--verbose" ]]; then
    print -- "### $source"
    print -- "$output" | grep -E "error:" | head -3
  fi
done

print -- "portable: $ok"
print -- "macOS-only: ${#failed[@]}"
for source in "${failed[@]}"; do
  print -- "  ${source:t}"
done
