# VirtualC64 core

A Commodore 64 core for Cassowary, built on [VirtualC64](https://github.com/dirkwhoffmann/virtualc64)'s
embeddable emulator library (`VCCore`).

VirtualC64 is cycle-accurate with a strong PAL focus, actively maintained by
Dirk W. Hoffmann, and — unlike OpenEmu's old VICE-Core — its emulator is a
library with a public API, so this core is glue rather than a rewrite.

## What's here

| Path | What it is |
|---|---|
| `VCCore/` | The upstream emulator library, unmodified. |
| `VirtualC64/` | The OpenEmu glue: `VirtualC64GameCore.mm` plus its Info.plist. |
| `project.yml` | XcodeGen spec for the plugin project. `VirtualC64.xcodeproj` is generated from it and committed. |
| `LICENSE` | Upstream's license summary: MPL-2.0 for the core emulator, MIT for the CPU (Peddle), GPL-2.0-or-later for reSID, GPL-3 for the Mac app (not used here). |

`VCCore/` is a snapshot of the upstream repository at commit
`38b7ce342ec1476385c13915f6c93ddf3dfe1063` (VirtualC64 v6.1, September 2026).
To update it, copy a newer `VCCore/` over the top and rebuild; nothing in it is
patched locally.

## Building

The emulator library is CMake-based, so it builds outside Xcode:

```bash
Scripts/cassowary/build-virtualc64-ios.sh              # iOS Simulator
Scripts/cassowary/build-virtualc64-ios.sh --device     # a real iPhone
Scripts/cassowary/build-virtualc64-ios.sh --catalyst   # the Mac
```

That writes static libraries to `build/cassowary-virtualc64-<mode>/lib`.
`Scripts/cassowary/build-core-ios.sh VirtualC64` compiles the glue, links
those libraries, and produces `VirtualC64.oecoreplugin`; the normal
`build-cassowary.sh` run does both for you.

Regenerate the plugin project after editing `project.yml`:

```bash
xcodegen generate --spec cores/VirtualC64/project.yml --project cores/VirtualC64
```

## ROMs

VirtualC64 ships the MEGA65 [Open ROMs](https://github.com/MEGA65/open-roms)
for BASIC, KERNAL and CHARGEN and installs them when no user ROMs are present,
so the core boots out of the box. Open ROMs are not a perfect match for the
originals, though, and some software notices.

User-supplied ROMs win. Put them in the app's BIOS folder using any of these
names:

| ROM | File names |
|---|---|
| KERNAL | `kernal`, `kernal.bin`, `kernal.rom` |
| BASIC | `basic`, `basic.bin`, `basic.rom` |
| Character | `chargen`, `chargen.bin`, `chargen.rom`, `character`, `character.bin` |
| 1541 drive | `1541`, `1541.bin`, `dos1541.bin`, `1541-ii.bin`, `1541-II.bin` |

The 1541 drive ROM has no open replacement, so disk images (`.d64`, `.g64`,
and friends) need a user-supplied one. Cartridges and `.prg` files do not.

## Supported media

`.prg` is flashed into RAM and started. `.crt` cartridges are attached to the
expansion port. `.d64`, `.d71`, `.d81`, `.g64`, `.x64`, `.t64` and `.p00` are
inserted into drive 8 and autostarted (`LOAD"*",8,1` followed by `RUN`).
`.tap` tapes are inserted and started with `LOAD`.

## Known limitations

- The whole 520×312 frame buffer is presented, including the border, because
  VirtualC64's border detection is currently stubbed upstream. This matches
  what VirtualC64's own Mac app shows today.
- The PAL/NTSC model is fixed at PAL. VirtualC64 can switch models at runtime;
  the core does not offer a display mode for it yet.
- The C64 mouse (1350/1351) is not wired up.
- Keyboard input needs a host path for hardware keyboards; the core accepts
  USB HID usage codes on `-keyDown:` / `-keyUp:`.
- Open ROMs BASIC (the built-in fallback) has no `PEEK` and ignores `SYS`,
  so test programs observe the machine with `POKE` only. Joystick and drive
  tests need real Commodore ROMs in the BIOS folder. Autostart typing uses
  lowercase: the C64 boots in uppercase mode, where shifted letters come out
  lowercase.
