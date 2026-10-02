#!/bin/zsh
#
# Build the Nintendo 64 video plugin for one kind of device.
#
# Apple devices have no OpenGL, so Mupen64Plus draws through paraLLEl-RDP,
# which renders with Vulkan through MoltenVK. This builds, into
# build/n64-video/<platform>/:
#
#   mupen64plus-video-parallel.dylib  the renderer, with its OpenGL
#                                     presentation swapped for
#                                     cores/Mupen64Plus/video-parallel/parallel_screen.cpp
#   mupen64plus-rsp-cxd4.dylib        the low-level RSP the renderer needs
#   libMoltenVK.dylib                 Vulkan on Metal; the renderer opens it
#                                     at run time, so it is not linked
#
# build-core-ios.sh runs this when it builds Mupen64Plus and finds the
# plugin missing. Sources come from Scripts/prepare-n64-video.sh.
#
# Usage:
#   Scripts/cassowary/build-n64-video.sh [--simulator | --device | --tvos | --tvos-sim | --catalyst]

set -euo pipefail
cd "${0:A:h}/../.."
REPO=$PWD

PLATFORM=simulator
for arg in "$@"; do
  case "$arg" in
    --simulator) PLATFORM=simulator ;;
    --device)    PLATFORM=device ;;
    --tvos)      PLATFORM=tvos ;;
    --tvos-sim)  PLATFORM=tvos-sim ;;
    --catalyst)  PLATFORM=catalyst ;;
    *) print -u2 -- "unknown option: $arg"; exit 1 ;;
  esac
done

# MoltenVK's names for each platform: the fetchDependencies flag and make
# target, and where its dynamic framework lands.
MVK_DYNAMIC="Package/Release/MoltenVK/dynamic/MoltenVK.xcframework"
case "$PLATFORM" in
  simulator) SDK_NAME=iphonesimulator;  TARGET=arm64-apple-ios17.0-simulator;  MVK=iossim;  MVK_SLICE=ios-arm64_x86_64-simulator ;;
  device)    SDK_NAME=iphoneos;         TARGET=arm64-apple-ios17.0;            MVK=ios;     MVK_SLICE=ios-arm64 ;;
  tvos)      SDK_NAME=appletvos;        TARGET=arm64-apple-tvos17.0;           MVK=tvos;    MVK_SLICE=tvos-arm64_arm64e ;;
  tvos-sim)  SDK_NAME=appletvsimulator; TARGET=arm64-apple-tvos17.0-simulator; MVK=tvossim; MVK_SLICE=tvos-arm64_x86_64-simulator ;;
  catalyst)  SDK_NAME=macosx;           TARGET=arm64-apple-ios17.0-macabi;     MVK=maccat;  MVK_SLICE="" ;;
esac

./Scripts/prepare-n64-video.sh

DEPS="$REPO/cores/Mupen64Plus/deps"
SRC="$DEPS/parallel-rdp"
MOLTENVK_SRC="$DEPS/MoltenVK"
CORE="$REPO/cores/Mupen64Plus/mupen64plus-core/src/api"
RSP="$REPO/cores/Mupen64Plus/mupen64plus-rsp-cxd4"
OUT="$REPO/build/n64-video/$PLATFORM"
mkdir -p "$OUT/obj" "$OUT/include/mupen64plus"

# --- MoltenVK ----------------------------------------------------------------
# Each platform's MoltenVK build replaces the package left by the one before,
# so the library is copied out straight away and kept here; a platform built
# once is not built again.

if [[ ! -f "$OUT/libMoltenVK.dylib" ]]; then
  print -- "building MoltenVK for $PLATFORM (slow the first time)..."
  ( cd "$MOLTENVK_SRC" && ./fetchDependencies --$MVK && make $MVK ) > "$OUT/moltenvk.log" 2>&1 || {
    print -u2 -- "error: MoltenVK did not build; see $OUT/moltenvk.log"
    exit 1
  }
  if [[ "$PLATFORM" == catalyst ]]; then
    # MoltenVK's Catalyst package only ships a static library, so wrap it in
    # a dylib the plugin can open like on the other platforms.
    SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
    xcrun --sdk macosx clang++ -dynamiclib -target "$TARGET" -isysroot "$SDK_PATH" \
      -iframework "$SDK_PATH/System/iOSSupport/System/Library/Frameworks" \
      -Wl,-force_load,"$MOLTENVK_SRC/Package/Release/MoltenVK/static/MoltenVK.xcframework/ios-arm64_x86_64-maccatalyst/libMoltenVK.a" \
      -Wl,-force_load,"$MOLTENVK_SRC/External/build/Release/SPIRVCross.xcframework/ios-arm64_x86_64-maccatalyst/libSPIRVCross.a" \
      -o "$OUT/libMoltenVK.dylib" \
      -framework Metal -framework Foundation -framework QuartzCore \
      -framework CoreGraphics -framework IOKit -framework IOSurface -framework UIKit
  else
    cp -f "$MOLTENVK_SRC/$MVK_DYNAMIC/$MVK_SLICE/MoltenVK.framework/MoltenVK" "$OUT/libMoltenVK.dylib"
  fi
fi

# --- The video plugin ----------------------------------------------------------

rm -rf "$OUT/include/mupen64plus"
mkdir -p "$OUT/include/mupen64plus"
for header in "$CORE"/*.h; do
  ln -sf "$header" "$OUT/include/mupen64plus/${header:t}"
done

SDK_FLAGS=(-target "$TARGET" -isysroot "$(xcrun --sdk "$SDK_NAME" --show-sdk-path)")
COMMON_FLAGS=(
  -std=c++17 -O2 -g -fPIC -pthread
  "${SDK_FLAGS[@]}"
  -DMUPEN_NO_SYSTEM
  -I"$OUT/include" -I"$SRC" -I"$SRC/parallel-rdp" -I"$SRC/volk"
  -I"$SRC/vulkan" -I"$SRC/vulkan-headers/include" -I"$SRC/util"
)

VULKAN_SOURCES=(buffer buffer_pool command_buffer command_pool context cookie
  descriptor_set device event_manager fence fence_manager image indirect_layout
  memory_allocator pipeline_event query_pool render_pass sampler semaphore
  semaphore_manager shader texture/texture_format)
SOURCES=("$SRC"/parallel-rdp/*.cpp)
for name in "${VULKAN_SOURCES[@]}"; do
  SOURCES+=("$SRC/vulkan/$name.cpp")
done
SOURCES+=(
  "$SRC"/util/*.cpp
  "$SRC/gfx_m64p.cpp" "$SRC/parallel_imp.cpp"
  "$REPO/cores/Mupen64Plus/video-parallel/parallel_screen.cpp"
)
OBJECTS=()
for source in "${SOURCES[@]}"; do
  object="$OUT/obj/${${source#$REPO/}//\//_}.o"
  if [[ ! -f "$object" || "$source" -nt "$object" ]]; then
    xcrun --sdk "$SDK_NAME" clang++ "${COMMON_FLAGS[@]}" -c "$source" -o "$object"
  fi
  OBJECTS+=("$object")
done
xcrun --sdk "$SDK_NAME" clang -c "$SRC/volk/volk.c" "${COMMON_FLAGS[@]:#-std=c++17}" -o "$OUT/obj/volk.o"

xcrun --sdk "$SDK_NAME" clang++ -dynamiclib "${OBJECTS[@]}" "$OUT/obj/volk.o" \
  -o "$OUT/mupen64plus-video-parallel.dylib" \
  "${SDK_FLAGS[@]}" -pthread -ldl \
  -framework Foundation -framework CoreGraphics \
  -Wl,-undefined,dynamic_lookup -Wl,-rpath,@loader_path

# --- The RSP plugin ------------------------------------------------------------
# The same nine sources the Xcode target compiles (not lto.c, which repeats
# the others).

xcrun --sdk "$SDK_NAME" clang -dynamiclib "${SDK_FLAGS[@]}" \
  -O2 -g -fPIC -DMUPEN_NO_SYSTEM -DM64P_PLUGIN_API -DUSE_SSE2NEON \
  -I"$RSP" -I"$CORE" \
  "$RSP/osal_dynamiclib_unix.c" "$RSP/vu/select.c" "$RSP/vu/logical.c" \
  "$RSP/module.c" "$RSP/su.c" "$RSP/vu/vu.c" "$RSP/vu/multiply.c" \
  "$RSP/vu/divide.c" "$RSP/vu/add.c" \
  -o "$OUT/mupen64plus-rsp-cxd4.dylib" \
  -Wl,-undefined,dynamic_lookup

print -- "built the N64 video plugin for $PLATFORM in $OUT"
