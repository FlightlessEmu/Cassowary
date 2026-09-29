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

// Boots a disc in the core, runs some frames, and writes the resulting frame
// out as a PPM.
//
// The point is to be able to run the same disc through the software renderer
// and the Metal one and compare the two pictures, without an app, a simulator
// or a UI in the way. Build and run it with
// `Scripts/cassowary/dump-psx-frame.py`.
//
// Usage:
//   psx-frame-dump --bios DIR --save DIR --game FILE --out FILE
//                  [--frames N] [--software]

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "SwanStationLibretroBridge.h"
#include "core/gpu.h"
#include "core/gpu_hw_metal.h"
#include "core/metal_device.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static bool WritePPM(const char* path, const uint8_t* rgb, uint32_t width, uint32_t height, uint32_t stride)
{
  FILE* file = std::fopen(path, "wb");
  if (!file)
    return false;

  std::fprintf(file, "P6\n%u %u\n255\n", width, height);
  for (uint32_t y = 0; y < height; y++)
    std::fwrite(rgb + (static_cast<size_t>(y) * stride), 1, static_cast<size_t>(width) * 3, file);

  std::fclose(file);
  return true;
}

static void AudioCallback(const int16_t*, size_t, void*) {}

// Scripted buttons for getting past the title and menu: entries of
// ID,START,END hold libretro joypad button ID down for frames
// [START, END). Frame counts drift between runs, so mash generously.
struct Press
{
  unsigned id;
  int start;
  int end;
};
static std::vector<Press> s_presses;
static int s_frame = 0;

static int16_t InputStateCallback(unsigned, unsigned, unsigned, unsigned id, void*)
{
  for (const Press& press : s_presses)
  {
    if (id == press.id && s_frame >= press.start && s_frame < press.end)
      return 1;
  }
  return 0;
}

// Reports vibration, so a game's rumble can be checked without a controller.
static void RumbleCallback(unsigned port, uint16_t strong, uint16_t weak, void*)
{
  std::printf("frame %d: port %u rumble strong %u weak %u\n", s_frame, port + 1, strong, weak);
}

int main(int argc, char** argv)
{
  @autoreleasepool
  {
    std::string bios_directory;
    std::string save_directory;
    std::string game_path;
    std::string output_path;
    std::string vram_path;
    int frames = 300;
    int series = 0;
    bool software = false;
    int state_at = -1;
    // Options set before the game loads, and options changed at a frame.
    std::vector<std::pair<std::string, std::string>> options;
    struct LateOption
    {
      int frame;
      std::string key;
      std::string value;
    };
    std::vector<LateOption> late_options;
    // Discs to swap to (0-based) at a frame.
    std::vector<std::pair<int, unsigned>> disc_swaps;
    auto split_option = [](const std::string& text, std::string* key, std::string* value) {
      const size_t equals = text.find('=');
      if (equals == std::string::npos)
        return false;
      *key = text.substr(0, equals);
      *value = text.substr(equals + 1);
      return true;
    };

    for (int i = 1; i < argc; i++)
    {
      const std::string argument = argv[i];
      auto value = [&]() -> std::string { return (i + 1 < argc) ? std::string(argv[++i]) : std::string(); };

      if (argument == "--bios")
        bios_directory = value();
      else if (argument == "--save")
        save_directory = value();
      else if (argument == "--game")
        game_path = value();
      else if (argument == "--out")
        output_path = value();
      else if (argument == "--vram")
        vram_path = value();
      else if (argument == "--frames")
        frames = std::atoi(value().c_str());
      else if (argument == "--series")
        series = std::atoi(value().c_str());
      else if (argument == "--software")
        software = true;
      else if (argument == "--state-at")
        state_at = std::atoi(value().c_str());
      else if (argument == "--option")
      {
        // KEY=VALUE, repeatable: a swanstation_ core option set before boot.
        std::string key, option_value;
        if (split_option(value(), &key, &option_value))
          options.emplace_back(key, option_value);
      }
      else if (argument == "--disc-at")
      {
        // FRAME DISC: swap to that disc (counted from 0) at that frame.
        const int frame = std::atoi(value().c_str());
        disc_swaps.emplace_back(frame, static_cast<unsigned>(std::atoi(value().c_str())));
      }
      else if (argument == "--option-at")
      {
        // FRAME KEY=VALUE: the same, changed while the game runs.
        LateOption late = {};
        late.frame = std::atoi(value().c_str());
        if (split_option(value(), &late.key, &late.value))
          late_options.push_back(late);
      }
      else if (argument == "--press")
      {
        // ID,START,END, repeatable.
        Press press = {};
        if (std::sscanf(value().c_str(), "%u,%d,%d", &press.id, &press.start, &press.end) == 3)
          s_presses.push_back(press);
      }
      else
      {
        std::fprintf(stderr, "unknown argument: %s\n", argument.c_str());
        return 2;
      }
    }

    if (game_path.empty() || output_path.empty())
    {
      std::fprintf(stderr,
                   "usage: psx-frame-dump --bios DIR --save DIR --game FILE --out FILE [--frames N] [--series N] "
                   "[--software]\n");
      return 2;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil)
    {
      std::fprintf(stderr, "no Metal device\n");
      return 1;
    }
    MetalDevice::SetDevice((__bridge void*)device);

    SwanStationBridge::SetMetalRendererEnabled(!software);
    SwanStationBridge::SetAudioCallback(AudioCallback, nullptr);
    SwanStationBridge::SetInputStateCallback(InputStateCallback, nullptr);
    SwanStationBridge::SetRumbleCallback(RumbleCallback, nullptr);
    SwanStationBridge::SetDirectories(bios_directory.c_str(), save_directory.c_str());
    for (const auto& [key, option_value] : options)
      SwanStationBridge::SetOption(key.c_str(), option_value.c_str());

    if (!SwanStationBridge::Initialize())
    {
      std::fprintf(stderr, "the core failed to start\n");
      return 1;
    }

    if (!SwanStationBridge::LoadGame(game_path.c_str()))
    {
      std::fprintf(stderr, "the core could not load %s\n", game_path.c_str());
      return 1;
    }

    // Dumps whatever the renderer has for the current frame.
    auto dump_frame = [&](const std::string& path) -> bool {
    // The hardware renderer publishes a texture; the software one leaves its
    // frame in the bridge.
    void* handle = SwanStationBridge::DisplayTextureHandle();
    if (handle != nullptr)
    {
      id<MTLTexture> texture = (__bridge id<MTLTexture>)handle;
      const uint32_t width = static_cast<uint32_t>(texture.width);
      const uint32_t height = static_cast<uint32_t>(texture.height);

      std::vector<uint8_t> rgba(static_cast<size_t>(width) * height * 4);
      [texture getBytes:rgba.data()
            bytesPerRow:static_cast<NSUInteger>(width) * 4
             fromRegion:MTLRegionMake2D(0, 0, width, height)
            mipmapLevel:0];

      std::vector<uint8_t> rgb(static_cast<size_t>(width) * height * 3);
      for (size_t i = 0, count = static_cast<size_t>(width) * height; i < count; i++)
      {
        rgb[(i * 3) + 0] = rgba[(i * 4) + 0];
        rgb[(i * 3) + 1] = rgba[(i * 4) + 1];
        rgb[(i * 3) + 2] = rgba[(i * 4) + 2];
      }

      if (!WritePPM(path.c_str(), rgb.data(), width, height, width * 3))
        return false;

      std::printf("wrote %s: %ux%u, published texture\n", path.c_str(), width, height);
    }
    else
    {
      const void* pixels = SwanStationBridge::LastFramePixels();
      const uint32_t width = SwanStationBridge::LastFrameWidth();
      const uint32_t height = SwanStationBridge::LastFrameHeight();
      const uint32_t pitch = SwanStationBridge::LastFramePitch();
      if (pixels == nullptr || width == 0 || height == 0)
      {
        std::fprintf(stderr, "the core produced no frame\n");
        return 1;
      }

      // RGB565, the format the bridge pins the core to.
      std::vector<uint8_t> rgb(static_cast<size_t>(width) * height * 3);
      for (uint32_t y = 0; y < height; y++)
      {
        const uint16_t* row = reinterpret_cast<const uint16_t*>(static_cast<const uint8_t*>(pixels) +
                                                                (static_cast<size_t>(y) * pitch));
        for (uint32_t x = 0; x < width; x++)
        {
          const uint16_t pixel = row[x];
          const size_t offset = (static_cast<size_t>(y) * width + x) * 3;
          rgb[offset + 0] = static_cast<uint8_t>(((pixel >> 11) & 0x1F) * 255 / 31);
          rgb[offset + 1] = static_cast<uint8_t>(((pixel >> 5) & 0x3F) * 255 / 63);
          rgb[offset + 2] = static_cast<uint8_t>((pixel & 0x1F) * 255 / 31);
        }
      }

      if (!WritePPM(path.c_str(), rgb.data(), width, height, width * 3))
        return false;

      std::printf("wrote %s: %ux%u, core frame\n", path.c_str(), width, height);
    }

      return true;
    };

    // --state-at N saves a state at frame N, keeps running to the end, then
    // loads it back and runs three frames, so the dump shows frame N + 3 as
    // the save state restored it. Three, not one: a state holds VRAM at 1x,
    // and a double-buffered game shows the restored buffer for a frame or two
    // before its next one, drawn at the internal resolution, reaches the
    // screen.
    std::printf("discs: %u\n", SwanStationBridge::DiscCount());

    std::vector<uint8_t> state;
    const auto run_start = std::chrono::steady_clock::now();
    for (int i = 0; i < frames; i++)
    {
      for (const LateOption& late : late_options)
      {
        if (late.frame == i)
          SwanStationBridge::SetOption(late.key.c_str(), late.value.c_str());
      }
      for (const auto& [frame, disc] : disc_swaps)
      {
        if (frame == i)
        {
          const bool swapped = SwanStationBridge::SetDisc(disc);
          std::printf("frame %d: swap to disc %u %s\n", i, disc + 1, swapped ? "started" : "refused");
        }
      }

      if (i == state_at)
      {
        state.resize(SwanStationBridge::SerializeSize());
        if (!SwanStationBridge::Serialize(state.data(), state.size()))
        {
          std::fprintf(stderr, "saving a state failed\n");
          return 1;
        }
      }

      SwanStationBridge::RunFrame();
      s_frame++;
    }

    if (frames > 0)
    {
      const double seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - run_start).count();
      std::printf("ran %d frames in %.1f s: %.2f ms a frame; disc %u of %u in the drive\n", frames, seconds,
                  seconds * 1000.0 / frames, SwanStationBridge::CurrentDisc() + 1, SwanStationBridge::DiscCount());
    }

    if (!state.empty())
    {
      if (!SwanStationBridge::Deserialize(state.data(), state.size()))
      {
        std::fprintf(stderr, "loading the state failed\n");
        return 1;
      }

      for (int i = 0; i < 3; i++)
        SwanStationBridge::RunFrame();
      s_frame = state_at + 3;
    }

    if (!vram_path.empty())
    {
      auto* metal_renderer = dynamic_cast<GPU_HW_Metal*>(g_gpu.get());
      if (metal_renderer != nullptr && metal_renderer->DebugWriteVRAM(vram_path.c_str()))
        std::printf("wrote %s (VRAM)\n", vram_path.c_str());
      else
        std::printf("no VRAM to dump\n");
    }

    if (series > 0)
    {
      // A run of consecutive frames, so two runs that are not in step can be
      // lined up by matching their contents.
      for (int i = 0; i < series; i++)
      {
        SwanStationBridge::RunFrame();
        s_frame++;

        char path[1024];
        std::snprintf(path, sizeof(path), "%s-%04d.ppm", output_path.c_str(), i);
        if (!dump_frame(path))
          return 1;
      }
    }
    else if (!dump_frame(output_path))
    {
      return 1;
    }
  }

  return 0;
}
