#!/bin/zsh
#
# Build MAME's headless emulator library for iOS.
#
# MAME builds its emulator as a dylib through its own makefile, not through
# the core's Xcode project. This script drives that makefile with the iOS SDK
# and target flags. cores/MAME/MAMEGameCore.m is the glue that links against
# the result.
#
# Usage:
#   Scripts/cassowary/build-mame-ios.sh [--device] [--catalyst] [--tvos] [--tvos-sim]
#
# Options:
#   --device    build for a real iPhone instead of the Simulator
#   --catalyst  build for Mac Catalyst
#   --tvos      build for a real Apple TV
#   --tvos-sim  build for the Apple TV Simulator
#
# The dylib lands in cores/MAME/deps/mame/ under a platform-specific name
# (mamearcade_headless.dylib for the Simulator, with a platform suffix
# otherwise). build-core-ios.sh looks there and builds this library
# itself when it is missing.

set -euo pipefail
setopt NULL_GLOB 2>/dev/null || true

cd "${0:A:h}/../.."

PLATFORM=simulator
for arg in "$@"; do
  case "$arg" in
    --device)   PLATFORM=device ;;
    --catalyst) PLATFORM=catalyst ;;
    --tvos)     PLATFORM=tvos ;;
    --tvos-sim) PLATFORM=tvos-sim ;;
    *) print -u2 -- "unknown option: $arg"; exit 1 ;;
  esac
done

case "$PLATFORM" in
  simulator)
    SDK_NAME=iphonesimulator
    TARGET=arm64-apple-ios17.0-simulator
    DYLIB_NAME=mamearcade_headless.dylib
    ;;
  device)
    SDK_NAME=iphoneos
    TARGET=arm64-apple-ios17.0
    DYLIB_NAME=mamearcade_headless-device.dylib
    ;;
  tvos)
    SDK_NAME=appletvos
    TARGET=arm64-apple-tvos17.0
    DYLIB_NAME=mamearcade_headless-tvos.dylib
    ;;
  tvos-sim)
    SDK_NAME=appletvsimulator
    TARGET=arm64-apple-tvos17.0-simulator
    DYLIB_NAME=mamearcade_headless-tvos-sim.dylib
    ;;
  catalyst)
    SDK_NAME=macosx
    TARGET=arm64-apple-ios17.0-macabi
    DYLIB_NAME=mamearcade_headless-catalyst.dylib
    ;;
esac

# MAME's project generator (genie) cannot build from a path with spaces in it,
# and it bakes these flags into the makefiles it generates. OPT_FLAGS reaches
# the compiler and LDOPTS the linker, so every object and the final dylib are
# built for iOS.
if [[ "$PWD" == *[[:space:]]* ]]; then
  print -u2 -- "error: MAME cannot build from a path containing spaces: $PWD"
  exit 1
fi

SDK=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
IOS_FLAGS="-target $TARGET -isysroot $SDK"

# MAME's makefile keys its object tree on the target OS name, not on the SDK
# flags, and the build above reuses whatever objects are already there. Every
# platform this script builds uses TARGETOS=macosx, so each one gets its own
# object tree instead — without it a tvOS link picks up the iOS objects and
# fails with "building for 'tvOS', but linking in object file ... built for
# 'iOS'".
case "$PLATFORM" in
  tvos)     BUILDDIR=build-tvos ;;
  tvos-sim) BUILDDIR=build-tvos-sim ;;
  *)        BUILDDIR=build ;;
esac

./Scripts/prepare-mame-core.sh

MAME_SRC="$PWD/cores/MAME/deps/mame"
cd "$MAME_SRC"

# macosx_arm64_clang is the closest of MAME's own targets: the emulator still
# builds its macOS-style dylib, but with the iOS target flags above it comes
# out as an iOS library. The headless OSD is the one that exposes the API the
# OpenEmu glue uses.
#
# NO_USE_PORTAUDIO and NO_USE_MIDI matter: PortAudio's CoreAudio backend needs
# headers the iOS SDK does not have, and neither library is used here. Audio
# and input reach the core through the headless OSD's delegate (the OpenEmu
# glue), not through the host APIs.
make NOWERROR=1 REGENIE=1 macosx_arm64_clang \
  OSD=headless TARGETOS=macosx CONFIG=release \
  TARGET=mame SUBTARGET=arcade \
  NO_USE_PORTAUDIO=1 NO_USE_MIDI=1 \
  BUILDDIR="$BUILDDIR" \
  OPT_FLAGS="$IOS_FLAGS" LDOPTS="$IOS_FLAGS" \
  -j"$(sysctl -n hw.ncpu)"

# MAME always writes the bare name, so a device build would otherwise
# overwrite the Simulator's copy.
BUILT="$MAME_SRC/mamearcade_headless.dylib"
install_name_tool -id "@rpath/${BUILT:t}" "$BUILT" 2>/dev/null || true

OUT="$MAME_SRC/$DYLIB_NAME"
if [[ "$DYLIB_NAME" != "mamearcade_headless.dylib" ]]; then
  mv -f "$BUILT" "$OUT"
else
  OUT="$BUILT"
fi

print -- "built $OUT"
file "$OUT"
