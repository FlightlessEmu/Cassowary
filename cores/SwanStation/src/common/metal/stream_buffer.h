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
/// the GPU has not read yet. This one does not wrap on its own: when a
/// reservation will not fit, the owner has to finish the GPU work that still
/// reads the ring, then Reset() it. The commands of a frame only reach the GPU
/// when the frame ends, so data written earlier in the same frame is still
/// waiting to be read.
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

  /// Whether `min_size` bytes, aligned up to `alignment`, fit before the end.
  bool HasSpaceFor(uint32_t alignment, uint32_t min_size) const;
  /// Reserves `min_size` bytes, aligned up to `alignment`. The space has to be
  /// there; check HasSpaceFor() first.
  MappingResult Map(uint32_t alignment, uint32_t min_size);
  /// Releases the reservation, keeping the `used_size` bytes that were written.
  void Unmap(uint32_t used_size);

  ALWAYS_INLINE id<MTLBuffer> GetBuffer() const { return m_buffer; }
  ALWAYS_INLINE uint32_t GetSize() const { return m_size; }
  ALWAYS_INLINE uint32_t GetPosition() const { return m_position; }

  /// Starts again from the beginning. Only once the GPU has finished with the
  /// ring.
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
