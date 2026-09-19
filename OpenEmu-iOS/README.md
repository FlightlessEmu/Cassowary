# OpenEmu for iOS

An iOS port of OpenEmu. It runs the same emulator cores as the macOS app, with
a native SwiftUI front end.

## What works

- Game Boy via the Gambatte core
- On-screen controls generated from each system plugin's own control list
- Library that scans the app's Documents folder
- Save states (the plumbing is in place; no UI yet)

## How it is put together

The macOS app runs the emulator in a separate XPC process. iOS does not allow
that, so the helper runs in the app's own process. Everything else is the same
code: the SDK, the cores, and OpenEmuKit's renderer and audio engine.

The pieces:

| Piece | Where it comes from |
|---|---|
| Emulator core | A `.oecoreplugin` built for iOS |
| System description | A `.oesystemplugin` built for iOS |
| Rendering, audio, plugin loading | `OpenEmuKit` |
| Shared protocols and types | `OpenEmuBase`, `OpenEmuSystem` |
| Front end | `OpenEmu-iOS/Sources` |

Cores and system plugins are the same bundles the macOS app uses — iOS can load
them with `dlopen` as long as they are signed with the app's team.

## Building

```bash
./Scripts/ios/build-ios.sh
```

That builds the frameworks, the plugins and the app, in that order.

## Running

```bash
xcrun simctl boot "OE-iPhone-17"
xcrun simctl install booted build/ios-derived-simulator/Build/Products/Debug-iphonesimulator/OpenEmu.app
xcrun simctl launch booted org.openemu.OpenEmu
```

To put a ROM on the device, copy it into the app's Documents directory:

```bash
CONTAINER=$(xcrun simctl get_app_container booted org.openemu.OpenEmu data)
cp mygame.gb "$CONTAINER/Documents/"
```

Then tap Refresh in the app. Pass `-OEAutoPlayFirstGame YES` on the launch line
to boot the first game automatically, which is what the test scripts use.

## Adding a core

`Scripts/ios/build-gambatte-ios.sh` is the model. A core needs:

1. Its Cocoa and OpenGL imports dropped, and any `GL_*` constants replaced with
   the SDK's `OEPixelFormat_*` equivalents.
2. A build script that compiles its sources against the iOS SDK.
3. A link step that produces the `.oecoreplugin` bundle.

Cores that render through Metal are the easiest port. Cores that need OpenGL
cannot run on iOS at all, since iOS has no OpenGL.
