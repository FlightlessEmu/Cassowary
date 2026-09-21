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

#import "MelonDSMetalRenderer.h"
#import "MelonDSMetalShaders.h"

#include "GPU.h"
#include "GPU3D_Soft.h"

#include <cstdlib>
#include <cstring>
#include <simd/simd.h>

using namespace melonDS;

namespace
{

/// One row of the accelerated layer buffer: three planes of 256 words plus
/// melonDS's metadata word. See GPU2D_Soft.cpp.
constexpr NSUInteger kLayerStride = 256 * 3 + 1;
constexpr NSUInteger kScreenWidth = 256;
constexpr NSUInteger kScreenHeight = 192;
constexpr NSUInteger kPictureHeight = kScreenHeight * 2;

/// Matches MelonDSCompositorVertex in the shader source.
struct CompositorVertex
{
    simd::float2 position;
    simd::float2 texel;
};

/// Matches MelonDSCompositorUniforms.
struct CompositorUniforms
{
    uint32_t scale3D;
};

/// Handed out when a capture read-back has not happened yet.
u32 kBlankLine[256] = {};

} // namespace

namespace MelonDSMetal
{

Renderer::Renderer(id<MTLDevice> device, u32 width, u32 height) noexcept
    : Renderer3D(true),
      _device(device),
      _width(width),
      _height(height),
      _ready(false),
      _frontIndex(0)
{
    // Until the Metal rasteriser draws polygons, the 3D layer is drawn by
    // melonDS's software rasteriser. Setting MELONDS_3D=metal leaves that
    // layer empty instead, which is what the port is tested against.
    const char *mode = getenv("MELONDS_3D");
    _softwareThreeD = (mode == nullptr) || (strcmp(mode, "metal") != 0);

    if (_device == nil)
    {
        NSLog(@"[melonDS] metal: no device");
        return;
    }

    _queue = [_device newCommandQueue];
    if (_queue == nil)
    {
        NSLog(@"[melonDS] metal: no command queue");
        return;
    }

    NSError *error = nil;
    _library = [_device newLibraryWithSource:@(kMelonDSMetalSource) options:nil error:&error];
    if (_library == nil)
    {
        NSLog(@"[melonDS] could not build the Metal shaders: %@", error);
        return;
    }

    // The layer buffer melonDS's 2D renderer fills, one row per scanline of
    // each screen: rows 0-191 are the top screen, 192-383 the bottom.
    MTLTextureDescriptor *layers = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint
                                                                                     width:kLayerStride
                                                                                    height:kPictureHeight
                                                                                 mipmapped:NO];
    layers.usage = MTLTextureUsageShaderRead;
    layers.storageMode = MTLStorageModeShared;
    _layerTexture = [_device newTextureWithDescriptor:layers];
    _layerTexture.label = @"melonDS layers";

    // The 3D layer, one frame behind the 2D layers. It starts transparent, so
    // a frame that draws no 3D shows the 2D layers underneath.
    MTLTextureDescriptor *threeD = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:kScreenWidth
                                                                                     height:kScreenHeight
                                                                                  mipmapped:NO];
    threeD.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    threeD.storageMode = MTLStorageModeShared;
    _threeDTexture = [_device newTextureWithDescriptor:threeD];
    _threeDTexture.label = @"melonDS 3D";

    // One finished picture per screen, swapped each frame so the app always
    // has a texture we are not drawing into.
    MTLTextureDescriptor *output = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:_width
                                                                                     height:_height
                                                                                  mipmapped:NO];
    output.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    output.storageMode = MTLStorageModeShared;

    for (int i = 0; i < 2; i++)
    {
        _output[i] = [_device newTextureWithDescriptor:output];
        _output[i].label = [NSString stringWithFormat:@"melonDS picture %d", i];
        _lastCommandBuffer[i] = nil;
    }

    if (_layerTexture == nil || _threeDTexture == nil || _output[0] == nil || _output[1] == nil)
    {
        NSLog(@"[melonDS] could not create the Metal textures");
        return;
    }

    MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
    pipeline.label            = @"melonDS compositor";
    pipeline.vertexFunction   = [_library newFunctionWithName:@"melonds_compositor_vertex"];
    pipeline.fragmentFunction = [_library newFunctionWithName:@"melonds_compositor_fragment"];
    pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    _compositorPipeline = [_device newRenderPipelineStateWithDescriptor:pipeline error:&error];
    if (_compositorPipeline == nil)
    {
        NSLog(@"[melonDS] could not build the Metal compositor pipeline: %@", error);
        return;
    }

    ClearThreeDLayer();
    _ready = true;
}

Renderer::~Renderer() noexcept
{
    WaitForCompletion();
}

void Renderer::ClearThreeDLayer() noexcept
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture     = _threeDTexture;
    pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor  = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
}

void Renderer::Reset(GPU& gpu)
{
    if (_software != nullptr)
        _software->Reset(gpu);
}

void Renderer::VCount144(GPU& gpu)
{
    // Only the threaded software rasteriser uses this; it is kept in step so
    // that turning that on later needs no change here.
    if (_software != nullptr)
        _software->VCount144(gpu);
}

void Renderer::RenderFrame(GPU& gpu)
{
    if (!_ready)
        return;

    if (_softwareThreeD)
        RenderSoftwareThreeD(gpu);

    // The Metal rasteriser's turn comes next.
}

void Renderer::RestartFrame(GPU& gpu)
{
    if (_software != nullptr)
        _software->RestartFrame(gpu);
}

void Renderer::RenderSoftwareThreeD(GPU& gpu) noexcept
{
    if (_software == nullptr)
    {
        _software = std::make_unique<SoftRenderer>();
        _software->Reset(gpu);
    }

    _software->RenderFrame(gpu);

    // The software rasteriser keeps the 3D layer in the DS's own pixel layout:
    // 6 bits per colour and 5 of alpha, one word per pixel. The compositor
    // samples the texture as 8-bit values and multiplies by 63 and 31, so each
    // channel is widened here the way the DS widens it: the top bits of the
    // value are repeated in the low bits.
    if (_threeDPixels.size() != kScreenWidth * kScreenHeight)
        _threeDPixels.resize(kScreenWidth * kScreenHeight);

    for (NSUInteger y = 0; y < kScreenHeight; y++)
    {
        const u32 *src = _software->GetLine((int) y);
        u32 *dst = _threeDPixels.data() + y * kScreenWidth;

        for (NSUInteger x = 0; x < kScreenWidth; x++)
        {
            const u32 pixel = src[x];
            const u32 r = pixel & 0x3F;
            const u32 g = (pixel >> 8) & 0x3F;
            const u32 b = (pixel >> 16) & 0x3F;
            const u32 a = (pixel >> 24) & 0x1F;

            const u32 r8 = (r << 2) | (r >> 4);
            const u32 g8 = (g << 2) | (g >> 4);
            const u32 b8 = (b << 2) | (b >> 4);
            const u32 a8 = (a << 3) | (a >> 2);

            dst[x] = b8 | (g8 << 8) | (r8 << 16) | (a8 << 24);
        }
    }

    [_threeDTexture replaceRegion:MTLRegionMake2D(0, 0, kScreenWidth, kScreenHeight)
                      mipmapLevel:0
                        withBytes:_threeDPixels.data()
                      bytesPerRow:kScreenWidth * sizeof(u32)];
}

void Renderer::Blit(const GPU& gpu)
{
    if (!_ready)
        return;

    // The frame being finished is the back buffer; the front one is still on
    // screen.
    const int backbuf = gpu.FrontBuffer ^ 1;
    const u32 *top = gpu.Framebuffer[backbuf][0].get();
    const u32 *bottom = gpu.Framebuffer[backbuf][1].get();
    if (top == nullptr || bottom == nullptr)
        return;

    [_layerTexture replaceRegion:MTLRegionMake2D(0, 0, kLayerStride, kScreenHeight)
                     mipmapLevel:0
                       withBytes:top
                     bytesPerRow:kLayerStride * sizeof(u32)];
    [_layerTexture replaceRegion:MTLRegionMake2D(0, kScreenHeight, kLayerStride, kScreenHeight)
                     mipmapLevel:0
                       withBytes:bottom
                     bytesPerRow:kLayerStride * sizeof(u32)];

    // Leave the texture the app may still be showing alone.
    const NSUInteger next = _frontIndex ^ 1;
    if (_lastCommandBuffer[next] != nil)
        [_lastCommandBuffer[next] waitUntilCompleted];

    const float w = (float) _width;
    const float h = (float) _height;
    const float screenHeight = (float) kScreenHeight;
    const CompositorVertex vertices[12] = {
        // Top screen: rows 0-191.
        { simd::make_float2(-1.0f,  1.0f), simd::make_float2(0.0f, 0.0f) },
        { simd::make_float2( 1.0f,  1.0f), simd::make_float2(w,    0.0f) },
        { simd::make_float2(-1.0f,  0.0f), simd::make_float2(0.0f, screenHeight) },
        { simd::make_float2( 1.0f,  1.0f), simd::make_float2(w,    0.0f) },
        { simd::make_float2( 1.0f,  0.0f), simd::make_float2(w,    screenHeight) },
        { simd::make_float2(-1.0f,  0.0f), simd::make_float2(0.0f, screenHeight) },

        // Bottom screen: rows 192-383.
        { simd::make_float2(-1.0f,  0.0f), simd::make_float2(0.0f, screenHeight) },
        { simd::make_float2( 1.0f,  0.0f), simd::make_float2(w,    screenHeight) },
        { simd::make_float2(-1.0f, -1.0f), simd::make_float2(0.0f, h) },
        { simd::make_float2( 1.0f,  0.0f), simd::make_float2(w,    screenHeight) },
        { simd::make_float2( 1.0f, -1.0f), simd::make_float2(w,    h) },
        { simd::make_float2(-1.0f, -1.0f), simd::make_float2(0.0f, h) },
    };

    CompositorUniforms uniforms { 1 };

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture     = _output[next];
    pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor  = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];

    [encoder setRenderPipelineState:_compositorPipeline];
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [encoder setFragmentTexture:_layerTexture atIndex:0];
    [encoder setFragmentTexture:_threeDTexture atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
    [encoder endEncoding];

    [commandBuffer commit];

    _lastCommandBuffer[next] = commandBuffer;
    _frontIndex = next;

    // The app displays this texture from its own queue, so the drawing has to
    // be finished before it is handed over.
    [commandBuffer waitUntilCompleted];
}

void Renderer::WaitForCompletion() noexcept
{
    for (int i = 0; i < 2; i++)
    {
        if (_lastCommandBuffer[i] != nil)
            [_lastCommandBuffer[i] waitUntilCompleted];
    }
}

void Renderer::PrepareCaptureFrame()
{
    // With the software rasteriser the 3D layer is already on the CPU, so
    // there is nothing to copy out of a texture here.
}

u32* Renderer::GetLine(int line)
{
    if (_software == nullptr || line < 0 || line >= (int) kScreenHeight)
        return kBlankLine;

    return _software->GetLine(line);
}

} // namespace MelonDSMetal
