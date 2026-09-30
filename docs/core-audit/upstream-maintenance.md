# Maintaining upstream cores and Cassowary's rendering changes

Reviewed 29 September 2026. This replaces the old macOS appcast/submodule
maintenance advice for Cassowary. The repository has **30 core directories**;
the app build currently stages **26**. Source presence does not mean a core
ships, and a successful compile does not prove that games run correctly.

The maintenance machinery is now in place, but source history recovery is
not finished for every older core. Do not describe the whole inventory as
ready for automatic updates.

## What the review found

| Finding | Consequence | Change or remaining work |
|---|---|---|
| Flattening preserved source, but usually dropped the imported revision. | Copying a newer upstream tree can erase local rendering, iOS, input, timing, or achievement changes. | `cores/upstream.json` now records source URLs, pinned baselines, mapped source paths, product names, and known gaps. |
| N64's required video plugin, presentation source, and build script lived in ignored `build/spike/`. | A working maintainer checkout could build N64 while a fresh clone could produce a plugin with no usable renderer. | Presentation source, diagnostic patch, license, and build recipe are tracked; paraLLEl-RDP and MoltenVK are fetched at exact pins into disposable build caches. |
| N64 device builds selected the desktop plugin directory. | An iPhone build could pick up a macOS binary. | Device has its own target triple, MoltenVK slice, and output directory. Device runtime testing is still required. |
| App builds skipped existing core bundles even after source changes. | An apparent successful test could run the old emulator. | `--rebuild-core NAME` rebuilds the requested core and then stages it into the app. Repeat the option for several cores. A requested rebuild failure stops the build. |
| melonDS and VirtualC64 checked only whether their static archives existed. | Rebuilding their wrapper could still link the old emulator. | Each core rebuild now asks CMake to rebuild changed emulator sources. Caches from another checkout are refreshed. MAME's make build is likewise checked on a core rebuild. |
| CI ran only on PRs/manual dispatch, and omitted melonDS, Mupen64Plus, VecXGL, and VirtualC64. | With PRs paused, normal work landing on main did not get those build checks. | CI also runs on pushes to main and reads the same shipped-core list as the app. Offline maintenance checks exercise real Git merges. |
| Older documentation counts 28 cores and lists Flycast/PPSSPP as shipped. | Maintenance effort and test expectations target the wrong inventory. | The machine-readable inventory is authoritative for what the app builds. Dolphin, Flycast, PPSSPP, and DeSmuME are present but not staged. |

## Where the Metal changes actually are

| Core/path | Rendering arrangement | What an upstream update must preserve |
|---|---|---|
| Bitmap cores / `OpenEmuKit` / `OpenEmu-Shaders` | The emulator supplies pixels. The shared engine converts, filters, and displays them with Metal. | Keep the wrapper's pixel format, row stride, buffer lifetime, audio timing, input, save states, and achievement integration. These are usually not separate native Metal backends inside each emulator. Shared engine patches need their own upstream review. |
| melonDS / `MelonDS/` | Local Metal compositor plus an optional local Metal 3D rasterizer. Software 3D remains the default; `MELONDS_3D=metal` and `cmp` select experimental paths. | Keep the local renderer, shader sources, texture-cache adapter, host layer, and CMake settings outside imported source. Inside upstream source, preserve `GPU2D_Soft.cpp` capture support for accelerated renderers and the `ARMJIT.cpp` Catalyst adaptation. |
| Mupen64Plus / `parallel/` | paraLLEl-RDP uses Vulkan through MoltenVK; the presentation replacement hands completed pixels to the shared Metal bitmap renderer. | Track the emulator, video/RSP plugin sources, MoltenVK, and local presentation code separately. Preserve Simulator external-host-memory fallback, interpreter defaults, speed limiter, clock units, and generated ARM64 assembly definitions. |
| Dolphin / `DolphinGameCore.mm`, `DolHost.mm`, `dolphin/Source/Core/VideoBackends/Metal/MTLGfx.mm` | Dolphin already has an upstream native Metal renderer. The local patch supplies an external texture and bypasses Dolphin's drawable presentation. | Preserve texture ownership and handoff, layer sizing, command submission, and ARC/non-ARC boundaries. The upstream renderer remains upstream's work; Cassowary maintains the integration changes. |
| VecXGL / `VecXGLGameCore.*` | Local Metal rendering of the Vectrex output. | Keep the wrapper's Metal output and SDK protocol hooks. Its exact upstream baseline still needs recovery. |
| Flycast and PPSSPP | The wrappers in this checkout select desktop OpenGL. | Upstream Vulkan/Apple support does not automatically make these wrappers ready for Cassowary. Updating the source and building an iOS renderer integration are separate jobs. |

### Rendering review items still requiring runtime evidence

- **N64 Simulator blocker reproduced during this review:** with the freely
  available `squaresdemo.n64` homebrew demo, plugins load and the cached
  interpreter starts, then Metal aborts with `Linear texture can only be
  created on buffers with MTLStorageModePrivate in the simulator`. The same
  assertion occurs with the previously built scratch-space plugins as with
  the new recipe. This is an existing Simulator limitation in the current
  Vulkan/MoltenVK path, not evidence of a newly introduced build regression.
  Resolving it requires reviewing texel-buffer memory allocation/view support;
  do not mark N64 Simulator runtime support as verified from a build result.
- **melonDS:** the current capture patch removes an OpenGL-only guard so any
  accelerated renderer gets the capture callback. This is a small, sensible
  upstream-facing change. Test display capture, blending, palettes, and save
  state reload when upstream changes GPU layout, texture decoding, or the
  `Renderer3D` interface. Metal work finishes before the texture is handed to
  the app's separate queue (`waitUntilCompleted`); preserve that synchronization
  until an explicit replacement is tested. Do not enable the experimental 3D
  renderer just because an upstream merge compiles.
- **Dolphin:** `s_oe_texture` is a process-wide texture reference, and the setter
  has no corresponding clear in `stopEmulation`. The local path flushes command
  encoders rather than using the same explicit completion wait as melonDS.
  Stop/restart, texture replacement, and producer/consumer synchronization
  deserve focused tests before this core is added to the current app. These
  are review concerns, not a claim that a crash or frame race was reproduced.
- **N64:** plugin startup/attachment failures are logged by the wrapper, and
  the presence of the video dylib sets the parallel path even if loading fails.
  A linked bundle alone is weak evidence. Test actual loading, a visible game,
  correct audio pacing, stop/restart, and save-state restore. The known ARM64
  dynarec problem is documented in `n64-optimization-audit.md`; keep the cached
  interpreter default. Inspect binary platform/slice and signatures for every
  device/TV build.

## Pinned baselines and source-history gaps

These are baselines for comparing and preserving local changes, not a request
to upgrade any emulator during this review. No emulator version was upgraded.
Full commit IDs and mappings live in `cores/upstream.json`.

| Core | Baseline | Evidence / qualification |
|---|---|---|
| melonDS | 1.1, `b86390e4428b` | Import `de4954abb`; comparison finds only two upstream-file modifications. |
| VirtualC64 | `38b7ce342ec1` | Exact commit in core README; VCCore comparison is unchanged. This is newer than the v6.1 tag, so the tag is not an interchangeable pin. |
| Mupen64Plus emulator | `b20b27ebf9e5` | Import date, source blob comparison, and full baseline diff; upstream code plus local adaptations and deliberate omissions. Other bundled Mupen plugins have independent histories. |
| Dolphin | `5b33289c04f4` | Exact pre-flattening gitlink recovered from `c4b8d3c25^`. Credits' “2603” alone is insufficient provenance. |
| Flycast | `05b270f05cec` | Import `df91dcc6d`. |
| PPSSPP | v1.14.4, `cd535263c1ad` | Import `df799e569`; separately imported externals/FFmpeg must be reviewed as local differences. |
| mGBA | 0.10.5, `26b7884bc25a` | Import `2ff1be178`; many upstream frontends and third-party files were deliberately omitted. |
| SNES9x | 1.63, `921f9f7b8366` | Import `e3fb29904`; optional desktop `external/` and Windows dependency trees are explicitly excluded. |
| BSNES | v115, `8e80d2f8a43e` | Import `a6a284f68`; comparison finds a funding-file change in the imported tree. |
| FCEU | v2.6.6, `34eb7601c415` | Release reference recovered from `src/version.h`; review the local diff, which also contains omitted frontends/dependencies. |
| Atari800 | 3.1.0, `27aaa95d2a4b` | Release reference recovered from `atari800-src/config.h`; wrapper version 3.1.4 is not the engine version. |
| Stella | 3.9.3, `8ab9090451a8` | Release reference recovered from `Core/src/common/Version.hxx`; this is a very old engine compared with active upstream. |
| MAME | headless fork `fac13e827b7b` | Downloaded source, not vendored. The preparation script reads this central pin and applies its tracked Apple/Clang patch. |

Seventeen cores still lack a recovered baseline: **4DO, Bliss, blueMSX,
CrabEmu, DeSmuME, Gambatte, GenesisPlus, JollyCV, Mednafen, Nestopia, O2EM,
picodrive, PokeMini, Potator-Core, ProSystem, VecXGL, and VirtualJaguar**.
The tool intentionally refuses to prepare an update for an unknown baseline.
Recover the imported release/commit and verify source blobs before enabling it.
Do not use today's upstream HEAD as the old baseline: that can mistake missing
upstream improvements for intentional local deletions.

For a new mapping, keep the emulator source separate from the wrapper whenever
the layout permits. Map only paths actually used by the build, include required
licenses and dependency sources, and list intentional exclusions explicitly.
Review generated definitions and build settings outside the source mapping too.
Mednafen's release archives need separate checksum-backed provenance; the tool
currently supports Git sources, not tarball imports.

## Which upstreams need ongoing attention

The online activity check on 29 September found 2026 commits in the primary
repositories for Atari800, BSNES, DeSmuME, Dolphin, FCEUX, Flycast, Genesis Plus
GX, melonDS, mGBA, Mupen64Plus, Nestopia, PPSSPP, SNES9x, Stella, VirtualC64,
and MAME. Commit activity is evidence of development, not proof that a specific
release should be imported.

Some older OpenEmu imports also have active **related Libretro forks**: blueMSX,
Gambatte, PokeMini, Potator, ProSystem, and VirtualJaguar. The inventory links
those as projects to evaluate; it does not claim that they are the source of
our current imports. Switching forks requires a separate API, behavior, and
license review. JollyCV's wrapper last changed in 2023, VecXGL's in 2025, and
picodrive's primary repo last changed in 2025 in this check. SourceForge-based
cores and Mednafen need manual checks.

Recommended order: recover GenesisPlus, Nestopia, and Mednafen provenance;
review the large version gaps in Stella/Atari800; then handle the remaining
active imports and related forks. Keep absent iOS cores on a separate track
from maintaining the 26 staged ones. Check active upstreams monthly and before
releases; import fixes deliberately, with one core update per branch.

Primary source references: [melonDS](https://github.com/melonDS-emu/melonDS),
[Mupen64Plus](https://github.com/mupen64plus/mupen64plus-core),
[VirtualC64](https://github.com/dirkwhoffmann/virtualc64),
[Dolphin](https://github.com/dolphin-emu/dolphin),
[Flycast](https://github.com/flyinghead/flycast),
[PPSSPP](https://github.com/hrydgard/ppsspp),
[mGBA](https://github.com/mgba-emu/mgba),
[SNES9x](https://github.com/snes9xgit/snes9x),
[Stella](https://github.com/stella-emu/stella),
[Atari800](https://github.com/atari800/atari800).

## Updating a core without losing local changes

The source in `cores/` stays flattened. Git clones and initialized dependency
submodules exist only in ignored build caches. No command below makes the
vendored core directories into submodules.

```bash
# Inventory and online activity; neither changes source.
python3 Scripts/upstream/core-upstream.py list
python3 Scripts/upstream/core-upstream.py remote-status

# Start a focused branch from main, with clean mapped core sources.
git checkout main
git checkout -b chore/update-melonds

# Choose and inspect a full upstream commit ID, then prepare an isolated merge.
python3 Scripts/upstream/core-upstream.py prepare melonDS <full-40-character-commit>
```

The result is in `build/upstream/reviews/<core>-<commit>/`. `local.patch`
records the complete baseline-to-Cassowary difference in mapped paths,
including deletions and binary changes. `review.json` records both upstream
pins, the Cassowary commit, the mappings, and any conflicts. `candidate/` is a
separate Git repository with the old baseline as the common ancestor, so Git
can combine new upstream work with existing local patches. Your checkout and
its recorded pin are unchanged. A conflict returns exit code 1 and leaves the
candidate ready to inspect. Other errors return 2.

Resolve conflicts in `candidate/`, stage them, and commit the candidate merge.
Its generated `README.txt` gives the exact command to export `update.patch`
against the recorded local commit. Inspect that patch, then apply it from the
Cassowary root with `git apply --check --directory=cores/<core>` followed by
`git apply --directory=cores/<core>`. This preserves wrapper code outside the
mapping and represents upstream deletions correctly. Existing review folders
and edited caches are never reset or overwritten.

Update the manifest's full revision and version in the same change. Record why
each conflict resolution or remaining local patch is needed. Compare relevant
licenses, rebuild generated source lists if upstream adds files, and regenerate
XcodeGen projects through their spec. Do not hand-edit Cassowary.xcodeproj.

```bash
# This rebuilds the emulator/plugin and stages it into the app before app build.
./Scripts/cassowary/build-cassowary.sh --rebuild-core melonDS
./Scripts/cassowary/build-cassowary.sh --catalyst --rebuild-core melonDS
# Also validate each supported device/TV mode affected by the change.
# Then launch games and check rendering, input, audio, saves, and stop/restart.
```

A plain app build still reuses existing bundles for speed. Use the explicit
rebuild option after source, pin, patch, or core build-setting changes.
`--app-only` cannot be combined with a requested core rebuild. Confirm that the
built plugin is inside the resulting **app bundle** before testing it.

For N64, `build-n64-plugins.sh` prepares the pinned sources, applies the loader
patch, builds the selected platform's MoltenVK slice if absent, compiles the
video/RSP plugins, and copies the loader beside them. It recompiles plugin
sources so header or flag changes cannot leave old objects. First builds need
network access and take longer. `MUPEN_PARALLEL_PLUGIN_DIR` remains an explicit
override for an already-built platform-correct set; users of that override are
responsible for provenance. To force a driver rebuild after changing its build
settings, move the ignored MoltenVK dependency cache aside first. New pins or
tracked patch contents select a new cache automatically.

MAME remains a two-level maintenance job: the headless fork must carry changes
from mamedev/MAME, and Cassowary's Apple/Clang patch must still apply to the
chosen fork commit. The generic vendored-source merge command does not manage
that downloaded source tree.

After the core build, full app build, and game checks pass, commit on the update
branch and merge it into main locally. Keep emulator-source changes and their
pin in the same commit. Preserve licenses; ship no build caches or binaries.
Do not send local platform adaptations upstream without separately reviewing
whether they fit that project's public API and platform policy.

## Validation of this maintenance change

The offline Git tests cover a preserved Metal-like edit, new upstream code,
local deletions, binary updates, executable modes, conflict exposure, dirty
source/cache rejection, repeat-review protection, and applying the exported
patch under a core directory. Same-revision comparisons were prepared for
melonDS, VirtualC64, Mupen64Plus, mGBA, SNES9x, BSNES, FCEU, Atari800, and
Stella. These verify the machinery and expose local differences; they do not
establish runtime correctness of every core.

A forward comparison of melonDS 1.1 with upstream `906e9ebb27da` exposed one
conflict in `src/GPU2D_Soft.cpp`, exactly where the local capture patch lives.
That candidate remains in ignored review output; no upstream version was
applied to the app. This illustrates the intended workflow: the conflict is
visible, and the existing Metal capture behavior survives until it is reviewed.

The full iOS Simulator app build passed after rebuilding N64, melonDS, and
VirtualC64. The existing Game Boy end-to-end test passed for video and touch,
keyboard, and gamepad input on a dedicated test Simulator. N64 video/RSP and
MoltenVK libraries also compiled for iPhone, with their iOS platform metadata
checked. The N64 Simulator runtime failure above remains unresolved; no
physical-device, Catalyst, or Apple TV runtime compatibility is claimed here.
