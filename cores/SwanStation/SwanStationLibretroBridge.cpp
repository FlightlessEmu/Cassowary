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

#include "SwanStationLibretroBridge.h"

#include "common/log.h"
#include "core/host_display.h"
#include "core/host_interface.h"
#include "core/metal_device.h"
#include "core/settings.h"

#include <libretro.h>

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>

// The core's entry points. Declared by libretro.h, defined by the core.
// (`retro_set_environment` and friends are the core's, not the frontend's:
// in libretro the core publishes them and the frontend calls them.)
RETRO_API void retro_set_environment(retro_environment_t);
RETRO_API void retro_set_video_refresh(retro_video_refresh_t);
RETRO_API void retro_set_audio_sample(retro_audio_sample_t);
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t);
RETRO_API void retro_set_input_poll(retro_input_poll_t);
RETRO_API void retro_set_input_state(retro_input_state_t);
RETRO_API void retro_init(void);
RETRO_API void retro_deinit(void);
RETRO_API void retro_get_system_info(struct retro_system_info*);
RETRO_API void retro_get_system_av_info(struct retro_system_av_info*);
RETRO_API bool retro_load_game(const struct retro_game_info*);
RETRO_API void retro_unload_game(void);
RETRO_API void retro_run(void);
RETRO_API void retro_reset(void);
RETRO_API void retro_set_controller_port_device(unsigned, unsigned);
RETRO_API std::size_t retro_serialize_size(void);
RETRO_API bool retro_serialize(void*, std::size_t);
RETRO_API bool retro_unserialize(const void*, std::size_t);

namespace SwanStationBridge {
namespace {

std::string s_system_dir;
std::string s_save_dir;

bool s_initialized = false;
bool s_game_loaded = false;
bool s_metal_renderer_enabled = false;

AudioCallback s_audio_callback = nullptr;
void* s_audio_userdata = nullptr;
InputStateCallback s_input_callback = nullptr;
void* s_input_userdata = nullptr;

const void* s_frame_pixels = nullptr;
unsigned s_frame_width = 0;
unsigned s_frame_height = 0;
unsigned s_frame_pitch = 0;

struct retro_system_av_info s_av_info = {};
bool s_have_av_info = false;

/// The core's own log, which does not go through the libretro callback. Info
/// is the level that shows the boot sequence, which is what this is for.
void CoreLogCallback(void* user_param, const char* channel_name, const char* function_name, LogLevel level,
                     const char* message)
{
  if (level > LogLevel::Info)
    return;

  std::fprintf(stderr, "[%s] %s\n", channel_name ? channel_name : "core", message);
}

void LogCallback(enum retro_log_level level, const char* fmt, ...)
{
  // Only the two levels that say something went wrong; the core is chatty at
  // info level and none of it is useful on a device.
  if (level != RETRO_LOG_WARN && level != RETRO_LOG_ERROR)
    return;

  va_list args;
  va_start(args, fmt);
  std::fputs(level == RETRO_LOG_ERROR ? "[SwanStation error] " : "[SwanStation warn] ", stderr);
  std::vfprintf(stderr, fmt, args);
  va_end(args);
}

bool EnvironCallback(unsigned cmd, void* data)
{
  switch (cmd)
  {
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
    {
      // Only RGB565, on purpose. The core's software renderer switches between
      // 15-bit and 24-bit output per frame depending on what the disc asks for,
      // while the engine takes one pixel format for the whole session. Refusing
      // XRGB8888 makes the core's 24-bit path pick RGB565 as well, so every
      // frame arrives in the same format and no conversion is needed.
      if (!data)
        return false;
      return *static_cast<const retro_pixel_format*>(data) == RETRO_PIXEL_FORMAT_RGB565;
    }

    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
      return true;

    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
      return true;

    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
      *static_cast<const char**>(data) = s_system_dir.c_str();
      return true;

    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
      *static_cast<const char**>(data) = s_save_dir.c_str();
      return true;

    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
      static_cast<retro_log_callback*>(data)->log = LogCallback;
      return true;

    case RETRO_ENVIRONMENT_GET_VARIABLE:
    {
      // The core asks which renderer to use before it boots the GPU. There is
      // one that works here, and the app decides whether to use it. Every
      // other option is left unanswered so the core keeps its own defaults.
      auto* variable = static_cast<retro_variable*>(data);
      if (!variable || !variable->key)
        return false;

      if (s_metal_renderer_enabled && std::strcmp(variable->key, "swanstation_GPU_Renderer") == 0)
      {
        variable->value = "Metal";
        return true;
      }

      return false;
    }

    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
      // Answer no, so the core asks for each button by id. Bitmasks would need
      // this bridge to know the core's whole button layout instead of
      // forwarding one question at a time.
      return false;

    case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
      // Bit 0 is video, bit 1 is audio; both are always on here.
      *static_cast<int*>(data) = 3;
      return true;

    case RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT:
      *static_cast<int*>(data) = RETRO_SAVESTATE_CONTEXT_NORMAL;
      return true;

    case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
      *static_cast<unsigned*>(data) = 2;
      return true;

    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
      if (!data)
        return false;
      s_av_info = *static_cast<const retro_system_av_info*>(data);
      s_have_av_info = true;
      return true;

    case RETRO_ENVIRONMENT_SET_GEOMETRY:
      if (!data)
        return false;
      s_av_info.geometry = *static_cast<const retro_game_geometry*>(data);
      s_have_av_info = true;
      return true;

    case RETRO_ENVIRONMENT_SET_MESSAGE:
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
      // The messages are things like "BIOS not found" during boot. They are
      // worth seeing while the port is young.
      if (data)
      {
        const char* message = (cmd == RETRO_ENVIRONMENT_SET_MESSAGE)
                                ? static_cast<const retro_message*>(data)->msg
                                : static_cast<const retro_message_ext*>(data)->msg;
        if (message)
          std::fprintf(stderr, "[SwanStation] %s\n", message);
      }
      return true;

    default:
      return false;
  }
}

void VideoRefreshCallback(const void* data, unsigned width, unsigned height, std::size_t pitch)
{
  if (!data || width == 0 || height == 0)
    return;

  s_frame_pixels = data;
  s_frame_width = width;
  s_frame_height = height;
  s_frame_pitch = static_cast<unsigned>(pitch);
}

std::size_t AudioBatchCallback(const int16_t* data, std::size_t frames)
{
  if (s_audio_callback && data)
    s_audio_callback(data, frames, s_audio_userdata);

  // Returning anything other than `frames` makes the core think the frontend
  // dropped samples.
  return frames;
}

void AudioSampleCallback(int16_t left, int16_t right)
{
  const int16_t frames[2] = {left, right};
  AudioBatchCallback(frames, 1);
}

void InputPollCallback() {}

int16_t RetroInputStateCallback(unsigned port, unsigned device, unsigned index, unsigned id)
{
  return s_input_callback ? s_input_callback(port, device, index, id, s_input_userdata) : 0;
}

} // namespace

void SetDirectories(const char* system_dir, const char* save_dir)
{
  s_system_dir = system_dir ? system_dir : "";
  s_save_dir = save_dir ? save_dir : "";
}

bool Initialize()
{
  if (s_initialized)
    return true;

  s_frame_pixels = nullptr;
  s_frame_width = s_frame_height = s_frame_pitch = 0;
  s_have_av_info = false;

  Log::SetFilterLevel(LogLevel::Info);
  Log::RegisterCallback(CoreLogCallback, nullptr);

  retro_set_environment(&EnvironCallback);
  retro_set_video_refresh(&VideoRefreshCallback);
  retro_set_audio_sample(&AudioSampleCallback);
  retro_set_audio_sample_batch(&AudioBatchCallback);
  retro_set_input_poll(&InputPollCallback);
  retro_set_input_state(&RetroInputStateCallback);

  retro_init();

  s_initialized = true;
  return true;
}

bool IsGameLoaded()
{
  return s_game_loaded;
}

void SetMetalRendererEnabled(bool enabled)
{
  s_metal_renderer_enabled = enabled;
}

bool MetalRendererEnabled()
{
  return s_metal_renderer_enabled;
}

void SetMetalDevice(void* device)
{
  MetalDevice::SetDevice(device);
}

void* DisplayTextureHandle()
{
  HostDisplay* display = g_host_interface ? g_host_interface->GetDisplay() : nullptr;
  if (!display || display->GetRenderAPI() != HostDisplay::RenderAPI::Metal)
    return nullptr;

  return const_cast<void*>(display->GetDisplayTextureHandle());
}

bool DisplaySize(unsigned* width, unsigned* height)
{
  HostDisplay* display = g_host_interface ? g_host_interface->GetDisplay() : nullptr;
  if (!display || display->GetDisplayWidth() <= 0 || display->GetDisplayHeight() <= 0)
    return false;

  *width = static_cast<unsigned>(display->GetDisplayWidth());
  *height = static_cast<unsigned>(display->GetDisplayHeight());
  return true;
}

bool LoadGame(const char* path)
{
  if (!s_initialized || s_game_loaded || !path)
    return false;

  // The renderer is chosen before the game boots: the GPU is built from the
  // settings during retro_load_game.
  if (s_metal_renderer_enabled && MetalDevice::HasDevice())
    g_settings.gpu_renderer = GPURenderer::HardwareMetal;

  retro_game_info game_info = {};
  game_info.path = path;

  if (!retro_load_game(&game_info))
    return false;

  s_game_loaded = true;

  retro_get_system_av_info(&s_av_info);
  s_have_av_info = true;

  // The core boots whatever pad the frontend asks for. A DualShock is the safe
  // default: it starts in digital mode, which every game understands, and the
  // sticks only matter to games that ask for them. The core only knows its
  // own device ids, so it has to be asked for by the subclass value
  // (RETRO_DEVICE_PS_DUALSHOCK). Plain RETRO_DEVICE_ANALOG is not one of them,
  // and the core plugs in no controller at all for it.
  const unsigned dualshock = RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 0);
  SetControllerPortDevice(0, dualshock);
  SetControllerPortDevice(1, dualshock);

  return true;
}

void UnloadGame()
{
  if (!s_initialized || !s_game_loaded)
    return;

  retro_unload_game();
  s_game_loaded = false;
  s_frame_pixels = nullptr;
  s_frame_width = s_frame_height = s_frame_pitch = 0;
}

void RunFrame()
{
  if (!s_game_loaded)
    return;

  retro_run();
}

void Reset()
{
  if (s_game_loaded)
    retro_reset();
}

std::size_t SerializeSize()
{
  return s_game_loaded ? retro_serialize_size() : 0;
}

bool Serialize(void* data, std::size_t size)
{
  return s_game_loaded && data && size > 0 && retro_serialize(data, size);
}

bool Deserialize(const void* data, std::size_t size)
{
  return s_game_loaded && data && size > 0 && retro_unserialize(data, size);
}

void SetControllerPortDevice(unsigned port, unsigned device)
{
  if (s_initialized)
    retro_set_controller_port_device(port, device);
}

double FrameRate()
{
  if (s_have_av_info && s_av_info.timing.fps > 0.0)
    return s_av_info.timing.fps;

  return 60.0;
}

double SampleRate()
{
  if (s_have_av_info && s_av_info.timing.sample_rate > 0.0)
    return s_av_info.timing.sample_rate;

  return 44100.0;
}

unsigned DisplayWidth()
{
  return s_have_av_info ? s_av_info.geometry.base_width : 0;
}

unsigned DisplayHeight()
{
  return s_have_av_info ? s_av_info.geometry.base_height : 0;
}

double AspectRatio()
{
  return s_have_av_info ? s_av_info.geometry.aspect_ratio : 0.0;
}

const void* LastFramePixels()
{
  return s_frame_pixels;
}

unsigned LastFrameWidth()
{
  return s_frame_width;
}

unsigned LastFrameHeight()
{
  return s_frame_height;
}

unsigned LastFramePitch()
{
  return s_frame_pitch;
}

void SetAudioCallback(AudioCallback callback, void* userdata)
{
  s_audio_callback = callback;
  s_audio_userdata = userdata;
}

void SetInputStateCallback(InputStateCallback callback, void* userdata)
{
  s_input_callback = callback;
  s_input_userdata = userdata;
}

} // namespace SwanStationBridge
