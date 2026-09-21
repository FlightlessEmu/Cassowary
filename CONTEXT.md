# CONTEXT.md — Cassowary shared vocabulary

The terms below show up across the app code, the issue tracker, commit messages, and release notes. Use them precisely. When you write code, comments, PR descriptions, or release notes, reach for these words rather than inventing synonyms.

This file is the source of truth for what each term means *in this codebase*. If you find the codebase using a term differently than what's written here, that's drift — flag it before assuming either is correct.

---

## Emulation layer

| Term | Meaning |
|---|---|
| **core** | An emulator backend for one or more game systems. There is one core per directory under `cores/` (e.g. `cores/Gambatte/`, `cores/Mednafen/`). Some cores cover multiple systems (Mednafen covers PSX, Saturn, WonderSwan, Lynx). |
| **plugin** / **`.oecoreplugin`** | The packaged build of a core — a bundle the app loads at runtime. Staged into the app under `Cassowary/PlugIns/Cores/`. |
| **system** | A console or platform (NES, SNES, Genesis, etc.). Multiple cores can support the same system; a core can support multiple systems. |
| **system plugin** / **`.oesystemplugin`** | The per-system bundle that describes a system and its controls. Its source lives in `OpenEmu/SystemPlugins/`; it is compiled for iOS and staged under `Cassowary/PlugIns/Systems/`. |
| **native core** | A core that subclasses `OEGameCore` directly (Mednafen, Mupen64Plus, BSNES, SNES9x, Genesis Plus GX, etc.). Owns its own frame loop and integrates cross-cutting services in-tree. Every core this project ships is a native core. |

## Process and runtime

| Term | Meaning |
|---|---|
| **app** | The Cassowary app. There is no separate "host app" any more — the macOS OpenEmu app it used to run beside has been removed. |
| **helper** | The code that actually runs a core inside the app process. The macOS app ran it in a separate XPC process; iOS does not allow that, so Cassowary runs it in its own process. |
| **rcheevos** | The vendored C library that talks to the RetroAchievements service. Cores integrate it directly. |
| **Responder client** | The per-system protocol header (e.g. `OEGBSystemResponderClient.h`) that a core imports to map input. Lives with the system plugin. |

## Code organization

| Term | Meaning |
|---|---|
| **app sources** | `Cassowary/Sources/`, grouped into `App/`, `Views/`, `Controls/`, `Models/`, `Session/`. |
| **OpenEmu-SDK** | Shared protocols and types that both the app and core plugins import. Treat as a public ABI — breaking changes ripple to every core. |
| **OpenEmuKit** | Rendering, audio, and plugin loading, shared with the cores. |
| **OpenEmu-Shaders** | The Metal shader library used by the renderer. |
| **Vendor/** | Third-party C libraries (XADMaster, UniversalDetector, rcheevos) plus the prebuilt frameworks `OpenEmuKit` links. |
| **flattened core** | A core directory that used to be a git submodule but has been committed as plain tracked files. Do not try to `git submodule init` these — they are flat on purpose. |

## Features

| Term | Meaning |
|---|---|
| **Play With…** | The library control that lets the player pick which core to launch a given ROM with. |
| **default core** | The core a system boots with when the player hasn't chosen one. Configurable per system in the app. |
| **RetroAchievements (RA)** | Third-party achievement system. The rcheevos C library is built into cores. |
| **hardcore mode** | A RetroAchievements concept (no save states or rewind) — *not currently supported*. Do not claim it in release notes or documentation. |
| **save state** | A snapshot of a running game, stored as an `.oesavestate` file next to the ROM. |
| **video filter** / **shader preset** | A post-processing effect on the game picture. The filter is a libretro-style shader preset — a `.slangp` file plus its shader sources — kept in `Cassowary/Resources/Shaders/` and compiled to Metal by OpenEmuShaders. "None" is the unfiltered picture, and is the default. |

---

## What this file is not

- It is not a module map or architecture overview — read [`docs/PROJECT_LAYOUT.md`](docs/PROJECT_LAYOUT.md) for that.
- It is not a list of supported cores — `AGENTS.md` has the current matrix.
- It is not a glossary of generic emulation terms — only the ones used distinctively in this codebase.

When you add a new feature or rename something significant, update this file in the same PR. Drift here is more harmful than no entry at all.
