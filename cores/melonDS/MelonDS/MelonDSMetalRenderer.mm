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
#import "MelonDSMetal3DShaders.h"

#include "GPU.h"
#include "GPU3D_Soft.h"

#include <algorithm>
#include <cmath>
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
    _compareThreeD = (mode != nullptr) && (strcmp(mode, "cmp") == 0);
    if (_compareThreeD)
        _softwareThreeD = false;

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
    threeD.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
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
    if (_rasterizer != nullptr)
        _rasterizer->Reset();
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
    {
        RenderSoftwareThreeD(gpu);
    }
    else
    {
        if (_rasterizer == nullptr)
            _rasterizer = std::make_unique<Rasterizer3D>(_device, _queue);

        if (_compareThreeD)
        {
            if (_software == nullptr)
            {
                _software = std::make_unique<SoftRenderer>();
                _software->Reset(gpu);
            }

            // The software rasteriser first, on the same polygon data, then
            // the Metal one, then diff the two colour buffers word for word.
            _software->RenderFrame(gpu);
            _rasterizer->Render(gpu, _threeDTexture);
            _rasterizer->CompareWithSoftware(*_software);
        }
        else
        {
            _rasterizer->Render(gpu, _threeDTexture);
        }
    }
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

// MARK: - The Metal 3D rasteriser
//
// The setup half, ported from melonDS's compute renderer (GPU3D_Compute.cpp):
// every polygon of the frame is turned into a list of vertical spans, and each
// line of a polygon points at the two spans its left and right edges are on.
// The shaders then walk those spans. Keeping this half on the CPU makes the
// shaders much simpler, and at 256x192 there is not much of it to do.

namespace
{

/// The number of lines a polygon can cover, times the polygon limit: melonDS
/// allows the same amount of span indices as its own renderer does.
constexpr u32 kMaxSpanIndices = 64 * 2048;

/// The span flags the shaders test, matching melonDS's.
constexpr u32 kXSpanSetup_Linear = 1U << 0;
constexpr u32 kXSpanSetup_FillInside = 1U << 1;
constexpr u32 kXSpanSetup_FillLeft = 1U << 2;
constexpr u32 kXSpanSetup_FillRight = 1U << 3;

/// The shift the span setup interpolates with. melonDS uses nine bits here
/// and eight in the rasteriser, because the setup is the more precise of the
/// two.
constexpr int kYFactorShift = 9;

s32 FindMSB(u32 value) noexcept
{
    return 31 - __builtin_clz(value);
}

/// Interpolation along a span. These are melonDS's (`InterpSpans` in
/// GPU3D_Compute_shaders.h) with the 32-bit division tricks written as plain
/// 64-bit arithmetic, which is what those tricks are a faster way of doing.
s32 InterpolateAttrPersp(s32 y0, s32 y1, s32 ifactor) noexcept
{
    if (y0 == y1)
        return y0;

    if (y0 < y1)
        return y0 + (s32) (((s64) (y1 - y0) * ifactor) >> kYFactorShift);

    return y1 + (s32) (((s64) (y0 - y1) * ((1 << kYFactorShift) - ifactor)) >> kYFactorShift);
}

s32 InterpolateAttrLinear(s32 y0, s32 y1, s32 i, s32 irecip, s32 idiff) noexcept
{
    if (y0 == y1)
        return y0;

    irecip = std::abs(irecip);

    u64 mul;
    if (y0 < y1)
        mul = (u64) (y1 - y0) * (u64) std::abs(i) * (u64) irecip;
    else
        mul = (u64) (y0 - y1) * (u64) std::abs(idiff - i) * (u64) irecip;

    mul += 3ULL << 24;

    if (y0 < y1)
        return y0 + (s32) (mul >> 30);

    return y1 + (s32) (mul >> 30);
}

u32 InterpolateZZBuffer(s32 z0, s32 z1, s32 i, s32 irecip, s32 idiff) noexcept
{
    if (z0 == z1)
        return (u32) z0;

    u32 base, disp, factor;
    if (z0 < z1)
    {
        base = (u32) z0;
        disp = (u32) (z1 - z0);
        factor = (u32) std::abs(i);
    }
    else
    {
        base = (u32) z1;
        disp = (u32) (z0 - z1);
        factor = (u32) std::abs(idiff - i);
    }

    s32 shiftl = 0;
    const s32 shiftr = 22;
    if (disp > 0x3FF)
    {
        shiftl = FindMSB(disp) - 9;
        disp >>= shiftl;
    }

    const u64 mul = (u64) (disp * factor) * (u64) (std::abs(irecip) >> 8);

    return base + (u32) ((mul >> shiftr) << shiftl);
}

s32 CalcYFactorY(const SpanSetupY& span, s32 i) noexcept
{
    const u32 numLo = (u32) std::abs(i) * (u32) span.W0n;
    const u32 numHi = numLo >> (32 - kYFactorShift);
    const u32 num = numLo << kYFactorShift;

    const u32 den = (u32) std::abs(i) * (u32) span.W0d
                  + (u32) std::abs(span.I1 - span.I0 - i) * (u32) span.W1d;

    if (den == 0)
        return 0;

    return (s32) ((((u64) numHi << 32) | num) / den);
}

s32 CalculateDx(s32 y, const SpanSetupY& span) noexcept
{
    return span.DxInitial + (y - span.Y0) * span.Increment;
}

s32 CalculateX(s32 dx, const SpanSetupY& span) noexcept
{
    s32 x = span.X0;
    if (span.X1 < span.X0)
        x -= dx >> 18;
    else
        x += dx >> 18;

    return std::clamp(x, span.XMin, span.XMax);
}

void EdgeParams_XMajor(bool side, s32 dx, const SpanSetupY& span, s32& edgelen, s32& edgecov) noexcept
{
    const bool negative = span.X1 < span.X0;
    s32 len;
    if (side != negative)
        len = (dx >> 18) - ((dx - span.Increment) >> 18);
    else
        len = ((dx + span.Increment) >> 18) - (dx >> 18);
    edgelen = len;

    const s32 xlen = span.XMax + 1 - span.XMin;
    s32 startx = dx >> 18;
    if (negative) startx = xlen - startx;
    if (side) startx = startx - len + 1;

    const s32 startcov = (s32) (((s64) ((startx << 10) + 0x1FF) * (span.Y1 - span.Y0)) / xlen);
    edgecov = (s32) ((1U << 31) | ((u32) (startcov & 0x3FF) << 12) | ((u32) span.XCovIncr & 0x3FF));
}

void EdgeParams_YMajor(bool side, s32 dx, const SpanSetupY& span, s32& edgelen, s32& edgecov) noexcept
{
    const bool negative = span.X1 < span.X0;
    edgelen = 1;

    if (span.Increment == 0)
    {
        edgecov = 31;
    }
    else
    {
        s32 cov = ((dx >> 9) + (span.Increment >> 10)) >> 4;
        if ((cov >> 5) != (dx >> 18)) cov = 31;
        cov &= 0x1F;
        if (side == negative) cov = 0x1F - cov;

        edgecov = cov;
    }
}

/// The rasterise mode for a variant, mirroring how melonDS's own renderer
/// picks its shader: 0 draws vertex colours, 1 multiplies them with the
/// texture, 2 pastes an opaque texture over them, 3 and 4 run them through the
/// toon table, and 5 records only depth for a shadow mask.
uint32_t RasterModeForVariant(u8 blendMode, bool textured, bool highLightMode) noexcept
{
    if (blendMode == 4)
        return 5;
    if (!textured)
        return (blendMode == 2) ? (highLightMode ? 4 : 3) : 0;
    switch (blendMode)
    {
    case 0: return 1;
    case 1: return 2;
    case 2: return highLightMode ? 4 : 3;
    default: return 2;
    }
}

} // namespace

Rasterizer3D::Rasterizer3D(id<MTLDevice> device, id<MTLCommandQueue> queue) noexcept
    : _device(device),
      _queue(queue),
      _texcache(TexcacheLoader(device)),
      _ready(false)
{
    if (_device == nil || _queue == nil)
    {
        NSLog(@"[melonDS] rasteriser: no device or queue");
        return;
    }

    NSError *error = nil;
    _library = [_device newLibraryWithSource:@(kMelonDSMetal3DSource) options:nil error:&error];
    if (_library == nil)
    {
        NSLog(@"[melonDS] could not build the Metal 3D shaders: %@", error);
        return;
    }

    _clearPipeline = [_device newComputePipelineStateWithFunction:[_library newFunctionWithName:@"melonds_3d_clear"]
                                                           error:&error];
    _rasterisePipeline = [_device newComputePipelineStateWithFunction:[_library newFunctionWithName:@"melonds_rasterise"]
                                                               error:&error];
    _finalPipeline = [_device newComputePipelineStateWithFunction:[_library newFunctionWithName:@"melonds_3d_final"]
                                                           error:&error];
    _outputPipeline = [_device newComputePipelineStateWithFunction:[_library newFunctionWithName:@"melonds_3d_output"]
                                                            error:&error];

    if (_clearPipeline == nil || _rasterisePipeline == nil || _finalPipeline == nil || _outputPipeline == nil)
    {
        NSLog(@"[melonDS] could not build the Metal 3D pipelines: %@", error);
        return;
    }

    _ySpanSetups = [_device newBufferWithLength:sizeof(SpanSetupY) * MaxYSpanSetups
                                       options:MTLResourceStorageModeShared];
    _xSpanSetups = [_device newBufferWithLength:sizeof(SpanSetupX) * kMaxSpanIndices
                                       options:MTLResourceStorageModeShared];
    _yspanIndices = [_device newBufferWithLength:sizeof(SetupIndices) * kMaxSpanIndices
                                         options:MTLResourceStorageModeShared];
    _renderPolygons = [_device newBufferWithLength:sizeof(RenderPolygon) * MaxPolygons
                                           options:MTLResourceStorageModeShared];
    _metaUniform = [_device newBufferWithLength:sizeof(MetaUniform)
                                        options:MTLResourceStorageModeShared];
    _linePolyOffsets = [_device newBufferWithLength:sizeof(u32) * (kScreenHeight + 1)
                                            options:MTLResourceStorageModeShared];
    _linePolyIndices = [_device newBufferWithLength:sizeof(u32) * MaxSpanIndices
                                             options:MTLResourceStorageModeShared];

    // Bound when a variant uses no texture, so there is always something to
    // sample from. It is never actually read.
    MTLTextureDescriptor* dummyDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Uint
                                                           width:8
                                                          height:8
                                                       mipmapped:NO];
    dummyDesc.textureType = MTLTextureType2DArray;
    dummyDesc.arrayLength = 1;
    dummyDesc.usage = MTLTextureUsageShaderRead;
    dummyDesc.storageMode = MTLStorageModeShared;
    _dummyTexture = [_device newTextureWithDescriptor:dummyDesc];

    const NSUInteger layerBytes = kScreenWidth * kScreenHeight * sizeof(u32);
    _colorBuffer = [_device newBufferWithLength:layerBytes options:MTLResourceStorageModeShared];
    _depthBuffer = [_device newBufferWithLength:layerBytes options:MTLResourceStorageModeShared];
    _attrBuffer = [_device newBufferWithLength:layerBytes options:MTLResourceStorageModeShared];
    _colorBufferB = [_device newBufferWithLength:layerBytes options:MTLResourceStorageModeShared];
    _depthBufferB = [_device newBufferWithLength:layerBytes options:MTLResourceStorageModeShared];
    _attrBufferB = [_device newBufferWithLength:layerBytes options:MTLResourceStorageModeShared];

    if (_ySpanSetups == nil || _xSpanSetups == nil || _yspanIndices == nil
        || _renderPolygons == nil || _metaUniform == nil
        || _linePolyOffsets == nil || _linePolyIndices == nil || _dummyTexture == nil
        || _colorBuffer == nil || _depthBuffer == nil || _attrBuffer == nil
        || _colorBufferB == nil || _depthBufferB == nil || _attrBufferB == nil)
    {
        NSLog(@"[melonDS] rasteriser: could not create its buffers");
        return;
    }

    _spans.resize(MaxYSpanSetups);
    _xSpans.resize(kMaxSpanIndices);
    _spanIndices.resize(kMaxSpanIndices);
    _polygons.resize(MaxPolygons);
    _linePolyIndicesCPU.resize(MaxSpanIndices);
    _toonTable.resize(4 * 34);

    _ready = true;
}

Rasterizer3D::~Rasterizer3D() noexcept
{
}

void Rasterizer3D::SetupAttrs(SpanSetupY* span, Polygon* poly, int from, int to) noexcept
{
    span->Z0 = poly->FinalZ[from];
    span->W0 = poly->FinalW[from];
    span->Z1 = poly->FinalZ[to];
    span->W1 = poly->FinalW[to];
    span->ColorR0 = poly->Vertices[from]->FinalColor[0];
    span->ColorG0 = poly->Vertices[from]->FinalColor[1];
    span->ColorB0 = poly->Vertices[from]->FinalColor[2];
    span->ColorR1 = poly->Vertices[to]->FinalColor[0];
    span->ColorG1 = poly->Vertices[to]->FinalColor[1];
    span->ColorB1 = poly->Vertices[to]->FinalColor[2];
    span->TexcoordU0 = poly->Vertices[from]->TexCoords[0];
    span->TexcoordV0 = poly->Vertices[from]->TexCoords[1];
    span->TexcoordU1 = poly->Vertices[to]->TexCoords[0];
    span->TexcoordV1 = poly->Vertices[to]->TexCoords[1];
}

void Rasterizer3D::SetupYSpanDummy(RenderPolygon* rp, SpanSetupY* span, Polygon* poly, int vertex, int side, s32 positions[10][2]) noexcept
{
    s32 x0 = positions[vertex][0];
    if (side)
    {
        span->DxInitial = -0x40000;
        x0--;
    }
    else
    {
        span->DxInitial = 0;
    }

    span->X0 = span->X1 = x0;
    span->XMin = x0;
    span->XMax = x0;
    span->Y0 = span->Y1 = positions[vertex][1];

    if (span->XMin < rp->XMin)
    {
        rp->XMin = span->XMin;
        rp->XMinY = span->Y0;
    }
    if (span->XMax > rp->XMax)
    {
        rp->XMax = span->XMax;
        rp->XMaxY = span->Y0;
    }

    span->Increment = 0;

    span->I0 = span->I1 = span->IRecip = 0;
    span->Linear = true;

    span->XCovIncr = 0;

    span->IsDummy = true;

    SetupAttrs(span, poly, vertex, vertex);
}

void Rasterizer3D::SetupYSpan(RenderPolygon* rp, SpanSetupY* span, Polygon* poly, int from, int to, int side, s32 positions[10][2]) noexcept
{
    span->X0 = positions[from][0];
    span->X1 = positions[to][0];
    span->Y0 = positions[from][1];
    span->Y1 = positions[to][1];

    SetupAttrs(span, poly, from, to);

    s32 minXY, maxXY;
    bool negative = false;
    if (span->X1 > span->X0)
    {
        span->XMin = span->X0;
        span->XMax = span->X1-1;

        minXY = span->Y0;
        maxXY = span->Y1;
    }
    else if (span->X1 < span->X0)
    {
        span->XMin = span->X1;
        span->XMax = span->X0-1;
        negative = true;

        minXY = span->Y1;
        maxXY = span->Y0;
    }
    else
    {
        span->XMin = span->X0;
        if (side) span->XMin--;
        span->XMax = span->XMin;

        // doesn't matter for completely vertical slope
        minXY = span->Y0;
        maxXY = span->Y0;
    }

    if (span->XMin < rp->XMin)
    {
        rp->XMin = span->XMin;
        rp->XMinY = minXY;
    }
    if (span->XMax > rp->XMax)
    {
        rp->XMax = span->XMax;
        rp->XMaxY = maxXY;
    }

    span->IsDummy = false;

    s32 xlen = span->XMax+1 - span->XMin;
    s32 ylen = span->Y1 - span->Y0;

    // slope increment has a 18-bit fractional part
    // note: for some reason, x/y isn't calculated directly,
    // instead, 1/y is calculated and then multiplied by x
    if (ylen == 0)
    {
        span->Increment = 0;
    }
    else if (ylen == xlen)
    {
        span->Increment = 0x40000;
    }
    else
    {
        s32 yrecip = (1<<18) / ylen;
        span->Increment = (span->X1-span->X0) * yrecip;
        if (span->Increment < 0) span->Increment = -span->Increment;
    }

    bool xMajor = (span->Increment > 0x40000);

    if (side)
    {
        // right

        if (xMajor)
            span->DxInitial = negative ? (0x20000 + 0x40000) : (span->Increment - 0x20000);
        else if (span->Increment != 0)
            span->DxInitial = negative ? 0x40000 : 0;
        else
            span->DxInitial = -0x40000;
    }
    else
    {
        // left

        if (xMajor)
            span->DxInitial = negative ? ((span->Increment - 0x20000) + 0x40000) : 0x20000;
        else if (span->Increment != 0)
            span->DxInitial = negative ? 0x40000 : 0;
        else
            span->DxInitial = 0;
    }

    if (xMajor)
    {
        if (side)
        {
            span->I0 = span->X0 - 1;
            span->I1 = span->X1 - 1;
        }
        else
        {
            span->I0 = span->X0;
            span->I1 = span->X1;
        }

        // used for calculating AA coverage
        span->XCovIncr = (ylen << 10) / xlen;
    }
    else
    {
        span->I0 = span->Y0;
        span->I1 = span->Y1;

        span->XCovIncr = 0;
    }

    if (span->I0 == span->I1)
    {
        span->Linear = true;
        span->IRecip = 0;
        span->W0n = span->W0d = span->W1d = 0;
    }
    else if (span->W0 == span->W1)
    {
        span->Linear = true;

        span->W0n = 0;
        span->W0d = 1;
        span->W1d = 1;

        span->IRecip = (1<<30) / (span->I1 - span->I0);
    }
    else
    {
        span->Linear = false;

        span->W0n = span->W0;
        span->W0d = span->W0;
        span->W1d = span->W1;

        s32 num = span->W1 - span->W0;
        s32 den = span->W1 * (span->I1 - span->I0);
        span->IRecip = (1<<30) / (den / num);
    }
}

void Rasterizer3D::SetupXSpan(SpanSetupX* xspan, const SpanSetupY& spanLIn, const SpanSetupY& spanRIn, u32 polyIdx, int y, u32 dispCnt) noexcept
{
    // Upstream copies the spans here and swaps the copies when the edges cross;
    // the spans in the buffer must not be touched, because the lines below this
    // one are still set up from them.
    SpanSetupY spanL = spanLIn;
    SpanSetupY spanR = spanRIn;

    xspan->Flags = 0;

    const s32 dxl = CalculateDx(y, spanL);
    const s32 dxr = CalculateDx(y, spanR);

    s32 xl = CalculateX(dxl, spanL);
    s32 xr = CalculateX(dxr, spanR);

    const RenderPolygon& polygon = _polygons[polyIdx];

    s32 edgeLenL, edgeLenR;

    if (xl > xr)
    {
        std::swap(spanL, spanR);
        std::swap(xl, xr);

        EdgeParams_YMajor(false, dxr, spanL, edgeLenL, xspan->EdgeCovL);
        EdgeParams_YMajor(true, dxl, spanR, edgeLenR, xspan->EdgeCovR);
    }
    else
    {
        // edges are the right way
        if (spanL.Increment > 0x40000)
            EdgeParams_XMajor(false, dxl, spanL, edgeLenL, xspan->EdgeCovL);
        else
            EdgeParams_YMajor(false, dxl, spanL, edgeLenL, xspan->EdgeCovL);

        if (spanR.Increment > 0x40000)
            EdgeParams_XMajor(true, dxr, spanR, edgeLenR, xspan->EdgeCovR);
        else
            EdgeParams_YMajor(true, dxr, spanR, edgeLenR, xspan->EdgeCovR);
    }

    xspan->CovLInitial = (xspan->EdgeCovL >> 12) & 0x3FF;
    if (xspan->CovLInitial == 0x3FF)
        xspan->CovLInitial = 0;
    xspan->CovRInitial = (xspan->EdgeCovR >> 12) & 0x3FF;
    if (xspan->CovRInitial == 0x3FF)
        xspan->CovRInitial = 0;

    xspan->X0 = xl;
    xspan->X1 = xr + 1;

    const u32 polyalpha = (polygon.Attr >> 16) & 0x1FU;
    const bool isWireframe = polyalpha == 0U;

    if (!isWireframe || (y == polygon.YTop || y == polygon.YBot - 1))
        xspan->Flags |= kXSpanSetup_FillInside;

    xspan->InsideStart = xspan->X0 + edgeLenL;
    if (xspan->InsideStart > xspan->X1)
        xspan->InsideStart = xspan->X1;
    xspan->InsideEnd = xspan->X1 - edgeLenR;
    if (xspan->InsideEnd > xspan->X1)
        xspan->InsideEnd = xspan->X1;

    const bool fillAllEdges = polyalpha < 31 || (dispCnt & (3U << 4)) != 0U;

    if (fillAllEdges || spanL.X1 < spanL.X0 || spanL.Increment <= 0x40000)
        xspan->Flags |= kXSpanSetup_FillLeft;
    if (fillAllEdges || (spanR.X1 >= spanR.X0 && spanR.Increment > 0x40000) || spanR.Increment == 0)
        xspan->Flags |= kXSpanSetup_FillRight;

    if (spanL.I0 == spanL.I1)
    {
        xspan->TexcoordU0 = spanL.TexcoordU0;
        xspan->TexcoordV0 = spanL.TexcoordV0;
        xspan->ColorR0 = spanL.ColorR0;
        xspan->ColorG0 = spanL.ColorG0;
        xspan->ColorB0 = spanL.ColorB0;
        xspan->Z0 = spanL.Z0;
        xspan->W0 = spanL.W0;
    }
    else
    {
        const s32 i = (spanL.Increment > 0x40000 ? xl : y) - spanL.I0;
        const s32 ifactor = CalcYFactorY(spanL, i);
        const s32 idiff = spanL.I1 - spanL.I0;

        xspan->Z0 = (s32) InterpolateZZBuffer(spanL.Z0, spanL.Z1, i, spanL.IRecip, idiff);

        if (!spanL.Linear)
        {
            xspan->TexcoordU0 = InterpolateAttrPersp(spanL.TexcoordU0, spanL.TexcoordU1, ifactor);
            xspan->TexcoordV0 = InterpolateAttrPersp(spanL.TexcoordV0, spanL.TexcoordV1, ifactor);

            xspan->ColorR0 = InterpolateAttrPersp(spanL.ColorR0, spanL.ColorR1, ifactor);
            xspan->ColorG0 = InterpolateAttrPersp(spanL.ColorG0, spanL.ColorG1, ifactor);
            xspan->ColorB0 = InterpolateAttrPersp(spanL.ColorB0, spanL.ColorB1, ifactor);

            xspan->W0 = InterpolateAttrPersp(spanL.W0, spanL.W1, ifactor);
        }
        else
        {
            xspan->TexcoordU0 = InterpolateAttrLinear(spanL.TexcoordU0, spanL.TexcoordU1, i, spanL.IRecip, idiff);
            xspan->TexcoordV0 = InterpolateAttrLinear(spanL.TexcoordV0, spanL.TexcoordV1, i, spanL.IRecip, idiff);

            xspan->ColorR0 = InterpolateAttrLinear(spanL.ColorR0, spanL.ColorR1, i, spanL.IRecip, idiff);
            xspan->ColorG0 = InterpolateAttrLinear(spanL.ColorG0, spanL.ColorG1, i, spanL.IRecip, idiff);
            xspan->ColorB0 = InterpolateAttrLinear(spanL.ColorB0, spanL.ColorB1, i, spanL.IRecip, idiff);

            xspan->W0 = spanL.W0; // linear mode is only taken if W0 == W1
        }
    }

    if (spanR.I0 == spanR.I1)
    {
        xspan->TexcoordU1 = spanR.TexcoordU0;
        xspan->TexcoordV1 = spanR.TexcoordV0;
        xspan->ColorR1 = spanR.ColorR0;
        xspan->ColorG1 = spanR.ColorG0;
        xspan->ColorB1 = spanR.ColorB0;
        xspan->Z1 = spanR.Z0;
        xspan->W1 = spanR.W0;
    }
    else
    {
        const s32 i = (spanR.Increment > 0x40000 ? xr : y) - spanR.I0;
        const s32 ifactor = CalcYFactorY(spanR, i);
        const s32 idiff = spanR.I1 - spanR.I0;

        xspan->Z1 = (s32) InterpolateZZBuffer(spanR.Z0, spanR.Z1, i, spanR.IRecip, idiff);

        if (!spanR.Linear)
        {
            xspan->TexcoordU1 = InterpolateAttrPersp(spanR.TexcoordU0, spanR.TexcoordU1, ifactor);
            xspan->TexcoordV1 = InterpolateAttrPersp(spanR.TexcoordV0, spanR.TexcoordV1, ifactor);

            xspan->ColorR1 = InterpolateAttrPersp(spanR.ColorR0, spanR.ColorR1, ifactor);
            xspan->ColorG1 = InterpolateAttrPersp(spanR.ColorG0, spanR.ColorG1, ifactor);
            xspan->ColorB1 = InterpolateAttrPersp(spanR.ColorB0, spanR.ColorB1, ifactor);

            xspan->W1 = InterpolateAttrPersp(spanR.W0, spanR.W1, ifactor);
        }
        else
        {
            xspan->TexcoordU1 = InterpolateAttrLinear(spanR.TexcoordU0, spanR.TexcoordU1, i, spanR.IRecip, idiff);
            xspan->TexcoordV1 = InterpolateAttrLinear(spanR.TexcoordV0, spanR.TexcoordV1, i, spanR.IRecip, idiff);

            xspan->ColorR1 = InterpolateAttrLinear(spanR.ColorR0, spanR.ColorR1, i, spanR.IRecip, idiff);
            xspan->ColorG1 = InterpolateAttrLinear(spanR.ColorG0, spanR.ColorG1, i, spanR.IRecip, idiff);
            xspan->ColorB1 = InterpolateAttrLinear(spanR.ColorB0, spanR.ColorB1, i, spanR.IRecip, idiff);

            xspan->W1 = spanR.W0;
        }
    }

    if (xspan->W0 == xspan->W1 && ((xspan->W0 | xspan->W1) & 0x7F) == 0)
        xspan->Flags |= kXSpanSetup_Linear;

    xspan->XRecip = (s32) (((u64) 1 << 30) / (u32) (xspan->X1 - xspan->X0));
}

void Rasterizer3D::SetupFrame(GPU& gpu) noexcept
{
    const int screenWidth = 256;
    const int screenHeight = 192;
    const u32 dispCnt = gpu.GPU3D.RenderDispCnt;

    // Drop textures whose VRAM changed before looking any of them up.
    _texcache.Update(gpu);

    u32 numSpans = 0;
    u32 numSpanIndices = 0;
    u32 numSetupPolygons = 0;

    // Polygons that share a texture, sampler and blend mode are drawn in one
    // dispatch. This grouping is melonDS's own.
    // The frame's texture table: one slot per array texture the frame's
    // polygons sample, so one dispatch can draw the whole frame.
    __strong id<MTLTexture> textureSlots[MaxTextureSlots];
    u32 numTextureSlots = 0;

    const bool enableTextureMaps = (gpu.GPU3D.RenderDispCnt & (1 << 0)) != 0;
    _highLightMode = (gpu.GPU3D.RenderDispCnt & (1 << 1)) != 0;

    for (u32 i = 0; i < (u32) gpu.GPU3D.RenderNumPolygons; i++)
    {
        // A frame cannot hold more spans than melonDS allows, but a broken
        // frame should not run off the end of the buffers either.
        if (numSpans + 400 > MaxYSpanSetups || numSpanIndices + 200 > kMaxSpanIndices)
            break;

        numSetupPolygons = i + 1;

        Polygon* polygon = gpu.GPU3D.RenderPolygonRAM[i];

        u32 nverts = polygon->NumVertices;
        u32 vtop = polygon->VTop, vbot = polygon->VBottom;

        u32 curVL = vtop, curVR = vtop;
        u32 nextVL, nextVR;

        RenderPolygon& rp = _polygons[i];
        rp.FirstXSpan = numSpanIndices;
        rp.Attr = polygon->Attr | (polygon->FacingView ? (1U << 6) : 0U);

        // Each polygon carries its own texture state, so one dispatch draws
        // the whole frame in submission order.
        rp.Variant = 0;
        rp.TextureLayer = 0.0f;
        rp.TexSlot = 0;
        rp.TexWrap = 0;
        rp.TexWidth = 8;
        rp.TexHeight = 8;
        rp.WBuffer = polygon->WBuffer ? 1 : 0;

        const u8 blendMode = polygon->IsShadowMask ? 4 : ((polygon->Attr >> 4) & 0x3);
        rp.TexMode = RasterModeForVariant(blendMode, false, _highLightMode);

        if (enableTextureMaps && (polygon->TexParam >> 26) & 0x7)
        {
            __strong id<MTLTexture> handle = nil;
            u32 texLayer = 0;
            u32* textureLastVariant = nullptr;
            _texcache.GetTexture(gpu, polygon->TexParam, polygon->TexPalette,
                                 handle, texLayer, textureLastVariant);
            if (handle != nil)
            {
                u32 slot = 0;
                for (; slot < numTextureSlots; slot++)
                {
                    if (textureSlots[slot] == handle)
                        break;
                }
                if (slot >= numTextureSlots)
                {
                    if (numTextureSlots >= MaxTextureSlots)
                    {
                        NSLog(@"[melonDS] rasteriser: frame uses more texture tables than fit");
                    }
                    else
                    {
                        slot = numTextureSlots;
                        textureSlots[numTextureSlots++] = handle;
                    }
                }

                bool wrapS = (polygon->TexParam >> 16) & 1;
                bool wrapT = (polygon->TexParam >> 17) & 1;
                bool mirrorS = (polygon->TexParam >> 18) & 1;
                bool mirrorT = (polygon->TexParam >> 19) & 1;

                rp.TexSlot = slot;
                rp.TexMode = RasterModeForVariant(blendMode, true, _highLightMode);
                rp.TexWrap = (wrapS ? (mirrorS ? 2 : 1) : 0) + (wrapT ? (mirrorT ? 2 : 1) : 0) * 3;
                rp.TexWidth = TextureWidth(polygon->TexParam);
                rp.TexHeight = TextureHeight(polygon->TexParam);
                rp.TextureLayer = (float) texLayer;
            }
        }

        if (polygon->FacingView)
        {
            nextVL = curVL + 1;
            if (nextVL >= nverts) nextVL = 0;
            nextVR = curVR - 1;
            if ((s32)nextVR < 0) nextVR = nverts - 1;
        }
        else
        {
            nextVL = curVL - 1;
            if ((s32)nextVL < 0) nextVL = nverts - 1;
            nextVR = curVR + 1;
            if (nextVR >= nverts) nextVR = 0;
        }

        s32 scaledPositions[10][2];
        s32 ytop = screenHeight, ybot = 0;
        for (u32 v = 0; v < nverts; v++)
        {
            scaledPositions[v][0] = polygon->Vertices[v]->FinalPosition[0];
            scaledPositions[v][1] = polygon->Vertices[v]->FinalPosition[1];
            ytop = std::min(scaledPositions[v][1], ytop);
            ybot = std::max(scaledPositions[v][1], ybot);
        }
        rp.YTop = ytop;
        rp.YBot = ybot;
        rp.XMin = screenWidth;
        rp.XMax = 0;

        if (ybot == ytop)
        {
            vtop = 0; vbot = 0;

            rp.YBot++;

            u32 j = 1;
            if (scaledPositions[j][0] < scaledPositions[vtop][0]) vtop = j;
            if (scaledPositions[j][0] > scaledPositions[vbot][0]) vbot = j;

            j = nverts - 1;
            if (scaledPositions[j][0] < scaledPositions[vtop][0]) vtop = j;
            if (scaledPositions[j][0] > scaledPositions[vbot][0]) vbot = j;

            u32 curSpanL = numSpans;
            SetupYSpanDummy(&rp, &_spans[numSpans++], polygon, vtop, 0, scaledPositions);
            u32 curSpanR = numSpans;
            SetupYSpanDummy(&rp, &_spans[numSpans++], polygon, vbot, 1, scaledPositions);

            _spanIndices[numSpanIndices].PolyIdx = i;
            _spanIndices[numSpanIndices].SpanIdxL = curSpanL;
            _spanIndices[numSpanIndices].SpanIdxR = curSpanR;
            _spanIndices[numSpanIndices].Y = ytop;
            SetupXSpan(&_xSpans[numSpanIndices], _spans[curSpanL], _spans[curSpanR], i, ytop, dispCnt);
            numSpanIndices++;
        }
        else
        {
            u32 curSpanL = numSpans;
            SetupYSpan(&rp, &_spans[numSpans++], polygon, curVL, nextVL, 0, scaledPositions);
            u32 curSpanR = numSpans;
            SetupYSpan(&rp, &_spans[numSpans++], polygon, curVR, nextVR, 1, scaledPositions);

            for (s32 y = ytop; y < ybot; y++)
            {
                if (y >= scaledPositions[nextVL][1] && curVL != polygon->VBottom)
                {
                    while (y >= scaledPositions[nextVL][1] && curVL != polygon->VBottom)
                    {
                        curVL = nextVL;
                        if (polygon->FacingView)
                        {
                            nextVL = curVL + 1;
                            if (nextVL >= nverts)
                                nextVL = 0;
                        }
                        else
                        {
                            nextVL = curVL - 1;
                            if ((s32)nextVL < 0)
                                nextVL = nverts - 1;
                        }
                    }

                    curSpanL = numSpans;
                    SetupYSpan(&rp, &_spans[numSpans++], polygon, curVL, nextVL, 0, scaledPositions);
                }
                if (y >= scaledPositions[nextVR][1] && curVR != polygon->VBottom)
                {
                    while (y >= scaledPositions[nextVR][1] && curVR != polygon->VBottom)
                    {
                        curVR = nextVR;
                        if (polygon->FacingView)
                        {
                            nextVR = curVR - 1;
                            if ((s32)nextVR < 0)
                                nextVR = nverts - 1;
                        }
                        else
                        {
                            nextVR = curVR + 1;
                            if (nextVR >= nverts)
                                nextVR = 0;
                        }
                    }

                    curSpanR = numSpans;
                    SetupYSpan(&rp, &_spans[numSpans++], polygon, curVR, nextVR, 1, scaledPositions);
                }

                _spanIndices[numSpanIndices].PolyIdx = i;
                _spanIndices[numSpanIndices].SpanIdxL = curSpanL;
                _spanIndices[numSpanIndices].SpanIdxR = curSpanR;
                _spanIndices[numSpanIndices].Y = y;
                SetupXSpan(&_xSpans[numSpanIndices], _spans[curSpanL], _spans[curSpanR], i, y, dispCnt);
                numSpanIndices++;
            }
        }
    }

    _numSpans = numSpans;
    _numSpanIndices = numSpanIndices;
    _numPolygons = (u32) gpu.GPU3D.RenderNumPolygons;

    for (u32 s = 0; s < numTextureSlots; s++)
        _textureSlots[s] = textureSlots[s];
    _numTextureSlots = numTextureSlots;


    if (numSpans == 0)
        return;

    memcpy(_ySpanSetups.contents, _spans.data(), sizeof(SpanSetupY) * numSpans);
    memcpy(_xSpanSetups.contents, _xSpans.data(), sizeof(SpanSetupX) * numSpanIndices);
    memcpy(_yspanIndices.contents, _spanIndices.data(), sizeof(SetupIndices) * numSpanIndices);
    memcpy(_renderPolygons.contents, _polygons.data(), sizeof(RenderPolygon) * _numPolygons);

    // Bin the polygons that were set up per scanline, in submission order, so
    // the shader walks only the polygons that touch its line. Every line of a
    // polygon got one span index, so the lists hold exactly numSpanIndices
    // entries between them and always fit.
    u32 lineOffsets[kScreenHeight + 1] = {};
    for (u32 i = 0; i < numSetupPolygons; i++)
    {
        const s32 y0 = std::max(_polygons[i].YTop, 0);
        const s32 y1 = std::min(_polygons[i].YBot, (s32) kScreenHeight);
        for (s32 y = y0; y < y1; y++)
            lineOffsets[y + 1]++;
    }
    for (int y = 0; y < (int) kScreenHeight; y++)
        lineOffsets[y + 1] += lineOffsets[y];

    // The second pass visits the polygons in the same order, so every line's
    // list stays in submission order.
    u32 lineCursors[kScreenHeight] = {};
    for (u32 i = 0; i < numSetupPolygons; i++)
    {
        const s32 y0 = std::max(_polygons[i].YTop, 0);
        const s32 y1 = std::min(_polygons[i].YBot, (s32) kScreenHeight);
        for (s32 y = y0; y < y1; y++)
            _linePolyIndicesCPU[lineOffsets[y] + lineCursors[y]++] = i;
    }

    memcpy(_linePolyOffsets.contents, lineOffsets, sizeof(lineOffsets));
    memcpy(_linePolyIndices.contents, _linePolyIndicesCPU.data(),
           sizeof(u32) * lineOffsets[kScreenHeight]);

    MetaUniform meta {};
    meta.DispCnt = gpu.GPU3D.RenderDispCnt;
    meta.NumPolygons = gpu.GPU3D.RenderNumPolygons;
    meta.AlphaRef = gpu.GPU3D.RenderAlphaRef;
    {
        u32 r = (gpu.GPU3D.RenderClearAttr1 << 1) & 0x3E; if (r) r++;
        u32 g = (gpu.GPU3D.RenderClearAttr1 >> 4) & 0x3E; if (g) g++;
        u32 b = (gpu.GPU3D.RenderClearAttr1 >> 9) & 0x3E; if (b) b++;
        u32 a = (gpu.GPU3D.RenderClearAttr1 >> 16) & 0x1F;
        meta.ClearColor = r | (g << 8) | (b << 16) | (a << 24);
        meta.ClearDepth = ((gpu.GPU3D.RenderClearAttr2 & 0x7FFF) * 0x200) + 0x1FF;
        meta.ClearAttr = gpu.GPU3D.RenderClearAttr1 & 0x3F008000;
    }
    for (u32 i = 0; i < 32; i++)
    {
        u32 color = gpu.GPU3D.RenderToonTable[i];
        u32 r = (color << 1) & 0x3E;
        u32 g = (color >> 4) & 0x3E;
        u32 b = (color >> 9) & 0x3E;
        if (r) r++;
        if (g) g++;
        if (b) b++;

        meta.ToonTable[i*4+0] = r | (g << 8) | (b << 16);
    }
    for (u32 i = 0; i < 34; i++)
    {
        meta.ToonTable[i*4+1] = gpu.GPU3D.RenderFogDensityTable[i];
    }
    for (u32 i = 0; i < 8; i++)
    {
        u32 color = gpu.GPU3D.RenderEdgeTable[i];
        u32 r = (color << 1) & 0x3E;
        u32 g = (color >> 4) & 0x3E;
        u32 b = (color >> 9) & 0x3E;
        if (r) r++;
        if (g) g++;
        if (b) b++;

        meta.ToonTable[i*4+2] = r | (g << 8) | (b << 16);
    }
    meta.FogOffset = gpu.GPU3D.RenderFogOffset;
    meta.FogShift = gpu.GPU3D.RenderFogShift;
    {
        u32 fogR = (gpu.GPU3D.RenderFogColor << 1) & 0x3E; if (fogR) fogR++;
        u32 fogG = (gpu.GPU3D.RenderFogColor >> 4) & 0x3E; if (fogG) fogG++;
        u32 fogB = (gpu.GPU3D.RenderFogColor >> 9) & 0x3E; if (fogB) fogB++;
        u32 fogA = (gpu.GPU3D.RenderFogColor >> 16) & 0x1F;
        meta.FogColor = fogR | (fogG << 8) | (fogB << 16) | (fogA << 24);
    }

    memcpy(_metaUniform.contents, &meta, sizeof(meta));

}

void Rasterizer3D::Render(GPU& gpu, id<MTLTexture> output) noexcept
{
    if (!_ready)
        return;

    SetupFrame(gpu);

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    const MTLSize layer = MTLSizeMake(kScreenWidth, kScreenHeight, 1);
    const MTLSize group = MTLSizeMake(8, 8, 1);

    {
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:_clearPipeline];
        [encoder setBuffer:_metaUniform offset:0 atIndex:0];
        [encoder setBuffer:_colorBuffer offset:0 atIndex:1];
        [encoder setBuffer:_depthBuffer offset:0 atIndex:2];
        [encoder setBuffer:_attrBuffer offset:0 atIndex:3];
        [encoder setBuffer:_colorBufferB offset:0 atIndex:4];
        [encoder setBuffer:_depthBufferB offset:0 atIndex:5];
        [encoder setBuffer:_attrBufferB offset:0 atIndex:6];
        [encoder dispatchThreads:layer threadsPerThreadgroup:group];
        [encoder endEncoding];
    }

    if (_numPolygons > 0)
    {
        // One dispatch draws the whole frame in submission order, the way the
        // software rasteriser does: each pixel walks only the polygons that
        // touch its line, and each polygon samples its own texture slot.
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:_rasterisePipeline];
        [encoder setBuffer:_renderPolygons offset:0 atIndex:0];
        [encoder setBuffer:_xSpanSetups offset:0 atIndex:1];
        [encoder setBuffer:_metaUniform offset:0 atIndex:2];
        [encoder setBuffer:_colorBuffer offset:0 atIndex:3];
        [encoder setBuffer:_depthBuffer offset:0 atIndex:4];
        [encoder setBuffer:_attrBuffer offset:0 atIndex:5];
        [encoder setBuffer:_linePolyOffsets offset:0 atIndex:6];
        [encoder setBuffer:_linePolyIndices offset:0 atIndex:7];
        [encoder setBuffer:_colorBufferB offset:0 atIndex:8];
        [encoder setBuffer:_depthBufferB offset:0 atIndex:9];
        [encoder setBuffer:_attrBufferB offset:0 atIndex:10];

        id<MTLTexture> textures[MaxTextureSlots];
        for (u32 s = 0; s < MaxTextureSlots; s++)
            textures[s] = (s < _numTextureSlots && _textureSlots[s] != nil) ? _textureSlots[s] : _dummyTexture;
        [encoder setTextures:textures withRange:NSMakeRange(0, MaxTextureSlots)];

        [encoder dispatchThreads:layer threadsPerThreadgroup:group];
        [encoder endEncoding];
    }

    {
        // Edge marking and fog, over the drawn polygons.
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:_finalPipeline];
        [encoder setBuffer:_metaUniform offset:0 atIndex:0];
        [encoder setBuffer:_colorBuffer offset:0 atIndex:1];
        [encoder setBuffer:_depthBuffer offset:0 atIndex:2];
        [encoder setBuffer:_attrBuffer offset:0 atIndex:3];
        [encoder setBuffer:_colorBufferB offset:0 atIndex:4];
        [encoder setBuffer:_depthBufferB offset:0 atIndex:5];
        [encoder setBuffer:_attrBufferB offset:0 atIndex:6];
        [encoder dispatchThreads:layer threadsPerThreadgroup:group];
        [encoder endEncoding];
    }

    {
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:_outputPipeline];
        [encoder setBuffer:_colorBuffer offset:0 atIndex:0];
        [encoder setTexture:output atIndex:0];
        [encoder dispatchThreads:layer threadsPerThreadgroup:group];
        [encoder endEncoding];
    }

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
}

void Rasterizer3D::CompareWithSoftware(SoftRenderer& software) noexcept
{
    const u32* mine = (const u32*) _colorBuffer.contents;

    u32 same = 0, diff = 0, diffReported = 0;
    for (int y = 0; y < (int) kScreenHeight; y++)
    {
        const u32* ref = software.GetLine(y);
        for (int x = 0; x < (int) kScreenWidth; x++)
        {
            const u32 a = mine[(size_t) y * kScreenWidth + x];
            const u32 b = ref[x];
            if (a == b)
            {
                same++;
                continue;
            }
            diff++;
            if (diffReported < 8)
            {
                diffReported++;
                fprintf(stderr, "[cmp] (%d,%d) metal %08x soft %08x\n", x, y, a, b);
            }
        }
    }

    {
        static int n = 0;
        if ((n++ % 200) == 0)
            fprintf(stderr, "[cmp] same %u diff %u\n", same, diff);
    }

    {
        // Write both layers out once so they can be looked at side by side:
        // the Metal colour buffer and the software rasteriser's lines, in the
        // same DS word layout, as PPMs.
        static bool written = false;
        if (!written && _numPolygons > 100)
        {
            written = true;
            FILE* metal = fopen("/tmp/cmp-metal.ppm", "wb");
            FILE* soft = fopen("/tmp/cmp-soft.ppm", "wb");
            if (metal != nullptr && soft != nullptr)
            {
                fprintf(metal, "P6\n256 192\n255\n");
                fprintf(soft, "P6\n256 192\n255\n");
                for (int y = 0; y < (int) kScreenHeight; y++)
                {
                    const u32* ref = software.GetLine(y);
                    for (int x = 0; x < (int) kScreenWidth; x++)
                    {
                        const u32 a = mine[(size_t) y * kScreenWidth + x];
                        const u32 b = ref[x];
                        const u8 pa[3] = {
                            (u8) (((a & 0x3F) << 2) | ((a & 0x3F) >> 4)),
                            (u8) ((((a >> 8) & 0x3F) << 2) | (((a >> 8) & 0x3F) >> 4)),
                            (u8) ((((a >> 16) & 0x3F) << 2) | (((a >> 16) & 0x3F) >> 4)),
                        };
                        const u8 pb[3] = {
                            (u8) (((b & 0x3F) << 2) | ((b & 0x3F) >> 4)),
                            (u8) ((((b >> 8) & 0x3F) << 2) | (((b >> 8) & 0x3F) >> 4)),
                            (u8) ((((b >> 16) & 0x3F) << 2) | (((b >> 16) & 0x3F) >> 4)),
                        };
                        fwrite(pa, 1, 3, metal);
                        fwrite(pb, 1, 3, soft);
                    }
                }
                fclose(metal);
                fclose(soft);
                fprintf(stderr, "[cmp] wrote /tmp/cmp-metal.ppm and /tmp/cmp-soft.ppm\n");
            }
        }
    }
}

} // namespace MelonDSMetal
