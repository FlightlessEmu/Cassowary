#!/bin/zsh
#
# Build the iOS app and everything it loads.
#
# This is the one command that produces a runnable OpenEmu. It builds, in
# order:
#
#   1. the SDK frameworks (OpenEmuBase, OpenEmuSystem)
#   2. OpenEmuShaders, whose Metal library the renderer needs
#   3. OpenEmuKit, which runs the emulator
#   4. the core plugins and system plugins
#   5. the app itself
#
# Usage:
#   Scripts/ios/build-ios.sh [--device | --catalyst] [--app-only]
#
#   --device     target a real iPhone instead of the Simulator
#   --catalyst   build the same app natively for the Mac (Mac Catalyst)
#   --app-only   skip the frameworks and plugins; just rebuild the app

set -euo pipefail

cd "${0:A:h}/../.."
setopt NULL_GLOB 2>/dev/null || true

MODE=simulator
APP_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --device)   MODE=device ;;
    --catalyst) MODE=catalyst ;;
    --app-only) APP_ONLY=1 ;;
    *)
      print -u2 -- "unknown option: $arg"
      exit 1
      ;;
  esac
done

# Each mode differs in three ways: which SDK, which ABI, and which destination
# string the build system understands.
case "$MODE" in
  simulator)
    SDK_NAME=iphonesimulator
    DESTINATION='generic/platform=iOS Simulator'
    ;;
  device)
    SDK_NAME=iphoneos
    DESTINATION='generic/platform=iOS'
    ;;
  catalyst)
    SDK_NAME=macosx
    DESTINATION='platform=macOS,variant=Mac Catalyst'
    ;;
esac

APP_PLATFORM=$SDK_NAME
BUILD="$PWD/build/ios-$MODE"
SUPPORTED="iphoneos iphonesimulator macosx"

banner() {
  print -- ""
  print -- "==> $1"
}

# 1. SDK frameworks.
if [[ $APP_ONLY -eq 0 ]]; then
  banner "Building the SDK frameworks"
  for target in OpenEmuBase OpenEmuSystem; do
    xcodebuild -project OpenEmu-SDK/OpenEmu-SDK.xcodeproj \
      -scheme "$target" \
      -configuration Debug \
      -destination "$DESTINATION" \
      -sdk "$SDK_NAME" \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
      CONFIGURATION_BUILD_DIR="$BUILD" \
      build >/dev/null
  done
fi

# 2 and 3. OpenEmuShaders and OpenEmuKit come from the workspace, which
# resolves OpenEmuShaders' Swift package dependencies.
if [[ $APP_ONLY -eq 0 ]]; then
  banner "Building OpenEmuKit"
  xcodebuild -workspace OpenEmu-metal.xcworkspace \
    -scheme OpenEmuKit \
    -configuration Debug \
    -destination "$DESTINATION" \
    -sdk "$SDK_NAME" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CONFIGURATION_BUILD_DIR="$BUILD" \
    build >/dev/null

  banner "Collecting the frameworks"
  mkdir -p OpenEmu-iOS/Frameworks
  rm -rf OpenEmu-iOS/Frameworks/*.framework
  for framework in OpenEmuBase OpenEmuSystem OpenEmuKit OpenEmuShaders; do
    if [[ ! -d "$BUILD/$framework.framework" ]]; then
      print -u2 -- "error: $BUILD/$framework.framework is missing"
      exit 1
    fi
    cp -R "$BUILD/$framework.framework" OpenEmu-iOS/Frameworks/
  done
fi

# 4. Plugins. They are staged into the app's PlugIns directory, which is the
#    layout OEPlugin scans inside the bundle.
if [[ $APP_ONLY -eq 0 ]]; then
  banner "Building the cores and system plugins"
  ./Scripts/ios/build-gambatte-ios.sh "$@" >/dev/null
  ./Scripts/ios/link-gambatte-ios.sh "$@" >/dev/null
  ./Scripts/ios/build-system-plugin-ios.sh GameBoy "$@" >/dev/null

  rm -rf OpenEmu-iOS/PlugIns/Cores/*.oecoreplugin
  rm -rf OpenEmu-iOS/PlugIns/Systems/*.oesystemplugin
  cp -R build/ios-plugins-$MODE/*.oecoreplugin OpenEmu-iOS/PlugIns/Cores/ 2>/dev/null || true
  cp -R build/ios-plugins-$MODE/*.oesystemplugin OpenEmu-iOS/PlugIns/Systems/ 2>/dev/null || true
fi

# 5. The app.
banner "Generating the Xcode project"
xcodegen generate --spec OpenEmu-iOS/project.yml --project OpenEmu-iOS >/dev/null

banner "Building the app"
xcodebuild -project OpenEmu-iOS/OpenEmu-iOS.xcodeproj \
  -scheme OpenEmu-iOS \
  -configuration Debug \
  -destination "$DESTINATION" \
  -sdk "$SDK_NAME" \
  -derivedDataPath "$BUILD/app" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  build

case "$MODE" in
  catalyst) PRODUCT_DIR=Debug-maccatalyst ;;
  *)        PRODUCT_DIR=Debug-$APP_PLATFORM ;;
esac
APP="$BUILD/app/Build/Products/$PRODUCT_DIR/OpenEmu.app"

# Mac Catalyst is signed ad-hoc after the fact. Xcode wants a development team
# to sign a Catalyst target, and a local build only needs a valid signature so
# that the sandbox entitlements take effect. Nested code is signed first,
# innermost out, because signing a bundle seals its contents.
if [[ "$MODE" == catalyst ]]; then
  banner "Signing ad-hoc"
  ENTITLEMENTS="$PWD/OpenEmu-iOS/Resources/OpenEmu-Catalyst.entitlements"

  find "$APP/Contents/Frameworks" -name "*.framework" -maxdepth 1 | while read -r framework; do
    codesign --force --sign - "$framework" 2>/dev/null
  done

  find "$APP/Contents/PlugIns" -name "*.oecoreplugin" -o -name "*.oesystemplugin" | while read -r plugin; do
    codesign --force --sign - "$plugin" 2>/dev/null
  done

  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
fi

print -- ""
print -- "built $APP"
