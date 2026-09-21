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
