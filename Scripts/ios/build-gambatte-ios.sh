#!/bin/zsh
#
# Build the Gambatte core for iOS, outside of Xcode.
#
# This is the fast feedback loop while porting: it compiles the same sources the
# core's Xcode target builds, but directly, so errors show up in a second rather
# than a full Xcode build. The real build goes through `Gambatte.xcodeproj`.
#
# Usage:
#   Scripts/ios/build-gambatte-ios.sh [--device]
#
# Defaults to the iOS Simulator SDK. Pass --device to target a real iPhone.

set -euo pipefail

cd "${0:A:h}/../.."

PLATFORM=simulator
TARGET=arm64-apple-ios17.0-simulator
if [[ "${1:-}" == "--device" ]]; then
  PLATFORM=device
  TARGET=arm64-apple-ios17.0
fi

SDK=$(xcrun --sdk iphone${PLATFORM} --show-sdk-path)
OUT="build/ios-gambatte-${PLATFORM}"
mkdir -p "$OUT"

# Header search paths, mirroring the core target's settings.
#
# The SDK headers are imported as <OpenEmuBase/...> and <OpenEmuSystem/...>, so
# the search path has to be the directory that *contains* those, not the
# directories themselves.
INCLUDES=(
  -I "$PWD/OpenEmu-SDK"
  -I "$PWD/OpenEmu-SDK/OpenEmuBase"
  -I "$PWD/OpenEmu-SDK/OpenEmuSystem"
  -I "$PWD/OpenEmu/SystemPlugins/GameBoy"
  -I "$PWD/Gambatte"
  -I "$PWD/Gambatte/src"
  -I "$PWD/Gambatte/src/libgambatte"
  -I "$PWD/Gambatte/src/resample"
  -I "$PWD/Vendor/rcheevos/include"
  -I "$PWD/Vendor/rcheevos/src"
  -I "$PWD/OpenEmuKit/Source"
)

# No -std flag: the core predates C++17 and uses std::bind1st, which later
# standards removed. Xcode's default is what the macOS build uses, so match it.
CXXFLAGS=(
  -target "$TARGET"
  -isysroot "$SDK"
  -fobjc-arc
  -DHAVE_STDINT_H
  -DRC_NO_THREADS=1
  -DRC_CLIENT_SUPPORTS_HASH
  -w
)

# rcheevos is built single-threaded with ROM hashing enabled, matching the
# core targets' settings.
CCFLAGS=(
  -target "$TARGET"
  -isysroot "$SDK"
  -fobjc-arc
  -DRC_NO_THREADS=1
  -DRC_CLIENT_SUPPORTS_HASH
  -w
)

# Gambatte's own sources, plus the shared support files the core links.
SOURCES=(
  Gambatte/GBGameCore.mm
  # The root-level statesaver is the one the core target builds.
  Gambatte/statesaver.cpp
  Vendor/rcheevos/rcheevos_build.c
  OpenEmuKit/Source/OERetroAchievementsTransport.m
  OpenEmuKit/Source/OERetroAchievementsBridge.m
  Gambatte/src/libgambatte/*.cpp
  # Note: Gambatte/statesaver.cpp and Gambatte/src/libgambatte/statesaver.cpp
  # both exist and define the same symbols. The core's Xcode target compiles
  # only the one in Gambatte/, so this list must not add the other.
  Gambatte/src/libgambatte/mem/*.cpp
  Gambatte/src/libgambatte/sound/*.cpp
  Gambatte/src/libgambatte/video/*.cpp
  Gambatte/src/libgambatte/file/*.cpp
  Gambatte/src/resample/*.cpp
)

failures=0
compiled=0
for source in "${SOURCES[@]}"; do
  [[ -f "$source" ]] || continue
  # Skipped on purpose: see the note in SOURCES.
  [[ "$source" == "Gambatte/src/libgambatte/statesaver.cpp" ]] && continue
  # Keep the source's directory in the object path: Gambatte has two different
  # files called statesaver.cpp, and flattening the name would lose one.
  object="$OUT/${source//\//_}.o"

  case "$source" in
    *.mm) compiler=(xcrun -sdk iphone${PLATFORM} clang++) ; flags=("${CXXFLAGS[@]}") ;;
    *.m)  compiler=(xcrun -sdk iphone${PLATFORM} clang)  ; flags=("${CCFLAGS[@]}") ;;
    *.c)  compiler=(xcrun -sdk iphone${PLATFORM} clang)  ; flags=("${CCFLAGS[@]}") ;;
    *.cpp) compiler=(xcrun -sdk iphone${PLATFORM} clang++) ; flags=("${CXXFLAGS[@]}") ;;
    *) continue ;;
  esac

  if ! output=$("${compiler[@]}" -c "$source" -o "$object" "${flags[@]}" "${INCLUDES[@]}" 2>&1); then
    print -u2 -- "### $source"
    print -u2 -- "${output[(f)1,8]}" | grep -E "error:" || print -u2 -- "$output" | head -8
    failures=$((failures + 1))
    continue
  fi
  compiled=$((compiled + 1))
done

print -- "compiled $compiled file(s), $failures failure(s)"
[[ $failures -eq 0 ]]
