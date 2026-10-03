# Documentation index

Everything in `docs/`. Start with [PROJECT_LAYOUT.md](PROJECT_LAYOUT.md) if
you're new to the repository.

[next-up.md](next-up.md) lists what is left to do, what needs a real Apple TV
to check, and known rough edges.

## Layout and process

| Doc | What's in it |
|---|---|
| [PROJECT_LAYOUT.md](PROJECT_LAYOUT.md) | Map of the repository: what lives where. |

## Architecture decisions

`adr/` holds the Architecture Decision Records — one short file per decision,
with a [template](adr/template.md).

- [0001 — Monorepo with flattened cores](adr/0001-monorepo-with-flattened-cores.md)
- [0002 — Pre-built vendor frameworks (retired)](adr/0002-pre-built-vendor-frameworks.md)
- [0003 — Claude tooling split](adr/0003-claude-tooling-split.md)
- [0004 — Core update channel ownership](adr/0004-core-update-channel-ownership.md)

## Cores

The shipped cores, and the upstream revision each one came from, are listed in [`cores/upstream.json`](../cores/upstream.json).

| Doc | What's in it |
|---|---|
| [core-audit/upstream-maintenance.md](core-audit/upstream-maintenance.md) | Current upstream pins, Metal patch review, safe update workflow, and remaining provenance gaps. |
| [core-audit/core-upscaling-investigation.md](core-audit/core-upscaling-investigation.md) | How upscaling could be added to the cores, bitmap ones first. |
| [PS1_METAL_PLAN.md](PS1_METAL_PLAN.md) | Bringing up the two PlayStation cores, and where the Metal work goes. |

## Features

| Doc | What's in it |
|---|---|
| [apple-tv-library-host-plan.md](apple-tv-library-host-plan.md) | Plan for the Apple TV build and the phone-hosted library. |
| [retro-achievements/retroachievements-implementation-guide.md](retro-achievements/retroachievements-implementation-guide.md) | How to wire a core into RetroAchievements, and the pitfalls already hit. |
| [catalyst-ui-review.md](catalyst-ui-review.md) | Mac UI findings, changes, and verification status. |
| [mobile-ui-review.md](mobile-ui-review.md) | iPhone and iPad UI findings and verification coverage. |

## Other

| Doc | What's in it |
|---|---|
| [crash-reports.md](crash-reports.md) | How crashes and hangs are collected, read and symbolicated. |
| `images/` | Images used by the docs. |
