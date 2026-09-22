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
#   Scripts/cassowary/build-cassowary.sh [--device | --catalyst | --tvos | --tvos-sim]
#                                       [--app-only] [--team TEAMID] [--udid UDID] [--no-sign]
#
#   --device     target a real iPhone instead of the Simulator
#   --catalyst   build the same app natively for the Mac (Mac Catalyst)
#   --tvos       build the Apple TV app for a real Apple TV
#   --tvos-sim   build the Apple TV app for the Apple TV Simulator
#   --app-only   skip the frameworks and plugins; just rebuild the app
#
# Device builds only:
#
#   --team       the Apple team to sign with. The default is DEVELOPMENT_TEAM
#                from the environment, then the team Xcode is set up with,
#                then the Apple Development certificate on this Mac.
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
    --tvos)     MODE=tvos; shift ;;
    --tvos-sim) MODE=tvos-sim; shift ;;
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

# The UDIDs of the physical devices CoreDevice can see, one per line.
# devicectl lists simulators alongside them, so they are filtered out here.
# The UDID is the hardware one, which is what xcodebuild's -destination wants.
device_udids() {
  xcrun devicectl list devices \
    --hide-default-columns --columns udid --hide-headers \
    --filter 'hardwareProperties.reality != "simulated"' 2>/dev/null \
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
  tvos)
    SDK_NAME=appletvos
    DESTINATION='generic/platform=tvOS'
    ;;
  tvos-sim)
    SDK_NAME=appletvsimulator
    DESTINATION='generic/platform=tvOS Simulator'
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

# The Apple TV app stages its frameworks and plugins apart from the phone's,
# so building one platform never overwrites the other's copies.
case "$MODE" in
  tvos|tvos-sim)
    FRAMEWORKS_DIR="Cassowary/Frameworks-tvOS"
    PLUGINS_DIR="Cassowary/PlugIns-tvOS"
    APP_SCHEME="CassowaryTV"
    ;;
  *)
    FRAMEWORKS_DIR="Cassowary/Frameworks"
    PLUGINS_DIR="Cassowary/PlugIns"
    APP_SCHEME="Cassowary"
    ;;
esac

# Where a mode's core bundles are kept. Every mode has its own directory, so a
# build never picks up another platform's binaries.
core_output_dir() {
  case "$MODE" in
    simulator) print -- "build/cassowary-plugins" ;;
    device)    print -- "build/cassowary-plugins-device" ;;
    catalyst)  print -- "build/cassowary-plugins-catalyst" ;;
    tvos)      print -- "build/cassowary-plugins-tvos" ;;
    tvos-sim)  print -- "build/cassowary-plugins-tvos-sim" ;;
  esac
}

# Whether every core bundle built for this mode is already staged. A bundle
# that was built after the last staging would otherwise be left out of an
# app-only build.
staged_cores_match() {
  local src
  for src in "$(core_output_dir)"/*.oecoreplugin; do
    [[ -d "$src" ]] || continue
    [[ -d "$PLUGINS_DIR/Cores/${src:t}" ]] || return 1
  done
  return 0
}

# The staged folders are what Xcode links against, and they can only hold one
# mode's binaries at a time. A full build stages the mode it just built; an
# app-only build copies that mode's binaries back if the last full build was
# for a different mode (the phone for a device right after the Simulator, or
# the Apple TV right after its Simulator). Without this, an app-only build
# links the wrong frameworks and fails in confusing ways.
restage_for_mode() {
  local stamp="$FRAMEWORKS_DIR/.staged-mode"

  # The stamp alone is not enough: a core built after the last staging is
  # missing from the app, and the stamp would happily skip the copy. Compare
  # the built core bundles with the staged ones as well.
  if [[ -f "$stamp" ]] && [[ "$(<"$stamp")" == "$MODE" ]] && staged_cores_match; then
    return 0
  fi

  if [[ ! -d "$BUILD/OpenEmuKit.framework" ]]; then
    print -u2 -- "error: no $MODE frameworks have been built yet."
    print -u2 -- "       Run a full build for this mode once (drop --app-only)."
    exit 1
  fi

  banner "Restaging the $MODE frameworks and plugins"

  mkdir -p "$FRAMEWORKS_DIR"
  rm -rf "$FRAMEWORKS_DIR"/*.framework
  for framework in OpenEmuBase OpenEmuSystem OpenEmuKit OpenEmuShaders; do
    cp -R "$BUILD/$framework.framework" "$FRAMEWORKS_DIR/"
  done

  mkdir -p "$PLUGINS_DIR/Cores" "$PLUGINS_DIR/Systems"
  rm -rf "$PLUGINS_DIR"/Cores/*.oecoreplugin
  rm -rf "$PLUGINS_DIR"/Systems/*.oesystemplugin

  local src
  for src in "$(core_output_dir)"/*.oecoreplugin; do
    if [[ -d "$src" ]]; then
      cp -R "$src" "$PLUGINS_DIR/Cores/"
    fi
  done
  for src in "build/cassowary-plugins-$MODE"/*.oesystemplugin; do
    if [[ -d "$src" ]]; then
      cp -R "$src" "$PLUGINS_DIR/Systems/"
    fi
  done

  print -- "$MODE" > "$stamp"
}

# tvOS device builds sign the same way a phone build does; the destination
# names the Apple TV instead of a phone.
DEVICE_LIKE=0
[[ "$MODE" == device || "$MODE" == tvos ]] && DEVICE_LIKE=1
if [[ "$MODE" == tvos ]]; then
  DEVICE_PLATFORM=tvOS
else
  DEVICE_PLATFORM=iOS
fi

# A real iPhone or Apple TV will not run an unsigned app, and it will not load
# the core plugins unless they are signed for the same team as the app. Signing
# is off in project.yml so Simulator and Catalyst builds need no Apple account;
# for --device and --tvos it is switched back on here.
APP_DESTINATION=$DESTINATION
SIGN_FLAGS=()
if [[ $DEVICE_LIKE -eq 1 && $SIGN -eq 1 ]]; then
  # The team to sign with: what the caller passed, then the team Xcode is
  # set up with, then the Apple Development certificate on this Mac.
  #
  # A certificate's team is its OU. The value in the common name's
  # parentheses is not a team ID for personal teams, even though it looks
  # like one, and xcodebuild rejects it as an unknown team.
  if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamManagerLastSelectedTeamID 2>/dev/null || true)
  fi
  if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU=\([A-Z0-9][A-Z0-9]*\).*/\1/p' | head -1 || true)
  fi
  if [[ -z "$TEAM_ID" ]]; then
    print -u2 -- "error: no Apple signing identity or team found."
    print -u2 -- ""
    print -u2 -- "Open Xcode → Settings → Accounts, add your Apple ID, then run"
    print -u2 -- "this again. To build without signing, pass --no-sign."
    exit 1
  fi

  # Tell xcodebuild which device this is for, so the device can be added to
  # the provisioning profile. A generic destination can produce an app that
  # no device is allowed to install.
  #
  # A phone is picked automatically when there is exactly one. An Apple TV is
  # not: devicectl lists phones and TVs together, and signing for the wrong
  # one is a confusing failure, so the TV's UDID is asked for.
  if [[ -z "$DEVICE_UDID" && "$MODE" == device ]]; then
    DEVICE_UDID=$(device_udids | head -1)
  fi
  if [[ -n "$DEVICE_UDID" ]]; then
    APP_DESTINATION="platform=$DEVICE_PLATFORM,id=$DEVICE_UDID"
    print -- "signing with team $TEAM_ID for $DEVICE_UDID"
  elif [[ "$MODE" == tvos ]]; then
    print -u2 -- "warning: no Apple TV UDID given; building for a generic device."
    print -u2 -- "         Pass --udid <UDID> (xcrun devicectl list devices) so the"
    print -u2 -- "         Apple TV is added to the provisioning profile."
  else
    print -u2 -- "warning: no iPhone found; building for a generic device."
    print -u2 -- "         Pass --udid <UDID> once the phone is connected."
  fi

  # The macOS sandbox entitlements are not valid on iOS. An empty value drops
  # the file XcodeGen generated from project.yml.
  #
  # The one entitlement worth having here is the user-assigned device name
  # (so a phone advertises itself as "Milk" rather than "iPhone"), but Apple
  # only grants it on request, and a personal team cannot use it at all.
  # Until the team can have it, the name shown to the Apple TV comes from the
  # field in the sharing settings.
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
    if ! xcodebuild -project OpenEmu-SDK/OpenEmu-SDK.xcodeproj \
      -scheme "$target" \
      -configuration Debug \
      -destination "$DESTINATION" \
      "${SDK_FLAGS[@]}" \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
      CONFIGURATION_BUILD_DIR="$BUILD" \
      build > "$BUILD/$target.log" 2>&1; then
      print -u2 -- "error: $target did not build; last lines of $BUILD/$target.log:"
      tail -25 "$BUILD/$target.log" >&2
      exit 1
    fi
  done
fi

# 2 and 3. OpenEmuShaders and OpenEmuKit come from the workspace, which
# resolves OpenEmuShaders' Swift package dependencies.
if [[ $APP_ONLY -eq 0 ]]; then
  banner "Building OpenEmuKit"
  if ! xcodebuild -workspace OpenEmu-metal.xcworkspace \
    -scheme OpenEmuKit \
    -configuration Debug \
    -destination "$DESTINATION" \
    "${SDK_FLAGS[@]}" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CONFIGURATION_BUILD_DIR="$BUILD" \
    build > "$BUILD/OpenEmuKit.log" 2>&1; then
    print -u2 -- "error: OpenEmuKit did not build; last lines of $BUILD/OpenEmuKit.log:"
    tail -25 "$BUILD/OpenEmuKit.log" >&2
    exit 1
  fi

  banner "Collecting the frameworks"
  mkdir -p "$FRAMEWORKS_DIR"
  rm -rf "$FRAMEWORKS_DIR"/*.framework
  for framework in OpenEmuBase OpenEmuSystem OpenEmuKit OpenEmuShaders; do
    if [[ ! -d "$BUILD/$framework.framework" ]]; then
      print -u2 -- "error: $BUILD/$framework.framework is missing"
      exit 1
    fi
    cp -R "$BUILD/$framework.framework" "$FRAMEWORKS_DIR/"
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
    tvos)      PLUGIN_MODE_FLAG="--tvos" ;;
    tvos-sim)  PLUGIN_MODE_FLAG="--tvos-sim" ;;
  esac
  ./Scripts/cassowary/build-all-system-plugins-ios.sh $PLUGIN_MODE_FLAG --keep-going

  # The cores to build, as source directory → product bundle name. The two
  # differ in case (picodrive → Picodrive) or in full (Potator-Core →
  # Potator), so both are listed. Extend this list when a new core is ported.
  #
  # tvOS attempts every core too. A core that does not compile against the
  # tvOS SDK is skipped with a warning and is simply not staged, and the
  # library says "No core on this Apple TV" for its systems.
  CORES=(
    4DO:4DO Atari800:Atari800 Bliss:Bliss blueMSX:blueMSX BSNES:BSNES
    CrabEmu:CrabEmu FCEU:FCEU Gambatte:Gambatte GenesisPlus:GenesisPlus
    JollyCV:JollyCV MAME:MAME Mednafen:Mednafen melonDS:melonDS mGBA:mGBA
    Mupen64Plus:Mupen64Plus Nestopia:Nestopia O2EM:O2EM picodrive:Picodrive
    PokeMini:PokeMini Potator-Core:Potator ProSystem:ProSystem SNES9x:SNES9x
    Stella:Stella VecXGL:VecXGL VirtualC64:VirtualC64
    VirtualJaguar:VirtualJaguar
  )

  case "$MODE" in
    simulator) CORE_MODE_FLAG="" ;;
    device)    CORE_MODE_FLAG="--device" ;;
    catalyst)  CORE_MODE_FLAG="--catalyst" ;;
    tvos)      CORE_MODE_FLAG="--tvos" ;;
    tvos-sim)  CORE_MODE_FLAG="--tvos-sim" ;;
  esac
  CORE_OUT="$(core_output_dir)"

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
  # The destination directories are not in git; without them, cp -R creates
  # the first one as a flattened copy of the first bundle (which then fails
  # code signing).
  mkdir -p "$PLUGINS_DIR/Cores" "$PLUGINS_DIR/Systems"
  rm -rf "$PLUGINS_DIR"/Cores/*.oecoreplugin
  rm -rf "$PLUGINS_DIR"/Systems/*.oesystemplugin
  # A fresh checkout has no PlugIns/Cores or PlugIns/Systems yet. Without
  # them, the first cp below would create the directory as a copy of the
  # first plugin and spill that plugin's files next to the other bundles.
  mkdir -p "$PLUGINS_DIR/Cores" "$PLUGINS_DIR/Systems"
  if [[ ${#WANT_PRODUCTS[@]} -gt 0 ]]; then
    for product in "${WANT_PRODUCTS[@]}"; do
      kind=Cores
      case "$product" in *.oesystemplugin) kind=Systems ;; esac
      src="build/cassowary-plugins-$MODE/$product"
      if [[ -d "$src" ]]; then
        cp -R "$src" "$PLUGINS_DIR/$kind/"
      else
        print -u2 -- "error: $src missing; its build step failed"
        exit 1
      fi
    done
  else
    # Cores and system plugins are staged from that mode's own output
    # directory, so a device build never picks up Simulator binaries, and a
    # TV build never picks up the phone's.
    staged=0
    for src in "$CORE_OUT"/*.oecoreplugin; do
      [[ -d "$src" ]] || continue
      cp -R "$src" "$PLUGINS_DIR/Cores/"
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
      cp -R "$src" "$PLUGINS_DIR/Systems/"
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
  for staged in "$PLUGINS_DIR"/Cores/*.oecoreplugin "$PLUGINS_DIR"/Systems/*.oesystemplugin; do
    [[ -e "$staged" ]] || continue
    if [[ ! -f "$staged/Info.plist" ]]; then
      print -u2 -- "warning: dropping $staged (no Info.plist — its build failed)"
      rm -rf "$staged"
    fi
  done

  # Remember which mode this staging belongs to, so a later --app-only build
  # can tell whether it has to copy anything back.
  print -- "$MODE" > "$FRAMEWORKS_DIR/.staged-mode"
fi

# An app-only build skips the frameworks and plugins, so the staged copies
# have to belong to this mode before Xcode links them.
if [[ $APP_ONLY -eq 1 ]]; then
  restage_for_mode
fi

# 5. The app.
banner "Generating the Xcode project"
xcodegen generate --spec Cassowary/project.yml --project Cassowary >/dev/null

banner "Building the app"
xcodebuild -project Cassowary/Cassowary.xcodeproj \
  -scheme "$APP_SCHEME" \
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
if [[ $DEVICE_LIKE -eq 1 && $SIGN -eq 1 ]]; then
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

  # The Copy PlugIns phase leaves a stamp file in PlugIns for Xcode's
  # dependency analysis. codesign treats anything in there as nested code and
  # refuses to sign the app ("code object is not signed at all"), so drop it;
  # the next Xcode build re-creates it.
  rm -f "$APP/Contents/PlugIns/.plugins-copied"

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

if [[ $DEVICE_LIKE -eq 1 ]]; then
  print -- ""
  if [[ $SIGN -eq 1 ]]; then
    if [[ "$MODE" == tvos ]]; then
      print -- "install it on the Apple TV from Xcode's Devices window, or with:"
      print -- "  xcrun devicectl device install app --device ${DEVICE_UDID:-<UDID>} \"$APP\""
    else
      HINT="Scripts/cassowary/run-cassowary.sh --device"
      if [[ -n "$DEVICE_UDID" ]]; then
        HINT="$HINT --udid $DEVICE_UDID"
      fi
      print -- "install it on the iPhone with:"
      print -- "  $HINT"
    fi
  else
    print -- "this build is unsigned; it will not install on a device."
  fi
fi

if [[ "$MODE" == tvos-sim ]]; then
  print -- ""
  print -- "run it in a booted Apple TV Simulator with:"
  print -- "  xcrun simctl install booted \"$APP\""
  print -- "  xcrun simctl launch booted org.cassowary.CassowaryTV"
fi
