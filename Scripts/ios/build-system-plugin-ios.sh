#!/bin/zsh
#
# Build a system plugin for iOS.
#
# System plugins are small bundles that describe a console: its controls, its
# file types, and the responder that turns HID events into button presses.
# Unlike cores they have no emulator code, so they are quick to build.
#
# Usage:
#   Scripts/ios/build-system-plugin-ios.sh <PluginName> [--device]
#
# Example:
#   Scripts/ios/build-system-plugin-ios.sh GameBoy

set -euo pipefail

# zsh errors on a glob that matches nothing; these loops are meant to tolerate
# a plugin having no files of a given kind.
setopt NULL_GLOB 2>/dev/null || true

cd "${0:A:h}/../.."

PLUGIN=${1:?usage: build-system-plugin-ios.sh <PluginName> [--device]}
shift || true

PLATFORM=simulator
TARGET=arm64-apple-ios17.0-simulator
if [[ "${1:-}" == "--device" ]]; then
  PLATFORM=device
  TARGET=arm64-apple-ios17.0
fi

# The directory name under OpenEmu/SystemPlugins that holds the plugin.
SOURCE_DIR="OpenEmu/SystemPlugins/${PLUGIN}"
if [[ ! -d "$SOURCE_DIR" ]]; then
  print -u2 -- "error: no system plugin at $SOURCE_DIR"
  exit 1
fi

SDK=$(xcrun --sdk iphone${PLATFORM} --show-sdk-path)
SDK_BUILD="$PWD/OpenEmu-SDK/build/Debug-iphone${PLATFORM}"
OUT="build/ios-plugins/${PLUGIN}.oesystemplugin"

if [[ ! -d "$SDK_BUILD/OpenEmuSystem.framework" ]]; then
  print -u2 -- "building the SDK for iOS first..."
  xcodebuild -project OpenEmu-SDK/OpenEmu-SDK.xcodeproj \
    -target OpenEmuBase -target OpenEmuSystem \
    -configuration Debug -sdk iphone${PLATFORM} \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build >/dev/null
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# The plugin imports the SDK as frameworks, so it needs both the header search
# root and the built frameworks on the framework search path.
INCLUDES=(
  -I "$PWD/OpenEmu-SDK"
  -I "$PWD/OpenEmu-SDK/OpenEmuBase"
  -I "$PWD/OpenEmu-SDK/OpenEmuSystem"
  -I "$SOURCE_DIR"
  -F "$SDK_BUILD"
)

FLAGS=(
  -target "$TARGET"
  -isysroot "$SDK"
  -fobjc-arc
  -fmodules
  -F "$SDK_BUILD"
  -w
)

OBJECTS=()
for source in "$SOURCE_DIR"/*.m "$SOURCE_DIR"/*.mm; do
  [[ -f "$source" ]] || continue
  object="build/ios-${PLUGIN}-${source:t}.o"
  xcrun -sdk iphone${PLATFORM} clang -c "$source" -o "$object" "${FLAGS[@]}" "${INCLUDES[@]}"
  OBJECTS+=("$object")
done

for source in "$SOURCE_DIR"/*.swift; do
  [[ -f "$source" ]] || continue
  object="build/ios-${PLUGIN}-${source:t}.o"
  xcrun -sdk iphone${PLATFORM} swiftc \
    -c "$source" \
    -o "$object" \
    -target "$TARGET" \
    -sdk "$SDK" \
    -swift-version 5 \
    -I "$SDK_BUILD" \
    -F "$SDK_BUILD" \
    -module-name "$PLUGIN" \
    -parse-as-library
  OBJECTS+=("$object")
done

# The plugin links the SDK frameworks, which live in the app's Frameworks
# directory. Bundles have no rpath by default, so add the two that let the
# loader find them: one for when the plugin sits in PlugIns/<kind>/ and one for
# when it is loaded from Application Support during development.
xcrun -sdk iphone${PLATFORM} clang \
  -bundle \
  -target "$TARGET" \
  -isysroot "$SDK" \
  -o "$OUT/$PLUGIN" \
  -F "$SDK_BUILD" \
  -framework OpenEmuBase \
  -framework OpenEmuSystem \
  -framework Foundation \
  -Wl,-rpath,@executable_path/../../Frameworks \
  -Wl,-rpath,@loader_path/../../Frameworks \
  "${OBJECTS[@]}"

# Expand the Info.plist the way Xcode would.
python3 - "$SOURCE_DIR" "$OUT" "$PLUGIN" <<'PY'
import glob, os, plistlib, sys

source_dir, out_dir, plugin = sys.argv[1], sys.argv[2], sys.argv[3]

# System plugins keep their Info.plist under a "<Name>-Info.plist" name.
candidates = glob.glob(os.path.join(source_dir, '*-Info.plist')) or [os.path.join(source_dir, 'Info.plist')]
with open(candidates[0], 'rb') as fh:
    info = plistlib.load(fh)

substitutions = {
    '$(EXECUTABLE_NAME)': plugin,
    '${EXECUTABLE_NAME}': plugin,
    '$(PRODUCT_NAME:c99extidentifier)': plugin,
    '$(PRODUCT_NAME)': plugin,
    '$(PRODUCT_BUNDLE_IDENTIFIER)': f'org.openemu.{plugin}',
    '$(PRODUCT_BUNDLE_PACKAGE_TYPE)': 'BNDL',
    '$(DEVELOPMENT_LANGUAGE)': 'en',
}

def expand(value):
    if isinstance(value, str):
        for needle, replacement in substitutions.items():
            value = value.replace(needle, replacement)
        return value
    if isinstance(value, dict):
        return {k: expand(v) for k, v in value.items()}
    if isinstance(value, list):
        return [expand(v) for v in value]
    return value

with open(os.path.join(out_dir, 'Info.plist'), 'wb') as fh:
    plistlib.dump(expand(info), fh)
PY

# Copy the plugin's resources alongside it.
for resource in "$SOURCE_DIR"/*.plist; do
  [[ -f "$resource" ]] || continue
  case "$resource" in
    *-Info.plist) continue ;;
  esac
  cp "$resource" "$OUT/"
done

# Asset catalogs have to be compiled, not copied: the app reads them through
# NSBundle's asset API, which looks for Assets.car.
if [[ -d "$SOURCE_DIR/Images.xcassets" ]]; then
  xcrun actool "$SOURCE_DIR/Images.xcassets" \
    --compile "$OUT" \
    --platform "iphone${PLATFORM}" \
    --minimum-deployment-target 17.0 \
    --output-format human-readable-text >/dev/null
fi

print -- "built $OUT"
file "$OUT/$PLUGIN"
