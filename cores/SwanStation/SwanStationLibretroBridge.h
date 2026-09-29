// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// The front half of libretro.
//
// SwanStation is a libretro core: it expects a frontend to hand it callbacks
// for video, audio, input and a pile of environment queries. OpenEmu's cores
// are plain Objective-C classes instead, so this file is the adapter — the
// smallest frontend that a libretro core will boot under. The glue
// (SwanStationGameCore.mm) drives it: Initialize once, LoadGame per disc,
// RunFrame per frame.
#pragma once

#include <cstddef>
#include <cstdint>

namespace SwanStationBridge {

/// Called before Initialize. Both are absolute paths that must exist.
void SetDirectories(const char* system_dir, const char* save_dir);

/// Whether the game should run on the GPU. The app decides this before the
/// game loads; when it is on, the core boots with its Metal renderer (and
/// falls back to software rendering if that cannot start).
void SetMetalRendererEnabled(bool enabled);
bool MetalRendererEnabled();

/// The app's Metal device. Handed over before the game loads.
void SetMetalDevice(void* device);

/// The texture the renderer published for the last frame, or nullptr. The
/// caller draws it; the core does not own it.
void* DisplayTextureHandle();

/// The size of that texture, or false when nothing has been rendered yet.
bool DisplaySize(unsigned* width, unsigned* height);

/// Sets up the libretro callbacks and boots the core (retro_init).
bool Initialize();

/// True once a game is loaded.
bool IsGameLoaded();

/// Loads a disc image or executable. The path must be readable by the core.
bool LoadGame(const char* path);

/// Tears down the running game (retro_unload_game).
void UnloadGame();

/// Runs one frame (retro_run). Video lands in the last-frame accessors below,
/// audio goes to the audio callback.
void RunFrame();

/// Resets the running game (retro_reset).
void Reset();

/// Save states, straight from the core's own serializer.
std::size_t SerializeSize();
bool Serialize(void* data, std::size_t size);
bool Deserialize(const void* data, std::size_t size);

/// Which controller the core should emulate on a port. Pass the libretro
/// device constants (RETRO_DEVICE_JOYPAD, RETRO_DEVICE_PS_DUALSHOCK, ...).
void SetControllerPortDevice(unsigned port, unsigned device);

/// Frames per second the core reports for the loaded game.
double FrameRate();

/// Audio rate the core reports. The core's own audio stream is fixed at
/// 44100 Hz, so this is a formality, but it is the core's number.
double SampleRate();

/// Size the core says it will render at. The real frame can differ (PlayStation
/// games switch resolution as they go), so this is only the starting point.
unsigned DisplayWidth();
unsigned DisplayHeight();

/// Display aspect ratio the core reports, or 0 when it has none.
double AspectRatio();

/// The frame the core last handed over. Pixels are XRGB8888, which on this
/// hardware is byte-for-byte BGRA.
const void* LastFramePixels();
unsigned LastFrameWidth();
unsigned LastFrameHeight();
unsigned LastFramePitch();

/// Called from inside RunFrame with interleaved stereo S16 samples.
using AudioCallback = void (*)(const int16_t* frames, std::size_t frame_count, void* userdata);
void SetAudioCallback(AudioCallback callback, void* userdata);

/// Called from inside RunFrame, once per device and id the core wants to know
/// about. Return non-zero when the button is held. The port/device/index/id
/// values are libretro's (RETRO_DEVICE_ID_JOYPAD_*, RETRO_DEVICE_ID_ANALOG_*).
using InputStateCallback = int16_t (*)(unsigned port, unsigned device, unsigned index, unsigned id, void* userdata);
void SetInputStateCallback(InputStateCallback callback, void* userdata);

/// Called from inside RunFrame when a port's vibration motors change. The
/// strengths run 0-65535; the DualShock's big motor is `strong`, its small
/// one `weak`.
using RumbleCallback = void (*)(unsigned port, uint16_t strong, uint16_t weak, void* userdata);
void SetRumbleCallback(RumbleCallback callback, void* userdata);

/// A core option (the `swanstation_...` keys in libretro_core_options.h),
/// answered when the core asks. Set before LoadGame for options that only
/// take effect at boot; a later change is picked up on the next frame.
/// A null value forgets the option, so the core's default applies again.
void SetOption(const char* key, const char* value);

/// The discs of the loaded game. An .m3u playlist lists several, anything
/// else is one. Indices count from 0.
unsigned DiscCount();
unsigned CurrentDisc();
/// Opens the lid, swaps the disc, and closes it again.
bool SetDisc(unsigned index);

} // namespace SwanStationBridge
