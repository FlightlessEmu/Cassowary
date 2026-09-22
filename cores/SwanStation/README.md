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
  `SwanStationPortStubs.cpp` returns an empty pointer from both factories;
  `System::CreateGPU` already treats that as "use the software renderer".
  This is the hook a Metal backend would replace.
- **CHD disc images.** libchdr carries its own zstd, lzma and miniz copies.
  `CDImage::OpenCHDImage` is stubbed, so `.chd` files fail to open instead of
  failing to link. Everything else — cue/bin, img, ECM, MDS, PBP, m3u — is in.
- **The CPU recompiler.** iOS does not allow JIT, so the core is built without
  `WITH_RECOMPILER` and runs its interpreter. The aarch64 recompiler sources
  are left in the tree, unused.
- **Disk control (multi-disc swapping), rumble and RetroAchievements** are not
  wired up yet.

Two port details worth knowing:

- The bridge pins the core to RGB565. The software renderer picks 15-bit or
  24-bit output per frame from what the disc asks for, and the engine takes one
  pixel format for the whole session, so only accepting RGB565 keeps every
  frame in a format the engine can show.
- BIOS files (`scph5500.bin`, `scph5501.bin`, `scph5502.bin`) go in the app's
  BIOS folder, which is handed to the core as its system directory. With no
  BIOS present the core falls back to its built-in OpenBIOS.

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
