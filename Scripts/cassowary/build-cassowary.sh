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
#   Scripts/cassowary/build-cassowary.sh [--device | --catalyst] [--app-only]
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

# xcodebuild's -destination already picks the SDK for Catalyst; adding -sdk
# macosx on top would override the variant and build plain macOS.
SDK_FLAGS=(-sdk "$SDK_NAME")
if [[ "$MODE" == catalyst ]]; then
  SDK_FLAGS=()
fi
BUILD="$PWD/build/cassowary-$MODE"
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
      "${SDK_FLAGS[@]}" \
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
    "${SDK_FLAGS[@]}" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CONFIGURATION_BUILD_DIR="$BUILD" \
    build >/dev/null

  banner "Collecting the frameworks"
  mkdir -p Cassowary/Frameworks
  rm -rf Cassowary/Frameworks/*.framework
  for framework in OpenEmuBase OpenEmuSystem OpenEmuKit OpenEmuShaders; do
    if [[ ! -d "$BUILD/$framework.framework" ]]; then
      print -u2 -- "error: $BUILD/$framework.framework is missing"
      exit 1
    fi
    cp -R "$BUILD/$framework.framework" Cassowary/Frameworks/
  done
fi

# 4. Plugins. They are staged into the app's PlugIns directory, which is the
#    layout OEPlugin scans inside the bundle. The library UI is data-driven:
#    every staged system plugin becomes a system row, and every staged core
#    appears in that system's core picker — so this step is what "adds the
#    systems to the UI".
if [[ $APP_ONLY -eq 0 ]]; then
  banner "Building the system plugins"
  case "$MODE" in
    simulator) PLUGIN_MODE_FLAG="" ;;
    device)    PLUGIN_MODE_FLAG="--device" ;;
    catalyst)  PLUGIN_MODE_FLAG="--catalyst" ;;
  esac
  ./Scripts/cassowary/build-all-system-plugins-ios.sh $PLUGIN_MODE_FLAG --keep-going

  # The bitmap cores, as source directory → product bundle name. The two
  # differ in case (picodrive → Picodrive) or in full (Potator-Core →
  # Potator), so both are listed. Extend this list when a new core is ported.
  CORES=(
    4DO:4DO Atari800:Atari800 Bliss:Bliss blueMSX:blueMSX BSNES:BSNES
    CrabEmu:CrabEmu FCEU:FCEU Gambatte:Gambatte GenesisPlus:GenesisPlus
    JollyCV:JollyCV MAME:MAME Mednafen:Mednafen mGBA:mGBA
    Mupen64Plus:Mupen64Plus Nestopia:Nestopia O2EM:O2EM picodrive:Picodrive
    PokeMini:PokeMini Potator-Core:Potator ProSystem:ProSystem SNES9x:SNES9x
    Stella:Stella VirtualJaguar:VirtualJaguar
  )

  case "$MODE" in
    simulator) CORE_MODE_FLAG="" ; CORE_OUT="build/cassowary-plugins" ;;
    device)    CORE_MODE_FLAG="--device" ; CORE_OUT="build/cassowary-plugins" ;;
    catalyst)  CORE_MODE_FLAG="--catalyst" ; CORE_OUT="build/cassowary-plugins-catalyst" ;;
  esac

  # Cores take tens of minutes in total, so only build what is missing from
  # that mode's output directory. A core that fails warns loudly and is
  # skipped for now.
  for pair in "${CORES[@]}"; do
    product="${pair#*:}.oecoreplugin"
    if [[ -d "$CORE_OUT/$product" ]]; then
      continue
    fi
    print -- "building missing core ${pair%%:*}..."
    if ! ./Scripts/cassowary/build-core-ios.sh "${pair%%:*}" $CORE_MODE_FLAG; then
      print -u2 -- "warning: ${pair%%:*} did not build; it will be missing from the app"
    fi
  done
  WANT_PRODUCTS=()

  # Stage what was built — nothing else. A broken controller in any staged
  # plugin crashes the library at startup, so the husk check below stays:
  # a staged plugin without an Info.plist is pruned, loudly.
  rm -rf Cassowary/PlugIns/Cores/*.oecoreplugin
  rm -rf Cassowary/PlugIns/Systems/*.oesystemplugin
  if [[ ${#WANT_PRODUCTS[@]} -gt 0 ]]; then
    for product in "${WANT_PRODUCTS[@]}"; do
      kind=Cores
      case "$product" in *.oesystemplugin) kind=Systems ;; esac
      src="build/cassowary-plugins-$MODE/$product"
      if [[ -d "$src" ]]; then
        cp -R "$src" "Cassowary/PlugIns/$kind/"
      else
        print -u2 -- "error: $src missing; its build step failed"
        exit 1
      fi
    done
  else
    # Note: core bundles currently share one output directory across modes,
    # so a device build stages whatever was built last for that directory.
    # System plugins are mode-separated (build/cassowary-plugins-$MODE).
    staged=0
    for src in "$CORE_OUT"/*.oecoreplugin; do
      [[ -d "$src" ]] || continue
      cp -R "$src" Cassowary/PlugIns/Cores/
      staged=$((staged + 1))
    done
    [[ $staged -gt 0 ]] || {
      print -u2 -- "error: no core bundles in $CORE_OUT"
      exit 1
    }
    print -- "staged $staged core bundles"
    staged=0
    for src in build/cassowary-plugins-$MODE/*.oesystemplugin; do
      [[ -d "$src" ]] || continue
      cp -R "$src" Cassowary/PlugIns/Systems/
      staged=$((staged + 1))
    done
    [[ $staged -gt 0 ]] || {
      print -u2 -- "error: no system plugins in build/cassowary-plugins-$MODE"
      exit 1
    }
    print -- "staged $staged system plugins"
  fi

  # A staged plugin without an Info.plist is a husk from a failed build. It
  # scans as a bundle with an empty infoDictionary and crashes the app at
  # startup, so prune it here and say so loudly. (The build scripts also
  # remove their own husks on failure; this guards against stale ones.)
  for staged in Cassowary/PlugIns/Cores/*.oecoreplugin Cassowary/PlugIns/Systems/*.oesystemplugin; do
    [[ -e "$staged" ]] || continue
    if [[ ! -f "$staged/Info.plist" ]]; then
      print -u2 -- "warning: dropping $staged (no Info.plist — its build failed)"
      rm -rf "$staged"
    fi
  done
fi

# 5. The app.
banner "Generating the Xcode project"
xcodegen generate --spec Cassowary/project.yml --project Cassowary >/dev/null

banner "Building the app"
xcodebuild -project Cassowary/Cassowary.xcodeproj \
  -scheme Cassowary \
  -configuration Debug \
  -destination "$DESTINATION" \
  "${SDK_FLAGS[@]}" \
  -derivedDataPath "$BUILD/app" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  build

case "$MODE" in
  catalyst) PRODUCT_DIR=Debug-maccatalyst ;;
  *)        PRODUCT_DIR=Debug-$APP_PLATFORM ;;
esac
APP="$BUILD/app/Build/Products/$PRODUCT_DIR/Cassowary.app"

# Mac Catalyst is signed ad-hoc after the fact. Xcode wants a development team
# to sign a Catalyst target, and a local build only needs a valid signature so
# that the sandbox entitlements take effect. Nested code is signed first,
# innermost out, because signing a bundle seals its contents.
if [[ "$MODE" == catalyst ]]; then
  banner "Signing ad-hoc"
  ENTITLEMENTS="$PWD/Cassowary/Resources/Cassowary.entitlements"

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
