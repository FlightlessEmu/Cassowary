#!/bin/zsh
#
# Build a system plugin for iOS.
#
# System plugins are small bundles that describe a console: its controls, its
# file types, and the responder that turns HID events into button presses.
# Unlike cores they have no emulator code, so they are quick to build.
#
# Usage:
#   Scripts/cassowary/build-system-plugin-ios.sh <PluginName> [--device]
#
# Example:
#   Scripts/cassowary/build-system-plugin-ios.sh GameBoy

set -euo pipefail

# zsh errors on a glob that matches nothing; these loops are meant to tolerate
# a plugin having no files of a given kind.
setopt NULL_GLOB 2>/dev/null || true

cd "${0:A:h}/../.."

PLUGIN=${1:?usage: build-system-plugin-ios.sh <PluginName> [--device]}
shift || true

MODE=simulator
case "${1:-}" in
  --device)   MODE=device ;;
  --catalyst) MODE=catalyst ;;
esac

case "$MODE" in
  simulator) SDK_NAME=iphonesimulator ; TARGET=arm64-apple-ios17.0-simulator ;;
  device)    SDK_NAME=iphoneos        ; TARGET=arm64-apple-ios17.0 ;;
  catalyst)  SDK_NAME=macosx          ; TARGET=arm64-apple-ios17.0-macabi ;;
esac

# The directory name under OpenEmu/SystemPlugins that holds the plugin.
SOURCE_DIR="OpenEmu/SystemPlugins/${PLUGIN}"
if [[ ! -d "$SOURCE_DIR" ]]; then
  print -u2 -- "error: no system plugin at $SOURCE_DIR"
  exit 1
fi

SDK=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
case "$MODE" in
  catalyst) SDK_BUILD="$PWD/build/catalyst" ;;
  *)        SDK_BUILD="$PWD/OpenEmu-SDK/build/Debug-iphone${MODE}" ;;
esac
OUT="build/cassowary-plugins-${MODE}/${PLUGIN}.oesystemplugin"

# Never leave a half-built husk: an empty *.oesystemplugin scans as a bundle
# with an empty Info.plist, and the app's plugin scan crashes on it at
# startup (OESystemPlugin asserts OESystemIdentifier). A failed build must
# leave nothing behind so the next step can report it missing instead.
trap 'rm -rf "$OUT"' ERR

# Swift module names must be valid identifiers. Plugin directories like
# "Atari 2600" contain spaces, so map anything outside [A-Za-z0-9_] to an
# underscore for -module-name only. The bundle and binary keep the real name.
MODULE=$(printf '%s' "$PLUGIN" | tr -c 'A-Za-z0-9_' '_')

CATALYST_FRAMEWORKS=()
if [[ "$MODE" == catalyst ]]; then
  CATALYST_FRAMEWORKS=(-iframework "$SDK/System/iOSSupport/System/Library/Frameworks")
fi

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
  "${CATALYST_FRAMEWORKS[@]}"
  -F "$SDK_BUILD"
  -w
)

OBJECTS=()
for source in "$SOURCE_DIR"/*.m "$SOURCE_DIR"/*.mm; do
  [[ -f "$source" ]] || continue
  object="build/cassowary-${PLUGIN}-${source:t}.o"
  xcrun -sdk "$SDK_NAME" clang -c "$source" -o "$object" "${FLAGS[@]}" "${INCLUDES[@]}"
  OBJECTS+=("$object")
done

for source in "$SOURCE_DIR"/*.swift; do
  [[ -f "$source" ]] || continue
  object="build/cassowary-${PLUGIN}-${source:t}.o"
  xcrun -sdk "$SDK_NAME" swiftc \
    -c "$source" \
    -o "$object" \
    -target "$TARGET" \
    -sdk "$SDK" \
    -swift-version 5 \
    -I "$SDK_BUILD" \
    -F "$SDK_BUILD" \
    -module-name "$MODULE" \
    -parse-as-library
  OBJECTS+=("$object")
done

# The plugin links the SDK frameworks, which live in the app's Frameworks
# directory. Bundles have no rpath by default, so add the two that let the
# loader find them: one for when the plugin sits in PlugIns/<kind>/ and one for
# when it is loaded from Application Support during development.
xcrun -sdk "$SDK_NAME" clang \
  -bundle \
  -target "$TARGET" \
  -isysroot "$SDK" \
  -o "$OUT/$PLUGIN" \
  "${CATALYST_FRAMEWORKS[@]}" \
  -F "$SDK_BUILD" \
  -framework OpenEmuBase \
  -framework OpenEmuSystem \
  -framework Foundation \
  -Wl,-rpath,@executable_path/../../Frameworks \
  -Wl,-rpath,@executable_path/../../../Frameworks \
  -Wl,-rpath,@loader_path/../../Frameworks \
  -Wl,-rpath,@loader_path/../../../Frameworks \
  "${OBJECTS[@]}"

# Expand the Info.plist the way Xcode would.
python3 - "$SOURCE_DIR" "$OUT" "$PLUGIN" "$MODULE" <<'PY'
import glob, os, plistlib, sys

source_dir, out_dir, plugin, module = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# System plugins keep their Info.plist under a "<Name>-Info.plist" name.
candidates = glob.glob(os.path.join(source_dir, '*-Info.plist')) or [os.path.join(source_dir, 'Info.plist')]
with open(candidates[0], 'rb') as fh:
    info = plistlib.load(fh)

substitutions = {
    '$(EXECUTABLE_NAME)': plugin,
    '${EXECUTABLE_NAME}': plugin,
    # Xcode's :c99extidentifier modifier turns the product name into a valid C
    # identifier, which for a Swift plugin is the module name. Names with
    # spaces ("GameBoy Advance") differ from the raw product name, and the
    # principal class is looked up by the module-qualified name.
    '$(PRODUCT_NAME:c99extidentifier)': module,
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
ACTOOL_PLATFORM="iphone${MODE}"
[[ "$MODE" == catalyst ]] && ACTOOL_PLATFORM="macosx"
if [[ -d "$SOURCE_DIR/Images.xcassets" ]]; then
  xcrun actool "$SOURCE_DIR/Images.xcassets" \
    --compile "$OUT" \
    --platform "$ACTOOL_PLATFORM" \
    --minimum-deployment-target 17.0 \
    --target-device iphone --target-device ipad \
    --output-format human-readable-text >/dev/null
fi

print -- "built $OUT"
file "$OUT/$PLUGIN"
