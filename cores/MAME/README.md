# MAME Core for OpenEmu-Silicon

This directory contains the OpenEmu MAME core wrapper, based on OpenEmu/UME-Core, with the small changes needed to build natively on Apple Silicon against this fork.

Status: WIP. The core is set up to build for iOS (Simulator, device, and Mac
Catalyst); only the Simulator path has been exercised so far. It loads as
`org.openemu.MAME`, but polygonal 3D arcade rendering still needs
validation/debugging. Use Sega Virtua Racing as the main repro case from
issue #500.

## Source dependency

The MAME headless source is intentionally not committed here because it is very large. Prepare it with:

```sh
./Scripts/prepare-mame-core.sh
```

That clones `OpenEmu-Silicon/mame` at the pinned commit in `deps-mame-revision.txt` into `MAME/deps/mame` and applies `patches/mame-headless-clang21-apple.patch`.

The patch also backports MAME commit `b5fafba307ba7acc2aea90681c71a3d43aa9cac3`, which fixes a V60 float-to-integer conversion issue reported upstream as causing glitched Virtua Racing / Sega Model 1 graphics on aarch64.

It also carries the two iOS fixes: Lua's `os.execute` (iOS has no `system()`)
and the headless OSD's `NSSize` alias (`NSSize` is AppKit-only on macOS, so on
iOS it maps to `CGSize`).

## Build

Build the core the same way as any other core:

```sh
./Scripts/cassowary/build-core-ios.sh MAME              # iOS Simulator
./Scripts/cassowary/build-core-ios.sh MAME --device     # a real iPhone
./Scripts/cassowary/build-core-ios.sh MAME --catalyst   # the Mac
```

If `mamearcade_headless.dylib` is missing, that script builds it first by
calling:

```sh
./Scripts/cassowary/build-mame-ios.sh [--device|--catalyst]
```

The emulator is built by MAME's own makefile, with the iOS SDK and target flags
passed through MAME's `OPT_FLAGS`/`LDOPTS` options. The first run takes tens of
minutes; later runs reuse MAME's object files. The dylib lands in
`MAME/deps/mame/`, under a platform-specific name.

`Scripts/build-mame-core.sh` is the older macOS build (dylib plus the
`MAME.xcodeproj` plugin); it is not used by the iOS app.

## Local testing

Rebuild the app so the plugin is restaged into it, then run it:

```sh
./Scripts/cassowary/build-cassowary.sh
./Scripts/cassowary/run-cassowary.sh
```

Use a MAME 0.250-compatible ROM set. Validate both:

- A known sprite-based arcade game, to confirm the core path works.
- Sega Virtua Racing, to investigate the missing polygon issue from #500.
