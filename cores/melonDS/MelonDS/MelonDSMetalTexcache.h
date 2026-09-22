/*
    Copyright 2016-2025 melonDS team

    This file is part of melonDS.

    melonDS is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    melonDS is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with melonDS. If not, see http://www.gnu.org/licenses/.
*/

#pragma once

#ifdef __OBJC__

#import <Metal/Metal.h>

#include "GPU3D_Texcache.h"

namespace MelonDSMetal
{

/// Loads melonDS's decoded textures into Metal array textures.
///
/// This is the Metal version of melonDS's OpenGL texture-cache loader: the
/// shared `Texcache` template decodes the DS's texture formats on the CPU and
/// this puts each size of texture into its own 2D array texture, one layer
/// per cached texture. The rasteriser samples those layers directly.
class TexcacheLoader
{
public:
    explicit TexcacheLoader(id<MTLDevice> device = nil) noexcept : _device(device) {}

    __strong id<MTLTexture> GenerateTexture(melonDS::u32 width, melonDS::u32 height, melonDS::u32 layers)
    {
        if (_device == nil)
            return nil;

        MTLTextureDescriptor* desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Uint
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        desc.textureType = MTLTextureType2DArray;
        desc.arrayLength = layers;
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;

        return [_device newTextureWithDescriptor:desc];
    }

    void UploadTexture(__strong id<MTLTexture> handle, melonDS::u32 width, melonDS::u32 height,
                       melonDS::u32 layer, void* data)
    {
        if (handle == nil)
            return;

        [handle replaceRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                 mipmapLevel:0
                       slice:layer
                   withBytes:data
                 bytesPerRow:width * 4
               bytesPerImage:width * height * 4];
    }

    void DeleteTexture(__strong id<MTLTexture> handle)
    {
        // ARC drops the last reference here, which frees the texture.
        (void) handle;
    }

private:
    __strong id<MTLDevice> _device;
};

using TexcacheMetal = melonDS::Texcache<TexcacheLoader, __strong id<MTLTexture>>;

} // namespace MelonDSMetal

#endif // __OBJC__
