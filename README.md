# Cassowary

An independent iOS, iPadOS, and Mac Catalyst emulator front end, built on
OpenEmu's emulation engine. Cassowary is **not affiliated with, sponsored, or
endorsed by the OpenEmu Team** — it runs on their engine, under their licenses.

<p align="center">
  <img width="2276" height="1550" alt="Cassowary" src="https://github.com/user-attachments/assets/3797ba95-3e8c-49f6-9d3d-ab1cca6e70b9" />
</p>

---

## What it is

A native SwiftUI app for iPhone, iPad, and the Mac (Catalyst). It plays games
through emulator cores and system plugins built from this repo. The emulation
engine — the shared frameworks (`OpenEmuBase`, `OpenEmuSystem`, `OpenEmuKit`,
`OpenEmuShaders`), the plugin architecture, and the cores themselves — is the
[OpenEmu](https://github.com/OpenEmu/OpenEmu) project's work.

See [`Cassowary/README.md`](Cassowary/README.md) for what works today and how
to add a core.

---

## Download

There is no signed build to download yet. The app is built from source; see
[`Cassowary/README.md`](Cassowary/README.md).

---

## Build

One command builds the app for the Simulator, frameworks and plugins included:

```bash
./Scripts/cassowary/build-cassowary.sh              # Simulator
./Scripts/cassowary/build-cassowary.sh --device     # a real iPhone
./Scripts/cassowary/build-cassowary.sh --catalyst   # the Mac, natively
```

Then:

```bash
./Scripts/cassowary/run-cassowary.sh            # build, install, launch
./Scripts/cassowary/run-cassowary.sh --device   # the same on a real iPhone
./Scripts/cassowary/test-cassowary.sh           # end-to-end check
```

Requirements: macOS with Xcode (latest stable), and an Apple Silicon Mac. A
real-device build also needs an Apple ID in Xcode and a trusted iPhone — see
[`Cassowary/README.md`](Cassowary/README.md).

---

## Supported Systems

The iOS build ships 22 cores covering 43 systems, including NES, SNES, Game
Boy, GBA, N64, DS, PlayStation, Genesis, Master System, PC Engine, Neo Geo
Pocket, WonderSwan, Virtual Boy, and more. Cores that need OpenGL cannot run
on iOS and are not part of the iOS build.

The full matrix is the table in [`AGENTS.md`](AGENTS.md), and every core lives
under [`cores/`](cores/).

---

## Repository layout

| Where | What |
|---|---|
| `Cassowary/` | The app: Swift sources, XcodeGen spec, resources. |
| `cores/` | The emulator cores, one directory each. |
| `OpenEmu-SDK/`, `OpenEmuKit/`, `OpenEmu-Shaders/` | The shared engine. |
| `OpenEmu/SystemPlugins/` | Per-system plugins and the responder-client headers cores include. |
| `Scripts/cassowary/` | Build, run, and test scripts. |
| `docs/` | Design docs, ADRs, audits. Start with [`docs/PROJECT_LAYOUT.md`](docs/PROJECT_LAYOUT.md). |

---

## About This Project

The original OpenEmu is an amazing piece of Mac software. [stuartcarnie](https://github.com/stuartcarnie) brought Metal rendering to the app in 2019. [MaddTheSane](https://github.com/MaddTheSane) ported the emulation cores to ARM64 starting in 2021. [cyco](https://github.com/cyco), [clobber](https://github.com/clobber), [J-rg](https://github.com/J-rg), and the rest of the OpenEmu team built the application, the plugin architecture, and the library experience over more than a decade. That work is the foundation everything here stands on.

This project descends from the OpenEmu-Silicon fork, which kept OpenEmu
running on modern Apple Silicon Macs. When that work moved to iOS, the app
became Cassowary.

**Lineage:**
- [OpenEmu/OpenEmu](https://github.com/OpenEmu/OpenEmu) — the original project
- [bazley82/OpenEmuARM64](https://github.com/bazley82/OpenEmuARM64) — the foundational ARM64 port
- OpenEmu-Silicon — the Apple Silicon fork this repo grew out of
- **This repo** — the Cassowary iOS/iPadOS/Catalyst app

---

## A Note on AI-Assisted Development

The vast majority of the code in this repo is still from the original
developers. I work on this project with AI-assisted development practices.
These tools help me write and debug code I couldn't write alone. That said, I
review every change, test everything, and make all the calls about direction
and quality. I'm transparent about this because honesty with the community
matters more than maintaining an illusion of expertise I don't have. The goal
is to keep something good alive and make it genuinely usable for players.

---

## Contributing

Issues, PRs, and testing feedback are all welcome. See
[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) for how to set up and
what to expect.

---

## License

This project is a derivative of [OpenEmu](https://github.com/OpenEmu/OpenEmu). Most of the engine and SDK carries the OpenEmu Team's original **BSD 3-Clause** copyright header, which is what actually governs those files — see [`LICENSE`](LICENSE) for the full text and how it applies. Individual emulation cores carry their own licenses (GPL v2, MPL 2.0, LGPL 2.1, and others) — see each core's directory for details. The app was built on the OpenEmu team's work.
