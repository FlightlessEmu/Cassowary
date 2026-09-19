#!/bin/zsh
#
# Build the iOS app and everything it loads.
#
# This is the one command that produces a runnable OpenEmu for the iOS
# Simulator. It builds, in order:
#
#   1. the SDK frameworks (OpenEmuBase, OpenEmuSystem)
#   2. OpenEmuShaders, whose Metal library the renderer needs
#   3. OpenEmuKit, which runs the emulator
#   4. the core plugins and system plugins
#   5. the app itself
#
# Usage:
#   Scripts/ios/build-ios.sh [--device] [--app-only]
#
#   --device     target a real iPhone instead of the Simulator
#   --app-only   skip the frameworks and plugins; just rebuild the app

set -euo pipefail

# Some globs below are meant to match nothing on a first build.
setopt NULL_GLOB 2>/dev/null || true

cd "${0:A:h}/../.."

PLATFORM=simulator
TARGET=arm64-apple-ios17.0-simulator
SDK_NAME=iphonesimulator
APP_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --device)
      PLATFORM=device
      TARGET=arm64-apple-ios17.0
      SDK_NAME=iphoneos
      ;;
    --app-only) APP_ONLY=1 ;;
    *)
      print -u2 -- "unknown option: $arg"
      exit 1
      ;;
  esac
done

DESTINATION="generic/platform=iOS Simulator"
[[ "$PLATFORM" == "device" ]] && DESTINATION="generic/platform=iOS"

DERIVED="$PWD/build/ios-derived-$PLATFORM"
SDK_BUILD="OpenEmu-SDK/build/Debug-$SDK_NAME"

banner() {
  print -- ""
  print -- "==> $1"
}

# 1. SDK frameworks.
if [[ $APP_ONLY -eq 0 ]]; then
  banner "Building the SDK frameworks"
  xcodebuild -project OpenEmu-SDK/OpenEmu-SDK.xcodeproj \
    -target OpenEmuBase -target OpenEmuSystem \
    -configuration Debug -sdk "$SDK_NAME" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build >/dev/null
fi

# 2 and 3. OpenEmuShaders and OpenEmuKit come from the workspace, which
# resolves OpenEmuShaders' Swift package dependencies.
if [[ $APP_ONLY -eq 0 ]]; then
  banner "Building OpenEmuKit"
  xcodebuild -workspace OpenEmu-metal.xcworkspace \
    -scheme OpenEmuKit -configuration Debug -sdk "$SDK_NAME" \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build >/dev/null

  banner "Collecting the frameworks"
  mkdir -p OpenEmu-iOS/Frameworks
  rm -rf OpenEmu-iOS/Frameworks/*.framework
  for framework in OpenEmuBase OpenEmuSystem OpenEmuKit OpenEmuShaders; do
    source_path="$DERIVED/Build/Products/Debug-$SDK_NAME/$framework.framework"
    [[ -d "$source_path" ]] || source_path="$SDK_BUILD/$framework.framework"
    if [[ ! -d "$source_path" ]]; then
      print -u2 -- "error: could not find $framework.framework"
      exit 1
    fi
    cp -R "$source_path" OpenEmu-iOS/Frameworks/
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
  cp -R build/ios-plugins/*.oecoreplugin OpenEmu-iOS/PlugIns/Cores/ 2>/dev/null || true
  cp -R build/ios-plugins/*.oesystemplugin OpenEmu-iOS/PlugIns/Systems/ 2>/dev/null || true
fi

# 5. The app.
banner "Generating the Xcode project"
xcodegen generate --spec OpenEmu-iOS/project.yml --project OpenEmu-iOS >/dev/null

banner "Building the app"
xcodebuild -project OpenEmu-iOS/OpenEmu-iOS.xcodeproj \
  -scheme OpenEmu-iOS -configuration Debug -sdk "$SDK_NAME" \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build

APP="$DERIVED/Build/Products/Debug-$SDK_NAME/OpenEmu.app"
print -- ""
print -- "built $APP"
