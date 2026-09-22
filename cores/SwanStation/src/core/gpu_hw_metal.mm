// SPDX-FileCopyrightText: 2026 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later
#include "gpu_hw_metal.h"

#ifdef __OBJC__

#include "common/align.h"
#include "common/log.h"
#include "common/state_wrapper.h"
#include "gpu_hw_shadergen.h"
#include "host_display.h"
#include "host_interface.h"
#include "metal_device.h"
#include "system.h"
#include "texture_replacements.h"
#include <cstring>

Log_SetChannel(GPU_HW_Metal);

/// The app's Metal device, parked here so the host display - which is built by
/// the host interface, not by the app - can find it.
static id<MTLDevice> s_metal_device = nil;

namespace MetalDevice {
void SetDevice(void* device)
{
  s_metal_device = (__bridge id<MTLDevice>)device;
}

void* GetDevice()
{
  return (__bridge void*)s_metal_device;
}

bool HasDevice()
{
  return (s_metal_device != nil);
}

std::unique_ptr<HostDisplay> CreateHostDisplay()
{
  return std::make_unique<LibretroMetalHostDisplay>();
}
} // namespace MetalDevice

// ---------------------------------------------------------------------------
// The display
// ---------------------------------------------------------------------------

class LibretroMetalHostDisplayTexture final : public HostDisplayTexture
{
public:
  LibretroMetalHostDisplayTexture(Metal::Texture texture, void* handle)
    : m_texture(std::move(texture)), m_handle(handle)
  {
  }
  ~LibretroMetalHostDisplayTexture() override = default;

  void* GetHandle() const override { return m_handle; }
  uint32_t GetWidth() const override { return m_texture.GetWidth(); }
  uint32_t GetHeight() const override { return m_texture.GetHeight(); }
  uint32_t GetSamples() const override { return m_texture.GetSamples(); }

private:
  Metal::Texture m_texture;
  void* m_handle;
};

LibretroMetalHostDisplay::LibretroMetalHostDisplay() = default;

LibretroMetalHostDisplay::~LibretroMetalHostDisplay()
{
  DestroyRenderDevice();
}

HostDisplay::RenderAPI LibretroMetalHostDisplay::GetRenderAPI() const
{
  return HostDisplay::RenderAPI::Metal;
}

void* LibretroMetalHostDisplay::GetRenderDevice() const
{
  return (__bridge void*)m_device;
}

void* LibretroMetalHostDisplay::GetRenderContext() const
{
  return nullptr;
}

bool LibretroMetalHostDisplay::CreateRenderDevice(const WindowInfo& wi, std::string_view adapter_name, bool debug_device,
                                                  bool threaded_presentation)
{
  // There is no context to request and no window to attach to: the app owns
  // both, and hands over its device before the emulation thread starts.
  m_device = s_metal_device;
  if (m_device == nil)
  {
    Log_ErrorPrintf("No Metal device has been given to the core.");
    return false;
  }

  m_window_info = wi;
  return true;
}

bool LibretroMetalHostDisplay::InitializeRenderDevice(std::string_view shader_cache_directory, bool debug_device,
                                                      bool threaded_presentation)
{
  if (m_device == nil)
    return false;

  if (m_queue == nil)
    m_queue = [m_device newCommandQueue];

  return (m_queue != nil);
}

void LibretroMetalHostDisplay::DestroyRenderDevice()
{
  m_queue = nil;
  m_device = nil;
  m_display_pixels_texture.Destroy();
  m_display_pixels_buffer.clear();
  m_display_pixels_width = 0;
  m_display_pixels_height = 0;
}

bool LibretroMetalHostDisplay::ChangeRenderWindow(const WindowInfo& new_wi)
{
  m_window_info = new_wi;
  return true;
}

bool LibretroMetalHostDisplay::CreateResources()
{
  return true;
}

void LibretroMetalHostDisplay::DestroyResources()
{
}

void LibretroMetalHostDisplay::ResizeRenderWindow(int32_t new_window_width, int32_t new_window_height)
{
  m_window_info.surface_width = static_cast<uint32_t>(new_window_width);
  m_window_info.surface_height = static_cast<uint32_t>(new_window_height);
}

std::unique_ptr<HostDisplayTexture> LibretroMetalHostDisplay::CreateTexture(uint32_t width, uint32_t height, uint32_t layers,
                                                                            uint32_t levels, uint32_t samples,
                                                                            HostDisplayPixelFormat format, const void* data,
                                                                            uint32_t data_stride, bool dynamic)
{
  if (layers != 1 || levels != 1 || format != HostDisplayPixelFormat::RGBA8)
    return {};

  Metal::Texture texture;
  if (!texture.Create(m_device, width, height, samples, MTLPixelFormatRGBA8Unorm, false, data))
    return {};

  void* handle = texture.GetHandle();
  return std::make_unique<LibretroMetalHostDisplayTexture>(std::move(texture), handle);
}

bool LibretroMetalHostDisplay::SupportsDisplayPixelFormat(HostDisplayPixelFormat format) const
{
  // RGB565 is what the software renderer hands over; it is widened on upload.
  return (format == HostDisplayPixelFormat::RGBA8 || format == HostDisplayPixelFormat::BGRA8 ||
          format == HostDisplayPixelFormat::RGB565);
}

bool LibretroMetalHostDisplay::BeginSetDisplayPixels(HostDisplayPixelFormat format, uint32_t width, uint32_t height,
                                                     void** out_buffer, uint32_t* out_pitch)
{
  const uint32_t pixel_size = GetDisplayPixelFormatSize(format);
  const uint32_t stride = Common::AlignUpPow2(width * pixel_size, 4);

  if (!m_display_pixels_texture.IsValid() || m_display_pixels_width != width || m_display_pixels_height != height)
  {
    m_display_pixels_texture.Destroy();
    if (!m_display_pixels_texture.Create(m_device, width, height, 1, MTLPixelFormatRGBA8Unorm, false))
      return false;

    m_display_pixels_width = width;
    m_display_pixels_height = height;
  }

  m_display_pixels_format = format;
  m_display_pixels_buffer.resize(stride * height);
  *out_buffer = m_display_pixels_buffer.data();
  *out_pitch = stride;

  SetDisplayTexture(m_display_pixels_texture.GetHandle(), HostDisplayPixelFormat::RGBA8, width, height, 0, 0, width,
                    height);
  return true;
}

void LibretroMetalHostDisplay::UploadDisplayPixels(const void* buffer, uint32_t pitch)
{
  if (!m_display_pixels_texture.IsValid() || buffer == nullptr)
    return;

  if (m_display_pixels_format == HostDisplayPixelFormat::RGB565)
  {
    const uint32_t width = m_display_pixels_width;
    const uint32_t height = m_display_pixels_height;
    m_display_pixels_wide_buffer.resize(width * height * 4);

    const uint8_t* source = static_cast<const uint8_t*>(buffer);
    uint8_t* destination = m_display_pixels_wide_buffer.data();
    for (uint32_t y = 0; y < height; y++)
    {
      const uint16_t* source_row = reinterpret_cast<const uint16_t*>(source + (y * pitch));
      uint8_t* destination_row = destination + (y * width * 4);
      for (uint32_t x = 0; x < width; x++)
      {
        const uint16_t pixel = source_row[x];
        const uint8_t r = static_cast<uint8_t>(((pixel >> 11) & 0x1F) * 255 / 31);
        const uint8_t g = static_cast<uint8_t>(((pixel >> 5) & 0x3F) * 255 / 63);
        const uint8_t b = static_cast<uint8_t>((pixel & 0x1F) * 255 / 31);
        destination_row[x * 4 + 0] = r;
        destination_row[x * 4 + 1] = g;
        destination_row[x * 4 + 2] = b;
        destination_row[x * 4 + 3] = 255;
      }
    }

    m_display_pixels_texture.Replace(m_display_pixels_wide_buffer.data());
    return;
  }

  m_display_pixels_texture.Replace(buffer);
}

void LibretroMetalHostDisplay::EndSetDisplayPixels()
{
  if (m_display_pixels_buffer.empty())
    return;

  UploadDisplayPixels(m_display_pixels_buffer.data(), m_display_pixels_width * GetDisplayPixelFormatSize(m_display_pixels_format));
}

bool LibretroMetalHostDisplay::SetDisplayPixels(HostDisplayPixelFormat format, uint32_t width, uint32_t height,
                                                const void* buffer, uint32_t pitch)
{
  if (!m_display_pixels_texture.IsValid() || m_display_pixels_width != width || m_display_pixels_height != height)
  {
    m_display_pixels_texture.Destroy();
    if (!m_display_pixels_texture.Create(m_device, width, height, 1, MTLPixelFormatRGBA8Unorm, false))
      return false;

    m_display_pixels_width = width;
    m_display_pixels_height = height;
  }

  m_display_pixels_format = format;
  UploadDisplayPixels(buffer, pitch);
  SetDisplayTexture(m_display_pixels_texture.GetHandle(), HostDisplayPixelFormat::RGBA8, width, height, 0, 0, width,
                    height);
  return true;
}

bool LibretroMetalHostDisplay::Render()
{
  // The app draws the published texture; there is nothing to do here.
  return true;
}

// ---------------------------------------------------------------------------
// The renderer
// ---------------------------------------------------------------------------

GPU_HW_Metal::GPU_HW_Metal() : GPU_HW() {}

GPU_HW_Metal::~GPU_HW_Metal()
{
  DestroyResources();
}

void GPU_HW_Metal::DestroyResources()
{
  EndRenderPass();
  m_command_buffer = nil;
  m_queue = nil;
  m_shader_cache.Clear();
  m_pipelines.clear();
  m_batch_fragment_sources.clear();
  m_batch_vertex_sources[0].clear();
  m_batch_vertex_sources[1].clear();
  m_nearest_sampler = nil;
  m_linear_sampler = nil;
  m_vram_texture.Destroy();
  m_vram_depth_texture.Destroy();
  m_vram_read_texture.Destroy();
  m_vram_encoding_texture.Destroy();
  m_display_texture.Destroy();
  m_downsample_texture.Destroy();
  m_vertex_stream_buffer.reset();
  m_uniform_stream_buffer.reset();
  m_texture_stream_buffer.reset();
  m_shadergen.reset();
}

bool GPU_HW_Metal::Initialize(HostDisplay* host_display)
{
  SetCapabilities();

  if (!GPU_HW::Initialize(host_display))
    return false;

  if (s_metal_device == nil)
  {
    Log_ErrorPrintf("No Metal device has been given to the core.");
    return false;
  }

  m_queue = [s_metal_device newCommandQueue];
  if (m_queue == nil)
  {
    Log_ErrorPrintf("Failed to create a command queue.");
    return false;
  }

  if (!CreateTextures() || !CreateBuffers() || !CreateSamplers() || !CreateShaderGen())
    return false;

  ResetGraphicsAPIState();
  return true;
}

void GPU_HW_Metal::SetCapabilities()
{
  // No multisampling yet: it needs multisampled render targets and a resolve
  // pass, and none of this has been run against a game to know it is right.
  m_max_multisamples = 1;
  m_supports_per_sample_shading = false;

  // Apple GPUs have plenty of texture size; the cap matches the other back ends.
  m_max_resolution_scale = 8;

  // Dual-source blending is what the transparency modes want, and Metal has it.
  m_supports_dual_source_blend = true;

  // Adaptive downsampling needs mip chains and extra passes. Box filter only.
  m_supports_adaptive_downsampling = false;

  // MSL has noperspective interpolation.
  m_supports_disable_color_perspective = true;
}

bool GPU_HW_Metal::CreateTextures()
{
  const uint32_t texture_width = VRAM_WIDTH * m_resolution_scale;
  const uint32_t texture_height = VRAM_HEIGHT * m_resolution_scale;

  if (!m_vram_texture.Create(s_metal_device, texture_width, texture_height, 1, MTLPixelFormatRGBA8Unorm, true) ||
      !m_vram_depth_texture.Create(s_metal_device, texture_width, texture_height, 1, MTLPixelFormatDepth32Float, true) ||
      !m_vram_read_texture.Create(s_metal_device, texture_width, texture_height, 1, MTLPixelFormatRGBA8Unorm, true) ||
      !m_vram_encoding_texture.Create(s_metal_device, VRAM_WIDTH, VRAM_HEIGHT, 1, MTLPixelFormatRGBA8Unorm, true))
  {
    Log_ErrorPrintf("Failed to create the VRAM textures.");
    return false;
  }

  if (m_downsample_mode == GPUDownsampleMode::Box)
  {
    if (!m_downsample_texture.Create(s_metal_device, VRAM_WIDTH, VRAM_HEIGHT, 1, MTLPixelFormatRGBA8Unorm, true))
      return false;
  }

  SetFullVRAMDirtyRectangle();
  return true;
}

bool GPU_HW_Metal::CreateBuffers()
{
  m_vertex_stream_buffer = Metal::StreamBuffer::Create(s_metal_device, VERTEX_BUFFER_SIZE);
  m_uniform_stream_buffer = Metal::StreamBuffer::Create(s_metal_device, UNIFORM_BUFFER_SIZE);
  m_texture_stream_buffer = Metal::StreamBuffer::Create(s_metal_device, VRAM_UPDATE_TEXTURE_BUFFER_SIZE);
  if (!m_vertex_stream_buffer || !m_uniform_stream_buffer || !m_texture_stream_buffer)
  {
    Log_ErrorPrintf("Failed to create the stream buffers.");
    return false;
  }

  return true;
}

bool GPU_HW_Metal::CreateSamplers()
{
  @autoreleasepool
  {
    MTLSamplerDescriptor* desc = [[MTLSamplerDescriptor alloc] init];
    desc.minFilter = MTLSamplerMinMagFilterNearest;
    desc.magFilter = MTLSamplerMinMagFilterNearest;
    desc.mipFilter = MTLSamplerMipFilterNotMipmapped;
    desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    m_nearest_sampler = [s_metal_device newSamplerStateWithDescriptor:desc];

    desc.minFilter = MTLSamplerMinMagFilterLinear;
    desc.magFilter = MTLSamplerMinMagFilterLinear;
    m_linear_sampler = [s_metal_device newSamplerStateWithDescriptor:desc];

    if (m_nearest_sampler == nil || m_linear_sampler == nil)
    {
      Log_ErrorPrintf("Failed to create the samplers.");
      return false;
    }
  }

  return true;
}

bool GPU_HW_Metal::CreateShaderGen()
{
  m_shadergen = std::make_unique<GPU_HW_ShaderGen>(HostDisplay::RenderAPI::Metal, m_resolution_scale, m_multisamples,
                                                   m_per_sample_shading, m_true_color, m_scaled_dithering,
                                                   m_texture_filtering, m_using_uv_limits, m_pgxp_depth_buffer,
                                                   m_disable_color_perspective, m_supports_dual_source_blend);
  m_batch_fragment_sources.clear();
  return true;
}

void GPU_HW_Metal::Reset(bool clear_vram)
{
  GPU_HW::Reset(clear_vram);

  EndRenderPass();

  if (clear_vram)
  {
    // Everything is in shared memory, so a CPU fill is the simplest way to get
    // a known-clear VRAM and depth buffer.
    std::vector<uint8_t> zero(VRAM_WIDTH * VRAM_HEIGHT * 4, 0);
    m_vram_texture.Replace(zero.data());
    m_vram_read_texture.Replace(zero.data());

    std::vector<float> depth(VRAM_WIDTH * VRAM_HEIGHT, 0.0f);
    m_vram_depth_texture.Replace(depth.data());
  }
}

bool GPU_HW_Metal::DoState(StateWrapper& sw, HostDisplayTexture** host_texture, bool update_display)
{
  // The base class serialises the shadow copy of VRAM, so bring the texture in
  // step with it on the way in and out.
  if (sw.IsWriting())
    ReadVRAM(0, 0, VRAM_WIDTH, VRAM_HEIGHT);

  if (!GPU_HW::DoState(sw, host_texture, update_display))
    return false;

  if (sw.IsReading())
  {
    UpdateVRAM(0, 0, VRAM_WIDTH, VRAM_HEIGHT, m_vram_shadow.data(), false, false);
    UpdateVRAMReadTexture();
  }

  return true;
}

void GPU_HW_Metal::ResetGraphicsAPIState()
{
  m_has_scissor = false;
  m_current_scissor[0] = 0;
  m_current_scissor[1] = 0;
  m_current_scissor[2] = m_vram_texture.GetWidth();
  m_current_scissor[3] = m_vram_texture.GetHeight();
}

void GPU_HW_Metal::RestoreGraphicsAPIState()
{
  ResetGraphicsAPIState();
}

void GPU_HW_Metal::UpdateSettings()
{
  GPU_HW::UpdateSettings();

  bool framebuffer_changed = false;
  bool shaders_changed = false;
  UpdateHWSettings(&framebuffer_changed, &shaders_changed);
  if (framebuffer_changed)
  {
    EndRenderPass();
    if (!CreateTextures())
      Log_ErrorPrintf("Failed to recreate textures after a settings change.");
  }

  if (shaders_changed)
  {
    EndRenderPass();
    m_pipelines.clear();
    m_shader_cache.Clear();
    CreateShaderGen();
  }
}

// --- frames ----------------------------------------------------------------

void GPU_HW_Metal::BeginFrame()
{
  if (m_command_buffer == nil)
    m_command_buffer = [m_queue commandBuffer];

  m_vertex_stream_buffer->Reset();
  m_uniform_stream_buffer->Reset();
  m_texture_stream_buffer->Reset();
}

void GPU_HW_Metal::EndFrame()
{
  EndRenderPass();

  if (m_command_buffer != nil)
  {
    [m_command_buffer commit];
    // The app samples these textures from its own command queue, so the work
    // has to be done before the frame is handed over. One wait per frame.
    [m_command_buffer waitUntilCompleted];
    m_command_buffer = nil;
  }
}

void GPU_HW_Metal::FlushAndWait()
{
  EndFrame();
}

void GPU_HW_Metal::EndRenderPass()
{
  if (m_encoder != nil)
  {
    [m_encoder endEncoding];
    m_encoder = nil;
  }

  m_encoder_target = RenderTarget::None;
}

id<MTLRenderCommandEncoder> GPU_HW_Metal::EnsureRenderPass(RenderTarget target, bool clear)
{
  if (m_encoder != nil && m_encoder_target == target && !clear)
    return m_encoder;

  BeginFrame();
  EndRenderPass();

  Metal::Texture* color_texture = nullptr;
  Metal::Texture* depth_texture = nullptr;

  switch (target)
  {
    case RenderTarget::VRAM:
      color_texture = &m_vram_texture;
      depth_texture = &m_vram_depth_texture;
      break;
    case RenderTarget::VRAMRead:
      color_texture = &m_vram_read_texture;
      break;
    case RenderTarget::VRAMEncoding:
      color_texture = &m_vram_encoding_texture;
      break;
    case RenderTarget::Display:
      color_texture = &m_display_texture;
      break;
    case RenderTarget::Downsample:
      color_texture = &m_downsample_texture;
      break;
    default:
      return nil;
  }

  if (color_texture == nullptr || !color_texture->IsValid())
    return nil;

  @autoreleasepool
  {
    MTLRenderPassDescriptor* desc = [[MTLRenderPassDescriptor alloc] init];
    desc.colorAttachments[0].texture = color_texture->GetTexture();
    desc.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

    if (depth_texture != nullptr && depth_texture->IsValid())
    {
      desc.depthAttachment.texture = depth_texture->GetTexture();
      desc.depthAttachment.loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
      desc.depthAttachment.storeAction = MTLStoreActionStore;
      desc.depthAttachment.clearDepth = m_pgxp_depth_buffer ? 1.0 : 0.0;
    }

    m_encoder = [m_command_buffer renderCommandEncoderWithDescriptor:desc];
    m_encoder_target = target;
  }

  if (m_encoder == nil)
    return nil;

  // Metal starts with no viewport and no scissor, so set both whenever a pass
  // opens; the drawing code overrides them as needed.
  const uint32_t width = color_texture->GetWidth();
  const uint32_t height = color_texture->GetHeight();
  [m_encoder setViewport:MTLViewport{0.0, 0.0, static_cast<double>(width), static_cast<double>(height), 0.0, 1.0}];
  [m_encoder setScissorRect:MTLScissorRect{0, 0, width, height}];

  return m_encoder;
}

// --- pipelines -------------------------------------------------------------

static uint64_t HashPipelineKey(const GPU_HW_Metal::PipelineKey& key)
{
  uint64_t hash = key.vertex_source;
  hash = (hash * 31) + key.fragment_source;
  hash = (hash * 31) + key.blend;
  hash = (hash * 31) + key.depth;
  return hash;
}

id<MTLRenderPipelineState> GPU_HW_Metal::GetOrCreatePipeline(const PipelineKey& key)
{
  const uint64_t hash = HashPipelineKey(key);
  const auto it = m_pipelines.find(hash);
  if (it != m_pipelines.end())
    return it->second;

  id<MTLRenderPipelineState> pipeline = CreatePipeline(key);
  m_pipelines.emplace(hash, pipeline);
  return pipeline;
}

id<MTLRenderPipelineState> GPU_HW_Metal::CreatePipeline(const PipelineKey& key)
{
  const std::string& vertex_source = GetVertexSource(key.vertex_source);
  const std::string& fragment_source = GetFragmentSource(key.fragment_source);

  id<MTLFunction> vertex_function = m_shader_cache.GetFunction(s_metal_device, vertex_source, METAL_VERTEX_FUNCTION_NAME);
  id<MTLFunction> fragment_function =
    m_shader_cache.GetFunction(s_metal_device, fragment_source, METAL_FRAGMENT_FUNCTION_NAME);
  if (vertex_function == nil || fragment_function == nil)
    return nil;

  @autoreleasepool
  {
    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"SwanStation";
    desc.vertexFunction = vertex_function;
    desc.fragmentFunction = fragment_function;
    desc.rasterSampleCount = 1;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;

    // The batch vertex shader takes its vertices through the stage-in struct.
    if (key.vertex_source <= VS_BATCH_UNTEXTURED)
    {
      MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
      vd.attributes[0].format = MTLVertexFormatFloat4;
      vd.attributes[0].offset = offsetof(BatchVertex, x);
      vd.attributes[0].bufferIndex = 0;
      vd.attributes[1].format = MTLVertexFormatUChar4Normalized;
      vd.attributes[1].offset = offsetof(BatchVertex, color);
      vd.attributes[1].bufferIndex = 0;
      vd.attributes[2].format = MTLVertexFormatUInt;
      vd.attributes[2].offset = offsetof(BatchVertex, u);
      vd.attributes[2].bufferIndex = 0;
      vd.attributes[3].format = MTLVertexFormatUInt;
      vd.attributes[3].offset = offsetof(BatchVertex, texpage);
      vd.attributes[3].bufferIndex = 0;
      vd.attributes[4].format = MTLVertexFormatUChar4Normalized;
      vd.attributes[4].offset = offsetof(BatchVertex, uv_limits);
      vd.attributes[4].bufferIndex = 0;
      vd.layouts[0].stride = sizeof(BatchVertex);
      vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
      desc.vertexDescriptor = vd;
    }

    if (key.depth != 0)
      desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

    // blend: 0 = off, 1 = alpha blending, 2 = reverse subtract. The source
    // alpha comes from the shader's second output, which is what dual-source
    // blending is for.
    MTLRenderPipelineColorAttachmentDescriptor* color = desc.colorAttachments[0];
    if (key.blend != 0)
    {
      color.blendingEnabled = YES;
      color.rgbBlendOperation = (key.blend == 2) ? MTLBlendOperationReverseSubtract : MTLBlendOperationAdd;
      color.alphaBlendOperation = MTLBlendOperationAdd;
      color.sourceRGBBlendFactor = MTLBlendFactorOne;
      color.destinationRGBBlendFactor = MTLBlendFactorSource1Alpha;
      color.sourceAlphaBlendFactor = MTLBlendFactorOne;
      color.destinationAlphaBlendFactor = MTLBlendFactorZero;
    }

    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline = [s_metal_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (pipeline == nil)
    {
      Log_ErrorPrintf("Failed to create a pipeline: %s", error ? [[error localizedDescription] UTF8String] : "unknown");
      return nil;
    }

    return pipeline;
  }
}

// --- shader sources --------------------------------------------------------

const std::string& GPU_HW_Metal::GetVertexSource(uint32_t kind)
{
  switch (kind)
  {
    case VS_BATCH_TEXTURED:
    {
      std::string& source = m_batch_vertex_sources[1];
      if (source.empty())
        source = ShaderGen::FinalizeMetalShader(m_shadergen->GenerateBatchVertexShader(true));
      return source;
    }

    case VS_BATCH_UNTEXTURED:
    {
      std::string& source = m_batch_vertex_sources[0];
      if (source.empty())
        source = ShaderGen::FinalizeMetalShader(m_shadergen->GenerateBatchVertexShader(false));
      return source;
    }

    default:
      if (m_screen_quad_source.empty())
        m_screen_quad_source = ShaderGen::FinalizeMetalShader(m_shadergen->GenerateScreenQuadVertexShader());
      return m_screen_quad_source;
  }
}

const std::string& GPU_HW_Metal::GetFragmentSource(uint32_t kind)
{
  if (kind >= FS_DISPLAY)
  {
    const uint32_t variant = kind - FS_DISPLAY;
    const bool depth_24bit = (variant & 1u) != 0;
    const bool interlaced = (variant & 2u) != 0;
    std::string& source = m_display_fragment_sources[depth_24bit ? 1 : 0];
    if (source.empty())
    {
      source = ShaderGen::FinalizeMetalShader(m_shadergen->GenerateDisplayFragmentShader(
        depth_24bit, interlaced ? InterlacedRenderMode::InterleavedFields : InterlacedRenderMode::None,
        m_chroma_smoothing));
    }
    return source;
  }

  if (kind >= FS_BATCH)
  {
    const uint32_t variant = kind - FS_BATCH;
    const auto render_mode = static_cast<BatchRenderMode>((variant >> 6) & 3u);
    const auto texture_mode = static_cast<GPUTextureMode>((variant >> 4) & 3u);
    const bool dithering = (variant & 2u) != 0;
    const bool interlacing = (variant & 1u) != 0;

    const uint32_t key = (variant >> 4) | (variant & 3u);
    auto it = m_batch_fragment_sources.find(key);
    if (it == m_batch_fragment_sources.end())
    {
      std::string source = ShaderGen::FinalizeMetalShader(
        m_shadergen->GenerateBatchFragmentShader(render_mode, texture_mode, dithering, interlacing));
      it = m_batch_fragment_sources.emplace(key, std::move(source)).first;
    }
    return it->second;
  }

  switch (kind)
  {
    case FS_VRAM_READ:
      if (m_vram_read_source.empty())
        m_vram_read_source = ShaderGen::FinalizeMetalShader(m_shadergen->GenerateVRAMReadFragmentShader());
      return m_vram_read_source;

    case FS_VRAM_WRITE:
      if (m_vram_write_source.empty())
        m_vram_write_source = ShaderGen::FinalizeMetalShader(m_shadergen->GenerateVRAMWriteFragmentShader(false));
      return m_vram_write_source;

    case FS_VRAM_COPY:
      if (m_vram_copy_source.empty())
        m_vram_copy_source = ShaderGen::FinalizeMetalShader(m_shadergen->GenerateVRAMCopyFragmentShader());
      return m_vram_copy_source;

    case FS_VRAM_FILL:
    case FS_VRAM_FILL + 1:
    case FS_VRAM_FILL + 2:
    case FS_VRAM_FILL + 3:
    {
      const uint32_t variant = kind - FS_VRAM_FILL;
      const uint32_t wrapped = (variant & 2u) >> 1;
      const uint32_t interlaced = variant & 1u;
      std::string& source = m_vram_fill_sources[wrapped][interlaced];
      if (source.empty())
      {
        source = ShaderGen::FinalizeMetalShader(
          m_shadergen->GenerateVRAMFillFragmentShader(wrapped != 0, interlaced != 0));
      }
      return source;
    }

    case FS_VRAM_UPDATE_DEPTH:
      if (m_vram_update_depth_source.empty())
        m_vram_update_depth_source = ShaderGen::FinalizeMetalShader(m_shadergen->GenerateVRAMUpdateDepthFragmentShader());
      return m_vram_update_depth_source;

    case FS_DOWNSAMPLE:
      if (m_downsample_source.empty())
        m_downsample_source = ShaderGen::FinalizeMetalShader(m_shadergen->GenerateBoxSampleDownsampleFragmentShader());
      return m_downsample_source;

    default:
      return m_vram_read_source;
  }
}

// --- drawing helpers -------------------------------------------------------

void GPU_HW_Metal::UploadUniforms(const void* data, uint32_t size)
{
  const Metal::StreamBuffer::MappingResult res = m_uniform_stream_buffer->Map(256, size);
  std::memcpy(res.pointer, data, size);
  m_uniform_stream_buffer->Unmap(size);

  m_uniform_buffer_offset = res.buffer_offset;
}

void GPU_HW_Metal::UploadUniformBuffer(const void* data, uint32_t data_size)
{
  UploadUniforms(data, data_size);
}

// --- batch drawing ---------------------------------------------------------

void GPU_HW_Metal::MapBatchVertexPointer(uint32_t required_vertices)
{
  const Metal::StreamBuffer::MappingResult res =
    m_vertex_stream_buffer->Map(sizeof(BatchVertex), required_vertices * sizeof(BatchVertex));

  m_batch_start_vertex_ptr = static_cast<BatchVertex*>(res.pointer);
  m_batch_current_vertex_ptr = m_batch_start_vertex_ptr;
  m_batch_end_vertex_ptr = m_batch_start_vertex_ptr + res.space_aligned;
  m_batch_base_vertex = res.index_aligned;
}

void GPU_HW_Metal::UnmapBatchVertexPointer(uint32_t used_vertices)
{
  m_vertex_stream_buffer->Unmap(used_vertices * sizeof(BatchVertex));
  m_batch_start_vertex_ptr = nullptr;
  m_batch_end_vertex_ptr = nullptr;
  m_batch_current_vertex_ptr = nullptr;
}

void GPU_HW_Metal::DrawBatchVertices(BatchRenderMode render_mode, uint32_t base_vertex, uint32_t num_vertices)
{
  id<MTLRenderCommandEncoder> encoder = EnsureRenderPass(RenderTarget::VRAM);
  if (encoder == nil)
    return;

  const uint32_t variant = (static_cast<uint32_t>(render_mode) << 6) |
                           (static_cast<uint32_t>(m_batch.texture_mode) << 4) |
                           (m_batch.dithering ? 2u : 0u) | (m_batch.interlacing ? 1u : 0u);

  PipelineKey key;
  key.vertex_source = (m_batch.texture_mode != GPUTextureMode::Disabled) ? VS_BATCH_TEXTURED : VS_BATCH_UNTEXTURED;
  key.fragment_source = FS_BATCH + variant;
  key.depth = m_batch.use_depth_buffer ? 2u : (m_batch.check_mask_before_draw ? 3u : 1u);
  key.blend = UseAlphaBlending(m_batch.transparency_mode, render_mode) ?
                (m_batch.transparency_mode == GPUTransparencyMode::BackgroundMinusForeground ? 2u : 1u) :
                0u;

  id<MTLRenderPipelineState> pipeline = GetOrCreatePipeline(key);
  if (pipeline == nil)
    return;

  [encoder setRenderPipelineState:pipeline];
  [encoder setVertexBuffer:m_vertex_stream_buffer->GetBuffer() offset:0 atIndex:0];
  [encoder setVertexBuffer:m_uniform_stream_buffer->GetBuffer() offset:m_uniform_buffer_offset atIndex:1];
  [encoder setFragmentBuffer:m_uniform_stream_buffer->GetBuffer() offset:m_uniform_buffer_offset atIndex:1];
  [encoder setFragmentTexture:m_vram_texture.GetTexture() atIndex:0];
  [encoder setFragmentSamplerState:m_nearest_sampler atIndex:0];

  if (m_has_scissor)
  {
    [encoder setScissorRect:MTLScissorRect{m_current_scissor[0], m_current_scissor[1], m_current_scissor[2],
                                           m_current_scissor[3]}];
  }

  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:m_batch_base_vertex vertexCount:num_vertices];
}

void GPU_HW_Metal::SetScissorFromDrawingArea()
{
  int left, top, right, bottom;
  CalcScissorRect(&left, &top, &right, &bottom);

  m_current_scissor[0] = static_cast<uint32_t>(std::max(left, 0));
  m_current_scissor[1] = static_cast<uint32_t>(std::max(top, 0));
  m_current_scissor[2] = static_cast<uint32_t>(std::max(right - left, 0));
  m_current_scissor[3] = static_cast<uint32_t>(std::max(bottom - top, 0));
  m_has_scissor = true;
}

// --- display ---------------------------------------------------------------

void GPU_HW_Metal::ClearDisplay()
{
  GPU_HW::ClearDisplay();
  m_host_display->ClearDisplayTexture();
  m_display_texture.Destroy();
  m_display_texture_width = 0;
  m_display_texture_height = 0;
}

void GPU_HW_Metal::DownsampleFramebufferBoxFilter(Metal::Texture& source, uint32_t left, uint32_t top, uint32_t width,
                                                  uint32_t height)
{
  const uint32_t ds_left = left / m_resolution_scale;
  const uint32_t ds_top = top / m_resolution_scale;
  const uint32_t ds_width = width / m_resolution_scale;
  const uint32_t ds_height = height / m_resolution_scale;
  if (ds_width == 0 || ds_height == 0)
    return;

  struct Uniforms
  {
    float u_uv_min[2];
    float u_uv_max[2];
    float u_rcp_resolution[2];
  } uniforms = {{static_cast<float>(left) / static_cast<float>(source.GetWidth()),
                 static_cast<float>(top) / static_cast<float>(source.GetHeight())},
                {static_cast<float>(left + width) / static_cast<float>(source.GetWidth()),
                 static_cast<float>(top + height) / static_cast<float>(source.GetHeight())},
                {1.0f / static_cast<float>(ds_width), 1.0f / static_cast<float>(ds_height)}};
  UploadUniforms(&uniforms, sizeof(uniforms));

  id<MTLRenderCommandEncoder> encoder = EnsureRenderPass(RenderTarget::Downsample);
  if (encoder == nil)
    return;

  [encoder setViewport:MTLViewport{static_cast<double>(ds_left), static_cast<double>(ds_top),
                                   static_cast<double>(ds_width), static_cast<double>(ds_height), 0.0, 1.0}];
  [encoder setScissorRect:MTLScissorRect{ds_left, ds_top, ds_width, ds_height}];

  PipelineKey key;
  key.vertex_source = VS_SCREEN_QUAD;
  key.fragment_source = FS_DOWNSAMPLE;

  id<MTLRenderPipelineState> pipeline = GetOrCreatePipeline(key);
  if (pipeline != nil)
  {
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentBuffer:m_uniform_stream_buffer->GetBuffer() offset:m_uniform_buffer_offset atIndex:1];
    [encoder setFragmentTexture:source.GetTexture() atIndex:0];
    [encoder setFragmentSamplerState:m_linear_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }

  EndRenderPass();
}

void GPU_HW_Metal::UpdateDisplay()
{
  GPU_HW::UpdateDisplay();

  m_host_display->SetDisplayParameters(m_crtc_state.display_width, m_crtc_state.display_height,
                                       m_crtc_state.display_origin_left, m_crtc_state.display_origin_top,
                                       m_crtc_state.display_vram_width, m_crtc_state.display_vram_height,
                                       GetDisplayAspectRatio());

  const uint32_t display_width = m_crtc_state.display_vram_width;
  const uint32_t display_height = m_crtc_state.display_vram_height;
  if (display_width == 0 || display_height == 0)
  {
    EndFrame();
    return;
  }

  // The app draws the whole texture, so the texture is the frame: it is
  // recreated when the display size changes rather than using a view rect.
  if (!m_display_texture.IsValid() || m_display_texture_width != display_width ||
      m_display_texture_height != display_height)
  {
    EndRenderPass();
    m_display_texture.Destroy();
    if (!m_display_texture.Create(s_metal_device, display_width, display_height, 1, MTLPixelFormatRGBA8Unorm, true))
    {
      Log_ErrorPrintf("Failed to create the display texture.");
      EndFrame();
      return;
    }

    m_display_texture_width = display_width;
    m_display_texture_height = display_height;
  }

  const bool depth_24bit = m_GPUSTAT.display_area_color_depth_24;
  const InterlacedRenderMode interlaced = GetInterlacedRenderMode();

  // The display shader samples whatever holds the 1x image: the VRAM texture
  // directly, or the downsampled copy when the internal resolution is higher
  // than the screen's.
  Metal::Texture* source_texture = &m_vram_texture;
  uint32_t source_resolution_scale = depth_24bit ? 1u : m_resolution_scale;
  if (IsUsingDownsampling())
  {
    DownsampleFramebufferBoxFilter(m_vram_texture, m_crtc_state.display_vram_left * m_resolution_scale,
                                   m_crtc_state.display_vram_top * m_resolution_scale,
                                   m_crtc_state.display_vram_width * m_resolution_scale,
                                   m_crtc_state.display_vram_height * m_resolution_scale);
    source_texture = &m_downsample_texture;
    source_resolution_scale = 1;
  }

  struct Uniforms
  {
    uint32_t u_vram_offset[2];
    uint32_t u_crop_left;
    uint32_t u_field_offset;
    uint32_t u_resolution_scale;
    uint32_t u_pad0;
  } uniforms = {{m_crtc_state.display_vram_left, m_crtc_state.display_vram_top},
                m_crtc_state.display_origin_left,
                (interlaced == InterlacedRenderMode::InterleavedFields && m_GPUSTAT.vertical_interlace) ?
                  static_cast<uint32_t>(m_crtc_state.display_origin_top + 1) :
                  0u,
                source_resolution_scale,
                0u};
  UploadUniforms(&uniforms, sizeof(uniforms));

  PipelineKey key;
  key.vertex_source = VS_SCREEN_QUAD;
  key.fragment_source = FS_DISPLAY + (depth_24bit ? 1u : 0u) + ((interlaced != InterlacedRenderMode::None) ? 2u : 0u);

  id<MTLRenderCommandEncoder> encoder = EnsureRenderPass(RenderTarget::Display, true);
  if (encoder != nil)
  {
    [encoder setViewport:MTLViewport{0.0, 0.0, static_cast<double>(display_width),
                                     static_cast<double>(display_height), 0.0, 1.0}];
    [encoder setScissorRect:MTLScissorRect{0, 0, display_width, display_height}];

    id<MTLRenderPipelineState> pipeline = GetOrCreatePipeline(key);
    if (pipeline != nil)
    {
      [encoder setRenderPipelineState:pipeline];
      [encoder setFragmentBuffer:m_uniform_stream_buffer->GetBuffer() offset:m_uniform_buffer_offset atIndex:1];
      [encoder setFragmentTexture:source_texture->GetTexture() atIndex:0];
      [encoder setFragmentSamplerState:m_nearest_sampler atIndex:0];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }

    EndRenderPass();
  }

  m_host_display->SetDisplayTexture(m_display_texture.GetHandle(), HostDisplayPixelFormat::RGBA8, display_width,
                                    display_height, 0, 0, display_width, display_height);

  // The app draws this frame after the emulation thread returns, so the work
  // has to be finished before then.
  EndFrame();
}

// --- VRAM ------------------------------------------------------------------

void GPU_HW_Metal::ReadVRAM(uint32_t x, uint32_t y, uint32_t width, uint32_t height)
{
  if (IsUsingSoftwareRendererForReadbacks())
  {
    ReadSoftwareRendererVRAM(x, y, width, height);
    return;
  }

  const Common::Rectangle<uint32_t> copy_rect = GetVRAMTransferBounds(x, y, width, height);
  const uint32_t encoded_width = (copy_rect.GetWidth() + 1) / 2;
  const uint32_t encoded_height = copy_rect.GetHeight();
  if (encoded_width == 0 || encoded_height == 0)
    return;

  struct Uniforms
  {
    uint32_t u_base_coords[2];
    uint32_t u_size[2];
    uint32_t u_resolution_scale;
    uint32_t u_pad0;
  } uniforms = {{copy_rect.left, copy_rect.top}, {copy_rect.GetWidth(), copy_rect.GetHeight()}, m_resolution_scale, 0u};
  UploadUniforms(&uniforms, sizeof(uniforms));

  id<MTLRenderCommandEncoder> encoder = EnsureRenderPass(RenderTarget::VRAMEncoding, true);
  if (encoder == nil)
    return;

  [encoder setViewport:MTLViewport{0.0, 0.0, static_cast<double>(encoded_width), static_cast<double>(encoded_height),
                                   0.0, 1.0}];
  [encoder setScissorRect:MTLScissorRect{0, 0, encoded_width, encoded_height}];

  PipelineKey key;
  key.vertex_source = VS_SCREEN_QUAD;
  key.fragment_source = FS_VRAM_READ;

  id<MTLRenderPipelineState> pipeline = GetOrCreatePipeline(key);
  if (pipeline != nil)
  {
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentBuffer:m_uniform_stream_buffer->GetBuffer() offset:m_uniform_buffer_offset atIndex:1];
    [encoder setFragmentTexture:m_vram_texture.GetTexture() atIndex:0];
    [encoder setFragmentSamplerState:m_nearest_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }

  // The readback needs the GPU to have finished, so this one waits.
  EndRenderPass();
  FlushAndWait();

  // The read shader packs two VRAM pixels into each texel, so the rows come
  // back at the same stride as the 16-bit shadow copy.
  uint8_t* destination = reinterpret_cast<uint8_t*>(m_vram_shadow.data()) +
                         ((copy_rect.top * VRAM_WIDTH + copy_rect.left) * sizeof(uint16_t));
  [m_vram_encoding_texture.GetTexture() getBytes:destination
                                     bytesPerRow:VRAM_WIDTH * sizeof(uint16_t)
                                      fromRegion:MTLRegionMake2D(0, 0, encoded_width, encoded_height)
                                     mipmapLevel:0];

  RestoreGraphicsAPIState();
}

void GPU_HW_Metal::FillVRAM(uint32_t x, uint32_t y, uint32_t width, uint32_t height, uint32_t color)
{
  if (IsUsingSoftwareRendererForReadbacks())
    FillSoftwareRendererVRAM(x, y, width, height, color);

  GPU_HW::FillVRAM(x, y, width, height, color);

  const Common::Rectangle<uint32_t> bounds(GetVRAMTransferBounds(x, y, width, height));
  m_current_scissor[0] = bounds.left * m_resolution_scale;
  m_current_scissor[1] = bounds.top * m_resolution_scale;
  m_current_scissor[2] = width * m_resolution_scale;
  m_current_scissor[3] = height * m_resolution_scale;
  m_has_scissor = true;

  const bool wrapped = IsVRAMFillOversized(x, y, width, height);
  const bool interlaced = IsInterlacedRenderingEnabled();

  const VRAMFillUBOData uniforms = GetVRAMFillUBOData(x, y, width, height, color);
  UploadUniforms(&uniforms, sizeof(uniforms));

  PipelineKey key;
  key.vertex_source = VS_SCREEN_QUAD;
  key.fragment_source = FS_VRAM_FILL + (wrapped ? 2u : 0u) + (interlaced ? 1u : 0u);
  key.depth = 1;

  id<MTLRenderCommandEncoder> encoder = EnsureRenderPass(RenderTarget::VRAM);
  if (encoder == nil)
    return;

  [encoder setScissorRect:MTLScissorRect{m_current_scissor[0], m_current_scissor[1], m_current_scissor[2],
                                         m_current_scissor[3]}];

  id<MTLRenderPipelineState> pipeline = GetOrCreatePipeline(key);
  if (pipeline != nil)
  {
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentBuffer:m_uniform_stream_buffer->GetBuffer() offset:m_uniform_buffer_offset atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }

  RestoreGraphicsAPIState();
}

void GPU_HW_Metal::UpdateVRAM(uint32_t x, uint32_t y, uint32_t width, uint32_t height, const void* data, bool set_mask,
                              bool check_mask)
{
  if (IsUsingSoftwareRendererForReadbacks())
    UpdateSoftwareRendererVRAM(x, y, width, height, data, set_mask, check_mask);

  const Common::Rectangle<uint32_t> bounds = GetVRAMTransferBounds(x, y, width, height);
  GPU_HW::UpdateVRAM(bounds.left, bounds.top, bounds.GetWidth(), bounds.GetHeight(), data, set_mask, check_mask);

  if (!check_mask)
  {
    const TextureReplacementTexture* rtex = g_texture_replacements.GetVRAMWriteReplacement(width, height, data);
    if (rtex && !m_warned_about_replacements)
    {
      // The data still goes up; only the replacement image is skipped.
      Log_WarningPrintf("VRAM write replacements are not supported by the Metal renderer yet.");
      m_warned_about_replacements = true;
    }
  }

  const uint32_t num_pixels = width * height;
  const auto map_result = m_texture_stream_buffer->Map(sizeof(uint16_t), num_pixels * sizeof(uint16_t));
  std::memcpy(map_result.pointer, data, num_pixels * sizeof(uint16_t));
  m_texture_stream_buffer->Unmap(num_pixels * sizeof(uint16_t));
  m_texture_buffer_offset = map_result.buffer_offset;

  const VRAMWriteUBOData uniforms =
    GetVRAMWriteUBOData(x, y, width, height, map_result.index_aligned, set_mask, check_mask);
  UploadUniforms(&uniforms, sizeof(uniforms));

  const Common::Rectangle<uint32_t> scaled_bounds = bounds * m_resolution_scale;
  m_current_scissor[0] = scaled_bounds.left;
  m_current_scissor[1] = scaled_bounds.top;
  m_current_scissor[2] = scaled_bounds.GetWidth();
  m_current_scissor[3] = scaled_bounds.GetHeight();
  m_has_scissor = true;

  PipelineKey key;
  key.vertex_source = VS_SCREEN_QUAD;
  key.fragment_source = FS_VRAM_WRITE;
  key.depth = (check_mask && !m_pgxp_depth_buffer) ? 3u : 1u;

  id<MTLRenderCommandEncoder> encoder = EnsureRenderPass(RenderTarget::VRAM);
  if (encoder == nil)
    return;

  [encoder setScissorRect:MTLScissorRect{m_current_scissor[0], m_current_scissor[1], m_current_scissor[2],
                                         m_current_scissor[3]}];

  id<MTLRenderPipelineState> pipeline = GetOrCreatePipeline(key);
  if (pipeline != nil)
  {
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentBuffer:m_uniform_stream_buffer->GetBuffer() offset:m_uniform_buffer_offset atIndex:1];
    [encoder setFragmentBuffer:m_texture_stream_buffer->GetBuffer() offset:m_texture_buffer_offset atIndex:2];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }

  RestoreGraphicsAPIState();
}

void GPU_HW_Metal::CopyVRAM(uint32_t src_x, uint32_t src_y, uint32_t dst_x, uint32_t dst_y, uint32_t width, uint32_t height)
{
  if (IsUsingSoftwareRendererForReadbacks())
    CopySoftwareRendererVRAM(src_x, src_y, dst_x, dst_y, width, height);

  const Common::Rectangle<uint32_t> dst_bounds = GetVRAMTransferBounds(dst_x, dst_y, width, height);
  const Common::Rectangle<uint32_t> src_bounds = GetVRAMTransferBounds(src_x, src_y, width, height);
  const bool src_dirty = m_vram_dirty_rect.Intersects(src_bounds);

  if (src_dirty)
    UpdateVRAMReadTexture();

  IncludeVRAMDirtyRectangle(dst_bounds);

  // Metal cannot copy a texture onto itself, so the copy always goes through
  // the read texture, which is the path the shader implements.
  const VRAMCopyUBOData uniforms = GetVRAMCopyUBOData(src_x, src_y, dst_x, dst_y, width, height);
  UploadUniforms(&uniforms, sizeof(uniforms));

  const Common::Rectangle<uint32_t> dst_bounds_scaled(dst_bounds * m_resolution_scale);
  m_has_scissor = false;

  id<MTLRenderCommandEncoder> encoder = EnsureRenderPass(RenderTarget::VRAM);
  if (encoder == nil)
    return;

  [encoder setViewport:MTLViewport{static_cast<double>(dst_bounds_scaled.left),
                                   static_cast<double>(dst_bounds_scaled.top),
                                   static_cast<double>(dst_bounds_scaled.GetWidth()),
                                   static_cast<double>(dst_bounds_scaled.GetHeight()), 0.0, 1.0}];
  [encoder setScissorRect:MTLScissorRect{dst_bounds_scaled.left, dst_bounds_scaled.top, dst_bounds_scaled.GetWidth(),
                                         dst_bounds_scaled.GetHeight()}];

  PipelineKey key;
  key.vertex_source = VS_SCREEN_QUAD;
  key.fragment_source = FS_VRAM_COPY;
  key.depth = (m_GPUSTAT.check_mask_before_draw && !m_pgxp_depth_buffer) ? 3u : 1u;

  id<MTLRenderPipelineState> pipeline = GetOrCreatePipeline(key);
  if (pipeline != nil)
  {
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentBuffer:m_uniform_stream_buffer->GetBuffer() offset:m_uniform_buffer_offset atIndex:1];
    [encoder setFragmentTexture:m_vram_read_texture.GetTexture() atIndex:0];
    [encoder setFragmentSamplerState:m_nearest_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }

  RestoreGraphicsAPIState();

  if (m_GPUSTAT.check_mask_before_draw)
    m_current_depth++;

  GPU_HW::CopyVRAM(src_x, src_y, dst_x, dst_y, width, height);
}

void GPU_HW_Metal::UpdateVRAMReadTexture()
{
  const auto scaled_rect = m_vram_dirty_rect * m_resolution_scale;
  const uint32_t width = scaled_rect.GetWidth();
  const uint32_t height = scaled_rect.GetHeight();
  if (width == 0 || height == 0)
  {
    GPU_HW::UpdateVRAMReadTexture();
    return;
  }

  // A blit cannot run inside a render pass, so close the pass first.
  EndRenderPass();

  id<MTLBlitCommandEncoder> blit = [m_command_buffer blitCommandEncoder];
  if (blit != nil)
  {
    [blit copyFromTexture:m_vram_texture.GetTexture()
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(scaled_rect.left, scaled_rect.top, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:m_vram_read_texture.GetTexture()
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(scaled_rect.left, scaled_rect.top, 0)];
    [blit endEncoding];
  }

  GPU_HW::UpdateVRAMReadTexture();
}

void GPU_HW_Metal::UpdateDepthBufferFromMaskBit()
{
  if (m_pgxp_depth_buffer)
    return;

  m_has_scissor = false;

  id<MTLRenderCommandEncoder> encoder = EnsureRenderPass(RenderTarget::VRAM);
  if (encoder == nil)
    return;

  [encoder setViewport:MTLViewport{0.0, 0.0, static_cast<double>(m_vram_texture.GetWidth()),
                                   static_cast<double>(m_vram_texture.GetHeight()), 0.0, 1.0}];
  [encoder setScissorRect:MTLScissorRect{0, 0, m_vram_texture.GetWidth(), m_vram_texture.GetHeight()}];

  PipelineKey key;
  key.vertex_source = VS_SCREEN_QUAD;
  key.fragment_source = FS_VRAM_UPDATE_DEPTH;
  key.depth = 1;

  id<MTLRenderPipelineState> pipeline = GetOrCreatePipeline(key);
  if (pipeline != nil)
  {
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:m_vram_read_texture.GetTexture() atIndex:0];
    [encoder setFragmentSamplerState:m_nearest_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }

  EndRenderPass();
}

void GPU_HW_Metal::ClearDepthBuffer()
{
  // Clearing the depth attachment means opening a pass on it. The colour
  // attachment is loaded and stored untouched.
  BeginFrame();
  EndRenderPass();

  @autoreleasepool
  {
    MTLRenderPassDescriptor* desc = [[MTLRenderPassDescriptor alloc] init];
    desc.colorAttachments[0].texture = m_vram_texture.GetTexture();
    desc.colorAttachments[0].loadAction = MTLLoadActionLoad;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.depthAttachment.texture = m_vram_depth_texture.GetTexture();
    desc.depthAttachment.loadAction = MTLLoadActionClear;
    desc.depthAttachment.storeAction = MTLStoreActionStore;
    desc.depthAttachment.clearDepth = 1.0;

    id<MTLRenderCommandEncoder> encoder = [m_command_buffer renderCommandEncoderWithDescriptor:desc];
    if (encoder != nil)
      [encoder endEncoding];
  }

  m_encoder = nil;
  m_encoder_target = RenderTarget::None;
  m_last_depth_z = 1.0f;
}

std::unique_ptr<GPU> GPU::CreateHardwareMetalRenderer()
{
  return std::make_unique<GPU_HW_Metal>();
}

#endif // __OBJC__
