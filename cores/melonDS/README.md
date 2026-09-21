# melonDS

The Nintendo DS core: [melonDS](https://melonds.kuribo64.net) 1.1, used under
the GPL-3.0-or-later.

melonDS is the modern DS emulator — faster and more accurate than DeSmuME, with
working local wireless and online play. It is the DS core this app ships;
`cores/DeSmuME/` is the older OpenEmu core, which does not build for iOS.

## Layout

| Path | What it is |
|------|------------|
| `src/` | Upstream melonDS 1.1, unmodified except for the two patches below |
| `MelonDS/` | This port's glue: the OpenEmu core, the platform layer, the plugin project |
| `project.yml` | XcodeGen spec for `melonDS.xcodeproj` (the glue only) |
| `LICENSE` | melonDS's GPL-3.0 |

## Building

The emulator is a CMake project, so it is compiled into static libraries and
linked into the plugin bundle:

```bash
./Scripts/cassowary/build-melonds-ios.sh --catalyst   # libcore.a + libteakra.a
./Scripts/cassowary/build-core-ios.sh melonDS --catalyst
```

`build-core-ios.sh` runs the first command for you when the libraries are
missing, so a normal app build only needs:

```bash
./Scripts/cassowary/build-cassowary.sh --catalyst
```

The ARM64 JIT is not enabled yet. On this combination of macOS and Xcode it
faults inside its own fast-memory setup during startup — before a frame is
ever run — and melonDS's fault handler needs a current emulator instance that
does not exist yet at that point. Every build therefore uses the interpreter,
which is what a device build gets regardless, since iOS does not permit a JIT.
Turning it back on means giving the JIT's fast memory a working setup on
Apple; see `src/ARMJIT_Memory.cpp` and `src/ARMJIT.cpp`.

## What works

- DS games, one frame at a time, with both screens stacked into one picture
  (256×384).
- Buttons, the touch screen, and the lid (the `Lid` binding closes it).
- Sound, resampled to 48 kHz.
- Battery saves (`.sav` next to the ROM's save), and save states.
- The Rumble Pak, played through the same haptics path as the N64 core.
- Optional BIOS and firmware images: drop `bios7.bin`, `bios9.bin` and
  `firmware.bin` into the app's BIOS folder to use a real firmware (the DS
  menu, Pictochat, Download Play). Without them melonDS uses its own FreeBIOS
  and generated firmware.

## What is not done yet

- **The Metal renderer.** The 3D picture is drawn by melonDS's software
  renderer at 1× for now. A Metal 3D renderer, which also gets us upscaling,
  is the next milestone — the plan is a `Renderer3D` in `MelonDS/` plus the
  compositor it needs, in the same shape as melonDS's OpenGL one.
- **Wi-Fi**: no local wireless, no LAN, and no online (Nintendo WFC) yet.
  melonDS keeps all of that in `src/net/`, which the emulator reaches through
  `Platform::MP_*`/`Platform::Net_*`; the glue currently answers "no link".
  The pieces to wire are `LocalMP` (two instances on one machine), `LAN` (needs
  ENet), and `Net_Slirp` (bundles libslirp, gives the DS an internet
  connection for community WFC servers).
- **DSi mode**, the camera, and microphone input.

## Patches to upstream

Only two, both for Mac Catalyst:

- `src/ARMJIT.cpp` — skips `pthread_jit_write_protect_np`, which the Catalyst
  SDK marks unavailable; Catalyst's JIT pages stay writable without it.
- The build itself lives in `MelonDS/CMakeLists.txt`, which includes upstream's
  `src/CMakeLists.txt` rather than copying its source list.

To move to a newer melonDS: replace `src/` with the new release, re-apply the
`ARMJIT.cpp` patch, and rebuild.
