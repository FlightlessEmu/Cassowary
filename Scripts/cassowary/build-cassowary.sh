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
#                                       [--team TEAMID] [--udid UDID] [--no-sign]
#
#   --device     target a real iPhone instead of the Simulator
#   --catalyst   build the same app natively for the Mac (Mac Catalyst)
#   --app-only   skip the frameworks and plugins; just rebuild the app
#
# Device builds only:
#
#   --team       the Apple team to sign with. The default is DEVELOPMENT_TEAM
#                from the environment, then the Apple Development certificate
#                already on this Mac, then the team Xcode is set up to use.
#   --udid       the iPhone to build for. The default is the only device
#                devicectl can see. The phone is added to the provisioning
#                profile, which is what lets the app install.
#   --no-sign    build without signing. The app will not install on a phone;
#                this is for checking that a device build compiles.

set -euo pipefail

cd "${0:A:h}/../.."
setopt NULL_GLOB 2>/dev/null || true

MODE=simulator
APP_ONLY=0
SIGN=1
TEAM_ID=${DEVELOPMENT_TEAM:-}
DEVICE_UDID=${CASSOWARY_DEVICE_UDID:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)   MODE=device; shift ;;
    --catalyst) MODE=catalyst; shift ;;
    --app-only) APP_ONLY=1; shift ;;
    --team)     TEAM_ID=${2:?--team needs a team ID}; shift 2 ;;
    --udid)     DEVICE_UDID=${2:?--udid needs a device UDID}; shift 2 ;;
    --no-sign)  SIGN=0; shift ;;
    *)
      print -u2 -- "unknown option: $1"
      exit 1
      ;;
  esac
done

# The UDIDs CoreDevice can see, one per line. devicectl reports the hardware
# UDID, which is the same string xcodebuild's -destination wants.
device_udids() {
  xcrun devicectl list devices \
    --hide-default-columns --columns udid --hide-headers 2>/dev/null \
    | awk 'NF' | sort -u || true
}

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

# A real iPhone will not run an unsigned app, and it will not load the core
# plugins unless they are signed for the same team as the app. Signing is off
# in project.yml so Simulator and Catalyst builds need no Apple account; for
# --device it is switched back on here.
APP_DESTINATION=$DESTINATION
SIGN_FLAGS=()
if [[ "$MODE" == device && $SIGN -eq 1 ]]; then
  # The team to sign with: what the caller passed, then the Apple
  # Development certificate on this Mac, then the team Xcode is set up
  # with — xcodebuild can create a certificate for that one on demand.
  if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID=$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*Apple Development: .*(\([A-Z0-9]\{10\}\)).*/\1/p' \
      | head -1 || true)
  fi
  if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamManagerLastSelectedTeamID 2>/dev/null || true)
  fi
  if [[ -z "$TEAM_ID" ]]; then
    print -u2 -- "error: no Apple signing identity or team found."
    print -u2 -- ""
    print -u2 -- "Open Xcode → Settings → Accounts, add your Apple ID, then run"
    print -u2 -- "this again. To build without signing, pass --no-sign."
    exit 1
  fi

  # Tell xcodebuild which phone this is for, so the device can be added to
  # the provisioning profile. A generic destination can produce an app that
  # no phone is allowed to install.
  if [[ -z "$DEVICE_UDID" ]]; then
    DEVICE_UDID=$(device_udids | head -1)
  fi
  if [[ -n "$DEVICE_UDID" ]]; then
    APP_DESTINATION="platform=iOS,id=$DEVICE_UDID"
    print -- "signing with team $TEAM_ID for $DEVICE_UDID"
  else
    print -u2 -- "warning: no iPhone found; building for a generic device."
    print -u2 -- "         Pass --udid <UDID> once the phone is connected."
  fi

  # The macOS sandbox entitlements are not valid on iOS. An empty value drops
  # the file XcodeGen generated from project.yml.
  SIGN_FLAGS=(
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_STYLE=Automatic
    CODE_SIGN_IDENTITY="Apple Development"
    DEVELOPMENT_TEAM="$TEAM_ID"
    CODE_SIGN_ENTITLEMENTS=
    -allowProvisioningUpdates
  )
fi

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
    JollyCV:JollyCV MAME:MAME Mednafen:Mednafen mGBA:mGBA Nestopia:Nestopia
    O2EM:O2EM picodrive:Picodrive PokeMini:PokeMini Potator-Core:Potator
    ProSystem:ProSystem SNES9x:SNES9x Stella:Stella VirtualJaguar:VirtualJaguar
  )

  case "$MODE" in
    simulator) CORE_MODE_FLAG="" ; CORE_OUT="build/cassowary-plugins" ;;
    device)    CORE_MODE_FLAG="--device" ; CORE_OUT="build/cassowary-plugins-device" ;;
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
  # A fresh checkout has no PlugIns/Cores or PlugIns/Systems yet. Without
  # them, the first cp below would create the directory as a copy of the
  # first plugin and spill that plugin's files next to the other bundles.
  mkdir -p Cassowary/PlugIns/Cores Cassowary/PlugIns/Systems
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
    # Cores and system plugins are staged from that mode's own output
    # directory, so a device build never picks up Simulator binaries.
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
  -destination "$APP_DESTINATION" \
  "${SDK_FLAGS[@]}" \
  "${SIGN_FLAGS[@]}" \
  -derivedDataPath "$BUILD/app" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  build

case "$MODE" in
  catalyst) PRODUCT_DIR=Debug-maccatalyst ;;
  *)        PRODUCT_DIR=Debug-$APP_PLATFORM ;;
esac
APP="$BUILD/app/Build/Products/$PRODUCT_DIR/Cassowary.app"

# A signed device build is only useful if the signature actually validates.
# A plugin signed by the wrong team fails when the app tries to load it on
# the phone, so catch that here rather than on the device.
if [[ "$MODE" == device && $SIGN -eq 1 ]]; then
  banner "Checking the signature"
  codesign --verify --deep "$APP"
  codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=/signed by /p' | head -1
fi

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

if [[ "$MODE" == device ]]; then
  print -- ""
  if [[ $SIGN -eq 1 ]]; then
    HINT="Scripts/cassowary/run-cassowary.sh --device"
    if [[ -n "$DEVICE_UDID" ]]; then
      HINT="$HINT --udid $DEVICE_UDID"
    fi
    print -- "install it on the iPhone with:"
    print -- "  $HINT"
  else
    print -- "this build is unsigned; it will not install on a device."
  fi
fi
