// SPDX-FileCopyrightText: 2026 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later
#include "texture.h"

#ifdef __OBJC__

#include <cstring>

namespace Metal {

Texture::Texture() = default;

Texture::Texture(Texture&& moved) noexcept
  : m_texture(moved.m_texture), m_width(moved.m_width), m_height(moved.m_height), m_samples(moved.m_samples),
    m_format(moved.m_format), m_cpu_accessible(moved.m_cpu_accessible)
{
  moved.m_texture = nil;
  moved.m_width = 0;
  moved.m_height = 0;
  moved.m_samples = 1;
  moved.m_format = MTLPixelFormatInvalid;
}

Texture::~Texture()
{
  Destroy();
}

Texture& Texture::operator=(Texture&& moved) noexcept
{
  if (this != &moved)
  {
    Destroy();
    m_texture = moved.m_texture;
    m_width = moved.m_width;
    m_height = moved.m_height;
    m_samples = moved.m_samples;
    m_format = moved.m_format;
    m_cpu_accessible = moved.m_cpu_accessible;
    moved.m_texture = nil;
    moved.m_width = 0;
    moved.m_height = 0;
    moved.m_samples = 1;
    moved.m_format = MTLPixelFormatInvalid;
  }
  return *this;
}

bool Texture::Create(id<MTLDevice> device, uint32_t width, uint32_t height, uint32_t samples, MTLPixelFormat format,
                     bool render_target, const void* data)
{
  Destroy();

  if (width == 0 || height == 0)
    return false;

  @autoreleasepool
  {
    MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = (samples > 1) ? MTLTextureType2DMultisample : MTLTextureType2D;
    desc.pixelFormat = format;
    desc.width = width;
    desc.height = height;
    desc.sampleCount = (samples > 1) ? samples : 1;
    desc.mipmapLevelCount = 1;
    desc.arrayLength = 1;
    // Colour textures are readable by the CPU: VRAM is uploaded to and read
    // back from, and the display texture is handed to the engine, which
    // samples it from its own command queue. Depth textures cannot be shared
    // on every device, and nothing here reads one back, so they are private.
    m_cpu_accessible = (format != MTLPixelFormatDepth32Float && format != MTLPixelFormatDepth16Unorm);
    desc.storageMode = m_cpu_accessible ? MTLStorageModeShared : MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead;
    if (render_target)
      desc.usage |= MTLTextureUsageRenderTarget;

    m_texture = [device newTextureWithDescriptor:desc];
    if (m_texture == nil)
      return false;

    m_width = width;
    m_height = height;
    m_samples = (samples > 1) ? samples : 1;
    m_format = format;

    if (data && m_cpu_accessible)
      Replace(data);
  }

  return true;
}

void Texture::Replace(const void* data)
{
  if (m_texture == nil || data == nullptr || !m_cpu_accessible)
    return;

  const uint32_t bytes_per_row = m_width * 4;
  [m_texture replaceRegion:MTLRegionMake2D(0, 0, m_width, m_height)
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:bytes_per_row];
}

void Texture::Upload(uint32_t x, uint32_t y, uint32_t width, uint32_t height, const void* data)
{
  if (m_texture == nil || data == nullptr || width == 0 || height == 0 || !m_cpu_accessible)
    return;

  const uint32_t bytes_per_row = width * 4;
  [m_texture replaceRegion:MTLRegionMake2D(x, y, width, height)
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:bytes_per_row];
}

void Texture::Download(void* data) const
{
  if (m_texture == nil || data == nullptr || !m_cpu_accessible)
    return;

  const uint32_t bytes_per_row = m_width * 4;
  [m_texture getBytes:data bytesPerRow:bytes_per_row fromRegion:MTLRegionMake2D(0, 0, m_width, m_height)
          mipmapLevel:0];
}

void Texture::Destroy()
{
  m_texture = nil;
  m_cpu_accessible = true;
  m_width = 0;
  m_height = 0;
  m_samples = 1;
  m_format = MTLPixelFormatInvalid;
}

} // namespace Metal

#endif // __OBJC__
