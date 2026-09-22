// SPDX-FileCopyrightText: 2026 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

#include "../types.h"
#include <memory>

namespace Metal {

/// A growable buffer the CPU writes and the GPU reads, used for the batch
/// vertex data and the uniform buffers.
///
/// The other back ends fence their ring so a write never lands on top of data
/// the GPU has not read yet. That is not needed here: this core submits one
/// command buffer per frame and waits for it to finish before the frame is
/// handed to the engine, so by the time the ring wraps the GPU has caught up.
class StreamBuffer
{
public:
  ~StreamBuffer();

  StreamBuffer(const StreamBuffer&) = delete;
  StreamBuffer& operator=(const StreamBuffer&) = delete;

  static std::unique_ptr<StreamBuffer> Create(id<MTLDevice> device, uint32_t size);

  struct MappingResult
  {
    void* pointer;
    uint32_t buffer_offset;
    uint32_t index_aligned; // offset / alignment, suitable for base vertex
    uint32_t space_aligned; // remaining space / alignment
  };

  /// Reserves `min_size` bytes, aligned up to `alignment`.
  MappingResult Map(uint32_t alignment, uint32_t min_size);
  /// Releases the reservation, keeping the `used_size` bytes that were written.
  void Unmap(uint32_t used_size);

  ALWAYS_INLINE id<MTLBuffer> GetBuffer() const { return m_buffer; }
  ALWAYS_INLINE uint32_t GetSize() const { return m_size; }
  ALWAYS_INLINE uint32_t GetPosition() const { return m_position; }

  /// Called once per frame, after the GPU has finished with the ring.
  ALWAYS_INLINE void Reset() { m_position = 0; }

private:
  StreamBuffer(id<MTLBuffer> buffer, uint8_t* mapped_pointer, uint32_t size);

  id<MTLBuffer> m_buffer;
  uint8_t* m_mapped_pointer;
  uint32_t m_size;
  uint32_t m_position = 0;
};

} // namespace Metal

#endif // __OBJC__
