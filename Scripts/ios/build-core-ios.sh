#!/bin/zsh
#
# Build any emulator core for iOS.
#
# The core's own Xcode project states its source list and build settings, so
# this script asks for those rather than keeping a second copy. See
# Scripts/ios/core-info.py.
#
# Usage:
#   Scripts/ios/build-core-ios.sh <CoreName> [--device] [--keep-going] [--quiet]
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
TARGET=arm64-apple-ios17.0-simulator
KEEP_GOING=0
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --device)
      PLATFORM=device
      TARGET=arm64-apple-ios17.0
      ;;
    --keep-going) KEEP_GOING=1 ;;
    --quiet) QUIET=1 ;;
    *) print -u2 -- "unknown option: $arg"; exit 1 ;;
  esac
done

SDK=$(xcrun --sdk iphone${PLATFORM} --show-sdk-path)
SDK_BUILD="$PWD/OpenEmu-SDK/build/Debug-iphone${PLATFORM}"
INFO_FILE="build/ios-core-info-${CORE}.json"
SHELL_FILE="build/ios-core-info-${CORE}.sh"

if [[ ! -d "$SDK_BUILD/OpenEmuBase.framework" ]]; then
  print -u2 -- "building the SDK frameworks for iOS first..."
  xcodebuild -project OpenEmu-SDK/OpenEmu-SDK.xcodeproj \
    -target OpenEmuBase -target OpenEmuSystem \
    -configuration Debug -sdk iphone${PLATFORM} \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build >/dev/null
fi

mkdir -p build
python3 Scripts/ios/core-info.py "$CORE" > "$INFO_FILE" 2>/dev/null || {
  print -u2 -- "error: could not read the project for $CORE"
  exit 1
}

# The shell assignments are written to a file and sourced, rather than built
# with `eval "$(python3 ... <<HEREDOC)"`. A heredoc inside a command
# substitution confuses zsh's parser badly enough that it silently reassigns
# PATH to the last value on the longest line.
python3 Scripts/ios/core-info.py "$CORE" --shell > "$SHELL_FILE"
source "$SHELL_FILE"

OUT="build/ios-cores-${PLATFORM}/${CORE}"
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
  -F "$SDK_BUILD"
  -I "$PWD/OpenEmu-SDK"
  -I "$PWD/OpenEmu-SDK/OpenEmuBase"
  -I "$PWD/OpenEmu-SDK/OpenEmuSystem"
  -I "$PWD/OpenEmuKit/Source"
  -I "$PWD/Vendor/rcheevos/include"
  -I "$PWD/Vendor/rcheevos/src"
  -w
  # Several cores predate modern C and rely on implicit integer/pointer
  # conversions that are now hard errors. They are warnings again here.
  -Wno-int-conversion
  "${INCLUDE_FLAGS[@]}"
  "${SYSTEM_PLUGIN_INCLUDES[@]}"
  "${EXTRA_CFLAGS[@]}"
)

[[ "$ARC" == "YES" ]] && COMMON+=(-fobjc-arc)


failures=()
compiled=0

# Walk the two parallel arrays so each file can carry its own flags.
for index in {1..${#SOURCES[@]}}; do
  source="${SOURCES[$index]}"
  file_flags="${SOURCE_FLAGS[$index]}"
  [[ -f "$source" ]] || continue

  case "$source" in
    *.m)    compiler=(xcrun -sdk iphone${PLATFORM} clang)   ;;
    *.mm)   compiler=(xcrun -sdk iphone${PLATFORM} clang++) ;;
    *.c)    compiler=(xcrun -sdk iphone${PLATFORM} clang)   ;;
    *.cc|*.cpp) compiler=(xcrun -sdk iphone${PLATFORM} clang++) ;;
    *.S|*.s) compiler=(xcrun -sdk iphone${PLATFORM} clang)  ;;
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

  if output=$("${compiler[@]}" -c "$source" -o "$object" "${COMMON[@]}" "${extra[@]}" 2>&1); then
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

PLUGIN_DIR="build/ios-plugins/${PRODUCT}.${WRAPPER}"
rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"

# Bundles have no rpath by default. These two resolve from PlugIns/<kind>/ and
# from a flat layout, which is where the SDK frameworks live inside the app.
xcrun -sdk iphone${PLATFORM} clang++ \
  -bundle \
  -target "$TARGET" \
  -isysroot "$SDK" \
  -o "$PLUGIN_DIR/$PRODUCT" \
  -F "$SDK_BUILD" \
  -framework OpenEmuBase \
  -framework OpenEmuSystem \
  -framework Foundation \
  -framework Metal \
  -framework CoreGraphics \
  -Wl,-rpath,@executable_path/../../Frameworks \
  -Wl,-rpath,@loader_path/../../Frameworks \
  "$OUT"/*.o

# Expand the Info.plist the way Xcode would.
python3 - "$PROJECT_DIR/Info.plist" "$PLUGIN_DIR/Info.plist" "$PRODUCT" "$BUNDLE_ID" <<'PY'
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
info.setdefault('CFBundleIdentifier', bundle_id)
info.setdefault('CFBundleExecutable', product)
info.setdefault('CFBundlePackageType', 'BNDL')

with open(destination, 'wb') as fh:
    plistlib.dump(info, fh)
PY

# Localizations, if the core has any.
for lproj in "$PROJECT_DIR"/*.lproj; do
  [[ -d "$lproj" ]] && cp -R "$lproj" "$PLUGIN_DIR/" 2>/dev/null || true
done

print -- "linked $PLUGIN_DIR"
