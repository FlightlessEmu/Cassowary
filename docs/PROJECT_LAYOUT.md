# Project layout

This is the map of the repository: what lives where, and why the top level
looks the way it does. Read this before moving files around — a lot of it is
the way it is for a reason.

---

## The shape of the repo

| Group | Directories | What it is |
|---|---|---|
| **Applications** | `OpenEmu/`, `Cassowary/` | The two front ends. `OpenEmu/` is the macOS app; `Cassowary/` is the iOS/iPadOS/Catalyst app. |
| **Shared code** | `OpenEmu-SDK/`, `OpenEmuKit/`, `OpenEmu-Shaders/` | The engine both apps are built on. SDK = protocols/types, Kit = rendering/audio/UI, Shaders = the Metal library. |
| **Cores** | `4DO/`, `Dolphin/`, `Mednafen/`, … (28 in all) | One directory per emulator backend. See the list below. |
| **Third-party** | `Vendor/` | Vendored C libraries the app links directly (XADMaster, UniversalDetector). |
| **Automation** | `Scripts/` | Build, verify, install, and release scripts. `Scripts/cassowary/` is the iOS side. |
| **Documentation** | `docs/` | Design docs, ADRs, audits, and guides. See [`README.md`](README.md) for the index. |
| **Distribution** | `Appcasts/`, `appcast.xml`, `oecores.xml`, `Casks/`, `OpenEmu.iconset/` | Sparkle update feeds (per-core in `Appcasts/`, host app at the root), the core manifest, the Homebrew cask, and the app icon source. |
| **Config / meta** | `.github/`, `.githooks/`, `.cursor/`, `.claude/` | CI, issue/PR templates, the pre-push hook, and local AI-tool settings. |

Root files: `README.md` (start here), `AGENTS.md` (rules for AI sessions),
`CONTEXT.md` (shared vocabulary), `LICENSE`.

---

## Why the top level is flat

The 28 core directories sit at the top level, not under a `cores/` folder.
That is deliberate:

- The workspace file (`OpenEmu-metal.xcworkspace/contents.xcworkspacedata`)
  links every core project by relative path.
- There are **34 `.xcodeproj` projects**. Each core project references shared
  code with relative `../` paths (`../OpenEmu-SDK/`, etc.).
- Build and install scripts reference the core directories by name.

Moving the cores one level deeper would rewrite hundreds of relative paths
across those projects and the scripts. **Don't do it** unless the whole build
system is being migrated at the same time — it is a refactor, not a tidy-up.

---

## The core directories

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
| Sega Saturn / PlayStation | `Mednafen/` |
| Sony PSP | `PPSSPP/` |
| SNES | `SNES9x/`, `BSNES/` |
| Supervision | `Potator-Core/` |
| Sega 32X (alt) | `picodrive/` |
| Vectrex | `VecXGL/` |

The authoritative, current list is the table in [`AGENTS.md`](../AGENTS.md).

---

## The iOS app (Cassowary)

`Cassowary/` is an independent iOS app that reuses OpenEmu's engine. It is
**not** part of OpenEmu's macOS app. It lives in its own directory, with its
own README, XcodeGen spec, and build scripts:

| Path | What it is |
|---|---|
| `Cassowary/project.yml` | XcodeGen spec. `Cassowary.xcodeproj` is generated from it and is not committed. |
| `Cassowary/Sources/` | Swift sources, grouped by role: `App/`, `Views/`, `Controls/`, `Models/`, `Session/`. |
| `Cassowary/Resources/`, `Frameworks/`, `PlugIns/` | Info.plist, the embedded frameworks, and the staged core/system plugins. |
| `Scripts/cassowary/` | Build, run, and test scripts for the iOS app. |

See [`Cassowary/README.md`](../Cassowary/README.md) for how to build and run it.

---

## Conventions worth knowing

- **Cores are flattened, not submodules.** They used to be git submodules;
  they are now plain tracked files (see
  [`CONTEXT.md`](../CONTEXT.md)). Do not run `git submodule init` for them.
- **Two appcasts, two owners.** The root `appcast.xml` is the host app's
  Sparkle feed. Each file in `Appcasts/` is one core's feed. See
  [`AGENTS.md`](../AGENTS.md) for the rules.
- **Generated, never committed:** `*.xcodeproj` for Cassowary, `build/`,
  DerivedData, credential files in `OpenEmu/`.
