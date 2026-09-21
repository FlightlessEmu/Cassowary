# Project layout

This is the map of the repository: what lives where, and why the top level
looks the way it does. Read this before moving files around.

---

## The shape of the repo

| Group | Directories | What it is |
|---|---|---|
| **App** | `Cassowary/` | The iOS/iPadOS/Catalyst front end. |
| **Shared engine** | `OpenEmu-SDK/`, `OpenEmuKit/`, `OpenEmu-Shaders/` | The engine Cassowary is built on. SDK = protocols/types, Kit = rendering/audio/UI, Shaders = the Metal library. |
| **Cores** | `cores/` | One directory per emulator backend (28 in all). See the list below. |
| **System plugins** | `OpenEmu/SystemPlugins/` | The per-system bundles, and the responder-client headers the cores include. The iOS build compiles these directly. |
| **Vendored** | `Vendor/`, `OpenEmu/XADMaster.framework` | Third-party C libraries and the prebuilt archive framework `OpenEmuKit` links. |
| **Automation** | `Scripts/` | Build, verify, and install scripts. `Scripts/cassowary/` is the iOS side. |
| **Documentation** | `docs/` | Design docs, ADRs, audits, and guides. See [`README.md`](README.md) for the index. |
| **Config / meta** | `.github/`, `.githooks/`, `.cursor/`, `.claude/` | CI, issue/PR templates, the pre-push hook, and local tool settings. |

Root files: `README.md` (start here), `AGENTS.md` (rules for AI sessions),
`CONTEXT.md` (shared vocabulary), `LICENSE`.

The macOS app and its distribution pipeline (appcast, DMG, Homebrew cask)
have been removed. The shared engine directories keep the `OpenEmu` name
because that is genuinely OpenEmu's code, used under its licenses.

---

## Why the cores live under `cores/`

The 28 core directories were at the top level, which made the root hard to
read. They now live under `cores/`.

Moving them means the cores sit one level deeper, so every core Xcode
project that reaches back to the repo root (`../OpenEmu-SDK`,
`../OpenEmuKit`, `../Vendor`) needs one extra `../`. That was done when
they moved:

- `cores/<Core>/<Core>.xcodeproj` references `../../OpenEmu-SDK`, etc.
- The workspace (`OpenEmu-metal.xcworkspace`) links `group:cores/<Core>/...`.
- `Scripts/cassowary/core-info.py` and the build scripts resolve cores
  through `cores/`.

If you ever move a core again, you must fix all three.

---

## The core directories

All paths are relative to `cores/`.

| System(s) | Directory |
|---|---|
| 3DO | `4DO/` |
| Arcade | `MAME/` |
| Atari 2600 / 8-bit / 5200 | `Stella/`, `Atari800/` |
| Atari 7800 | `ProSystem/` |
| Atari Jaguar | `VirtualJaguar/` |
| Atari Lynx | `Mednafen/` |
| ColecoVision | `JollyCV/`, `CrabEmu/`, `blueMSX/` |
| Game Boy / GBC | `Gambatte/` |
| Game Boy Advance | `mGBA/` |
| GameCube / Wii | `Dolphin/` |
| Intellivision | `Bliss/` |
| MSX | `blueMSX/` |
| NES / FDS | `Nestopia/`, `FCEU/` |
| Nintendo 64 | `Mupen64Plus/` |
| Nintendo DS | `DeSmuME/` |
| Odyssey² | `O2EM/` |
| PC Engine / PC-FX / Saturn / PSX / WonderSwan / Virtual Boy | `Mednafen/` |
| Pokémon Mini | `PokeMini/` |
| Sega 32X / Genesis / Sega CD / Master System / Game Gear | `GenesisPlus/` |
| Sega Dreamcast | `Flycast/` |
| Sony PSP | `PPSSPP/` |
| SNES | `SNES9x/`, `BSNES/` |
| Supervision | `Potator-Core/` |
| Sega 32X (alt) | `picodrive/` |
| Vectrex | `VecXGL/` |

The authoritative, current list is the table in [`AGENTS.md`](../AGENTS.md).

---

## The app

`Cassowary/` is an independent iOS app that reuses OpenEmu's engine. It is
not affiliated with or endorsed by the OpenEmu Team. It has its own README,
XcodeGen spec, and build scripts:

| Path | What it is |
|---|---|
| `Cassowary/project.yml` | XcodeGen spec. `Cassowary.xcodeproj` is generated from it and is not committed. |
| `Cassowary/Sources/` | Swift sources, grouped by role: `App/`, `Views/`, `Controls/`, `Models/`, `Session/`. |
| `Cassowary/Resources/`, `Frameworks/`, `PlugIns/` | Info.plist, the bundled video-filter shader presets, the embedded frameworks, and the staged core/system plugins. |
| `Scripts/cassowary/` | Build, run, and test scripts for the app. |

See [`Cassowary/README.md`](../Cassowary/README.md) for how to build and run it.

---

## Conventions worth knowing

- **Cores are flattened, not submodules.** They used to be git submodules;
  they are now plain tracked files (see [`CONTEXT.md`](../CONTEXT.md)). Do
  not run `git submodule init` for them.
- **Generated, never committed:** `Cassowary.xcodeproj`, `build/`,
  DerivedData.
