# melonDS

The Nintendo DS core: [melonDS](https://melonds.kuribo64.net) 1.1, used under
the GPL-3.0-or-later.

melonDS is the modern DS emulator — faster and more accurate than DeSmuME, with
working local wireless and online play. It is the DS core this app ships;
`cores/DeSmuME/` is the older OpenEmu core, which does not build for iOS.

## Layout

| Path | What it is |
|------|------------|
| `src/` | Upstream melonDS 1.1, unmodified except for the two patches below |
| `MelonDS/` | This port's glue: the OpenEmu core, the platform layer, the plugin project |
| `project.yml` | XcodeGen spec for `melonDS.xcodeproj` (the glue only) |
| `LICENSE` | melonDS's GPL-3.0 |

## Building

The emulator is a CMake project, so it is compiled into static libraries and
linked into the plugin bundle:

```bash
./Scripts/cassowary/build-melonds-ios.sh --catalyst   # libcore.a + libteakra.a
./Scripts/cassowary/build-core-ios.sh melonDS --catalyst
```

`build-core-ios.sh` runs the first command for you when the libraries are
missing, so a normal app build only needs:

```bash
./Scripts/cassowary/build-cassowary.sh --catalyst
```

The ARM64 JIT is not enabled yet. On this combination of macOS and Xcode it
faults inside its own fast-memory setup during startup — before a frame is
ever run — and melonDS's fault handler needs a current emulator instance that
does not exist yet at that point. Every build therefore uses the interpreter,
which is what a device build gets regardless, since iOS does not permit a JIT.
Turning it back on means giving the JIT's fast memory a working setup on
Apple; see `src/ARMJIT_Memory.cpp` and `src/ARMJIT.cpp`.

## What works

- DS games, one frame at a time, with both screens stacked into one picture
  (256×384).
- The picture is finished by a **Metal renderer** into one texture, which the
  app displays directly (`OEGameCoreRenderingMetal2`), so the frame never goes
  through the CPU. The 2D layers are composited by Metal; the 3D layer is
  drawn by melonDS's software rasteriser for now (see below).
- Buttons, the touch screen — a finger on iPhone and iPad, a mouse or trackpad
  click-drag on the Mac — and the lid (the `Lid` binding closes it).
- Sound, resampled to 48 kHz.
- Battery saves (`.sav` next to the ROM's save), and save states.
- The Rumble Pak, played through the same haptics path as the N64 core.
- Display capture (`CaptureCnt`) works: the 3D layer the game captures is read
  back for the frames a game captures.
- Optional BIOS and firmware images: drop `bios7.bin`, `bios9.bin` and
  `firmware.bin` into the app's BIOS folder to use a real firmware (the DS
  menu, Pictochat, Download Play). Without them melonDS uses its own FreeBIOS
  and generated firmware.

## What is not done yet

- **The Metal 3D rasteriser.** The compositor and the display path are done.
  Polygons are drawn by melonDS's software rasteriser and copied into the 3D
  texture each frame, so 3D scenes are complete and correct but the 3D work
  is still on the CPU. See "The Metal renderer" above for the port's plan and
  where it stands.
- **Wi-Fi**: no local wireless, no LAN, and no online (Nintendo WFC) yet.
  melonDS keeps all of that in `src/net/`, which the emulator reaches through
  `Platform::MP_*`/`Platform::Net_*`; the glue currently answers "no link".
  The pieces to wire are `LocalMP` (two instances on one machine), `LAN` (needs
  ENet), and `Net_Slirp` (bundles libslirp, gives the DS an internet
  connection for community WFC servers).
- **DSi mode**, the camera, and microphone input.

## The Metal renderer

The picture is finished on the GPU. It has two pieces:

- **The compositor** (`MelonDS/MelonDSMetalRenderer.{h,mm}`, with the shaders
  in `MelonDS/MelonDSMetalShaders.h`). melonDS's accelerated 2D renderer hands
  it a layer buffer — three layers plus a metadata word per scanline — and it
  composes both screens into one 256×384 texture that the app displays.
- **The 3D layer.** Until the Metal rasteriser below is finished, the polygons
  are drawn by melonDS's software rasteriser and its output is copied into the
  ​3D texture each frame. That is a CPU cost, but it makes the picture
  complete and correct, and it gives the Metal rasteriser something to be
  checked against. `MELONDS_3D=metal` in the environment turns the software
  rasteriser off, which leaves the 3D layer empty and is how the port is
  tested step by step.

**The 3D rasteriser**, ported from melonDS's compute renderer
(`src/GPU3D_Compute.cpp` and `src/GPU3D_Compute_shaders.h`). That renderer
suits Metal better than the OpenGL one: no stencil buffer, no fixed-function
blending, everything in compute shaders.

The port follows upstream's passes in order, each stage checked against the
software renderer with an offline harness that renders the same ROM and frame
with both:

1. ~~Buffers, uniforms and the CPU-side span setup (`SetupYSpan`,
   `SetupYSpanDummy`, `SetupAttrs`, polygon and variant collection).~~ Done:
   `MelonDSMetal::Rasterizer3D` fills the spans, the per-line indices and the
   per-frame values, and the same setup also produces the horizontal spans
   (`InterpSpans`' work) on the CPU.
2. `ClearCoarseBinMask`, `ClearIndirectWorkCount`, `InterpSpans`,
   `BinCombined`, `CalcOffsets`, `SortWork`. Not needed as passes: the CPU
   does the span setup, and the rasteriser walks polygons in submission order
   instead of binning them into tiles.
3. ~~`Rasterise` (starting with the no-texture Z-buffer variants) and
   `DepthBlend`.~~ Done, in a simpler shape than upstream's: the CPU does the
   span setup, bins the polygons per scanline, and hands the shaders the list
   for each line; one dispatch then walks the polygons in submission order, so
   the depth test, the translucent blending and the anti-aliasing push-down all
   happen in the order the DS does them. Each pixel does a handful of spans
   instead of the whole frame, which is what makes the dispatch finish at all.
4. ~~`FinalPass` without effects, then edge marking, fog and anti-aliasing.~~
   Done: edge marking, fog and anti-aliasing are in, with melonDS's pushed-down
   second line of buffers behind the anti-aliasing.
5. Textures: done — a Metal texture cache (`MelonDSMetalTexcache.h`) behind the
   same `Texcache` template, loading into 2D array textures, with the frame's
   array textures in a table the shader indexes per polygon. Decal, modulate,
   toon and highlight are in, and shadow masks record depth only. Two things
   worth knowing: the shader has to declare the table as `texture2d_array` to
   read a slice out of it (through a plain `texture2d` the slice is swallowed
   and every read hits the empty first layer), and drawing per variant instead
   of per frame breaks the depth, blending and anti-aliasing order across
   variants.
6. Shadow masks, toon and highlight modes, and the W-buffering variants: the
   modes are in; W-buffering is per polygon and in.

Where it stands: a frame of a retail game matches the software rasteriser on
about 45,500 to 46,300 of its 49,152 pixels, with the rest spread over a
handful of surfaces rather than edges.

The comparison harness is the tool to finish it with. `MELONDS_3D=cmp` runs
both rasterisers on the same frame in the same process and:

- prints `same`/`diff` counts and a 4x4-block map of where the differences are
- prints a fixed set of probe pixels with both renderers' colours and the
  attributes the Metal side stored
- has the shader record what it sampled for two of those pixels — the polygon,
  its texture mode, slot and layer, the interpolated `u`/`v`, the wrapped texel
  coordinates, the texel itself and the colour it produced — and prints the
  software rasteriser's own decode of the same texel beside it
- writes `/tmp/cmp-metal.ppm` and `/tmp/cmp-soft.ppm` for a side-by-side look

`MELONDS_NO_TEX` and `MELONDS_NO_BLEND` clear the display's texture and
blending bits for both renderers, which splits a difference into "texture" and
"everything else" in one run; `MELONDS_TEXDIFF` compares every decoded texture
against the software rasteriser's decode, texel by texel.

What the harness has established so far:

- With textures off, the two agree on all but about 200 pixels, so the span
  setup, the depth test, the blending, the coverage and the final pass all
  match. The rest is in the texture path.
- Every decoded texture in a frame matches the software rasteriser's decode
  texel for texel. (Worth knowing when comparing the two: only the four-colour
  palette is addressed in the smaller units, so the software rasteriser shifts
  the base by three for that format alone. A5I3 uses the same shift as the
  larger palettes.)
- The differences that are left are in the *coordinates*, not the texels: for
  the probe pixels the software rasteriser samples a different texel of a
  texture that is decoded correctly.

One of those differences is now fixed. For edges that run mostly horizontally
(the X-major edges) melonDS's software rasteriser interpolates along Y with a
one-pixel offset (`interpoffset` in `Slope::Setup`), while its compute renderer
— which this port followed — switches the interpolation parameter to X and
shifts the range by one. The two give slightly different span endpoints, which
shifts the texture coordinates. The span setup now follows the software
rasteriser for those edges, and one of the two test frames went from 6,994
differing pixels to 4,511.

What is left is one solid rectangle of a surface, about 2,800 pixels. The
probe pixels there are drawn by a translucent polygon whose texture decodes
correctly, and working backwards from the software rasteriser's own colour says
something more specific than "the coordinates differ":

- With blending off, the software's pixel at (100,20) is `1f152e38`, so its
  source colour is (56, 46, 21).
- Both rasterisers agree that polygon's vertex colour is (61, 61, 45): with
  textures off the polygon is opaque, so it overwrites the pixel and the two
  agree on it.
- No texel in that polygon's texture produces (56, 46, 21) from (61, 61, 45)
  through the modulate the polygon uses. The search runs over the whole
  texture, using the software rasteriser's own decode.

Three polygons cover that pixel — 55, 73 and 117, all the same material, in
that submission order — and the search says the software's colour can only come
from the *first* of them. So the software rasteriser's last writer is a
different polygon from the Metal one's, and the difference is in which polygon
wins rather than in the fetch.

The probe reports the whole set now, in submission order, with each polygon's
span, whether the span covers the pixel, and whether any texel of its texture
could produce the software's colour. That is the tool to finish this with. The
remaining candidates for why the later polygons lose in the software are the
depth test (a step of Z can flip it, which is why the Y-direction Z
interpolation now follows the software rasteriser's higher-precision version)
and the edge fill rules, which the software rasteriser relaxes for translucent
polygons with blending enabled — `l_filledge`/`r_filledge` in `RenderScanline`
— where this port still follows the compute renderer's
`FillLeft`/`FillRight`/`FillInside` flags.

Until step 3 lands, the 3D layer comes from the software rasteriser (see
above), and with it the Metal picture is pixel-for-pixel identical to the
software one — the offline harness renders the same ROM and frame with both
and compares them.

## Patches to upstream

Three, all documented where they change the code:

- `src/ARMJIT.cpp` — skips `pthread_jit_write_protect_np`, which the Catalyst
  SDK marks unavailable; Catalyst's JIT pages stay writable without it.
- `src/GPU2D_Soft.cpp` — calls the renderer's `PrepareCaptureFrame` for any
  accelerated renderer, not only the OpenGL one. Display capture reads the 3D
  layer back on the CPU, and a Metal renderer needs the same call.
- The build itself lives in `MelonDS/CMakeLists.txt`, which includes upstream's
  `src/CMakeLists.txt` rather than copying its source list.

To move to a newer melonDS: replace `src/` with the new release, re-apply those
patches, and rebuild.
