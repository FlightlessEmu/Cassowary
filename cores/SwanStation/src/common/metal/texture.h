// SPDX-FileCopyrightText: 2026 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

#include "../types.h"

namespace Metal {

/// A texture, and the render target it can be drawn into.
///
/// Unlike the OpenGL and Vulkan wrappers there is no framebuffer object: a
/// render pass names the texture it draws into. The storage mode is shared,
/// which on the devices this runs on means the CPU can upload and read back
/// without a staging buffer.
class Texture
{
public:
  Texture();
  Texture(Texture&& moved) noexcept;
  ~Texture();

  Texture(const Texture&) = delete;
  Texture& operator=(const Texture&) = delete;
  Texture& operator=(Texture&& moved) noexcept;

  bool Create(id<MTLDevice> device, uint32_t width, uint32_t height, uint32_t samples, MTLPixelFormat format,
              bool render_target = false, const void* data = nullptr);

  /// Replaces the whole texture's contents. The size must match.
  void Replace(const void* data);
  /// Replaces a sub-rectangle's contents.
  void Upload(uint32_t x, uint32_t y, uint32_t width, uint32_t height, const void* data);
  /// Reads the whole texture back into `data`, which must be GetWidth() * GetHeight() * 4 bytes.
  void Download(void* data) const;

  void Destroy();

  ALWAYS_INLINE bool IsValid() const { return (m_texture != nil); }
  ALWAYS_INLINE bool IsMultisampled() const { return (m_samples > 1); }
  ALWAYS_INLINE id<MTLTexture> GetTexture() const { return m_texture; }
  ALWAYS_INLINE void* GetHandle() const { return (__bridge void*)m_texture; }
  ALWAYS_INLINE uint32_t GetWidth() const { return m_width; }
  ALWAYS_INLINE uint32_t GetHeight() const { return m_height; }
  ALWAYS_INLINE uint32_t GetSamples() const { return m_samples; }
  ALWAYS_INLINE MTLPixelFormat GetFormat() const { return m_format; }

private:
  id<MTLTexture> m_texture = nil;
  uint32_t m_width = 0;
  uint32_t m_height = 0;
  uint32_t m_samples = 1;
  MTLPixelFormat m_format = MTLPixelFormatInvalid;
};

} // namespace Metal

#endif // __OBJC__
