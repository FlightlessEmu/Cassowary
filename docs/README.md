# Documentation index

Everything in `docs/`. Start with [PROJECT_LAYOUT.md](PROJECT_LAYOUT.md) if
you're new to the repository.

## Layout and process

| Doc | What's in it |
|---|---|
| [PROJECT_LAYOUT.md](PROJECT_LAYOUT.md) | Map of the repository: what lives where. |

## Architecture decisions

`adr/` holds the Architecture Decision Records — one short file per decision,
with a [template](adr/template.md).

- [0001 — Monorepo with flattened cores](adr/0001-monorepo-with-flattened-cores.md)
- [0002 — Pre-built vendor frameworks](adr/0002-pre-built-vendor-frameworks.md)
- [0003 — Claude tooling split](adr/0003-claude-tooling-split.md)
- [0004 — Core update channel ownership](adr/0004-core-update-channel-ownership.md)

## Cores

The shipped cores are listed in [`Scripts/cassowary/cores.txt`](../Scripts/cassowary/cores.txt).

| Doc | What's in it |
|---|---|
| [core-audit/core-upscaling-investigation.md](core-audit/core-upscaling-investigation.md) | How upscaling could be added to the cores, bitmap ones first. |

## Features

| Doc | What's in it |
|---|---|
| [apple-tv-library-host-plan.md](apple-tv-library-host-plan.md) | Plan for the Apple TV build and the phone-hosted library. |
| [retro-achievements/retroachievements-implementation-guide.md](retro-achievements/retroachievements-implementation-guide.md) | How to wire a core into RetroAchievements, and the pitfalls already hit. |

## Other

| Doc | What's in it |
|---|---|
| `images/` | Images used by the docs. |
