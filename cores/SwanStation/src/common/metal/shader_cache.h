// SPDX-FileCopyrightText: 2026 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

#include "../types.h"
#include <string_view>
#include <unordered_map>

namespace Metal {

/// Compiles Metal Shading Language source into libraries, and remembers them.
///
/// Compiling a source string is the expensive half of building a pipeline, and
/// the renderer asks for the same handful of sources over and over (once per
/// pipeline state that shares a shader). The pipelines themselves are cached by
/// the caller, which knows the blend and depth state they also depend on.
class ShaderCache
{
public:
  ShaderCache();
  ~ShaderCache();

  ShaderCache(const ShaderCache&) = delete;
  ShaderCache& operator=(const ShaderCache&) = delete;

  /// Returns the library for `source`, compiling it if this is the first time.
  /// Logs and returns nil if the source does not compile.
  id<MTLLibrary> GetLibrary(id<MTLDevice> device, std::string_view source);

  /// Returns the named function from `source`'s library.
  id<MTLFunction> GetFunction(id<MTLDevice> device, std::string_view source, const char* name);

  void Clear();

  /// Number of source compilations, for the OSD stats.
  ALWAYS_INLINE uint32_t GetCompileCount() const { return m_compile_count; }

private:
  struct Entry
  {
    id<MTLLibrary> library;
  };

  std::unordered_map<uint64_t, Entry> m_libraries;
  uint32_t m_compile_count = 0;
};

} // namespace Metal

#endif // __OBJC__
