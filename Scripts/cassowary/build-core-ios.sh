#!/bin/zsh
#
# Build any emulator core for iOS.
#
# The core's own Xcode project states its source list and build settings, so
# this script asks for those rather than keeping a second copy. See
# Scripts/cassowary/core-info.py.
#
# Usage:
#   Scripts/cassowary/build-core-ios.sh <CoreName> [--device] [--keep-going] [--quiet]
#
# Options:
#   --device      target a real iPhone instead of the Simulator
#   --keep-going  compile every file even after one fails, then report a summary
#   --quiet       only print the summary
#
# Exit status is 0 when every source compiled and the bundle linked.

set -euo pipefail
setopt NULL_GLOB 2>/dev/null || true

cd "${0:A:h}/../.."

CORE=${1:?usage: build-core-ios.sh <CoreName> [--device]}
shift || true

PLATFORM=simulator
SDK_NAME=iphonesimulator
TARGET=arm64-apple-ios17.0-simulator
KEEP_GOING=0
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --device)
      PLATFORM=device
      SDK_NAME=iphoneos
      TARGET=arm64-apple-ios17.0
      ;;
    --catalyst)
      PLATFORM=catalyst
      SDK_NAME=macosx
      TARGET=arm64-apple-ios17.0-macabi
      ;;
    --keep-going) KEEP_GOING=1 ;;
    --quiet) QUIET=1 ;;
    *) print -u2 -- "unknown option: $arg"; exit 1 ;;
  esac
done

SDK=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
case "$PLATFORM" in
  catalyst) SDK_BUILD="$PWD/build/catalyst" ;;
  *)        SDK_BUILD="$PWD/OpenEmu-SDK/build/Debug-${SDK_NAME}" ;;
esac

# Mac Catalyst builds against the macOS SDK plus the iOS support frameworks;
# without this, UIKit and friends are not on the search path.
CATALYST_FRAMEWORKS=()
if [[ "$PLATFORM" == catalyst ]]; then
  CATALYST_FRAMEWORKS=(-iframework "$SDK/System/iOSSupport/System/Library/Frameworks")
fi
INFO_FILE="build/cassowary-core-info-${CORE}.json"
SHELL_FILE="build/cassowary-core-info-${CORE}.sh"

if [[ ! -d "$SDK_BUILD/OpenEmuBase.framework" ]]; then
  print -u2 -- "building the SDK frameworks for iOS first..."
  xcodebuild -project OpenEmu-SDK/OpenEmu-SDK.xcodeproj \
    -target OpenEmuBase -target OpenEmuSystem \
    -configuration Debug -sdk "$SDK_NAME" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build >/dev/null
fi

mkdir -p build
python3 Scripts/cassowary/core-info.py "$CORE" > "$INFO_FILE" 2>/dev/null || {
  print -u2 -- "error: could not read the project for $CORE"
  exit 1
}

# The shell assignments are written to a file and sourced, rather than built
# with `eval "$(python3 ... <<HEREDOC)"`. A heredoc inside a command
# substitution confuses zsh's parser badly enough that it silently reassigns
# PATH to the last value on the longest line.
python3 Scripts/cassowary/core-info.py "$CORE" --shell > "$SHELL_FILE"
source "$SHELL_FILE"

# Per-core additions the projects cannot state for an iOS build.
case "$CORE" in
  4DO)
    # libcue.h lives at libcue-1.4.0/src/libcue, below the stale
    # $(PROJECT_DIR)/libcue/** search path. That directory is skipped by
    # header discovery (it holds a time.h that would shadow the system
    # header), so the glue includes it by relative path instead of another
    # -I. The libcue static-library target's sources are compiled in as
    # well — the iOS link has no .a files.
    for libcue_src in cd.c cdtext.c cue_parser.c cue_scanner.c rem.c time.c; do
      SOURCES+=("$PWD/cores/4DO/libcue-1.4.0/src/libcue/$libcue_src")
      SOURCE_FLAGS+=("")
    done
    ;;
  BSNES)
    # nall specializes std::is_signed<int128_t>, which the current SDK's
    # libc++ forbids. The specializations are benign, so the diagnostic is
    # silenced for this core's C++ sources.
    EXTRA_CXXFLAGS=(-Wno-invalid-specialization)
    ;;
  GenesisPlus)
    # genplusgx_source/tremor/block.h shadows the SDK's <Block.h> (included
    # by CFBase.h) on case-insensitive filesystems. Nothing needs the tremor
    # directory on the search path: its sources include each other with
    # quotes, and the one outside user (cdd.h → "tremor/ivorbisfile.h")
    # resolves via genplusgx_source, which stays.
    keep=()
    for d in "${INCLUDES[@]}"; do
      [[ "$d" == */tremor ]] || keep+=("$d")
    done
    INCLUDES=("${keep[@]}")
    # The shared -iquote dirs put libFLAC's include/private (which holds its
    # own macros.h) ahead of genplusgx_source, so m68k.h's "macros.h" picks
    # up the wrong file and INLINE goes undefined. Searching
    # genplusgx_source first restores Xcode's resolution — macros.h is the
    # only basename the two directories share.
    QUOTE_INCLUDES=("$PWD/cores/GenesisPlus/genplusgx_source" "${QUOTE_INCLUDES[@]}")
    ;;
  MAME)
    # The project compiles MAMEGameCore.m as ObjC++
    # (GCC_INPUT_FILETYPE = sourcecode.cpp.objcpp): it assigns braced lists
    # to existing structs, which is valid C++ but not C.
    OBJCPP=1
    # The emulator itself is a separate dylib built by MAME's own makefile
    # (Scripts/build-mame-core.sh), not by the Xcode project's sources. It is
    # named without a lib prefix, so it is linked by path, not with -l.
    MAME_DYLIB="$PWD/cores/MAME/deps/mame/mamearcade_headless.dylib"
    if [[ -f "$MAME_DYLIB" ]]; then
      EXTRA_LINK_FLAGS=("$MAME_DYLIB")
      EMBED_LIBS=("$MAME_DYLIB")
    fi
    ;;
esac

OUT="build/cassowary-cores-${PLATFORM}/${CORE}"
mkdir -p "$OUT"

# The project's header search paths arrive as bare paths; turn them into -I
# flags. Without the flag clang treats them as input files and silently fails
# to find anything.
INCLUDE_FLAGS=()
# Note: the loop variable must not be called `path`. In zsh `path` is a special
# array tied to PATH, so assigning to it silently replaces the command search
# path with the include directory.
for include_dir in "${INCLUDES[@]}"; do
  INCLUDE_FLAGS+=(-I "$include_dir")
done

# Directories holding a C library header name (Mednafen's Time.h shadows the
# system time.h). These go on -iquote: "..." includes still resolve, while
# <...> includes fall through to the real system headers.
QUOTE_FLAGS=()
# Note: the loop variable must not be called `path`. In zsh `path` is a special
# array tied to PATH, so assigning to it silently replaces the command search
# path with the include directory.
for quote_dir in "${QUOTE_INCLUDES[@]}"; do
  QUOTE_FLAGS+=(-iquote "$quote_dir")
done

# Every core imports the responder-client protocol of the system it drives,
# e.g. "OEGBSystemResponderClient.h". Those headers live in the system plugin
# directories, and a core can cover several systems (Genesis Plus covers six),
# so all of them go on the search path.
SYSTEM_PLUGIN_INCLUDES=()
for plugin_dir in OpenEmu/SystemPlugins/*/; do
  [[ -d "$plugin_dir" ]] && SYSTEM_PLUGIN_INCLUDES+=(-I "$PWD/${plugin_dir%/}")
done

# The SDK headers are imported as <OpenEmuBase/...>, so the search path has to
# be the directory that contains those.
COMMON=(
  -target "$TARGET"
  -isysroot "$SDK"
  # Source headers before the built frameworks: -F is position-sensitive for
  # Framework/Header.h lookups, and the frameworks in SDK_BUILD can be older
  # than the sources (e.g. a fresh SDK typedef invisible until rebuild).
  -I "$PWD/OpenEmu-SDK"
  -I "$PWD/OpenEmu-SDK/OpenEmuBase"
  -I "$PWD/OpenEmu-SDK/OpenEmuSystem"
  -I "$PWD/OpenEmuKit/Source"
  -I "$PWD/Vendor/rcheevos/include"
  -I "$PWD/Vendor/rcheevos/src"
  -F "$SDK_BUILD"
  -w
  # Several cores predate modern C and rely on implicit integer/pointer
  # conversions that are now hard errors. They are warnings again here.
  -Wno-int-conversion
  # Matches Xcode's GCC_SYMBOLS_PRIVATE_EXTERN = YES, which every core project
  # sets. With C globals hidden, the linker can dead-strip code that nothing
  # reachable calls — including code that references symbols the project never
  # compiles (FCEU's hq2x filters, VirtualJaguar's debugger hooks). The classes
  # the host looks up are marked OE_EXPORTED_CLASS and stay visible.
  -fvisibility=hidden
  "${CATALYST_FRAMEWORKS[@]}"
  "${INCLUDE_FLAGS[@]}"
  "${QUOTE_FLAGS[@]}"
  "${SYSTEM_PLUGIN_INCLUDES[@]}"
  "${EXTRA_CFLAGS[@]}"
)

[[ "$ARC" == "YES" ]] && COMMON+=(-fobjc-arc)

# Match the projects' language standards. The command-line compiler default is
# older than what Xcode uses, and BSNES needs C++17 for its nall traits.
CSTD_FLAGS=()
[[ -n "${CSTD:-}" ]] && CSTD_FLAGS=(-std="$CSTD")
CXXSTD_FLAGS=()
[[ -n "${CXXSTD:-}" ]] && CXXSTD_FLAGS=(-std="$CXXSTD")
# Per-core C++ additions (set in the case block above; empty for the rest).
CXXSTD_FLAGS+=("${EXTRA_CXXFLAGS[@]:-}")


failures=()
compiled=0

# Walk the two parallel arrays so each file can carry its own flags.
for index in {1..${#SOURCES[@]}}; do
  source="${SOURCES[$index]}"
  file_flags="${SOURCE_FLAGS[$index]}"
  [[ -f "$source" ]] || continue

  case "$source" in
    *.m)
      if [[ "${OBJCPP:-0}" == "1" ]]; then
        compiler=(xcrun -sdk "$SDK_NAME" clang++ -x objective-c++); std=("${CXXSTD_FLAGS[@]}")
      else
        compiler=(xcrun -sdk "$SDK_NAME" clang);   std=("${CSTD_FLAGS[@]}")
      fi ;;
    *.mm)   compiler=(xcrun -sdk "$SDK_NAME" clang++); std=("${CXXSTD_FLAGS[@]}") ;;
    *.c)    compiler=(xcrun -sdk "$SDK_NAME" clang);   std=("${CSTD_FLAGS[@]}") ;;
    *.cc|*.cpp|*.cxx|*.C|*.cp|*.CPP|*.c++) compiler=(xcrun -sdk "$SDK_NAME" clang++); std=("${CXXSTD_FLAGS[@]}") ;;
    *.S|*.s) compiler=(xcrun -sdk "$SDK_NAME" clang);  std=() ;;
    *) continue ;;
  esac

  # Keep the source's directory in the object name: several cores have two
  # files with the same basename in different directories.
  object="$OUT/${source//\//_}.o"

  if [[ -n "${OE_DEBUG:-}" && "$compiled" == "0" && ${#failures[@]} -eq 0 ]]; then
    print -- "first source: $source"
    print -- "compiler:     ${#compiler[@]} words: ${compiler[1]} | ${compiler[2]} | ${compiler[3]}"
    print -- "PATH now:     $PATH"
    print -- "PATH has /usr/bin: ${PATH[(I)/usr/bin]:-no}"
    print -- "commands:     ${#commands}"
    print -- "aliases:      ${#aliases}"
  fi

  # Per-file flags are already a string; split them into words.
  extra=()
  [[ -n "$file_flags" ]] && extra=(${=file_flags})

  if output=$("${compiler[@]}" -c "$source" -o "$object" "${COMMON[@]}" "${std[@]}" "${extra[@]}" 2>&1); then
    compiled=$((compiled + 1))
    continue
  fi

  failures+=("$source")
  if [[ $QUIET -eq 0 ]]; then
    print -u2 -- "### $source"
    print -u2 -- "$output" | grep -E "error:" | head -3
  fi

  if [[ $KEEP_GOING -eq 0 ]]; then
    print -u2 -- ""
    print -u2 -- "stopping at the first failure; pass --keep-going to compile everything"
    exit 1
  fi
done

print -- "$CORE: compiled $compiled, failed ${#failures[@]}"

if [[ ${#failures[@]} -gt 0 ]]; then
  print -- ""
  print -- "files that did not compile:"
  for source in "${failures[@]}"; do
    print -- "  ${source#$PWD/}"
  done
  exit 1
fi

# --- Link -----------------------------------------------------------------

PLUGIN_DIR="build/cassowary-plugins/${PRODUCT}.${WRAPPER}"
case "$PLATFORM" in
  device)   PLUGIN_DIR="build/cassowary-plugins-device/${PRODUCT}.${WRAPPER}" ;;
  catalyst) PLUGIN_DIR="build/cassowary-plugins-catalyst/${PRODUCT}.${WRAPPER}" ;;
esac
rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"

# Never leave a half-built husk: an empty *.oecoreplugin scans as a bundle
# with an empty Info.plist, and the app's plugin scan crashes on it at
# startup (OECorePlugin force-casts CFBundleIdentifier).
trap 'rm -rf "$PLUGIN_DIR"' ERR

# Bundles have no rpath by default. These two resolve from PlugIns/<kind>/ and
# from a flat layout, which is where the SDK frameworks live inside the app.
#
# LIBS carries the system libraries from the core's Frameworks phase (libz for
# cores that bundle minizip, libbz2, ...). Only libX.dylib/.tbd entries become
# -lX; Apple frameworks are deliberately not mapped.
LIB_FLAGS=()
for lib in "${LIBS[@]}"; do
  LIB_FLAGS+=(-l "$lib")
done

# Extra link inputs a core needs beyond its own sources (currently MAME's
# emulator dylib).
LINK_EXTRA=("${EXTRA_LINK_FLAGS[@]:-}")

xcrun -sdk "$SDK_NAME" clang++ \
  -bundle \
  -target "$TARGET" \
  -isysroot "$SDK" \
  -o "$PLUGIN_DIR/$PRODUCT" \
  -F "$SDK_BUILD" \
  "${CATALYST_FRAMEWORKS[@]}" \
  -framework OpenEmuBase \
  -framework OpenEmuSystem \
  -framework Foundation \
  -framework Metal \
  -framework CoreGraphics \
  "${LIB_FLAGS[@]}" \
  "${LINK_EXTRA[@]}" \
  -Wl,-rpath,@executable_path/../../Frameworks \
  -Wl,-rpath,@loader_path/../../Frameworks \
  -Wl,-rpath,@loader_path \
  -Wl,-dead_strip \
  "$OUT"/*.o

# Some cores ship a dylib alongside the plugin binary. The install name is
# rewritten to a loader-relative path so the bundle is relocatable.
for lib_path in "${EMBED_LIBS[@]:-}"; do
  [[ -f "$lib_path" ]] || continue
  cp -f "$lib_path" "$PLUGIN_DIR/"
  install_name_tool -id "@loader_path/${lib_path:t}" "$PLUGIN_DIR/${lib_path:t}" 2>/dev/null || true
done

# Rewrite every reference to an embedded dylib, whatever spelling the linker
# recorded (the path as passed, a relativised version, or just the basename).
for lib_path in "${EMBED_LIBS[@]:-}"; do
  [[ -f "$PLUGIN_DIR/${lib_path:t}" ]] || continue
  while read -r recorded; do
    [[ -n "$recorded" ]] || continue
    [[ "$recorded" == "@loader_path/"* ]] && continue
    install_name_tool -change "$recorded" "@loader_path/${lib_path:t}" "$PLUGIN_DIR/$PRODUCT" 2>/dev/null || true
  done < <(otool -L "$PLUGIN_DIR/$PRODUCT" 2>/dev/null | grep -F "${lib_path:t}" | awk '{print $1}')
done

# Expand the Info.plist the way Xcode would. Its location comes from the
# project's INFOPLIST_FILE (Potator keeps it under Potator/, blueMSX names it
# blueMSX-Info.plist) rather than assuming $PROJECT_DIR/Info.plist.
python3 - "$INFO_PLIST" "$PLUGIN_DIR/Info.plist" "$PRODUCT" "$BUNDLE_ID" <<'PY'
import os, plistlib, sys

source, destination, product, bundle_id = sys.argv[1:5]

with open(source, 'rb') as fh:
    info = plistlib.load(fh)

substitutions = {
    '$(EXECUTABLE_NAME)': product,
    '${EXECUTABLE_NAME}': product,
    '$(PRODUCT_NAME)': product,
    '${PRODUCT_NAME}': product,
    '$(PRODUCT_NAME:identifier)': product,
    '$(PRODUCT_NAME:rfc1034identifier)': product,
    '$(PRODUCT_NAME:c99extidentifier)': product,
    # The bundle identifier is resolved separately (it can itself contain a
    # variable, e.g. org.openemu.${PRODUCT_NAME:rfc1034identifier}), so map
    # every spelling of it here once bundle_id is known.
    '$(PRODUCT_BUNDLE_IDENTIFIER)': bundle_id,
    '${PRODUCT_BUNDLE_IDENTIFIER}': bundle_id,
    '$(DEVELOPMENT_LANGUAGE)': 'en',
}

def expand(value):
    if isinstance(value, str):
        for needle, replacement in substitutions.items():
            value = value.replace(needle, replacement)
        # Anything left is a build setting with no meaning here.
        while '$(' in value and ')' in value:
            start = value.index('$(')
            end = value.index(')', start)
            value = value[:start] + value[end + 1:]
        return value
    if isinstance(value, dict):
        return {k: expand(v) for k, v in value.items()}
    if isinstance(value, list):
        return [expand(v) for v in value]
    return value

info = expand(info)
# setdefault is not enough: several projects declare the key with an empty
# value, which setdefault would keep. An empty bundle identifier breaks core
# identification in the app (every core would share the same id).
for key, fallback in (('CFBundleIdentifier', bundle_id),
                      ('CFBundleExecutable', product),
                      ('CFBundlePackageType', 'BNDL')):
    if not info.get(key):
        info[key] = fallback

with open(destination, 'wb') as fh:
    plistlib.dump(info, fh)
PY

# Localizations, if the core has any.
for lproj in "$PROJECT_DIR"/*.lproj; do
  [[ -d "$lproj" ]] && cp -R "$lproj" "$PLUGIN_DIR/" 2>/dev/null || true
done

print -- "linked $PLUGIN_DIR"
