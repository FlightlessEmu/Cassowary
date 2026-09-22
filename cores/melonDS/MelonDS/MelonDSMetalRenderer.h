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

#include "GPU3D.h"
#include "types.h"

#include <cstdint>
#include <memory>
#include <vector>

namespace melonDS
{
class SoftRenderer;
}

namespace MelonDSMetal
{

using melonDS::s32;
using melonDS::u16;
using melonDS::u32;

// The data the Metal rasteriser and its compute shaders pass between each
// other. The field order matters: the shaders declare the same structures and
// read the same buffers, so these have to stay in step with them. They are
// copies of melonDS's own (`GPU3D_Compute.h`) so the two can be read side by
// side, and so a bug can be chased in either.

/// One vertical span of a polygon: everything that is constant down a line of
/// it, plus the slope used to walk to the next line.
struct SpanSetupY
{
    // Attributes
    s32 Z0, Z1, W0, W1;
    s32 ColorR0, ColorG0, ColorB0;
    s32 ColorR1, ColorG1, ColorB1;
    s32 TexcoordU0, TexcoordV0;
    s32 TexcoordU1, TexcoordV1;

    // Interpolator
    s32 I0, I1;
    s32 Linear;
    s32 IRecip;
    s32 W0n, W0d, W1d;

    // Slope
    s32 Increment;

    s32 X0, X1, Y0, Y1;
    s32 XMin, XMax;
    s32 DxInitial;

    s32 XCovIncr;
    u32 IsDummy;
};

/// One horizontal span: a run of pixels on one line, with the attributes at
/// each end and the coverage values the edge marking needs. The layout follows
/// the shader's (`XSpanSetup` in GPU3D_Compute_shaders.h), because the shaders
/// read these fields by offset.
struct SpanSetupX
{
    s32 X0, X1;

    s32 InsideStart, InsideEnd, EdgeCovL, EdgeCovR;

    s32 XRecip;

    u32 Flags;

    s32 Z0, Z1, W0, W1;
    s32 ColorR0, ColorG0, ColorB0;
    s32 ColorR1, ColorG1, ColorB1;
    s32 TexcoordU0, TexcoordV0;
    s32 TexcoordU1, TexcoordV1;

    s32 CovLInitial, CovRInitial;
};

/// Which polygon and which of its spans a line belongs to.
struct SetupIndices
{
    u16 PolyIdx, SpanIdxL, SpanIdxR, Y;
};

/// A polygon, as the rasteriser needs it: where it sits on screen, which
/// shader variant draws it and the polygon's own attributes.
struct RenderPolygon
{
    u32 FirstXSpan;
    s32 YTop, YBot;

    s32 XMin, XMax;
    s32 XMinY, XMaxY;

    u32 Variant;
    u32 Attr;

    float TextureLayer;

    /// True when the polygon interpolates W for its depth rather than Z.
    u32 WBuffer;
};

/// Values that are the same for every polygon in a frame.
struct MetaUniform
{
    u32 NumPolygons;
    u32 NumVariants;

    u32 AlphaRef;
    u32 DispCnt;

    u32 ToonTable[4*34];

    u32 ClearColor, ClearDepth, ClearAttr;

    u32 FogOffset, FogShift, FogColor;
};

/// Draws the DS's 3D layer with Metal compute shaders.
///
/// This is the port of melonDS's compute renderer (`GPU3D_Compute.cpp`). It
/// fills the same buffers with the same values, runs the same passes in the
/// same order, and its shaders are the same maths — so a frame it draws can be
/// compared, pixel for pixel, against the software rasteriser.
///
/// The port is being written pass by pass. While `MELONDS_3D` is not `metal`,
/// the software rasteriser draws the 3D layer and this class does nothing.
class Rasterizer3D
{
public:
    Rasterizer3D(id<MTLDevice> device, id<MTLCommandQueue> queue) noexcept;
    ~Rasterizer3D() noexcept;

    /// True when the shaders and buffers were built.
    [[nodiscard]] bool IsReady() const noexcept { return _ready; }

    /// Draws the frame's polygons into the 3D texture the compositor reads.
    void Render(melonDS::GPU& gpu, id<MTLTexture> output) noexcept;

private:
    /// The largest number of vertical spans a frame can set up, matching
    /// melonDS's own limit.
    static constexpr int MaxYSpanSetups = 6144 * 2;
    static constexpr int MaxPolygons = 2048;

    __strong id<MTLDevice> _device;
    __strong id<MTLCommandQueue> _queue;
    __strong id<MTLLibrary> _library;

    /// The three passes: clear the layer, draw the polygons, hand the layer to
    /// the compositor.
    __strong id<MTLComputePipelineState> _clearPipeline;
    __strong id<MTLComputePipelineState> _rasterisePipeline;
    __strong id<MTLComputePipelineState> _outputPipeline;

    /// The 3D layer while it is being drawn, in the DS's own layouts: a colour
    /// per pixel (six bits each of red, green and blue, five of alpha), a
    /// depth, and the attributes the depth test and edge marking read.
    __strong id<MTLBuffer> _colorBuffer;
    __strong id<MTLBuffer> _depthBuffer;
    __strong id<MTLBuffer> _attrBuffer;

    /// The spans of every polygon in the frame, the polygons themselves, and
    /// the values that are the same for all of them.
    __strong id<MTLBuffer> _ySpanSetups;
    __strong id<MTLBuffer> _xSpanSetups;
    __strong id<MTLBuffer> _yspanIndices;
    __strong id<MTLBuffer> _renderPolygons;
    __strong id<MTLBuffer> _metaUniform;

    /// The CPU-side copies the buffers are filled from.
    std::vector<SpanSetupY> _spans;
    std::vector<SpanSetupX> _xSpans;
    std::vector<SetupIndices> _spanIndices;
    std::vector<RenderPolygon> _polygons;
    std::vector<u32> _toonTable;

    u32 _numSpans = 0;
    u32 _numSpanIndices = 0;
    u32 _numPolygons = 0;

    bool _ready;

    /// Fills the buffers for one frame: every polygon's vertical spans and the
    /// per-frame values the shaders read.
    void SetupFrame(melonDS::GPU& gpu) noexcept;

    /// The span setup, ported from melonDS's compute renderer.
    void SetupAttrs(SpanSetupY* span, melonDS::Polygon* poly, int from, int to) noexcept;
    void SetupYSpan(RenderPolygon* rp, SpanSetupY* span, melonDS::Polygon* poly, int from, int to, int side, s32 positions[10][2]) noexcept;
    void SetupYSpanDummy(RenderPolygon* rp, SpanSetupY* span, melonDS::Polygon* poly, int vertex, int side, s32 positions[10][2]) noexcept;

    /// Turns one line's two vertical spans into the horizontal span the
    /// shaders walk. This is melonDS's `InterpSpans` pass, done on the CPU:
    /// the arithmetic is the same, written with 64-bit division, which is
    /// exactly what melonDS's 32-bit routines are a faster way of doing.
    void SetupXSpan(SpanSetupX* xspan, const SpanSetupY& spanL, const SpanSetupY& spanR, u32 polyIdx, int y, u32 dispCnt) noexcept;
};

/// Draws the DS's 3D and composites its 2D layers with Metal.
///
/// This is the app's replacement for melonDS's OpenGL and compute renderers:
/// iOS has no OpenGL, and this app already draws with Metal. Both DS screens
/// are drawn into one texture, which the app displays directly through the
/// `OEGameCoreRenderingMetal2` path — the finished frame never touches the CPU.
///
/// The renderer reports itself as accelerated, which is what makes melonDS's
/// 2D renderer hand over its per-line layer buffer for the GPU to composite
/// instead of finishing the picture in software.
///
/// The 3D layer is not drawn with Metal yet: the polygons come from melonDS's
/// own software rasteriser, which is complete and correct, and are copied into
/// the 3D texture each frame. The Metal rasteriser is being ported and takes
/// over when `MELONDS_3D=metal` is set in the environment.
class Renderer final : public melonDS::Renderer3D
{
public:
    /// Builds the renderer, its shaders and its textures. Check `IsReady()`
    /// before using it.
    Renderer(id<MTLDevice> device, melonDS::u32 width, melonDS::u32 height) noexcept;
    ~Renderer() noexcept override;

    /// True when Metal started and the renderer can draw.
    [[nodiscard]] bool IsReady() const noexcept { return _ready; }

    /// The finished picture: both screens stacked into one texture.
    [[nodiscard]] id<MTLTexture> OutputTexture() const noexcept { return _output[_frontIndex]; }

    /// Waits for the last frame to finish drawing. The app never needs this;
    /// the offline test harness does.
    void WaitForCompletion() noexcept;

    // Renderer3D
    void Reset(melonDS::GPU& gpu) override;
    void VCount144(melonDS::GPU& gpu) override;
    void RenderFrame(melonDS::GPU& gpu) override;
    void RestartFrame(melonDS::GPU& gpu) override;
    [[nodiscard]] melonDS::u32* GetLine(int line) override;
    void Blit(const melonDS::GPU& gpu) override;

    /// Display capture (CaptureCnt) reads the 3D layer back on the CPU. With
    /// the software rasteriser that layer is already on the CPU, so there is
    /// nothing to copy out here.
    void PrepareCaptureFrame() override;

private:
    /// Fills the 3D layer with transparent black.
    void ClearThreeDLayer() noexcept;

    /// Renders the 3D layer with melonDS's software rasteriser and copies it
    /// into the 3D texture the compositor reads.
    void RenderSoftwareThreeD(melonDS::GPU& gpu) noexcept;

    __strong id<MTLDevice> _device;
    __strong id<MTLCommandQueue> _queue;
    __strong id<MTLLibrary> _library;

    /// The accelerated 2D layer buffer, uploaded once per frame. One row per
    /// scanline of each screen, 769 words wide.
    __strong id<MTLTexture> _layerTexture;

    /// The 3D layer, drawn a frame ahead of the 2D layers and read back by the
    /// compositor.
    __strong id<MTLTexture> _threeDTexture;

    /// The finished picture, swapped each frame: one for the app to show, one
    /// being drawn into.
    __strong id<MTLTexture> _output[2];

    __strong id<MTLRenderPipelineState> _compositorPipeline;
    __strong id<MTLCommandBuffer> _lastCommandBuffer[2];

    /// melonDS's software 3D rasteriser, which draws the 3D layer until the
    /// Metal one is ready. Made on the first frame.
    std::unique_ptr<melonDS::SoftRenderer> _software;

    /// The Metal 3D rasteriser, made the first time MELONDS_3D=metal is used.
    std::unique_ptr<Rasterizer3D> _rasterizer;

    /// The software 3D layer, one word per pixel, converted for upload into
    /// _threeDTexture.
    std::vector<melonDS::u32> _threeDPixels;

    /// True while the 3D layer comes from the software rasteriser.
    bool _softwareThreeD = true;

    melonDS::u32 _width;
    melonDS::u32 _height;
    bool _ready;
    NSUInteger _frontIndex;
};

} // namespace MelonDSMetal

#endif // __OBJC__
