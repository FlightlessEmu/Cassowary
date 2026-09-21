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
    {
        RenderSoftwareThreeD(gpu);
    }
    else
    {
        if (_rasterizer == nullptr)
            _rasterizer = std::make_unique<Rasterizer3D>(_device);

        _rasterizer->Render(gpu, _threeDTexture);
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

} // namespace

Rasterizer3D::Rasterizer3D(id<MTLDevice> device) noexcept
    : _device(device),
      _ready(false)
{
    if (_device == nil)
    {
        NSLog(@"[melonDS] rasteriser: no device");
        return;
    }

    _ySpanSetups = [_device newBufferWithLength:sizeof(SpanSetupY) * MaxYSpanSetups
                                       options:MTLResourceStorageModeShared];
    _yspanIndices = [_device newBufferWithLength:sizeof(SetupIndices) * kMaxSpanIndices
                                         options:MTLResourceStorageModeShared];
    _renderPolygons = [_device newBufferWithLength:sizeof(RenderPolygon) * MaxPolygons
                                           options:MTLResourceStorageModeShared];
    _metaUniform = [_device newBufferWithLength:sizeof(MetaUniform)
                                        options:MTLResourceStorageModeShared];

    if (_ySpanSetups == nil || _yspanIndices == nil || _renderPolygons == nil || _metaUniform == nil)
    {
        NSLog(@"[melonDS] rasteriser: could not create its buffers");
        return;
    }

    _spans.resize(MaxYSpanSetups);
    _spanIndices.resize(kMaxSpanIndices);
    _polygons.resize(MaxPolygons);
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

void Rasterizer3D::SetupFrame(GPU& gpu) noexcept
{
    const int screenWidth = 256;
    const int screenHeight = 192;

    u32 numSpans = 0;
    u32 numSpanIndices = 0;

    for (u32 i = 0; i < (u32) gpu.GPU3D.RenderNumPolygons; i++)
    {
        // A frame cannot hold more spans than melonDS allows, but a broken
        // frame should not run off the end of the buffers either.
        if (numSpans + 400 > MaxYSpanSetups || numSpanIndices + 200 > kMaxSpanIndices)
            break;

        Polygon* polygon = gpu.GPU3D.RenderPolygonRAM[i];

        u32 nverts = polygon->NumVertices;
        u32 vtop = polygon->VTop, vbot = polygon->VBottom;

        u32 curVL = vtop, curVR = vtop;
        u32 nextVL, nextVR;

        RenderPolygon& rp = _polygons[i];
        rp.FirstXSpan = numSpanIndices;
        rp.Attr = polygon->Attr;

        // Textures are not drawn yet, so every polygon is the same variant.
        // When the texture cache lands, this is where the array-texture layer
        // and sampler are chosen, as melonDS does.
        rp.Variant = 0;
        rp.TextureLayer = 0.0f;

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
                numSpanIndices++;
            }
        }
    }

    _numSpans = numSpans;
    _numSpanIndices = numSpanIndices;
    _numPolygons = (u32) gpu.GPU3D.RenderNumPolygons;

    if (numSpans == 0)
        return;

    memcpy(_ySpanSetups.contents, _spans.data(), sizeof(SpanSetupY) * numSpans);
    memcpy(_yspanIndices.contents, _spanIndices.data(), sizeof(SetupIndices) * numSpanIndices);
    memcpy(_renderPolygons.contents, _polygons.data(), sizeof(RenderPolygon) * _numPolygons);

    MetaUniform meta {};
    meta.DispCnt = gpu.GPU3D.RenderDispCnt;
    meta.NumPolygons = gpu.GPU3D.RenderNumPolygons;
    meta.NumVariants = 1;
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

    if (_numSpans == 0)
        return;

    // The passes that walk the spans are the next piece of the port. Until
    // they are in, the 3D layer is left as it was and the picture shows the 2D
    // layers alone — which is what MELONDS_3D=metal asks for.
}

} // namespace MelonDSMetal
