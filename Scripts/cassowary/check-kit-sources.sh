#!/bin/zsh
#
# Report which OpenEmuKit sources can compile for a given platform.
#
# The framework was written for macOS and contains AppKit views, OpenGL
# renderers and XPC plumbing that have no iOS equivalent. Rather than guess
# which files are portable, this compiles each one against the SDK and prints
# the ones that fail.
#
# Usage:
#   Scripts/cassowary/check-kit-sources.sh [--tvos] [--verbose]
#
#   --tvos     check against the tvOS Simulator SDK instead of iOS.
#              The tvOS frameworks have to exist first:
#                ./Scripts/cassowary/build-cassowary.sh --tvos-sim

set -euo pipefail

cd "${0:A:h}/../.."

MODE=iOS
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --tvos)    MODE=tvOS ;;
    --verbose) VERBOSE=1 ;;
    *) print -u2 -- "unknown option: $arg"; exit 1 ;;
  esac
done

if [[ "$MODE" == tvOS ]]; then
  SDK_NAME=appletvsimulator
  TARGET=arm64-apple-tvos17.0-simulator
  SDK_BUILD="$PWD/build/cassowary-tvos-sim"
  OUT=build/cassowary-kit-check-tvos
else
  SDK_NAME=iphonesimulator
  TARGET=arm64-apple-ios17.0-simulator
  SDK_BUILD="$PWD/OpenEmu-SDK/build/Debug-iphonesimulator"
  OUT=build/cassowary-kit-check
fi
SDK=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
mkdir -p "$OUT"

# The SDK frameworks have to be built for the target platform first.
if [[ ! -d "$SDK_BUILD/OpenEmuBase.framework" ]]; then
  if [[ "$MODE" == tvOS ]]; then
    print -u2 -- "error: the tvOS frameworks are not built yet."
    print -u2 -- "       Run: ./Scripts/cassowary/build-cassowary.sh --tvos-sim"
    exit 1
  fi
  print -u2 -- "building the SDK for iOS first..."
  xcodebuild -project OpenEmu-SDK/OpenEmu-SDK.xcodeproj \
    -target OpenEmuBase -target OpenEmuSystem \
    -configuration Debug -sdk iphonesimulator \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build >/dev/null
fi

# OpenEmuShaders comes from the build the frameworks were staged into: the
# DerivedData products for iOS, and the tvOS build directory for tvOS.
if [[ "$MODE" == tvOS ]]; then
  SHADERS_BUILD="$SDK_BUILD"
else
  SHADERS_BUILD=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name 'OpenEmu-metal-*' 2>/dev/null | head -1)/Build/Products/Debug-iphonesimulator
fi

ok=0
failed=()

for source in OpenEmuKit/Source/*.swift; do
  [[ -f "$source" ]] || continue
  object="$OUT/${source:t}.o"
  output=$(xcrun -sdk "$SDK_NAME" swiftc \
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
  if [[ $VERBOSE -eq 1 ]]; then
    print -- "### $source"
    print -- "$output" | grep -E "error:" | head -3
  fi
done

print -- "portable: $ok"
print -- "not portable: ${#failed[@]}"
for source in "${failed[@]}"; do
  print -- "  ${source:t}"
done
