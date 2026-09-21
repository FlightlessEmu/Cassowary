# Cassowary

An independent iOS emulator frontend. Cassowary is **not affiliated with,
sponsored, or endorsed by the OpenEmu Team** — it just runs on their engine.

## What it is

A native SwiftUI app for iPhone, iPad, and Mac (Catalyst) that plays games
through emulator cores and system plugins built from this repo. The
emulation engine — the shared frameworks (`OpenEmuBase`, `OpenEmuSystem`,
`OpenEmuKit`, `OpenEmuShaders`), the plugin architecture, and the cores
themselves — is the [OpenEmu](https://github.com/OpenEmu/OpenEmu) project's
work, used under its licenses. See Settings → About in the app for the full
credits and per-core licenses.

## What works

- Game Boy via the Gambatte core
- Vectrex via the VecXGL core, which draws its vector display with Metal
- Nintendo 64 via Mupen64Plus, rendering through paraLLEl-RDP on MoltenVK
- Multi-core library: systems sidebar, per-system default cores, Play With…
- On-screen controls generated from each system plugin's own control list
- Physical controllers through Apple's GameController framework — a paired
  gamepad drives the same buttons as the on-screen pad, using the mapping the
  system plugin already ships, and is remappable in Settings → Controller
  Bindings
- Keyboard input, remappable per system in Settings → Keyboard Bindings
- Three directional styles (Buttons, D-Pad, Thumbstick with analog support)
  and three button themes, with a pressable test pad in Settings → Controls
- Optional auto-repeat for the D-Pad: a held direction retriggers at a rate set
  in Settings → Controls, for games that only act on a fresh press
- Haptics: on-screen presses buzz, and the N64's Rumble Pak plays through the
  device, at Off/Low/Medium/High from the in-game menu
- Save states (plumbing in place; minimal UI)
- Video filters: OpenEmu's shader presets (CRT Geom, CRT Royale Kurozumi, NTSC,
  VHS, …), switchable while playing and settable per system in Settings
- Cover art: box art downloaded from libretro-thumbnails, and from
  ScreenScraper too once an app key is set up (Settings → Cover Art)

## How it is put together

The macOS app runs the emulator in a separate XPC process. iOS does not allow
that, so Cassowary runs the helper in its own process. Everything else is the
same code: the SDK, the cores, and OpenEmuKit's renderer and audio engine.

| Piece | Where it comes from |
|---|---|
| Emulator core | A `.oecoreplugin` built for iOS |
| System description | A `.oesystemplugin` built for iOS |
| Rendering, audio, plugin loading | `OpenEmuKit` (OpenEmu project) |
| Shared protocols and types | `OpenEmuBase`, `OpenEmuSystem` (OpenEmu project) |
| Front end | `Cassowary/Sources` (this project) |

Cores and system plugins are the same bundles the macOS app uses — iOS can load
them with `dlopen` as long as they are signed with the app's team.

## Building

```bash
./Scripts/cassowary/build-cassowary.sh              # for the Simulator
./Scripts/cassowary/build-cassowary.sh --device     # for a real iPhone
./Scripts/cassowary/build-cassowary.sh --catalyst   # for the Mac, natively
```

One-command dev loop and end-to-end test:

```bash
./Scripts/cassowary/run-cassowary.sh
./Scripts/cassowary/test-cassowary.sh
```

## Running on a real iPhone

```bash
./Scripts/cassowary/build-cassowary.sh --device   # build and sign for the phone
./Scripts/cassowary/run-cassowary.sh --device     # install and launch
```

One-time setup:

1. Connect the iPhone and tap **Trust** on it.
2. Turn on **Settings → Privacy & Security → Developer Mode** (iOS 16 and
   later).
3. Add your Apple ID in **Xcode → Settings → Accounts**. A free account works;
   apps it signs stop working after 7 days, and building again renews them.

The scripts use the only connected phone and the only Apple Development
certificate on the Mac. With more than one of either, pass `--udid` and
`--team` (or set `DEVELOPMENT_TEAM`). Add `--no-sign` to check that a device
build compiles without needing an account; the result will not install.

The same commands work over Wi-Fi after a one-time pairing: in Xcode's
**Window → Devices and Simulators**, select the phone and tick **Connect via
network**. The cable is only needed for that first pairing.

To put a game on the phone:

```bash
./Scripts/cassowary/run-cassowary.sh --device --game ~/Games/Legend.gb
```

Games can also be dragged into the app's folder in Finder once the app is
installed.

The first `--device` build compiles every core for the phone, so it takes
longer than a Simulator build. Later builds only compile what changed.

If signing fails, it is usually the Apple ID session or the Xcode license:
run `sudo xcodebuild -license accept` once, and check that **Xcode → Settings
→ Accounts** shows your Apple ID without an error. Xcode also has to prepare
the phone for development the first time — open **Window → Devices and
Simulators**, keep the phone unlocked, and wait for that to finish.

After an Xcode update, two components are often missing:

```bash
xcodebuild -downloadComponent MetalToolchain   # "missing Metal Toolchain"
sudo xcodebuild -runFirstLaunch                # first-launch packages
```

## Running (Simulator by hand)

```bash
xcrun simctl boot "Cassowary-iPhone-17"
xcrun simctl install booted build/cassowary-simulator/app/Build/Products/Debug-iphonesimulator/Cassowary.app
xcrun simctl launch booted org.cassowary.Cassowary
```

To put a ROM on the device, copy it into the app's Documents directory:

```bash
CONTAINER=$(xcrun simctl get_app_container booted org.cassowary.Cassowary data)
cp mygame.gb "$CONTAINER/Documents/"
```

Then tap Refresh in the app. Pass `-cassowary.autoPlayFirstGame YES` on the
launch line to boot the first game automatically, which is what the test
scripts use.

## Cover art

Cassowary downloads box art for your games and keeps it in the app's
Application Support folder. Each game is looked up on
[libretro-thumbnails](https://thumbnails.libretro.com) first — it is free and
needs no account — and then on ScreenScraper, when an app key is set up. A game
that is not found is left alone for a week before it is tried again.

The switch, a "Download Missing Artwork" button, and the account fields are in
**Settings → Cover Art**. Per game, long-press the tile for *Download Cover
Art* / *Remove Cover Art*.

ScreenScraper is the optional second source. It has better coverage for discs,
and it needs an app key, which screenscraper.fr issues to software developers
(Developer area → My API credentials). To bake one into a build:

```bash
cp Cassowary/ScreenScraperDevCredentials.example.plist \
   Cassowary/Resources/ScreenScraperDevCredentials.plist
# fill in devid and devpassword, then rebuild
```

That file is not committed. App keys can also be entered in
Settings → Cover Art → ScreenScraper → App Key, which is the way to try one on
a device without a rebuild.

## Moving from the OpenEmu iOS prototype

Cassowary ships under a new bundle ID (`org.cassowary.Cassowary`), so iOS
treats it as a different app: ROMs, save states, and preferences do **not**
carry over automatically (the sandbox won't let apps read each other's
containers). Copy your ROMs into Cassowary's Documents folder via the Files
app or Finder; save states (`.oesavestate` files next to the ROMs) move with
them.

## Adding a core

`Scripts/cassowary/build-gambatte-ios.sh` is the model, and
`Scripts/cassowary/build-core-ios.sh` builds any core from its own Xcode
project. A core needs:

1. Its Cocoa and OpenGL imports dropped, and any `GL_*` constants replaced with
   the SDK's `OEPixelFormat_*` equivalents.
2. A build script that compiles its sources against the iOS SDK.
3. A link step that produces the `.oecoreplugin` bundle.

Cores that render through Metal are the easiest port. Cores that need OpenGL
cannot run on iOS at all, since iOS has no OpenGL.

When porting a core, add its license to the map in `AboutView`
(`Cassowary/Sources/SettingsView.swift`) so the in-app credits stay complete.
