#!/bin/zsh
#
# Build melonDS's emulator (the core library) for iOS and Mac Catalyst.
#
# melonDS is a CMake project, unlike the other cores' Xcode projects, so its
# emulator is built here and linked into the plugin bundle by
# Scripts/cassowary/build-core-ios.sh.
#
# Usage:
#   Scripts/cassowary/build-melonds-ios.sh [--device | --catalyst]
#
# Defaults to the iOS Simulator SDK. The static libraries land in
# build/cassowary-melonds-<mode>/lib/.

set -euo pipefail

cd "${0:A:h}/../.."

MODE=simulator
case "${1:-}" in
  --device)   MODE=device ;;
  --catalyst) MODE=catalyst ;;
esac

case "$MODE" in
  # Catalyst's deployment target is a macOS version: Mac Catalyst 17 is
  # macOS 14, and the compiler target below carries the iOS side.
  simulator) SDK_NAME=iphonesimulator ; SYSROOT=iphonesimulator ; TARGET=17.0 ;;
  device)    SDK_NAME=iphoneos        ; SYSROOT=iphoneos        ; TARGET=17.0 ;;
  catalyst)  SDK_NAME=macosx          ; SYSROOT=macosx          ; TARGET=14.0 ;;
esac

BUILD="build/cassowary-melonds-$MODE"
mkdir -p "$BUILD"

# The ARM64 JIT currently fails to start on this combination of macOS and
# Xcode — it faults inside its own fast-memory setup before a frame is ever
# run — so every build uses the interpreter for now. The device build would
# use the interpreter anyway, since iOS does not permit a JIT. See the README.
JIT=OFF

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET"
  -DMELONDS_JIT="$JIT"
  # CMake 4 dropped compatibility with pre-3.5 minimums, which the vendored
  # subprojects still declare.
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

if [[ "$MODE" == catalyst ]]; then
  CMAKE_ARGS+=(-DCMAKE_SYSTEM_NAME=Darwin)
  CMAKE_ARGS+=(-DCMAKE_OSX_SYSROOT=macosx)
  CMAKE_ARGS+=(-DCMAKE_C_COMPILER_TARGET=arm64-apple-ios17.0-macabi)
  CMAKE_ARGS+=(-DCMAKE_CXX_COMPILER_TARGET=arm64-apple-ios17.0-macabi)
  CMAKE_ARGS+=(-DCMAKE_ASM_COMPILER_TARGET=arm64-apple-ios17.0-macabi)
else
  CMAKE_ARGS+=(-DCMAKE_SYSTEM_NAME=iOS)
  CMAKE_ARGS+=(-DCMAKE_OSX_SYSROOT="$SYSROOT")
fi

print -- "configuring melonDS for $MODE (JIT $JIT)..."
cmake -B "$BUILD/cmake" -S cores/melonDS/MelonDS "${CMAKE_ARGS[@]}" >/dev/null

print -- "building melonDS for $MODE..."
cmake --build "$BUILD/cmake" --target core -j "$(sysctl -n hw.ncpu)" >/dev/null

# Static archives do not carry their dependencies, so collect both the core and
# the DSP emulator (teakra) it links against. The plugin link needs both, with
# the core first.
rm -rf "$BUILD/lib"
mkdir -p "$BUILD/lib"
cp "$BUILD/cmake/melonds-src/libcore.a" "$BUILD/lib/"
cp "$BUILD/cmake/melonds-src/teakra/src/libteakra.a" "$BUILD/lib/"

print -- "built $BUILD/lib"
ls -1 "$BUILD/lib"
