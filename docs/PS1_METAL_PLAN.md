# PS1 (Mednafen) on iOS with Metal — work plan

Branch: `feat/ps1-metal`
Worktree: `../Cassowary-ps1-metal` (branched from `main`)

## Status

| Piece | State |
|---|---|
| SwanStation (DuckStation fork) core | Sources vendored, glue and project written, building |
| SwanStation Metal shaders | All 70 variants generated as MSL and compiled with `xcrun metal` |
| SwanStation Metal renderer | Written and building; not yet run against a game |
| Mednafen PSX core | Plan only, not started |

Two PlayStation cores are in play. Mednafen's PSX core is a software renderer
(the plan below). SwanStation is the one that can grow a Metal backend, so it is
being brought up first. Its port notes live in `cores/SwanStation/README.md`.

## SwanStation, in order

1. **Boot the core through its own glue.** `SwanStationLibretroBridge` plays
   libretro frontend; `SwanStationGameCore` presents it as an `OEGameCore`.
   Done when `build-core-ios.sh SwanStation` links and a disc reaches gameplay.
2. **Get it into the app.** Staged by `build-cassowary.sh` like every other
   core; appears in the PlayStation core picker next to Mednafen.
3. **Metal, phase 1: the output path.** Done. The core reports
   `OEGameCoreRenderingMetal2`, renders into its own texture, and publishes it;
   the app draws it. The app's device reaches the core through
   `-createMetalTextureWithDevice:`.
4. **Metal, phase 2: a GPU backend.** Written: `GPU_HW_Metal` plus the
   `common/metal/` wrappers and the MSL back end in `ShaderGen`. It needs to be
   run against a disc and checked picture by picture — geometry, texture
   windows, transparency, the VRAM passes, the display crop. Multisampling,
   adaptive downsampling, texture replacements and the software cursor are
   deliberately not written yet.
5. **Fill in the gaps**: multi-disc swapping (needs the libretro disk control
   interface), rumble, RetroAchievements, and the core's option list surfaced
   as `OEGameCore` display modes.

## What we already know

- The PlayStation core in Mednafen is a software renderer (`cores/Mednafen/mednafen/psx/`).
  It draws into a plain BGRA memory buffer — there is no OpenGL GPU to replace.
  The only "OpenGL" mention in `psx.cpp` is a help-text string, not code.
- The engine already shows buffers on screen with Metal:
  `MTLGameRenderer` (`OpenEmuKit/Source/MTLGameRenderer.swift`) turns
  `OEPixelFormat_BGRA` into a Metal `bgra8Unorm` texture and
  `OEPixelFormat_RGB`/`OEPixelType_UNSIGNED_SHORT_5_6_5` into `b5g6r5Unorm`.
- The PlayStation system plugin already exists
  (`OpenEmu/SystemPlugins/PlayStation/`, controller mappings included).
- No x86 assembly in the PSX sources (only hit was an unrelated V810 file).
- `MednafenGameCore.mm:4336` shows someone already started on iOS portability
  (AppKit vs CGSize note). Check how far that got.

## Mednafen PSX core, in order

1. Compile for iOS with `build-core-ios.sh Mednafen --keep-going`; run
   `port-core-sources.py Mednafen --dry-run` first for the mechanical glue
   fixes. Cores take tens of minutes on first build, so expect a slow first run.
2. Restage with `build-cassowary.sh`, then boot a disc: BIOS plus cue/bin.
3. Video through the existing Metal buffer path, resolution switching, and a
   device speed check.
4. Audio, input, and the app fit-and-finish (license entry is already in
   `AboutView`).

## What this plan deliberately leaves out

- Mednafen's PSX core has no hardware rendering at all. Any upscaling or PGXP
  work belongs to SwanStation, not to Mednafen.
- CHD images in SwanStation, until libchdr's codec dependencies are wired up.

## What we need from you to test

- A PlayStation BIOS in the app's BIOS folder: `scph5500.bin`, `scph5501.bin`
  or `scph5502.bin`. Without one the core falls back to its built-in OpenBIOS,
  which boots most games but not all.
- A disc image to boot — ideally a `.cue` with its `.bin` (or a single `.bin`),
  and ideally one small early game, so a bad frame is easy to spot.
- Later, once the basics work: a game with 24-bit display areas, a
  multi-disc game, and a game that leans on the analog sticks.

