#!/bin/zsh
#
# Link the compiled Gambatte objects into an iOS .oecoreplugin bundle.
#
# Run Scripts/ios/build-gambatte-ios.sh first; this picks up the objects it
# produced. The result is a bundle with the same layout OpenEmu expects on
# macOS, so the host app can load it with the existing plugin machinery.
#
# Usage:
#   Scripts/ios/link-gambatte-ios.sh [--device]

set -euo pipefail

cd "${0:A:h}/../.."

# Matches the modes build-gambatte-ios.sh understands.
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

SDK=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
OBJECTS_DIR="build/ios-gambatte-${MODE}"
PLUGIN_DIR="build/ios-plugins-${MODE}/Gambatte.oecoreplugin"

if [[ ! -d "$OBJECTS_DIR" ]]; then
  print -u2 -- "error: no objects in $OBJECTS_DIR; run Scripts/ios/build-gambatte-ios.sh first"
  exit 1
fi

rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"

# The core plugin links against the two SDK frameworks, which are built as part
# of the iOS app target. At this stage they are linked from the SDK build tree.
case "$MODE" in
  catalyst) SDK_BUILD="$PWD/build/catalyst" ;;
  *)        SDK_BUILD="$PWD/OpenEmu-SDK/build/Debug-iphone${MODE}" ;;
esac
FRAMEWORKS=(
  "$SDK_BUILD/OpenEmuBase.framework"
  "$SDK_BUILD/OpenEmuSystem.framework"
)

for framework in "${FRAMEWORKS[@]}"; do
  if [[ ! -d "$framework" ]]; then
    print -u2 -- "error: missing $framework"
    print -u2 -- "       build the SDK first:"
    print -u2 -- "       see Scripts/ios/build-ios.sh for the right invocation"
    exit 1
  fi
done

# The bundle is a loadable Mach-O. iOS allows dlopen of bundles signed with the
# app's own team, which is what the host app relies on.
# Bundles have no rpath by default, so add the two that let the loader find the
# SDK frameworks in the app's Frameworks directory: one for when the plugin
# sits in PlugIns/<kind>/, and one for a flat layout.
CATALYST_FRAMEWORKS=()
if [[ "$MODE" == catalyst ]]; then
  CATALYST_FRAMEWORKS=(-iframework "$SDK/System/iOSSupport/System/Library/Frameworks")
fi

xcrun -sdk "$SDK_NAME" clang++ \
  -bundle \
  -target "$TARGET" \
  -isysroot "$SDK" \
  -o "$PLUGIN_DIR/Gambatte" \
  "${CATALYST_FRAMEWORKS[@]}" \
  -F "$SDK_BUILD" \
  -framework OpenEmuBase \
  -framework OpenEmuSystem \
  -framework Foundation \
  -framework Metal \
  -framework CoreGraphics \
  -Wl,-rpath,@executable_path/../../Frameworks \
  -Wl,-rpath,@executable_path/../../../Frameworks \
  -Wl,-rpath,@loader_path/../../Frameworks \
  -Wl,-rpath,@loader_path/../../../Frameworks \
  "$OBJECTS_DIR"/*.o

# The Info.plist is the same one the macOS build uses, but Xcode normally
# expands its $(...) build settings. Nothing does that here, so substitute the
# values the bundle needs to be loadable.
python3 - "$PLUGIN_DIR/Info.plist" <<'PY'
import plistlib, sys

src = 'Gambatte/Info.plist'
dst = sys.argv[1]

with open(src, 'rb') as fh:
    info = plistlib.load(fh)

substitutions = {
    '$(EXECUTABLE_NAME)': 'Gambatte',
    '${EXECUTABLE_NAME}': 'Gambatte',
    '$(PRODUCT_BUNDLE_IDENTIFIER)': 'org.openemu.Gambatte',
    '$(DEVELOPMENT_LANGUAGE)': 'en',
    '$(PRODUCT_NAME)': 'Gambatte',
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

with open(dst, 'wb') as fh:
    plistlib.dump(expand(info), fh)
PY

# Core artwork and localizations, if any.
[[ -d Gambatte/en.lproj ]] && cp -R Gambatte/en.lproj "$PLUGIN_DIR/" 2>/dev/null || true

print -- "built $PLUGIN_DIR"
file "$PLUGIN_DIR/Gambatte"
