// SPDX-FileCopyrightText: 2026 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later
#include "shader_cache.h"

#ifdef __OBJC__

#include "../log.h"
Log_SetChannel(Metal::ShaderCache);

namespace Metal {

static uint64_t HashSource(std::string_view source)
{
  // FNV-1a. The key is only ever compared against itself, so a cheap hash is
  // enough.
  uint64_t hash = UINT64_C(0xcbf29ce484222325);
  for (const char c : source)
  {
    hash ^= static_cast<uint8_t>(c);
    hash *= UINT64_C(0x100000001b3);
  }
  return hash;
}

ShaderCache::ShaderCache() = default;

ShaderCache::~ShaderCache()
{
  Clear();
}

id<MTLLibrary> ShaderCache::GetLibrary(id<MTLDevice> device, std::string_view source)
{
  const uint64_t key = HashSource(source);
  const auto it = m_libraries.find(key);
  if (it != m_libraries.end())
    return it->second.library;

  @autoreleasepool
  {
    NSError* error = nil;
    NSString* source_string = [[NSString alloc] initWithBytes:source.data()
                                                       length:source.size()
                                                     encoding:NSUTF8StringEncoding];
    id<MTLLibrary> library = [device newLibraryWithSource:source_string options:nil error:&error];
    if (library == nil)
    {
      Log_ErrorPrintf("Failed to compile shader: %s", error ? [[error localizedDescription] UTF8String] : "unknown error");
      // Remember the failure so the same source is not retried every draw.
      m_libraries.emplace(key, Entry{nil});
      return nil;
    }

    m_compile_count++;
    m_libraries.emplace(key, Entry{library});
    return library;
  }
}

id<MTLFunction> ShaderCache::GetFunction(id<MTLDevice> device, std::string_view source, const char* name)
{
  id<MTLLibrary> library = GetLibrary(device, source);
  if (library == nil)
    return nil;

  @autoreleasepool
  {
    NSString* function_name = [NSString stringWithUTF8String:name];
    id<MTLFunction> function = [library newFunctionWithName:function_name];
    if (function == nil)
      Log_ErrorPrintf("Shader has no function named %s", name);

    return function;
  }
}

void ShaderCache::Clear()
{
  m_libraries.clear();
  m_compile_count = 0;
}

} // namespace Metal

#endif // __OBJC__
