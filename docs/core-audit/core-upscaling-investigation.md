# Core upscaling investigation

Scope: how to make the picture bigger and better for the cores Cassowary
actually ships on iOS, starting with the bitmap (2D) ones. This is a survey of
what exists, what is missing, and the cheapest way to close the gap. It changes
no code. The work lives on the `feat/core-upscaling` branch.

---

## 1. The short version

There are two different things people call "upscaling", and only one of them
applies to the bitmap cores.

1. **Internal resolution scaling** — the emulator itself renders the game at
   2x/3x/4x, then shows it smaller. This only means anything for cores that
   draw 3D geometry, and it lives *inside* each core. In this repo the cores
   that have that knob (Flycast, PPSSPP, Dolphin, GLideN64) are **not part of
   the iOS build**.
2. **Image upscaling** — the core hands over its picture at its natural size,
   and the picture is enlarged on the way to the screen. This applies to every
   core, and for the bitmap cores it is **already built and working**.

So for the bitmap cores there is no unsolved rendering problem to fix. The
picture is already enlarged to the screen through the shared Metal chain, and
there are already two real upscalers available (xBRZ/SABR shader presets and
MetalFX). The actual gaps are narrower:

- No classic pixel-art scalers are bundled as presets (scale2x/3x, hq2x/3x/4x,
  2xSaI/Super2xSaI/SuperEagle, Eagle). Only xBRZ and SABR ship today.
- No pixel-perfect / integer-scale option, so non-integer screen sizes get
  uneven pixels.
- The one shipped core that *could* scale internally — melonDS — has its 3D
  scale hard-wired to 1 in the Metal port.

Everything else is either already done or belongs to cores that are not in the
app.

---

## 2. Two kinds of core

The engine asks each core how it will produce its picture. That answer is the
`gameCoreRendering` property (`OpenEmu-SDK/OpenEmuBase/OEGameCore.h:111-121`,
`:369-371`). It has two shapes:

- **Bitmap** (`OEGameCoreRenderingBitmap`, the default —
  `OpenEmu-SDK/OpenEmuBase/OEGameCore.m:551-560`). The core writes packed
  pixels into a plain block of memory that the app reads. Every 2D system
  works this way, and so do the software-rendered ones.
- **Self-rendering** (`OpenGL2`, `OpenGL3`, `Metal2`). The core owns its own
  GPU surface and the app just hands that surface to the screen.

This is the "some are different" split. It decides where upscaling can happen:

- Bitmap cores all funnel through **one shared path**, so one improvement
  helps all of them at once. This is why they are the right place to start.
- Self-rendering cores each need their own change.

### Which shipped cores are which

The authoritative list of what the iOS build stages is the `CORES` array in
`Scripts/cassowary/build-cassowary.sh:353-361`. By render type:

| Kind | Cores | How the picture gets out |
|---|---|---|
| **Bitmap** | 4DO, Atari800, Bliss, blueMSX, BSNES, CrabEmu, FCEU, Gambatte, GenesisPlus, JollyCV, MAME, Mednafen (PSX, Saturn, PC-FX, PCE, WonderSwan, Lynx, VB, NGP), mGBA, **Mupen64Plus (paraLLEl-RDP)**, Nestopia, O2EM, picodrive, PokeMini, Potator, ProSystem, SNES9x, Stella, VirtualJaguar, VirtualC64 | `MTLGameRenderer` → `FilterChain` → screen |
| **Metal2** | melonDS, VecXGL | `MTL3DGameRenderer`, core's own `MTLTexture` |
| **OpenGL3** | *(not staged)* Flycast, PPSSPP, DeSmuME | rejected on iOS — see below |

Two things worth calling out:

- **Mupen64Plus is a bitmap core by default.** The bundled N64 video plugin is
  paraLLEl-RDP, which hands over finished frames; the core reports `.bitmap`
  for it (`cores/Mupen64Plus/MupenGameCore.m:921-926`). The GLideN64 fallback
  reports `.openGL3`, which iOS cannot run. So in practice N64 is a bitmap core
  here, and the "internal resolution" lever for N64 is not reachable.
- **Flycast / PPSSPP / Dolphin / DeSmuME are not in the iOS build.** They are
  absent from the `CORES` list, and their render type is `.openGL3`, which the
  helper turns into a hard stop on iOS
  (`OpenEmuKit/Source/OpenEmuHelperApp.swift:216-222`). Their upstream
  resolution knobs (`rend.Resolution`, `iInternalResolution`, `iEFBScale`)
  therefore cannot be used today. `AGENTS.md` still lists Flycast and PPSSPP
  as shipped; that table looks out of step with the build script and is worth
  reconciling on its own.

---

## 3. How a bitmap frame reaches the screen

One frame, in order:

```
core -executeFrame
  └─ getVideoBufferWithHint:            packed pixels, OEPixelFormat/OEPixelType
OpenEmuHelperApp  (OpenEmuKit/Source/OpenEmuHelperApp.swift)
  └─ MTLGameRenderer.prepareFrameForRender        (MTLGameRenderer.swift:107-113)
       copies/converts the pixels into a bgra8Unorm texture
       sized to gameCore.screenRect               (MTLGameRenderer.swift:80-95)
  └─ FilterChain.renderOffscreenPasses            (FilterChain.swift:619-644)
       the chosen .slangp preset's passes, on the GPU
  └─ [ MetalFX, if on ]                           (OpenEmuHelperApp.swift:1024-1043)
  └─ FilterChain.renderFinalPass / renderFinalTexture   (FilterChain.swift:708-727, :743-756)
       draws into the CAMetalLayer drawable, at the layer's pixel size
```

The important part: `FilterChain` **already fits the core's picture to the
drawable and draws it up to screen size**
(`FilterChain.swift:369-392`, `:708-727`), nearest-neighbour by default
(`:591-605`). So every bitmap core is already upscaled to fill the screen. When
a preset is chosen, those passes run at view resolution and do the upscaling
with the preset's own quality.

There is no fixed output resolution: the picture is sized to the view, and 3D
cores can ask for a different size through `tryToResizeVideoTo:` — but the
default refuses for bitmap cores (`OEGameCore.m:585-591`), which is correct,
because a 2D console's resolution is fixed by the hardware.

### Where a new upscaler would plug in

Three seams already exist, in order of least change:

1. **A bundled shader preset.** Drop a folder under
   `Cassowary/Resources/Shaders/`. No code. It shows up in the existing
   Video Filter picker and is remembered per system.
2. **The final-stage scaler.** `FilterChain.finalSourceTexture`
   (`FilterChain.swift:729-741`) plus `renderFinalTexture` (`:743-756`) is the
   seam MetalFX already uses. A new whole-picture upscaler (e.g. a MetalFX
   temporal or a custom Metal kernel) would sit here.
3. **The source conversion.** `MTLGameRenderer.update`/`prepareFrameForRender`
   (`MTLGameRenderer.swift:45-113`) if a filter had to run at the core's
   native resolution before anything else.

---

## 4. What already exists (do not rebuild it)

**The shader engine is real.** `OpenEmu-Shaders/` compiles libretro `.slang` /
`.slangp` presets to Metal at runtime (glslang → SPIRV-Cross; see
`OpenEmu-Shaders/Source/SlangCompiler.swift`, `ShaderPassCompiler.swift`). Any
libretro slang preset that compiles is usable.

**Two genuine pixel-art upscalers already ship** under
`Cassowary/Resources/Shaders/`:

| Preset | Files | Notes |
|---|---|---|
| `xBRZ Freescale` | one `.slangp`, one `.slang` | edge-directed pixel scaler |
| `xBRZ Multipass Freescale` | two passes | higher quality, slower |
| `SABR` | one `.slangp`, one `.slang` | Sabr v3.0, edge-smoothing |

Plus `Nearest Neighbor`, `Linear`, `Smooth`, `Pixellate`, and the CRT/LCD/scanline
family (19 preset folders in all). The picker is
`Cassowary/Sources/Views/GameView.swift:181-186` in-game and
`Cassowary/Sources/Views/SettingsView.swift` app-wide/per-system. The list is
read by `OpenEmuKit/Source/OEShaderStore.swift:158-193` and wrapped by
`Cassowary/Sources/Models/ShaderCatalog.swift:73-76`.

**Adding a preset is a resource change, not a code change.** `project.yml`
copies `Resources/Shaders` as one folder reference
(`Cassowary/project.yml:66-69`), which preserves the
`Shaders/<name>/<name>.slangp` layout the store scans for — a new folder
appears automatically.

**MetalFX spatial upscaling is already implemented end-to-end.** It runs as the
final stage after the filter chain:
`OpenEmuKit/Source/OpenEmuHelperApp.swift:1167-1241` (the scaler),
`:303-341` (build/reuse), `:1024-1043` (per-frame), gated on
`#if canImport(MetalFX) && !os(macOS)` (`:33-38`). The UI is an off-by-default
toggle in `GameView.swift:189-193`, availability-checked at `:294-303`. It only
helps on hardware that passes `MTLFXSpatialScalerDescriptor.supportsDevice`
(Apple Silicon; some older A-series chips are unsupported), which is why it
degrades gracefully rather than being the default.

So the app already has: nearest upscale (default), a library of quality
scalers, CRT/LCD looks, and a hardware upscaler. The bitmap-core gap is about
*coverage and pixel-perfectness*, not about a missing mechanism.

---

## 5. Gap list

### 5a. Bitmap cores — the real, cheap wins

1. **No classic pixel scalers.** xBRZ and SABR are the only scalers bundled.
   The other well-known family is missing: scale2x/scale3x, hq2x/3x/4x,
   2xSaI/Super2xSaI/SuperEagle, and Eagle. These are what players mean by
   "upscaling" for NES/SNES/Genesis/GB. Adding them is a drop-in of libretro
   `.slangp` presets, exactly like the xBRZ one already there. **No code.**
2. **No pixel-perfect / integer scaling.** The final draw stretches the source
   to the whole drawable, so 256x240 on a non-integer scale produces a pixel
   grid with uneven rows/columns. An "integer scale" option (letterbox the
   remainder) or a small "scale" step would fix that. This is a code change in
   the final-pass viewport math (`FilterChain.swift:369-392`, `:708-727`).
3. **No per-system default upscaler.** Filters are opt-in and remembered per
   system (good), but there is no shipped notion of "this system looks best
   with xBRZ". That is a data/choice question, not engine work.

Nothing here needs any core to change. That is the point of the bitmap path:
one chain, all cores.

### 5b. Self-rendering cores

- **melonDS (NDS, Metal2).** Upstream can render the 3D layer at 1x–16x
  (`3D.GL.ScaleFactor`), and the OpenEmu Metal renderer carries a `scale3D`
  uniform (`cores/melonDS/MelonDS/MelonDSMetalRenderer.mm:52-56`) that is
  hard-wired to `1` at `:348`, with the 3D texture fixed at 256x192
  (`:41-42`). Wiring a scale here would sharpen DS 3D without touching the 2D
  layers — a genuine, self-contained improvement. This is the only shipped core
  with an internal-resolution lever worth pulling.
- **VecXGL (Vectrex, Metal2).** Vector output at native resolution; upscaling
  is not meaningful. Leave it.
- **Mednafen (PSX/Saturn/PC-FX/…, bitmap but software-rendered).** The core has
  no resolution knob at all — the PSX GPU is a software rasteriser
  (`cores/Mednafen/mednafen/psx/gpu.cpp:163-205`, settings at
  `psx.cpp:2243-2297`). PSX/Saturn "internal resolution" would mean porting a
  higher-res renderer (PGXP / GPU overclock), a large project on its own. Out of
  scope here; image upscaling via shaders is the only practical improvement for
  now.
- **Flycast / PPSSPP / Dolphin / DeSmuME.** Not in the iOS build and their
  render type is rejected on iOS. Their resolution knobs are a reason to finish
  those ports, not part of this work.

---

## 6. Options, cheapest first

| # | Idea | Touches | Cost | Risk | Payoff |
|---|---|---|---|---|---|
| 1 | Bundle classic pixel scalers as shader presets (scale2x/3x, hq2x/3x/4x, 2xSaI/Super2xSaI/SuperEagle, Eagle) | `Cassowary/Resources/Shaders/` only | Low | Low (each preset may fail to compile; verify each) | High — the obvious missing feature for 2D |
| 2 | Add integer-scale / pixel-perfect option | `OpenEmu-Shaders/Source/FilterChain.swift`, small UI | Medium | Medium (layout math) | Medium — fixes uneven pixels |
| 3 | Wire melonDS 3D scale (`scale3D` uniform + 3D texture size) | `cores/melonDS/MelonDS/`, core UI | Medium | Medium | Medium — sharper DS 3D |
| 4 | Let MetalFX run automatically when the device supports it | `OpenEmuHelperApp.swift`, `GameView.swift` | Low | Low | Medium — one less manual step |
| 5 | Port Flycast/PPSSPP to iOS, then expose internal resolution | core ports | Very high | High | Large, separate project |

### Notes on option 1

The bundled xBRZ preset is the template: one folder, a `<Name>.slangp` pointing
at a `<name>/shaders/<file>.slang`, and for single-pass scalers that is the
whole thing:

```
shaders = 1
shader0 = <name>/shaders/<name>.slang
filter_linear0 = false
scale_type0 = viewport
scale0 = 1.0
```

Sources for the missing presets are the libretro slang-shaders tree
(`scalenx/`, `hqx/`, `sabr/`, `xbr/`, and the 2xSaI/SuperEagle family). Prefer
single-file `.slang` shaders with no `#include` chain, because that is what the
existing bundled presets use and it is the least likely to trip the
glslang/SPIRV-Cross path. Budget time to actually run each one: a preset that
does not compile should be dropped, not shipped.

Licensing, if these are vendored: scale2x is GPL-2.0-or-later, hqx is LGPL-2.1,
xBRZ is GPL-3.0 with a linking exception, 2xSaI is GPL (avoid the Snes9x copy,
which adds a non-commercial restriction). GPL/LGPL are fine for a bundle that
already ships GPL cores, but check each shader's header and avoid any
CC-BY-NC-SA ones.

---

## 7. Recommended plan

**Phase 1 — bitmap cores, presets only (no code).**
Vendor scale2x/3x, hq2x/3x/4x, 2xSaI/Super2xSaI/SuperEagle and Eagle as
`.slangp` folders. Verify each compiles and looks right. This is the fastest
real improvement and it reaches every 2D core at once.

**Phase 2 — bitmap cores, pixel-perfect.**
Add an integer-scale / pixel-perfect choice in the final pass so 240p content
lands on a clean grid.

**Phase 3 — melonDS 3D scale.**
Expose the `scale3D` uniform and size the 3D render target accordingly, with a
small per-core setting. This is the first change that lives in a core.

MetalFX stays as-is (opt-in, device-gated). Auto-enabling it is optional polish,
not a phase.

## 8. What this branch implements

**Phase 1 — classic pixel scalers as presets (no core changes).**
Eight new `.slangp` presets under `Cassowary/Resources/Shaders/`, each a folder
the existing picker reads automatically:

| Preset | What it does |
|---|---|
| `Scale2x`, `Scale3x` | Andrea Mazzoleni's scale2x/3x, then a bicubic stretch |
| `2xSaI`, `Super 2xSaI` | Derek Liauw Kie Fa's edge-directed 2x scalers |
| `Super Eagle` | the SuperEagle 2x scaler |
| `HQ2x`, `HQ3x`, `HQ4x` | Maxim Stepin's hq2x/3x/4x with their LUTs |

Shared shaders and look-up tables live in `Cassowary/Resources/Shaders/Common/`.
That folder has no `.slangp`, so `OEShaderStore` skips it as a preset while the
folder reference still copies it into the app.

Every bundled preset — the 19 that were already there plus these 8 — was
compile-checked with the `oeshaders compile` tool (`OpenEmu-Shaders/oeshaders`)
before commit; all 27 pass the glslang → SPIR-V → Metal translation the app
performs at runtime.

**Phase 2 — pixel-perfect (integer) scaling.**
A new "Scaling" picker in `GameView` (Fill / Pixel Perfect) drives a new
`integerScaleEnabled` flag on `FilterChain`
(`OpenEmu-Shaders/Source/FilterChain.swift`). When on, the final picture is
enlarged by the largest whole number that fits and centred, instead of being
stretched to any size. It applies to the unfiltered picture and to presets
whose last pass is sized from the source; when a preset already renders at
screen size, or the picture would not fit even once, it falls back to the
normal fill. The choice is remembered per app
(`cassowary.integerScaling`) and is safe to toggle mid-game.

Files touched: `OpenEmu-Shaders/Source/FilterChain.swift`,
`OpenEmuKit/Source/OpenEmuHelperApp.swift`,
`Cassowary/Sources/Session/GameSession.swift`,
`Cassowary/Sources/Views/GameView.swift`.

## 9. How to check it works

- Presets: `./Scripts/cassowary/build-cassowary.sh`, then
  `./Scripts/cassowary/run-cassowary.sh`; pick the new filter in-game and
  confirm the picture changes with no console errors.
- `./Scripts/cassowary/test-cassowary.sh` for the end-to-end pass.
- MetalFX path already logs its scale change: look for
  `[Cassowary] MetalFX spatial upscaling …` in the device console.
- Remember the plugin rule: a core change does nothing until the app is rebuilt
  and the plugin restaged (`./Scripts/cassowary/build-cassowary.sh`), because
  the app loads `.oecoreplugin` from its own bundle, not from `build/`.

---

## 10. Open questions

- Should the shipped set include a per-system recommended filter (e.g. stretch
  vs xBRZ), or stay fully manual as today?
- Is pixel-perfect scaling worth the UI, or is nearest-to-screen good enough
  once a real scaler is selected?
- The `AGENTS.md` supported-core table lists Flycast and PPSSPP but the build
  script does not stage them. Worth reconciling in a follow-up so this document
  and the table agree.
