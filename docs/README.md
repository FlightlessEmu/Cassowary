# Documentation index

Everything in `docs/`. Start with [PROJECT_LAYOUT.md](PROJECT_LAYOUT.md) if
you're new to the repository.

## Layout and process

| Doc | What's in it |
|---|---|
| [PROJECT_LAYOUT.md](PROJECT_LAYOUT.md) | Map of the repository: what lives where. |
| [TRIAGE_GUIDE.md](TRIAGE_GUIDE.md) | How to triage issues. |
| [progress-report-template.md](progress-report-template.md) | Template for progress reports. |

## Architecture decisions

`adr/` holds the Architecture Decision Records — one short file per decision,
with a [template](adr/template.md).

- [0001 — Monorepo with flattened cores](adr/0001-monorepo-with-flattened-cores.md)
- [0002 — Pre-built vendor frameworks](adr/0002-pre-built-vendor-frameworks.md)
- [0003 — Claude tooling split](adr/0003-claude-tooling-split.md)
- [0004 — Core update channel ownership](adr/0004-core-update-channel-ownership.md)

## Cores

| Doc | What's in it |
|---|---|
| [core-audit/core-support-audit.md](core-audit/core-support-audit.md) | Audit of core support status. |
| [core-audit/core-upscaling-investigation.md](core-audit/core-upscaling-investigation.md) | How upscaling could be added to the cores, bitmap ones first. |
| [core-audit/local-inventory.md](core-audit/local-inventory.md) | Inventory of the cores in this repo. |
| [core-audit/upstream-research.md](core-audit/upstream-research.md) | Research on upstream core sources. |
| [core-audit/vice-core-investigation.md](core-audit/vice-core-investigation.md) | The Commodore 64 / VICE investigation. |
| [core-audit/vice-local-c64-context.md](core-audit/vice-local-c64-context.md) | Local C64 context. |
| [core-audit/vice-upstream-research.md](core-audit/vice-upstream-research.md) | VICE upstream research. |

## Features

| Doc | What's in it |
|---|---|
| [retro-achievements/retroachievements-implementation-guide.md](retro-achievements/retroachievements-implementation-guide.md) | How to wire a core into RetroAchievements. |
| [retro-achievements/retroachievements-community-guide.md](retro-achievements/retroachievements-community-guide.md) | Testing RA as a user or tester. |
| [retro-achievements/retroachievements-compliance-evidence.md](retro-achievements/retroachievements-compliance-evidence.md) | RA compliance evidence. |
| [retro-achievements/retroachievements-submission-package.md](retro-achievements/retroachievements-submission-package.md) | RA submission package. |
| [retroarch-removal-migration.md](retroarch-removal-migration.md) | Migrating off the removed libretro bridge. |
| [apple-tv-library-host-plan.md](apple-tv-library-host-plan.md) | Plan for the Apple TV build and the phone-hosted library. |

## Other

| Doc | What's in it |
|---|---|
| [privacy-policy.md](privacy-policy.md) | The app's privacy policy. |
| [wiki-export/Cheat-Codes.md](wiki-export/Cheat-Codes.md) | Exported wiki page on cheat codes. |
| `superpowers/` | Dated plans and specs (working notes). |
| `images/` | Images used by the docs. |
