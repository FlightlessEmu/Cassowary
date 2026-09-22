# N64 (Mupen64Plus) optimisation audit

Scope: what is slow in the N64 core, what was changed, and what is left.
The work lives on the `feat/n64-core-master` branch.

---

## 1. The core was five years behind upstream

The vendored `mupen64plus-core` was an OpenEmu fork snapshot from
December 2020 (`732cddb`) with the 2021 OpenEmuARM64 patches, still
reporting version 2.5.9. Upstream released 2.6.0 in July 2024 and kept
going; master (September 2026) now has:

- **Native Apple Silicon support for the new dynarec** (PR #1184,
  `new_dynarec: native Apple Silicon (darwin-arm64) support`) — MAP_JIT
  allocation, `sys_icache_invalidate`, Mach-O linkage.
- Five years of `new_dynarec` correctness fixes (idle loop, FPU crashes,
  cop2, register allocation, interpreted fallback).
- Interpreter accuracy fixes and savestate changes (minizip).

This branch rebases the core on upstream master. The local changes kept
are small: the OpenEmu glue (`Compatibility/`), the iOS adaptations in
`new_dynarec.c`, the exported speed limiter, the Xcode project, and the
minizip include path.

## 2. Emulation mode: the biggest lever

`MupenGameCore.m` used to force `EMUMODE_PURE_INTERPRETER` on every
`aarch64` build — the slowest of the three CPU modes — because the old
ARM64 dynarec was broken. With upstream master:

- The cached interpreter is the default on Apple Silicon. It is much
  faster than the pure interpreter and it is what runs today.
- The dynarec is compiled in and can be tried with
  `CASSOWARY_N64_DYNAREC=1`, but upstream master's brand-new
  darwin-arm64 backend (PR #1184, September 2026) still crashes the
  emulation thread a few seconds into a game: the generated code stores
  to an untranslated N64 address (`strh w1, [x0, x30]` with the RDRAM
  offset register zero, faulting at `0x800f694a`). That is upstream
  code, not this port; it needs reporting and a fix before the dynarec
  can become the default.

## 3. Build flags: the cores are compiled at `-O0`

`Scripts/cassowary/build-core-ios.sh` passes no optimisation flag at
all, and `core-info.py` never reads `GCC_OPTIMIZATION_LEVEL` (the
projects set 3 for Release, 0 for Debug, and the script reads Debug).
Every core in the app is therefore built at clang's default, `-O0`.
For the N64 core that means the interpreter, the RSP and the whole
core run unoptimised; the same is true for every other core.

This is the single largest win left and it is not N64-specific.

## 4. Plugin build flags

The paraLLEl-RDP video plugin and the cxd4 RSP are built by
`build/spike/parallel-plugin/build.sh` (not vendored yet):

- Both are compiled at `-O1`; `-O2` (or `-O3`) is worth several percent
  in the RSP interpreter and the RDP command processor.
- The RSP is built without `-DUSE_SSE2NEON`, which the upstream
  Makefile defines for ARM. cxd4's vector unit has SSE2 intrinsics
  (`vu.c`, `add.c`, `multiply.c`, `divide.c`) that go through
  `sse2neon` on ARM; without the define it falls back to scalar C.

## 5. Frame handoff

`copyParallelFrame` copies the plugin's frame and swizzles RGBA to BGRA
one pixel at a time, on the emulation thread, every frame. The Metal
bitmap renderer already has a GPU converter for `OEPixelFormat_RGBA`
(`MTLPixelConverter.convert_rgba8888_to_bgra8888_buf`), so the swizzle
can be dropped and the copy reduced to a row `memcpy`. A 32-bit word
variant of the loop crashed with an out-of-bounds read; the row copy is
bounds-safe.

## 6. Simulator support

The N64 core now runs in the iOS Simulator, which needed three fixes:

1. **MoltenVK is unsigned** in the xcframework, and dyld refuses to load
   an unsigned dylib in the Simulator. The staging step now signs the
   nested dylibs ad-hoc (Simulator and Catalyst only).
2. **The Simulator's Metal cannot wrap a host pointer in an
   `MTLBuffer`**, and MoltenVK traps in
   `VK_EXT_external_memory_host`. The core sets
   `PARALLEL_RDP_ALLOW_EXTERNAL_HOST=0` there, so parallel-rdp uses its
   device-memory fallback (a copy, slower, but it works).
3. **`pthread_jit_write_protect_np` is unavailable in the iOS SDK** but
   exists at runtime in the Simulator, and MAP_JIT pages are
   executable-only until the toggle is used. The core now looks the
   symbol up with `dlsym` and falls back to a no-op on a device.

## 7. Audio

The old port's audio was jumbled. The likely cause is already in this
branch: without the SDL clock fix and the VI speed limiter, the core
runs unthrottled, the ring buffer overruns, and OpenEmu discards the
oldest samples (`OERingBufferDiscardPolicyOldest`). Both fixes are
carried here. The audio format itself (native-endian 16-bit stereo,
left/right swapped by the glue) matches what OpenEmu's audio unit
expects.

## 8. Crashes found while bringing the core up

1. **The GFX plugin would not start.** MoltenVK ships unsigned in the
   xcframework and dyld refuses to load an unsigned dylib in the
   Simulator; the staging step now signs the nested dylibs ad-hoc
   (Simulator and Catalyst only). With that fixed, MoltenVK traps in
   `VK_EXT_external_memory_host` because the Simulator's Metal cannot
   wrap a host pointer in an `MTLBuffer`. The core sets
   `PARALLEL_RDP_ALLOW_EXTERNAL_HOST=0` there, so parallel-rdp uses its
   device-memory fallback (a copy per frame, slower, but it works).
2. **The JIT crashed in `arch_init`.** `pthread_jit_write_protect_np` is
   unavailable in the iOS SDK, so the core stubbed it out; on current
   Apple systems MAP_JIT pages are executable-only until the toggle is
   used, so the first write to the code cache faulted. The core now
   looks the symbol up with `dlsym` and falls back to a no-op on a
   device.
3. **cxd4's RSP plugin hijacked other threads.** It installs
   process-wide `SIGSEGV`/`SIGILL` handlers and recovers with `longjmp`
   into a `jmp_buf` saved during `InitiateRSP`. The RSP's boot probe
   deliberately reads past the RDRAM to measure it, and any stray RSP
   address faults the same way. The `jmp_buf` was a plain global, so a
   fault delivered to any other thread — or one after the RSP run had
   finished — longjmp-ed that thread onto the RSP's stack. The Simulator
   showed the main thread frozen inside `_sigtramp`/`longjmp`, and later
   crashed with a corrupted main-thread stack. The recovery buffer is
   now thread-local and live only while the RSP is actually running.
4. **`controllerCommand` was called with NULL.** Upstream master calls
   the input plugin with `(-1, NULL)` after PIF RAM processing and after
   a savestate load, per the Zilmar plugin spec. The glue read
   `Command[0]` unconditionally, so controller detection crashed the
   core. It now returns early for that call.

## 9. The GPU channel converter is not safe for the N64 frame path

Reporting `OEPixelFormat_RGBA` so the Metal renderer converts RGBA to
BGRA on the GPU (`MTLPixelConverter`) crashes the app with a corrupted
main-thread stack within seconds. The CPU swizzle in
`copyParallelFrame` is what works today; the RGBA path needs its own
investigation before it can replace it.

## 10. Still open

- The `-O0` build (section 3), the plugin flags (section 4) and the
  frame handoff (section 5) are measured only by inspection so far.
- The Simulator's Metal cannot import host memory, so the N64 core
  there runs parallel-rdp's device-memory fallback (a copy per frame).
  That is a Simulator-only cost.
- The 32-bit word copy of the frame (from `0f7a4ed6f`) is still out;
  it over-read the source row. The row `memcpy` in this branch is the
  safe version of that idea.
