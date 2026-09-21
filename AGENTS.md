# AGENTS.md — Cassowary

Instructions for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in this repository.

---

## Read First

Before doing any work, read this file fully. It is the authoritative source for how this project is structured and how changes should be made.

Then read [`docs/PROJECT_LAYOUT.md`](docs/PROJECT_LAYOUT.md) for where things live.

---

## About This Project

Cassowary is an independent iOS, iPadOS, and Mac Catalyst app that runs on
OpenEmu's emulation engine. It is **not affiliated with, sponsored, or
endorsed by the OpenEmu Team**.

The engine — the shared frameworks and the emulator cores — comes from
OpenEmu, used under its licenses. The app itself is this project's work.

It descends from:

- [OpenEmu/OpenEmu](https://github.com/OpenEmu/OpenEmu) — the original project
- [bazley82/OpenEmuARM64](https://github.com/bazley82/OpenEmuARM64) — the foundational ARM64 port
- OpenEmu-Silicon — the Apple Silicon fork this repo grew out of

**The maintainer is not a professional developer.** If you are writing explanations, commit messages, or comments, please use plain language. Avoid jargon where a plain word works just as well.

---

## Ground Rules

1. **No pull requests for now.** Work lands on `main` directly, once the build passes. The PR flow comes back when the app is in better shape.
2. **Branch from `main` when you branch.** Feature branches and worktrees are fine for experiments; merge them into `main` when the work is ready. There is no staging branch.
3. **Build before committing.** Run the app build (below) on any Swift/ObjC change before staging a commit.
4. **Don't rewrite files wholesale.** This is a large project with many third-party cores. Make surgical changes. Rewriting an Xcode project or a core source file without understanding it will break the build.
5. **Respect the flattened architecture.** Core directories under `cores/` are regular directories — do not attempt to re-initialize them as git submodules.
6. **Do not commit build artifacts.** No `.o` files, derived data, `.app` bundles, build logs, or compiled executables.
7. **Never edit `Cassowary.xcodeproj` by hand.** It is generated from `Cassowary/project.yml` by XcodeGen. Change the spec, then regenerate.

---

## Language and Tooling

- **Swift** — the app is SwiftUI. The engine is a mix of Swift and Objective-C with bridging headers in place. Don't break them.
- **Xcode** — use `xcodebuild` for CLI builds. The workspace is `OpenEmu-metal.xcworkspace`.
- **XcodeGen** — `Cassowary.xcodeproj` is generated, not committed. Regenerate with:
  ```bash
  xcodegen generate --spec Cassowary/project.yml --project Cassowary
  ```
- **No package manager** — no SPM dependencies in the app, no CocoaPods, no Carthage. The engine's handful of Swift packages are resolved through the workspace.

---

## Build and Test

Cores and system plugins are built for iOS and staged into the app bundle. One
command does the whole chain — frameworks, system plugins, any missing cores,
then the app:

```bash
./Scripts/cassowary/build-cassowary.sh              # iOS Simulator
./Scripts/cassowary/build-cassowary.sh --device     # a real iPhone
./Scripts/cassowary/build-cassowary.sh --catalyst   # the Mac, natively
```

Then run or test it:

```bash
./Scripts/cassowary/run-cassowary.sh    # build, install, launch
./Scripts/cassowary/test-cassowary.sh   # end-to-end check
```

Build one core on its own while working on it:

```bash
./Scripts/cassowary/build-core-ios.sh <CoreName>
```

A clean run of `build-cassowary.sh` is the definition of "passing." Anything
else means stop and fix it.

### One-command setup notes

Cores take tens of minutes in total, so `build-cassowary.sh` only builds what
is missing from that mode's output directory: `build/cassowary-plugins/` for
the Simulator, `build/cassowary-plugins-device/` for a phone, and
`build/cassowary-plugins-catalyst/` for the Mac. The first run is slow; later
runs are quick.

A `--device` build is signed and installed through `devicectl`, so it needs an
Apple ID in Xcode and a paired phone with Developer Mode on. See
[`Cassowary/README.md`](Cassowary/README.md).

There are no credential files to create. The macOS app that needed them has
been removed.

---

## File Organization

| What you're touching | Where it lives |
|----------------------|---------------|
| The app | `Cassowary/Sources/` (grouped: `App/`, `Views/`, `Controls/`, `Models/`, `Session/`) |
| App build spec | `Cassowary/project.yml` |
| Shared protocols/types | `OpenEmu-SDK/` |
| Rendering, audio, plugin loading | `OpenEmuKit/` |
| Metal shaders | `OpenEmu-Shaders/` |
| Emulator cores | `cores/[CoreName]/` |
| System plugins | `OpenEmu/SystemPlugins/` |
| Build and utility scripts | `Scripts/` (`Scripts/cassowary/` for the app) |
| Design docs | `docs/` |

---

## Supported Cores

The iOS build ships these cores. Cores that need OpenGL cannot run on iOS and
are not included.

| System | Core(s) |
|--------|---------|
| 3DO | 4DO |
| Arcade | MAME |
| Atari 2600 / 8-bit / 5200 | Stella, Atari800 |
| Atari 7800 | ProSystem |
| Atari Jaguar | VirtualJaguar |
| ColecoVision | JollyCV, CrabEmu, blueMSX |
| Game Boy / GBC | Gambatte |
| Game Boy Advance | mGBA |
| Intellivision | Bliss |
| MSX | blueMSX |
| NES / Famicom Disk System | Nestopia, FCEU |
| Nintendo 64 | Mupen64Plus |
| Nintendo DS | DeSmuME |
| Odyssey² / Videopac+ | O2EM |
| PC Engine / PC-FX / Sega Saturn / PlayStation / WonderSwan / Virtual Boy / Atari Lynx / Neo Geo Pocket | Mednafen |
| Pokémon Mini | PokeMini |
| Sega 32X / Genesis / Sega CD / Master System / Game Gear | Genesis Plus GX |
| Sega Dreamcast | Flycast |
| Sega 32X (alt) | picodrive |
| Sony PSP | PPSSPP |
| SNES | SNES9x, BSNES |
| Supervision | Potator |
| Vectrex | VecXGL |

Which systems appear in the app is data-driven: every staged system plugin
becomes a row, and every staged core appears in that system's core picker.

---

## Branch Rules

Pull requests are paused for now — merge branches into `main` locally instead.
When PRs come back, this section should get the PR rules back too.

**Branches:**

| Rule | Why |
|------|-----|
| Always branch from `main` | Prevents tangled history |
| One branch = one concern | Keeps changes focused and reviewable |
| Never reuse a merged branch | New commits on a merged branch can go missing |
| Branch name must match content | If scope changes, start a new branch |
| Delete local branch after merge | `git branch -d` once its work is on main |

**Commit messages:** `fix: description` / `feat: description` / `chore: description`

Reference an issue in the commit body with `Fixes #N` (auto-closes on merge)
or `Related to #N` (soft link).

---

## Issue Tracker

The issue tracker is the primary place for bug reports, feature requests, and
core integration work.

**Issue templates** — always use the appropriate template:

| Template | Use when |
|----------|----------|
| `bug_report` | Runtime crash, wrong behavior |
| `feature_request` | New capability |
| `core_integration` | Core fails to build, needs iOS porting |
| `checklist` | Milestone tracking — one open checklist per milestone max |

**Issue hygiene rules (non-negotiable):**

1. **Search before opening.** If the problem is already tracked, comment — don't open a duplicate.
2. **No type prefixes in titles.** Never write `note:`, `fix:`, `feat:`, `bug:` in the issue title. Labels carry the type. The title describes the problem.
3. **One issue per concern.** Same root cause + same fix = one issue covering both.
4. **Close resolved issues immediately.** Do not leave issues open for a later cleanup pass.
5. **Close superseded issues immediately.** If you open a more comprehensive issue that replaces an older one, close the old one in the same session.
6. **Only one checklist per milestone.** If one is already open, update it.

---

## What NOT to Do

- Do not edit `Cassowary.xcodeproj` directly — edit `Cassowary/project.yml` and regenerate
- Do not modify a core's `project.pbxproj` unless you know exactly what you're changing
- Do not add new dependencies without discussion — the project intentionally has no package manager
- Do not remove or rename core directories — they are referenced by the workspace and the build scripts
- Do not change the iOS deployment target below `17.0` without discussion
- Do not commit secrets or credentials
- Do not commit large binaries — these belong in GitHub Releases
- Do not commit directly to `main`
- Do not claim a core works because it compiled. Compiling and running in the app are different things.

---

## How the app loads plugins

This is the single most expensive failure mode in this repo, so it gets its own
section.

The app loads `.oecoreplugin` and `.oesystemplugin` bundles from **its own
bundle**, staged under `Cassowary/PlugIns/`. It does **not** read them from
`build/`.

That means: building a core changes nothing until you rebuild and restage the
app with `./Scripts/cassowary/build-cassowary.sh`. If you test without doing
that, you are testing the previously staged plugin.

---

## License Rules

The main app is **BSD 2-Clause**. Emulator cores are mostly **GPL v2**. Key rules:

1. **Preserve all copyright headers** — never strip or modify the license block at the top of any file
2. **Add a header to new files** you create in `Cassowary/Sources/`, `OpenEmu-SDK/`, or `OpenEmuKit/`:
   ```
   // Copyright (c) 2026, OpenEmu Team
   //
   // Redistribution and use in source and binary forms, with or without
   // modification, are permitted provided that the following conditions are met:
   // ...
   ```
3. **picodrive is non-commercial** — never charge for a build that includes it
4. **No CLA** — your contributions are covered by the license of the files you touch

---

## Adding a Core

`Scripts/cassowary/build-core-ios.sh` builds any core from its own Xcode
project. A core needs:

1. Its Cocoa and OpenGL imports dropped, and any `GL_*` constants replaced with
   the SDK's `OEPixelFormat_*` equivalents.
2. A build script that compiles its sources against the iOS SDK.
3. A link step that produces the `.oecoreplugin` bundle.

Cores that render through Metal are the easiest port. Cores that need OpenGL
cannot run on iOS at all.

When porting a core, add its license to the map in `AboutView`
(`Cassowary/Sources/Views/SettingsView.swift`) so the in-app credits stay
complete.

---

## Quick Reference

```bash
# Build the app (and everything it loads)
./Scripts/cassowary/build-cassowary.sh

# Run it in the Simulator
./Scripts/cassowary/run-cassowary.sh

# End-to-end check
./Scripts/cassowary/test-cassowary.sh

# Build one core for iOS
./Scripts/cassowary/build-core-ios.sh <CoreName>

# Regenerate the app project after editing the spec
xcodegen generate --spec Cassowary/project.yml --project Cassowary

# --- Start of every new piece of work ---
git checkout main

# Optional: work on a feature branch
git checkout -b fix/your-description

# Stage and commit
git add -p
git commit -m "fix: description"

# Land it: move main to the branch, then delete the branch
git checkout main
git merge --ff-only fix/your-description
git branch -d fix/your-description
```
