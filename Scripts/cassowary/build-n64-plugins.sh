#!/bin/zsh
#
# Build the mupen64plus plugins used by Cassowary's N64 core.
#
#   mupen64plus-video-parallel.dylib  the RDP renderer (paraLLEl-RDP + MoltenVK)
#   mupen64plus-rsp-cxd4.dylib        the LLE RSP the RDP path needs
#
# The video plugin has its OpenGL presentation replaced by parallel_screen.cpp.
# MoltenVK is dlopen'd by Granite at runtime, so it is not linked; the matching
# libMoltenVK.dylib is copied next to the plugin.
#
# Usage:
#   build-n64-plugins.sh [--device | --catalyst | --tvos | --tvos-sim]

set -euo pipefail
setopt NULL_GLOB
cd "${0:A:h}/../.."

REPO="$PWD"
SRC=$(python3 Scripts/upstream/core-upstream.py fetch-dependency parallel-rdp)
MVK_ROOT=$(python3 Scripts/upstream/core-upstream.py fetch-dependency MoltenVK)
CORE="$REPO/cores/Mupen64Plus/mupen64plus-core/src/api"
RSP="$REPO/cores/Mupen64Plus/mupen64plus-rsp-cxd4"

PLATFORM=simulator
for arg in "$@"; do
  case "$arg" in
    --simulator) PLATFORM=simulator ;;
    --device)    PLATFORM=device ;;
    --catalyst)  PLATFORM=catalyst ;;
    --tvos)      PLATFORM=tvos ;;
    --tvos-sim)  PLATFORM=tvos-sim ;;
    --macos)     PLATFORM=macos ;;
    *) print -u2 -- "unknown option: $arg"; exit 1 ;;
  esac
done

case "$PLATFORM" in
  simulator)
    SDK_NAME=iphonesimulator
    TARGET=arm64-apple-ios17.0-simulator
    MVK_PLATFORM=iossim
    ;;
  device)
    SDK_NAME=iphoneos
    TARGET=arm64-apple-ios17.0
    MVK_PLATFORM=ios
    ;;
  catalyst)
    SDK_NAME=macosx
    TARGET=arm64-apple-ios17.0-macabi
    MVK_PLATFORM=maccat
    ;;
  tvos)
    SDK_NAME=appletvos
    TARGET=arm64-apple-tvos17.0
    MVK_PLATFORM=tvos
    ;;
  tvos-sim)
    SDK_NAME=appletvsimulator
    TARGET=arm64-apple-tvos17.0-simulator
    MVK_PLATFORM=tvossim
    ;;
  macos)
    SDK_NAME=macosx
    TARGET=""
    MVK_PLATFORM=macos
    ;;
esac

# Xcode versions can give slices different directory names. Select by the
# XCFramework's platform/variant metadata so a phone never picks a desktop slice.
MVK_KIND=dynamic
[[ "$PLATFORM" == catalyst ]] && MVK_KIND=static
MVK_FRAMEWORK="$MVK_ROOT/Package/Release/MoltenVK/$MVK_KIND/MoltenVK.xcframework"
MOLTENVK=$(python3 Scripts/upstream/xcframework-library.py "$MVK_FRAMEWORK" "$PLATFORM" 2>/dev/null || true)
if [[ -z "$MOLTENVK" ]]; then
  (cd "$MVK_ROOT" && ./fetchDependencies "--$MVK_PLATFORM" && make "$MVK_PLATFORM")
  MOLTENVK=$(python3 Scripts/upstream/xcframework-library.py "$MVK_FRAMEWORK" "$PLATFORM")
fi
[[ -f "$MOLTENVK" ]] || { print -u2 -- "error: MoltenVK missing at $MOLTENVK"; exit 1; }

OUT="$REPO/build/cassowary-n64-plugins-$PLATFORM"
mkdir -p "$OUT" "$OUT/include/mupen64plus"
rm -f "$OUT/include/mupen64plus"/*.h 2>/dev/null || true
for header in "$CORE"/*.h; do
  ln -sf "$header" "$OUT/include/mupen64plus/${header:t}"
done

SDK_FLAGS=()
if [[ -n "$TARGET" ]]; then
  SDK_FLAGS=(-target "$TARGET" -isysroot "$(xcrun --sdk "$SDK_NAME" --show-sdk-path)")
fi

COMMON_FLAGS=(
  -std=c++17
  -O2
  -g
  -fPIC
  -pthread
  "${SDK_FLAGS[@]}"
  -DMUPEN_NO_SYSTEM
  -I"$OUT/include"
  -I"$SRC"
  -I"$SRC/parallel-rdp"
  -I"$SRC/volk"
  -I"$SRC/vulkan"
  -I"$SRC/vulkan-headers/include"
  -I"$SRC/util"
)

RDP_SOURCES=(
  "$SRC"/parallel-rdp/*.cpp
  "$SRC"/vulkan/buffer.cpp
  "$SRC"/vulkan/buffer_pool.cpp
  "$SRC"/vulkan/command_buffer.cpp
  "$SRC"/vulkan/command_pool.cpp
  "$SRC"/vulkan/context.cpp
  "$SRC"/vulkan/cookie.cpp
  "$SRC"/vulkan/descriptor_set.cpp
  "$SRC"/vulkan/device.cpp
  "$SRC"/vulkan/event_manager.cpp
  "$SRC"/vulkan/fence.cpp
  "$SRC"/vulkan/fence_manager.cpp
  "$SRC"/vulkan/image.cpp
  "$SRC"/vulkan/indirect_layout.cpp
  "$SRC"/vulkan/memory_allocator.cpp
  "$SRC"/vulkan/pipeline_event.cpp
  "$SRC"/vulkan/query_pool.cpp
  "$SRC"/vulkan/render_pass.cpp
  "$SRC"/vulkan/sampler.cpp
  "$SRC"/vulkan/semaphore.cpp
  "$SRC"/vulkan/semaphore_manager.cpp
  "$SRC"/vulkan/shader.cpp
  "$SRC"/vulkan/texture/texture_format.cpp
  "$SRC"/util/*.cpp
)

compile() {
  local source="$1" object="$2"
  xcrun --sdk "$SDK_NAME" clang++ "${COMMON_FLAGS[@]}" -c "$source" -o "$object"
}

# --- Video plugin -----------------------------------------------------------

VIDEO_OBJECTS=()
for source in "${RDP_SOURCES[@]}" "$SRC/gfx_m64p.cpp" "$SRC/parallel_imp.cpp" "$REPO/cores/Mupen64Plus/parallel/parallel_screen.cpp"; do
  object="$OUT/${${source#$REPO/}//\//_}.o"
  compile "$source" "$object"
  VIDEO_OBJECTS+=("$object")
done
xcrun --sdk "$SDK_NAME" clang -c "$SRC/volk/volk.c" "${COMMON_FLAGS[@]:#-std=c++17}" -o "$OUT/volk.o"

xcrun --sdk "$SDK_NAME" clang++ -dynamiclib "${VIDEO_OBJECTS[@]}" "$OUT/volk.o" \
  -o "$OUT/mupen64plus-video-parallel.dylib" \
  "${SDK_FLAGS[@]}" \
  -pthread -ldl \
  -framework Foundation -framework CoreGraphics \
  -Wl,-undefined,dynamic_lookup \
  -Wl,-rpath,@loader_path

# --- RSP plugin (LLE) -------------------------------------------------------
# The same nine sources the Xcode target compiles (not lto.c; it duplicates
# the others and is not in the target).

xcrun --sdk "$SDK_NAME" clang -dynamiclib \
  "${SDK_FLAGS[@]}" \
  -O2 -g -fPIC -DMUPEN_NO_SYSTEM -DM64P_PLUGIN_API -DUSE_SSE2NEON \
  -I"$RSP" -I"$CORE" \
  "$RSP/osal_dynamiclib_unix.c" \
  "$RSP/vu/select.c" \
  "$RSP/vu/logical.c" \
  "$RSP/module.c" \
  "$RSP/su.c" \
  "$RSP/vu/vu.c" \
  "$RSP/vu/multiply.c" \
  "$RSP/vu/divide.c" \
  "$RSP/vu/add.c" \
  -o "$OUT/mupen64plus-rsp-cxd4.dylib" \
  -Wl,-undefined,dynamic_lookup

# --- MoltenVK next to the video plugin --------------------------------------

if [[ "$PLATFORM" == catalyst ]]; then
  # MoltenVK's Catalyst package only ships a static library (the dynamic
  # framework has unresolved build issues upstream), so wrap it in a dylib
  # that the plugin can dlopen like on the other platforms.
  MVK_STATIC="$MOLTENVK"
  SPVC_STATIC=$(python3 Scripts/upstream/xcframework-library.py "$MVK_ROOT/External/build/Release/SPIRVCross.xcframework" catalyst)
  SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
  if [[ -f "$MVK_STATIC" ]]; then
    xcrun --sdk macosx clang++ -dynamiclib -target "$TARGET" -isysroot "$SDK_PATH" \
      -iframework "$SDK_PATH/System/iOSSupport/System/Library/Frameworks" \
      -Wl,-force_load,"$MVK_STATIC" -Wl,-force_load,"$SPVC_STATIC" \
      -o "$OUT/libMoltenVK.dylib" \
      -framework Metal -framework Foundation -framework QuartzCore \
      -framework CoreGraphics -framework IOKit -framework IOSurface -framework UIKit
  fi
elif [[ -f "$MOLTENVK" ]]; then
  cp -f "$MOLTENVK" "$OUT/libMoltenVK.dylib"
else
  print -u2 -- "error: no MoltenVK dylib at $MOLTENVK"
  exit 1
fi

print -- "built $OUT/mupen64plus-video-parallel.dylib and $OUT/mupen64plus-rsp-cxd4.dylib"
