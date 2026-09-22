// SPDX-FileCopyrightText: 2026 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

#include "common/metal/shader_cache.h"
#include "common/metal/stream_buffer.h"
#include "common/metal/texture.h"
#include "core/host_display.h"
#include "gpu_hw.h"
#include <array>
#include <memory>
#include <string>
#include <unordered_map>

class GPU_HW_ShaderGen;

/// The display for the app's own renderer.
///
/// There is no libretro hardware context behind this one: the app hands the
/// core its Metal device, the core renders into its own textures, and the app
/// draws the texture the core publishes. Everything here that a frontend would
/// normally own - the device, the swap chain, the final composite - belongs to
/// the app, so most of this class is about satisfying the interface and
/// remembering the current frame's texture.
class LibretroMetalHostDisplay final : public HostDisplay
{
public:
  LibretroMetalHostDisplay();
  ~LibretroMetalHostDisplay() override;

  RenderAPI GetRenderAPI() const override;
  void* GetRenderDevice() const override;
  void* GetRenderContext() const override;

  bool CreateRenderDevice(const WindowInfo& wi, std::string_view adapter_name, bool debug_device,
                          bool threaded_presentation) override;
  bool InitializeRenderDevice(std::string_view shader_cache_directory, bool debug_device,
                              bool threaded_presentation) override;
  void DestroyRenderDevice() override;
  bool ChangeRenderWindow(const WindowInfo& new_wi) override;
  bool CreateResources() override;
  void DestroyResources() override;
  void ResizeRenderWindow(int32_t new_window_width, int32_t new_window_height) override;

  std::unique_ptr<HostDisplayTexture> CreateTexture(uint32_t width, uint32_t height, uint32_t layers, uint32_t levels,
                                                    uint32_t samples, HostDisplayPixelFormat format, const void* data,
                                                    uint32_t data_stride, bool dynamic = false) override;
  bool Render() override;
  bool SupportsDisplayPixelFormat(HostDisplayPixelFormat format) const override;
  bool BeginSetDisplayPixels(HostDisplayPixelFormat format, uint32_t width, uint32_t height, void** out_buffer,
                             uint32_t* out_pitch) override;
  void EndSetDisplayPixels() override;
  bool SetDisplayPixels(HostDisplayPixelFormat format, uint32_t width, uint32_t height, const void* buffer,
                        uint32_t pitch) override;

  ALWAYS_INLINE id<MTLDevice> GetDevice() const { return m_device; }
  ALWAYS_INLINE id<MTLCommandQueue> GetCommandQueue() const { return m_queue; }

private:
  id<MTLDevice> m_device = nil;
  id<MTLCommandQueue> m_queue = nil;

  // The upload path the software renderer falls back to: a CPU buffer that is
  // pushed into a texture when the frame is finished.
  Metal::Texture m_display_pixels_texture;
  std::vector<uint8_t> m_display_pixels_buffer;
  std::vector<uint8_t> m_display_pixels_wide_buffer;
  HostDisplayPixelFormat m_display_pixels_format = HostDisplayPixelFormat::Unknown;
  uint32_t m_display_pixels_width = 0;
  uint32_t m_display_pixels_height = 0;

  /// The published texture is always RGBA8, because that is what the app is
  /// told to expect. The software renderer hands over RGB565, so widen it.
  void UploadDisplayPixels(const void* buffer, uint32_t pitch);
};

/// The PlayStation GPU, rendered with Metal.
///
/// This is the hardware renderer the other back ends are: it batches primitives
/// and runs the same shaders. It differs in how it reaches the screen. There is
/// no swap chain to present to, so each frame it draws the display area into a
/// texture and publishes that for the app to draw.
class GPU_HW_Metal final : public GPU_HW
{
public:
  GPU_HW_Metal();
  ~GPU_HW_Metal() override;

  bool Initialize(HostDisplay* host_display) override;
  void Reset(bool clear_vram) override;
  bool DoState(StateWrapper& sw, HostDisplayTexture** host_texture, bool update_display) override;

  void ResetGraphicsAPIState() override;
  void RestoreGraphicsAPIState() override;
  void UpdateSettings() override;

  /// Which texture the current render pass draws into.
  enum class RenderTarget : uint8_t
  {
    None,
    VRAM,
    VRAMRead,
    VRAMEncoding,
    Display,
    Downsample
  };

  /// Which shader a pipeline uses. The batch fragment shader varies with the
  /// batch state, so those values carry that state rather than naming a shader.
  enum : uint32_t
  {
    VS_BATCH_TEXTURED = 0,
    VS_BATCH_UNTEXTURED = 1,
    VS_SCREEN_QUAD = 2,

    FS_VRAM_READ = 1,
    FS_VRAM_WRITE = 2,
    FS_VRAM_COPY = 3,
    FS_VRAM_FILL = 4, // 4 + (wrapped << 1) | interlaced
    FS_VRAM_UPDATE_DEPTH = 8,
    FS_DOWNSAMPLE = 9,

    FS_BATCH = 1000,   // 1000 + (render_mode << 6) | (texture_mode << 4) | (dithering << 1) | interlacing
    FS_DISPLAY = 2000, // 2000 + (depth_24bit << 1) | interlaced
  };

  /// What a pipeline is built with. Metal bakes blend and depth state into the
  /// pipeline, so they are part of the identity rather than encoder state.
  struct PipelineKey
  {
    uint32_t vertex_source = VS_SCREEN_QUAD;
    uint32_t fragment_source = FS_VRAM_READ;
    uint32_t blend = 0; // 0 = off, 1 = alpha, 2 = reverse subtract
    uint32_t depth = 0; // 0 = no depth attachment, 1 = always, 2 = less-equal, 3 = greater-equal

    bool operator==(const PipelineKey& rhs) const
    {
      return vertex_source == rhs.vertex_source && fragment_source == rhs.fragment_source && blend == rhs.blend &&
             depth == rhs.depth;
    }
  };

protected:
  void ClearDisplay() override;
  void UpdateDisplay() override;
  void ReadVRAM(uint32_t x, uint32_t y, uint32_t width, uint32_t height) override;
  void FillVRAM(uint32_t x, uint32_t y, uint32_t width, uint32_t height, uint32_t color) override;
  void UpdateVRAM(uint32_t x, uint32_t y, uint32_t width, uint32_t height, const void* data, bool set_mask,
                  bool check_mask) override;
  void CopyVRAM(uint32_t src_x, uint32_t src_y, uint32_t dst_x, uint32_t dst_y, uint32_t width, uint32_t height) override;
  void UpdateVRAMReadTexture() override;
  void UpdateDepthBufferFromMaskBit() override;
  void ClearDepthBuffer() override;
  void SetScissorFromDrawingArea() override;
  void MapBatchVertexPointer(uint32_t required_vertices) override;
  void UnmapBatchVertexPointer(uint32_t used_vertices) override;
  void UploadUniformBuffer(const void* data, uint32_t data_size) override;
  void DrawBatchVertices(BatchRenderMode render_mode, uint32_t base_vertex, uint32_t num_vertices) override;

private:
  void SetCapabilities();
  bool CreateTextures();
  bool CreateBuffers();
  bool CreateSamplers();
  bool CreateShaderGen();
  void DestroyResources();

  void BeginFrame();
  void EndFrame();

  /// Makes sure a render pass into `target` is open, ending whatever pass was
  /// open before. `clear` clears the target when the pass starts.
  id<MTLRenderCommandEncoder> EnsureRenderPass(RenderTarget target, bool clear = false);
  void EndRenderPass();
  /// Flushes the command buffer and waits for it, so the CPU can read a texture.
  void FlushAndWait();

  id<MTLRenderPipelineState> GetOrCreatePipeline(const PipelineKey& key);
  id<MTLRenderPipelineState> CreatePipeline(const PipelineKey& key);
  const std::string& GetVertexSource(uint32_t kind);
  const std::string& GetFragmentSource(uint32_t kind);

  void DownsampleFramebufferBoxFilter(Metal::Texture& source, uint32_t left, uint32_t top, uint32_t width,
                                      uint32_t height);
  void UploadUniforms(const void* data, uint32_t size);

  Metal::Texture m_vram_texture;
  Metal::Texture m_vram_depth_texture;
  Metal::Texture m_vram_read_texture;
  Metal::Texture m_vram_encoding_texture;
  Metal::Texture m_display_texture;
  Metal::Texture m_downsample_texture;

  std::unique_ptr<Metal::StreamBuffer> m_vertex_stream_buffer;
  std::unique_ptr<Metal::StreamBuffer> m_uniform_stream_buffer;
  std::unique_ptr<Metal::StreamBuffer> m_texture_stream_buffer;

  Metal::ShaderCache m_shader_cache;
  std::unique_ptr<GPU_HW_ShaderGen> m_shadergen;

  id<MTLSamplerState> m_nearest_sampler = nil;
  id<MTLSamplerState> m_linear_sampler = nil;

  id<MTLCommandQueue> m_queue = nil;
  id<MTLCommandBuffer> m_command_buffer = nil;
  id<MTLRenderCommandEncoder> m_encoder = nil;
  RenderTarget m_encoder_target = RenderTarget::None;

  std::unordered_map<uint64_t, id<MTLRenderPipelineState>> m_pipelines;
  std::unordered_map<uint32_t, std::string> m_batch_fragment_sources;
  std::string m_batch_vertex_sources[2];
  std::array<std::string, 2> m_display_fragment_sources;
  std::string m_vram_read_source;
  std::string m_vram_write_source;
  std::string m_vram_copy_source;
  std::string m_vram_fill_sources[2][2]; // [wrapped][interlaced]
  std::string m_vram_update_depth_source;
  std::string m_screen_quad_source;
  std::string m_downsample_source;

  uint32_t m_uniform_buffer_offset = 0;
  uint32_t m_texture_buffer_offset = 0;
  uint32_t m_display_texture_width = 0;
  uint32_t m_display_texture_height = 0;

  uint32_t m_current_scissor[4] = {0, 0, 0, 0};
  bool m_has_scissor = false;
  bool m_warned_about_replacements = false;
};

#endif // __OBJC__
