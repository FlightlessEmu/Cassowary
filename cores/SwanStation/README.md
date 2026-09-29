# SwanStation - PlayStation 1, aka. PSX Emulator
[Features](#features) | [System Requirements](#system-requirements) | [Disclaimers](#disclaimers)

## Cassowary iOS port

Upstream commit: `b6c30a7b270a3f68ac41f268eafdfa678d17dea2` (libretro/swanstation `main`).
The sources below are that tree, flattened into the repository.

SwanStation is a libretro core, and OpenEmu cores are Objective-C classes, so
the port is a small frontend rather than a rewrite:

| File | What it does |
|---|---|
| `SwanStationLibretroBridge.{h,cpp}` | Plays frontend to the core: the environ callback, video/audio/input callbacks, and the libretro entry points the OpenEmu side calls. |
| `SwanStationGameCore.{h,mm}` | The `OEGameCore` subclass: loads the disc, runs a frame, converts input, and hands the frame to the engine. |
| `SwanStationPortStubs.cpp` | Stand-ins for the parts left out (see below). |
| `config.h`, `version.h` | Normally written by CMake; fixed here for iOS. |
| `SwanStation.xcodeproj` | States the source list for `Scripts/cassowary/build-core-ios.sh`. |

What the iOS build leaves out, and why:

- **The OpenGL and Vulkan GPU backends.** Vulkan would need MoltenVK, and the
  OpenGL backend wants GLES 3.1 core-profile entry points iOS does not expose.
  `SwanStationPortStubs.cpp` returns an empty pointer from both factories.
  The Metal backend below is what replaced them.
- **CHD disc images.** libchdr carries its own zstd, lzma and miniz copies.
  `CDImage::OpenCHDImage` is stubbed, so `.chd` files fail to open instead of
  failing to link. Everything else — cue/bin, img, ECM, MDS, PBP, m3u — is in.
- **The CPU recompiler.** iOS does not allow JIT, so the core is built without
  `WITH_RECOMPILER` and runs its interpreter. The aarch64 recompiler sources
  are left in the tree, unused.
- **RetroAchievements** are not wired up yet.

## The Metal renderer

The PlayStation GPU has two renderers: a software one that draws on the CPU,
and a hardware one that batches the console's primitives and runs them on the
GPU at higher internal resolution. On iOS the hardware renderer is Metal.

| File | What it does |
|---|---|
| `src/core/gpu_hw_metal.{h,mm}` | The renderer and its host display. Batches primitives, runs the shaders, manages VRAM, and publishes each finished frame. |
| `src/common/metal/` | Thin wrappers over `MTLTexture`, `MTLBuffer` and `MTLLibrary`, in the same shape as `common/gl/`. |
| `src/core/metal_device.h` | Where the app's device is parked so the host interface can build the display without being Objective-C++ itself. |

How it reaches the screen, since there is no libretro hardware context here:
the app makes a Metal device, hands it to the core through
`-createMetalTextureWithDevice:`, and the core renders into its own textures.
Each frame it draws the display area into a texture and publishes that;
the app samples it. The core waits for its own command buffer to finish before
handing the frame over, because the app samples from a different queue.

The shaders are the same ones the other back ends run, generated as Metal
Shading Language. `ShaderGen` already had GLSL and HLSL back ends; MSL is the
third, and the shared shader bodies read the same in all three. Every variant
the renderer can ask for — 70 of them, across texture modes, transparency
modes, dithering, interlacing, multisampling, the VRAM passes and the
downsample — was compiled with `xcrun metal` before any of this was run on a
GPU.

### Comparing the Metal renderer against the software one

`Scripts/cassowary/dump-psx-frame.py` boots a disc in this core on the Mac -
no app, no simulator - and writes the frame out as a PPM. Run it twice, once
with `--software`, and the two pictures of the same moment can be compared with
`Scripts/cassowary/compare-psx-frames.py`, which reports how many pixels differ
and writes a picture of the differences. The build is incremental, so a change
to the renderer is a few seconds to try rather than an app build and a
simulator install.

Two things to know about the comparison. The two runs are not in step: the
disc reader is paced by real time, so the same frame count lands at slightly
different points. Dumping a run of consecutive frames from each
(`--series N`) and matching them by content lines them up. And the software
renderer hands over RGB565 while the hardware one works in RGBA8, so a few
levels of rounding difference are expected everywhere.

Where it stands, checked on Crash Bandicoot:

- The title screen (512x224, frame 3000) is **pixel-identical** between the two
  renderers.
- The first level, after walking, jumping and spinning (scripted with
  `--press`), differs by a mean of about 2.2 per channel. That is the
  RGB565-vs-RGBA8 rounding floor plus Crash's idle animation, which runs a
  frame or two apart between the two runs.
- A save state taken in the level and loaded back (`--state-at`) gives the
  same frame as a run that never saved (mean difference 0.02).

The title screen matching was not enough on its own: gameplay was almost all
black until four ordering and clipping bugs were fixed. They are worth knowing
because they only show once a game is past its menus:

- After a VRAM fill, copy or upload the renderer must go back to clipping at
  the console's drawing area, as the OpenGL renderer does. Leaving all of VRAM
  open lets a game's oversized polygons paint over its textures.
- Batches keep their own uniform block. The VRAM passes upload theirs in
  between, and the batch block is only uploaded again when it changes.
- Anything the CPU writes into a texture lands at once, while the frame's
  draws only run when the command buffer is committed. Texture uploads are
  therefore a blit queued with the draws.
- The vertex, uniform and texture rings are only rewound once the GPU has
  finished with them, never mid-frame.

An earlier bug, fixed before those: the batch fragment-shader variant packed
the texture mode into two bits, but `GPUTextureMode` runs 0-8, so the top bit
overflowed into the render mode. The variant is now
`(render_mode << 8) | (texture_mode << 4) | ...` and the pipeline cache is keyed
on the whole variant.

What is deliberately not there yet:

- **Multisampling.** The renderer caps itself at one sample. It needs
  multisampled targets and a resolve pass that have not been written.
- **Adaptive downsampling.** Box filter only.
- **Texture replacements** (high-resolution texture packs).
- **The software cursor.**
- **Save states** move VRAM through a full readback and re-upload rather than
  copying GPU-side, which is slower but correct.
- **Adaptive downsampling** and **multisampling** (see above).

The renderer is on by default. Set the `SwanStationMetalRenderer` user default
to `NO` to fall back to software rendering; if the Metal renderer cannot start,
the core falls back on its own.

### Settings, rumble and discs

The app's PlayStation page writes `SwanStation.*` user defaults (internal
resolution, true colour, texture filter, PGXP geometry correction,
widescreen), and `SwanStationGameCore` hands them to the core as its own
`swanstation_` options through `SwanStationBridge::SetOption`. They are read
at boot and again whenever the defaults change, so a change applies to a
running game on its next frame. A resolution change moves VRAM across in
`GPU_HW_Metal::UpdateSettings`: read back at the old scale, uploaded at the
new one.

Checked in the frame dumper (`--option`, `--option-at`): 1x to 8x, a live 1x
to 3x switch, true colour, Bilinear, JINC2 and xBR filtering, PGXP with and
without its depth buffer, and the widescreen hack.

Rumble goes through libretro's rumble interface to the app's haptics, and an
`.m3u` playlist's discs swap through the core's disk control interface
(`--disc-at` in the dumper). The DualShock's ANALOG button presses the core's
analog-mode combo, L1+R1+L3+R3.

Two port details worth knowing:

- The bridge pins the core to RGB565. The software renderer picks 15-bit or
  24-bit output per frame from what the disc asks for, and the engine takes one
  pixel format for the whole session, so only accepting RGB565 keeps every
  frame in a format the engine can show.
- BIOS files (`scph5500.bin`, `scph5501.bin`, `scph5502.bin`) go in the app's
  BIOS folder, which is handed to the core as its system directory. With no
  BIOS present the core falls back to its built-in OpenBIOS.
- The controller plugged in is a DualShock, asked for by the core's own
  device id (`RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 0)`). Plain
  `RETRO_DEVICE_ANALOG` is not an id the core knows, and it plugs in nothing.
- Memory card 1 is a card per game title (`<title>_1.mcd` in the saves
  folder), which the core writes itself. The core's default is libretro save
  RAM, which only survives if the frontend writes it out, and this one does
  not.

SwanStation is a hard fork and open-source Libretro core implementation of DuckStation, which is an emulator of the Sony PlayStation(TM) console, focusing on playability, speed, and long-term maintainability. The goal is to be as accurate as possible while maintaining performance suitable for low-end devices. "Hack" options are discouraged, the default configuration should support all playable games with only some of the enhancements having compatibility issues.

A "BIOS" ROM image can be used, but is not required. You can use an image from any hardware version or region, although mismatching game regions and BIOS regions may have compatibility issues. A ROM image is not provided with the emulator for legal reasons, you should dump this from your own console using Caetla or other means. If no ROM image is provided, [OpenBIOS](https://pcsx-redux.consoledev.net/openbios/) will be used instead.

## Features

SwanStation features include:

 - CPU Recompiler/JIT (x86-64, armv7/AArch32 and AArch64)
 - Hardware (D3D11, OpenGL, Vulkan) and software rendering
 - Upscaling, texture filtering, and true colour (24-bit) in hardware renderers
 - PGXP for geometry precision, texture correction, and depth buffer emulation
 - Adaptive downsampling filter
 - Post processing shader chains
 - "Fast boot" for skipping BIOS splash/intro
 - Save state support
 - Supports bin/cue images, raw bin/img files, MAME CHD, single-track ECM, MDS/MDF, and unencrypted PBP formats.
 - Direct booting of homebrew executables
 - Direct loading of Portable Sound Format (psf) files
 - Digital and analog controllers for input (rumble is forwarded to host)
 - Namco GunCon lightgun support (simulated with mouse)
 - NeGcon support
 - Emulated CPU overclocking
 - Multitap controllers (up to 8 devices)
 - RetroAchievements
 - Automatic loading/applying of PPF patches

## System Requirements
 - A CPU faster than a potato. But it needs to be x86_64, AArch32/armv7, or AArch64/ARMv8, otherwise you won't get a recompiler and it'll be slow.
 - For the hardware renderers, a GPU capable of OpenGL 3.1/OpenGL ES 3.0/Direct3D 11 Feature Level 10.0 (or Vulkan 1.0) and above. So, basically anything made in 2013 or later.

### Region detection and BIOS images
By default, SwanStation will emulate the region check present in the CD-ROM controller of the console. This means that when the region of the console does not match the disc, it will refuse to boot, giving a "Please insert PlayStation CD-ROM" message. SwanStation supports automatic detection disc regions, and if you set the console region to auto-detect as well, this should never be a problem.

The region checking can be disabled in the console options tab. This is the only way to play unlicensed games or homebrew which does not supply a correct region string on the disc, aside from using fastboot which skips the check entirely.

Mismatching the disc and console regions with the check disabled is supported, but may break games if they are patching the BIOS and expecting specific content.

### LibCrypt protection and SBI files

A number of PAL region games use LibCrypt protection, requiring additional CD subchannel information to run properly. libcrypt not functioning usually manifests as hanging or crashing, but can sometimes affect gameplay too, depending on how the game implemented it.

For these games, make sure that the CD image and its corresponding SBI (.sbi) file have the same name and are placed in the same directory. SwanStation will automatically load the SBI file when it is found next to the CD image.

For example, if your disc image was named `Spyro3.cue`, you would place the SBI file in the same directory, and name it `Spyro3.sbi`.

## Tests
 - Passes amidog's CPU and GTE tests in both interpreter and recompiler modes, partial passing of CPX tests

## Disclaimers

"PlayStation" and "PSX" are registered trademarks of Sony Interactive Entertainment Europe Limited. This project is not affiliated in any way with Sony Interactive Entertainment.
