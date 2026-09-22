# Apple TV build with a phone-hosted library — plan

_2026-09-21_

Status: **plan only.** Nothing here is built yet. This is the reference for the
phases below. Update it as decisions change — it is meant to be corrected, not
preserved.

---

## 1. The goal

Add an Apple TV app that plays the same library as the iPhone, where the phone
(or iPad, or Mac) is the source of the games. The Apple TV copies a game down
before playing it, so play is local and unaffected by the network. Saves,
state, and play history sync back to the other devices, and games can be
copied between devices too.

In one picture:

```
   iPhone / iPad / Mac (hosts)                Apple TV (borrower)
   ───────────────────────────                ───────────────────
   Documents/                                 Caches/Media/
     Mario.sfc          ──── Wi-Fi ────►        <game>/Mario.sfc        whole file,
     Mario.oesavestate                          <game>/Mario.oesavestate  verified, then played
     Zelda.z64                                  <game>/Zelda.z64

   saves, play history, and games flow         saves flow back on every
   between the hosts as peers                  reconnect, until confirmed
```

The phone is the library. The TV is a working set. Nothing needs a server, an
account, or the internet.

---

## 2. The constraints that shape the design

### 2.1 tvOS does not keep files

Apple's tvOS programming guide, word for word:

> "The maximum size for a tvOS app bundle 4 GB. Moreover, your app can only
> access **500 KB** of persistent storage that is local to the device (using the
> `NSUserDefaults` class). Outside of this limited local storage, all other data
> must be purgeable by the operating system when space is low."
>
> "… your app can download the data it needs into its cache directory.
> Downloaded data is not deleted while the app is running. However, when space
> is low and your app is not running, this data may be deleted. Do not use the
> entire cache space as this can cause unpredictable results."
>
> — [App Programming Guide for tvOS](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/index.html)

Three consequences:

1. **500 KB is a guarantee, not a ceiling.** It is the fixed slice for tiny
   things like the library index. It is not the size of the cache.
2. **The cache has no promised size.** In practice it is free space on the
   Apple TV (32/64/128 GB minus the system and other apps), and the system
   reclaims it when it wants. A "downloaded" game may simply be gone tomorrow.
3. **On-Demand Resources do not help.** Those are for content shipped with the
   app, hosted by Apple — not user files. There is no supported way to make
   ROMs permanent on an Apple TV.

So: the TV keeps a **working set, never a library**, and every cached game is
treated as disposable. Our own budget: **2 GB by default**, adjustable, and
never the only copy of anything that matters.

### 2.2 The phone can only serve while its app is open

iOS suspends an app that is only listening on a socket. There is no honest way
around that without background modes Apple does not grant for this. While
serving, the host app stays in the foreground, keeps the screen awake, and says
so plainly. The TV shows "Open Cassowary on your iPhone and tap Share" when no
host answers.

### 2.3 Local network permission

Both the host and the TV need the local-network permission, with
`NSLocalNetworkUsageDescription` and `NSBonjourServices` in each Info.plist.
The user sees one system prompt the first time. Devices on a guest network with
client isolation cannot reach each other at all; the TV should explain that
rather than fail silently.

---

## 3. What already exists that this builds on

| Today | Where | What it means for this plan |
|---|---|---|
| Library = files in the app's Documents folder | `Cassowary/Sources/Models/GameLibrary.swift` | The host keeps working exactly as now. The game index is a new sidecar, not a replacement. |
| Save states next to the ROM, `<name>.oesavestate` | `Cassowary/Sources/Session/GameSession.swift` | **File format and location stay untouched.** Existing saves keep working. |
| Battery saves in `Application Support/OpenEmu/<Core>/Battery Saves/` | `OpenEmu-SDK/OpenEmuBase/OEGameCoreController.m` | Sync has to map a battery save back to a game — a known wrinkle (see §5.7). |
| Cover art in `Application Support/CoverArt` | `Cassowary/Sources/Models/CoverArtStore.swift` | The TV can fetch its own art, or get it from the host. Both are cheap. |
| Physical controllers via GameController | `OpenEmu-SDK/OpenEmuSystem/OEiOSGameControllerManager.m` | The same bridge iOS and Mac Catalyst use; extend it to tvOS and the TV input path is mostly free. |
| Emulator runs in-process | `Cassowary/Sources/Session/GameSession.swift` | The TV can reuse it as-is once the engine builds for tvOS. |
| Build modes: simulator / device / catalyst | `Scripts/cassowary/build-cassowary.sh` | A `--tvos` mode follows the same pattern. |
| Generated project, never hand-edited | `Cassowary/project.yml` | A second target is a spec change, not a project surgery. |
| Engine source checker | `Scripts/cassowary/check-kit-sources.sh` | Reuse it to find which OpenEmuKit files fail on tvOS, instead of guessing. |
| Project-editing helpers | `Scripts/cassowary/xcodeproj_set_setting.py`, `xcodeproj_add_setting.py` | The safe way to add tvOS to the engine projects. |

---

## 4. Design

### 4.1 Roles

- **Host** — the existing app on iPhone, iPad, or Mac. Serves the library,
  accepts saves, and can send or receive games.
- **Borrower** — the Apple TV app. Downloads a working set, plays locally,
  syncs saves.

Every host is also a peer for saves and games. There is no master device.

### 4.2 Discovery and pairing

- Hosts advertise a Bonjour service, `_cassowary._tcp`, with a small TXT record
  (protocol version, host id, display name, role).
- The TV lists nearby hosts and connects on tap.
- First connection shows one prompt on the host: *"Living Room Apple TV wants
  to connect"* → Allow. Both sides remember each other.
- Optional setting, off by default: trust new devices on this network without
  asking.

No PINs, no QR codes, no accounts.

### 4.3 Game identity

Saves, play history, and games all key off the same thing: **the content of the
ROM file**, not its name or path.

- A SHA-256 is computed once per file and cached in a local index.
- Large disc images use a quick fingerprint first (size + first/last chunk) and
  pay for the full hash only when transferring.
- Renaming a file keeps its identity; patching a ROM makes a new one, which is
  correct — the save state genuinely does not apply to patched code.
- The same game on the phone, iPad, Mac, and TV resolves to one id, so saves
  follow it everywhere, and duplicate copies can be recognised.

The index is a small JSON file beside the library. It can always be rebuilt by
re-scanning; deleting it never loses a save.

### 4.4 Save data

Two kinds, same machinery:

| Kind | Examples | Lives locally in |
|---|---|---|
| Save state | `Mario.oesavestate` | Documents, next to the ROM |
| Battery save | `.sav`, `.srm`, `.rtc`, `.eep`, `.nv` | `Application Support/OpenEmu/<Core>/Battery Saves/` |

Each blob carries:

- `gameID` and `kind`
- a **version**: a counter that goes up on every write, plus the id of the
  device that wrote it. Not a wall-clock time — device clocks disagree, and a
  TV with a wrong clock must not win a conflict.
- a content hash
- a display date (for showing "saved today on Apple TV", never for deciding)
- optionally a small preview image, captured at save time

**Sync happens whenever two devices can see each other**: on app open, after a
game session, when another device connects, and periodically while hosting.
The exchange is metadata first — "here is what I have, tell me what is new to
you" — and only genuinely different blobs move as bytes.

**The queue is the important part.** Every save written anywhere is marked "not
yet everywhere" and retried until confirmed. Nothing unsynced is ever deleted.
The TV shows a small "2 saves waiting to go to your iPhone" line, and retries
the moment a host appears.

**Off the TV, saves are exempt from our own cache cleanup**, because they are
the one thing on the TV that cannot be re-downloaded. They are also the first
thing uploaded on reconnect.

### 4.5 Conflicts

A conflict is the same game played on two devices before they synced. The rule:

- **Never overwrite silently.** The losing copy is kept with a dated name.
- **Ask the user**, showing both sides — device name, date, size, and the
  preview image if there is one:

```
  Keep which version?

  ┌──────────────────┐   ┌──────────────────┐
  │  iPhone          │   │  Apple TV        │
  │  Saved Tue 9:14  │   │  Saved today 6:02│
  │  612 KB          │   │  618 KB          │
  └──────────────────┘   └──────────────────┘
     [ Keep both ]  [ Keep iPhone ]  [ Keep Apple TV ]
```

- Same prompt on every device: a sheet on iPhone/iPad/Mac, a focus dialog on
  the TV.
- "Keep both" is always offered and is the safe answer.

### 4.6 Play history

Synced with saves, so every device agrees: last played, play count, favorite.
These fields do not exist in the app yet; they arrive with the index in
Phase 3. The TV uses them for a "Continue" row; the phone can use them for
sorting.

### 4.7 Games between devices

Games move the same way saves do, with the same identity rules, but with two
differences: they are large, and they are **never automatic**.

- The library view shows where each game is: "on iPhone, on Mac, not here".
- **Send to…** pushes a game to another device. **Get Games** browses what
  other devices have, with sizes, total, and a free-space check.
- Transfers are resumable (HTTP `Range`) and verified by hash before use.
- A game already present, by hash, is skipped.
- The TV is the same machinery with a small budget: favorites prefetch, the
  rest downloads when picked.

This is what makes a new device usable: the iPad arrives, opens "Get Games",
picks what it wants from the phone or Mac, and the saves for those games follow
automatically.

### 4.8 The TV's working set

```
Caches/Media/<gameID>/rom              the game itself — disposable
Caches/Media/<gameID>/saves/…          saved states, mirrored home
Caches/Artwork/…                       cover art — disposable
Application Support/library-index.json tiny: hosts, tokens, what is cached,
                                       the save queue, play history
```

Rules:

- Games are evicted least-recently-used when over the budget (2 GB default).
- A game being played is never evicted.
- A missing game is not an error: the badge flips from **Ready** to
  **Download** and picking it just fetches again.
- The index stays far under the 500 KB guarantee. It holds hashes and counts,
  never game data.

### 4.9 Protocol

Plain HTTP on the local network, versioned in the path, token in a header.
Chosen over a bespoke socket protocol because it gives resume, progress,
and debuggability (`curl`) for free — and it is the least code to get wrong.

```
GET  /v1/info                        protocol version, host name, pairing required?
POST /v1/pair                        TV asks, host prompts, TV gets a token
GET  /v1/library                     games: id, title, system, size, hash, save presence
GET  /v1/games/{id}/files/{n}        ROM bytes — Range, ETag, resume
GET  /v1/games/{id}/artwork          cover art, when the host has it
GET  /v1/saves/index                 save metadata: game, kind, version, hash
POST /v1/saves/merge                 "here is my index — what are you missing?"
GET  /v1/saves/{gameID}/{kind}       one save
PUT  /v1/saves/{gameID}/{kind}       one save, with the version it replaces
```

A game is a **list of files** from the start, even though it is always one
today, so multi-disc games and playlists fit later without a breaking change.
Protocol version mismatch = polite refusal, never a half-working transfer.

### 4.10 Host UI

A "Share with Apple TV" section in Settings:

- On/off switch; nothing listens when it is off.
- Status: "Sharing · Living Room Apple TV connected", the paired-device list,
  and a way to forget a device.
- "Keep this screen open while sharing" — with the screen kept awake.
- Sending/receiving progress, and the save queue when something is waiting.

### 4.11 TV UI

- Connect screen listing nearby hosts.
- Library grid with badges: Ready, Download 43%, On iPhone, No TV core.
- Download screen: size, progress, cancel; play begins when it is complete.
- Player: the existing game screen without touch controls; controller-driven
  menu for pause, save, load, and quit.
- A small "saves waiting" indicator, and Settings for cache budget and
  trusted hosts.

---

## 5. Running the emulator on Apple TV

### 5.1 Frameworks

| Framework | Today | Needs |
|---|---|---|
| OpenEmuShaders | Already declares `appletvos appletvsimulator` | Nothing |
| OpenEmuBase, OpenEmuSystem | `iphoneos iphonesimulator macosx` | Add tvOS platforms; expect one or two `TARGET_OS_TV` guards |
| OpenEmuKit | `iphoneos iphonesimulator macosx` | Add tvOS platforms and a `TVOS_DEPLOYMENT_TARGET`; fix whatever `check-kit-sources.sh --tvos` reports |

Known candidates for guards: `OpenEmuBase/OEPlatform.h`'s
`OEPlatformApplication()` (uses `UIApplication.sharedApplication`), and the two
iOS-only SwiftUI modifiers in `GameView.swift`. The real list comes from the
compile, not from this table.

### 5.2 Cores

Cores are compiled by `Scripts/cassowary/build-core-ios.sh`, which already
takes an explicit `-target`. A tvOS mode is `arm64-apple-tvos17.0` plus tvOS
SDK frameworks. Start with the pure bitmap cores and grow:

**First:** Gambatte, Nestopia, SNES9x, FCEU, Genesis Plus, mGBA, Stella,
ProSystem, blueMSX, Potator, PokeMini, JollyCV, CrabEmu, O2EM, VirtualC64.

**Later, with care:** Mupen64Plus (JIT is not allowed on tvOS; interpreter
only), and anything that needs Vulkan or OpenGL.

**Not planned:** cores whose renderer cannot work on tvOS.

"Works" means a game runs for five minutes at the right speed with sound and a
controller — not that it compiled.

### 5.3 Input, audio, video

- Video: `CAMetalLayer`, fully supported on tvOS. The Metal layer host view
  works as-is.
- Audio: CoreAudio `AudioUnit`, supported on tvOS.
- Controllers: `GameController` is the same framework on tvOS; the
  GameController bridge that iOS and Mac Catalyst use is the input path. The
  Siri Remote maps as a micro gamepad for simple systems.
- Touch controls, haptics, and keyboard capture are iOS-only and get gated out.

---

## 6. Build and repo changes

| Area | Change |
|---|---|
| `Cassowary/project.yml` | New `CassowaryTV` target: platform tvOS, target 17.0, device family 3, bundle id `org.cassowary.Cassowary.tv`, its own Info.plist. Shares `Sources`, plus `Sources/TV/`. Uses separate `Frameworks-tvOS/` and `PlugIns-tvOS/` so staging one platform never clobbers another. |
| `Scripts/cassowary/build-cassowary.sh` | New `--tvos` mode: builds frameworks, plugins, cores for tvOS, then the TV app. Outputs to `build/cassowary-tvos`, `build/cassowary-plugins-tvos`. |
| `build-system-plugin-ios.sh`, `build-core-ios.sh` | New `--tvos` mode. |
| `check-kit-sources.sh` | New `--tvos` mode, to find engine files that need guards. |
| `Cassowary/Resources/Info-tvOS.plist` | New. No file sharing keys; adds local-network usage description and Bonjour service. |
| `Cassowary/Sources/Transfer/` | New shared code: manifest, index, host server, client, cache, queue. Must compile for iOS, Catalyst, and tvOS. |
| `Cassowary/Sources/TV/` | New tvOS-only UI. |
| Signing | Simulator needs none. A real Apple TV needs an Apple ID, a team, and a tvOS provisioning profile; the run script learns a `--tvos` install path. |
| Docs | Privacy policy line: local network only, nothing leaves the house. This plan and an ADR for the architecture. |

No new dependencies. The transfer layer is hand-rolled on Apple's Network
framework, because the project has no package manager and this is not the
change to introduce one.

---

## 7. Implementation method — how this stays safe

This is the part that decides whether the project breaks. The rules:

### 7.1 Additive only

- Every change is a new file, a new build mode, or a guarded addition. No
  existing file gets rewritten.
- The existing save-state format and location do not change. Existing saves
  keep working, on every platform.
- ROMs are never moved by sync code. Documents stays the library; the index is
  a sidecar that can be deleted and rebuilt.
- The host feature does nothing until the user turns it on. No listener, no
  scan, no background work with the switch off.
- The TV app is a separate target. If it breaks, the iOS app is untouched and
  can still be built and shipped.

### 7.2 Never hand-edit generated projects

`Cassowary.xcodeproj` is generated from the spec. The TV target is a spec
change followed by `xcodegen`. The engine projects are not generated, so their
edits go through `xcodeproj_set_setting.py` — targeted lines only, verified by
building every platform afterwards.

### 7.3 Build gates before anything lands

| Touching | Must pass |
|---|---|
| Any Swift/ObjC | `./Scripts/cassowary/build-cassowary.sh` (Simulator) |
| Engine frameworks or cores | The above, plus `--device` (compile with `--no-sign` if no phone) and `--catalyst` |
| Anything after Phase 0 | The above, plus `--tvos` |
| Scripts | Run the script in its default mode too — the new mode must not change the old ones |

The build is the contract. A green build is the only thing that counts as
passing; a core or feature is not "working" until it runs.

### 7.4 Data safety rules

- Writes are atomic: temp file, then replace.
- A save is never deleted, and never overwritten without keeping the old copy.
- A file is verified by hash before a core is allowed to open it.
- Nothing is synced that the user did not ask to sync, except saves and play
  history, which are tiny and reversible.
- Game copying is always explicit, with a free-space check first.

### 7.5 Compatibility rules

- The protocol is versioned; an old and new app must refuse cleanly rather than
  half-work.
- Save blobs move with their version and hash, so an interrupted transfer
  cannot masquerade as a complete one.
- Previews and extra metadata are optional fields; an older peer that does not
  understand them still syncs.

### 7.6 Testing

| Layer | How |
|---|---|
| Pure logic — manifest, index, versioning, range parsing | Unit tests, added as a small test target beside the app |
| Protocol | `curl` against a running host in the Simulator (the Simulator shares the Mac's network) |
| End to end | iPhone Simulator hosting, Apple TV Simulator borrowing, a real ROM round-tripped and hash-checked |
| Device | Real Apple TV: five minutes of play, controller, audio, cache purge, reconnect sync |

### 7.7 Workflow (per the current AGENTS rules)

No pull requests for now. Per phase: branch from `main`, build until green,
commit in small steps, then fast-forward `main` to the branch and delete the
branch. The first phase's branch is `feat/tvos-phase0`.

### 7.8 Rollback

Each phase is independent and additive. If the TV work misbehaves:

- Turn sharing off, or remove the TV target from the spec, and the iOS app is
  exactly as it was.
- Delete the local index; it rebuilds by scanning, and no save is affected.
- A bad protocol change is refused by version check, not worked around.

---

## 8. Phases

### Phase 0 — Prove the engine runs on Apple TV

No networking, no library, no transfer code. One game runs on the TV.

- [ ] Branch `feat/tvos-phase0` from `main`.
- [ ] Add tvOS platforms to the OpenEmuBase/OpenEmuSystem targets with
      `xcodeproj_set_setting.py`; build for tvOS.
- [ ] Add tvOS platforms (and a TV deployment target) to OpenEmuKit; build.
- [ ] `check-kit-sources.sh --tvos`: list the files that fail, fix with guards.
- [ ] Add `--tvos` to `build-system-plugin-ios.sh`; build one system plugin
      (Game Boy) and one core (Gambatte) with it.
- [ ] Add `CassowaryTV` to `project.yml` with its Info.plist and staging dirs;
      generate and build.
- [ ] Minimal TV app: register plugins, play the bundled demo ROM
      (`Scripts/cassowary/make-demo-rom.py`) through the existing `GameSession`
      and Metal layer.
- [ ] Run on the Apple TV Simulator: video, audio, a Bluetooth controller.
- [ ] Confirm the iOS Simulator, device compile, and Catalyst builds still pass.

**Exit:** five minutes of play on the TV Simulator, right speed, sound, and
controller input; every other build still green.

### Phase 1 — The link

- Host: HTTP server + Bonjour + pairing prompt, off by default, in Settings.
- TV: browse, pair, fetch one file, verify the hash.
- Testable with `curl` from the Mac against the Simulator, then
  TV Simulator → iPhone Simulator.
- Privacy policy updated.

**Exit:** a ROM arrives on the TV byte-identical; killing the host mid-download
resumes rather than restarts.

### Phase 2 — TV library and play

- Library grid from the manifest, artwork, badges.
- Download screen; play only when complete; remember what is Ready.
- Cache budget and eviction; purge recovery.

**Exit:** pick a game on the TV, watch it download, play it; next launch it is
Ready; clearing the app's cache returns it to Download without losing anything.

### Phase 3 — Saves, queue, conflicts

- Game id index on every device; save index; play history.
- Queue with retry on reconnect; "waiting" indicator.
- Conflict prompt with dates, sizes, and previews.
- Battery saves mapped back to games.

**Exit:** play offline on the TV, reconnect, and the save lands on the host;
playing the same game on both and reconnecting raises one clear prompt.

### Phase 4 — Games between devices

- "Send to…" and "Get Games" flows with sizes and free-space checks.
- Resumable, hash-verified transfers; artwork follows.
- iPad arrives, fills itself from the phone or Mac.

**Exit:** a game copied between two hosts is identical, resumable, and the
saves for it follow automatically.

### Phase 5 — Comfort

- Favorites prefetch on the TV; "Play on Apple TV" from the host.
- Phone as a controller for the TV.
- BIOS transfer (explicit, with a warning), multi-disc grouping.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Engine port to tvOS is bigger than expected | Phase 0 first, narrow core list, evidence from the compiler |
| Cores that cannot port (JIT, Vulkan, OpenGL) | TV coverage starts small; the UI says "No TV core" instead of failing |
| Cache purged while saves are pending | Saves are never evicted locally, uploaded at every opportunity, and the UI shows what is waiting |
| Host app suspended mid-transfer | Range resume; TV keeps its progress; playback is never affected |
| Wi-Fi isolation on guest networks | Clear message; no silent failure |
| App Review: a TV app that needs a phone | Bundled demo game makes it useful alone; local network only |
| Scope creep into streaming | Not this project; noted as a possible future option for cores that cannot port |

---

## 10. Decisions

Settled:

- Hosts: iPhone, iPad, Mac Catalyst, and any later target. TV borrows.
- Pairing: discovery + one Allow prompt, remembered.
- Saves: sync both kinds, queued and retried on reconnect; conflicts prompt the
  user with dates/sizes/previews and always offer Keep Both.
- Play history syncs too.
- Games can be copied between devices, explicitly.
- TV cache: 2 GB default, adjustable; TV keeps a working set.
- Transport: Bonjour + HTTP on the local network, no cloud, no dependencies.

Open:

- Which Apple TV model this is, and therefore whether the deployment target
  stays at 17.0.
- Cache budget default (2 GB proposed) and whether "remove after playing"
  should even exist.
- When the ADR should be written: with Phase 0, or with Phase 1.

---

## 11. Alternatives considered

| Option | Why not |
|---|---|
| iCloud Drive / CloudKit for games | Storage the user pays for, slow, and tvOS has no file browser to reach it. |
| SMB client on the TV | Needs a third-party library and a NAS; can become a second host type later. |
| Stream video from the phone | Different product: latency, encoding, controller lag. Worth revisiting only for cores that cannot run on tvOS. |
| AirPlay mirroring today | Works as a stopgap; too much lag for games. |
| MultipeerConnectivity instead of HTTP | Simpler discovery, but no resume, poor for large disc images, and awkward to debug. |
| Copy ROMs onto the TV with a Mac | tvOS gives no access to app files, and updates or offloads erase them. |
