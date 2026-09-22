// SPDX-FileCopyrightText: 2026 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later
#include "stream_buffer.h"

#ifdef __OBJC__

#include "../align.h"
#include <cassert>

namespace Metal {

StreamBuffer::StreamBuffer(id<MTLBuffer> buffer, uint8_t* mapped_pointer, uint32_t size)
  : m_buffer(buffer), m_mapped_pointer(mapped_pointer), m_size(size)
{
}

StreamBuffer::~StreamBuffer()
{
  m_buffer = nil;
  m_mapped_pointer = nullptr;
}

std::unique_ptr<StreamBuffer> StreamBuffer::Create(id<MTLDevice> device, uint32_t size)
{
  @autoreleasepool
  {
    id<MTLBuffer> buffer = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
    if (buffer == nil)
      return {};

    return std::unique_ptr<StreamBuffer>(new StreamBuffer(buffer, static_cast<uint8_t*>([buffer contents]), size));
  }
}

StreamBuffer::MappingResult StreamBuffer::Map(uint32_t alignment, uint32_t min_size)
{
  assert(alignment > 0 && min_size <= m_size);

  if (m_position > 0)
    m_position = Common::AlignUp(m_position, alignment);

  // Wrap around when the reservation would run off the end. The GPU has
  // finished with the whole ring by now, so nothing has to be waited on.
  if ((m_position + min_size) > m_size)
    m_position = 0;

  return MappingResult{m_mapped_pointer + m_position, m_position, m_position / alignment,
                       (m_size - m_position) / alignment};
}

void StreamBuffer::Unmap(uint32_t used_size)
{
  m_position += used_size;
}

} // namespace Metal

#endif // __OBJC__
