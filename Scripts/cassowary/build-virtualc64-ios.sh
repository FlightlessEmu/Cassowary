#!/bin/zsh
#
# Build VirtualC64's emulator library (VCCore) for iOS.
#
# VCCore is a CMake project, unlike the other cores' Xcode projects, so it is
# built here and linked into the plugin bundle by Scripts/cassowary/build-core-ios.sh.
#
# Usage:
#   Scripts/cassowary/build-virtualc64-ios.sh [--device | --catalyst]
#
# Defaults to the iOS Simulator SDK. The static libraries land in
# build/cassowary-virtualc64-<mode>/.

set -euo pipefail

cd "${0:A:h}/../.."

MODE=simulator
case "${1:-}" in
  --device)   MODE=device ;;
  --catalyst) MODE=catalyst ;;
esac

case "$MODE" in
  simulator) SDK_NAME=iphonesimulator ; SYSROOT=iphonesimulator ; TARGET=17.0 ;;
  device)    SDK_NAME=iphoneos        ; SYSROOT=iphoneos        ; TARGET=17.0 ;;
  catalyst)  SDK_NAME=macosx          ; SYSROOT=macosx          ; TARGET=17.0 ;;
esac

BUILD="build/cassowary-virtualc64-$MODE"
mkdir -p "$BUILD"

# The CMake project uses CMAKE_SYSTEM_NAME=iOS for the Simulator and a real
# device. Mac Catalyst is a macOS build with the iOS ABI, so it keeps Darwin
# as the system name and only changes the target triple.
CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET"
  # CMake 4 dropped compatibility with pre-3.5 minimums; VCCore's vendored
  # subprojects still declare old ones.
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

if [[ "$MODE" == catalyst ]]; then
  CMAKE_ARGS+=(-DCMAKE_SYSTEM_NAME=Darwin)
  CMAKE_ARGS+=(-DCMAKE_OSX_SYSROOT=macosx)
  CMAKE_ARGS+=(-DCMAKE_C_COMPILER_TARGET=arm64-apple-ios17.0-macabi)
  CMAKE_ARGS+=(-DCMAKE_CXX_COMPILER_TARGET=arm64-apple-ios17.0-macabi)
else
  CMAKE_ARGS+=(-DCMAKE_SYSTEM_NAME=iOS)
  CMAKE_ARGS+=(-DCMAKE_OSX_SYSROOT="$SYSROOT")
fi

print -- "configuring VCCore for $MODE..."
cmake -B "$BUILD/cmake" -S cores/VirtualC64/VCCore "${CMAKE_ARGS[@]}" >/dev/null

print -- "building VCCore for $MODE..."
cmake --build "$BUILD/cmake" --target VCCore -j "$(sysctl -n hw.ncpu)" >/dev/null

# Collect the static libraries. VCCore links reSID, rvlib, utlib and xdms, and
# static archives do not carry their dependencies, so the plugin link needs
# all of them.
rm -rf "$BUILD/lib"
mkdir -p "$BUILD/lib"
for library in libVCCore.a \
               Components/SID/resid/libresid.a \
               rvlib/librvlib.a \
               rvlib/ThirdParty/xdms/libxdms.a \
               utlib/libutlib.a; do
  cp "$BUILD/cmake/$library" "$BUILD/lib/"
done

print -- "built $BUILD/lib"
ls -1 "$BUILD/lib"
