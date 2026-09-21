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

/// The Metal shaders, kept as source and compiled when the renderer starts.
///
/// melonDS embeds its OpenGL shaders the same way for the same reason: the
/// build then needs no shader step, and the plugin stays one self-contained
/// bundle.
///
/// The compositor is a line-for-line port of melonDS's OpenGL compositor
/// (`kCompositorFS_Nearest` in `GPU_OpenGL_shaders.h`); the comment tags keep
/// the two readable side by side.
static const char *kMelonDSMetalSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

// MARK: - The compositor
//
// The DS picture is finished here, on the GPU. melonDS's 2D renderer cannot
// finish it in software once a GPU renderer is in use, so it lays out, for
// every scanline of every screen, three layers of 256 pixels plus a metadata
// word (that is the 769-word rows the app's framebuffer holds) and this pass
// turns those into the picture. The 3D layer comes in as its own texture.

struct MelonDSCompositorVertex
{
    float2 position;   // in clip space
    float2 texel;      // in texels of the layer texture
};

struct MelonDSCompositorOut
{
    float4 position [[position]];
    float2 texel;
};

struct MelonDSCompositorUniforms
{
    uint scale3D;
};

vertex MelonDSCompositorOut melonds_compositor_vertex(
    const device MelonDSCompositorVertex *vertices [[buffer(0)]],
    uint vertexID [[vertex_id]])
{
    MelonDSCompositorOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texel = vertices[vertexID].texel;

    return out;
}

/// One layer word: 6-bit red, 6-bit green, 6-bit blue and flags in the top
/// byte. The shader works in those bytes, exactly like the OpenGL one.
inline int4 MelonDSLayerWord(uint word)
{
    return int4(word & 0xFF, (word >> 8) & 0xFF, (word >> 16) & 0xFF, (word >> 24) & 0xFF);
}

/// A pixel of the 3D layer, back in the DS's own ranges: 6 bits per colour and
/// 5 of alpha. The 3D renderer widens each channel to eight bits by repeating
/// its top bits, so rounding recovers the value it drew; truncating would drop
/// the bottom step of every colour that is not exactly representable.
inline int4 MelonDS3DPixel(texture2d<float, access::read> threeD, uint2 pos3d)
{
    return int4(round(threeD.read(pos3d) * float4(63.0, 63.0, 63.0, 31.0)));
}

fragment float4 melonds_compositor_fragment(
    MelonDSCompositorOut in [[stage_in]],
    texture2d<uint, access::read> layers [[texture(0)]],
    texture2d<float, access::read> threeD [[texture(1)]],
    constant MelonDSCompositorUniforms &uniforms [[buffer(0)]])
{
    const uint2 texel = uint2(in.texel);

    int4 pixel = MelonDSLayerWord(layers.read(texel).r);

    // The metadata word lives after the three planes of pixels.
    uint4 mbrightWord = layers.read(uint2(256 * 3, texel.y));
    int4 mbright = MelonDSLayerWord(mbrightWord.r);
    int dispmode = mbright.b & 0x3;

    // mbright.a == HOFS bit0..7
    // mbright.b bit7 == HOFS bit8 (sign)
    float _3dxpos = float(mbright.a - ((mbright.b & 0x80) * 2));

    if (dispmode == 1)
    {
        int4 val1 = pixel;
        int4 val2 = MelonDSLayerWord(layers.read(texel + uint2(256, 0)).r);
        int4 val3 = MelonDSLayerWord(layers.read(texel + uint2(512, 0)).r);

        int compmode = val3.a & 0xF;
        int eva, evb, evy;

        if (compmode == 4)
        {
            // 3D on top, blending

            float xpos = in.texel.x + _3dxpos;
            float ypos = fmod(in.texel.y, 192.0);
            uint2 pos3d = uint2(uint2(xpos, ypos) * uniforms.scale3D);
            pos3d = min(pos3d, uint2(threeD.get_width() - 1, threeD.get_height() - 1));
            int4 _3dpix = MelonDS3DPixel(threeD, pos3d);

            if (_3dpix.a > 0)
            {
                eva = (_3dpix.a & 0x1F) + 1;
                evb = 32 - eva;

                val1 = ((_3dpix * eva) + (val1 * evb) + 0x10) >> 5;
                val1 = min(val1, 0x3F);
            }
            else
                val1 = val2;
        }
        else if (compmode == 1)
        {
            // 3D on bottom, blending

            float xpos = in.texel.x + _3dxpos;
            float ypos = fmod(in.texel.y, 192.0);
            uint2 pos3d = uint2(uint2(xpos, ypos) * uniforms.scale3D);
            pos3d = min(pos3d, uint2(threeD.get_width() - 1, threeD.get_height() - 1));
            int4 _3dpix = MelonDS3DPixel(threeD, pos3d);

            if (_3dpix.a > 0)
            {
                eva = val3.g;
                evb = val3.b;

                val1 = ((val1 * eva) + (_3dpix * evb) + 0x8) >> 4;
                val1 = min(val1, 0x3F);
            }
            else
                val1 = val2;
        }
        else if (compmode <= 3)
        {
            // 3D on top, normal/fade

            float xpos = in.texel.x + _3dxpos;
            float ypos = fmod(in.texel.y, 192.0);
            uint2 pos3d = uint2(uint2(xpos, ypos) * uniforms.scale3D);
            pos3d = min(pos3d, uint2(threeD.get_width() - 1, threeD.get_height() - 1));
            int4 _3dpix = MelonDS3DPixel(threeD, pos3d);

            if (_3dpix.a > 0)
            {
                evy = val3.g;

                val1 = _3dpix;
                if      (compmode == 2) val1 += (((0x3F - val1) * evy) + 0x8) >> 4;
                else if (compmode == 3) val1 -= ((val1 * evy) + 0x7) >> 4;
            }
            else
                val1 = val2;
        }

        pixel = val1;
    }

    if (dispmode != 0)
    {
        int brightmode = mbright.g >> 6;
        if (brightmode == 1)
        {
            // up
            int evy = mbright.r & 0x1F;
            if (evy > 16) evy = 16;

            pixel += ((0x3F - pixel) * evy) >> 4;
        }
        else if (brightmode == 2)
        {
            // down
            int evy = mbright.r & 0x1F;
            if (evy > 16) evy = 16;

            pixel -= ((pixel * evy) + 0xF) >> 4;
        }
    }

    pixel.r <<= 2;
    pixel.r |= (pixel.r >> 6);
    pixel.g <<= 2;
    pixel.g |= (pixel.g >> 6);
    pixel.b <<= 2;
    pixel.b |= (pixel.b >> 6);

    return float4(float(pixel.r) / 255.0,
                  float(pixel.g) / 255.0,
                  float(pixel.b) / 255.0,
                  1.0);
}
)MSL";
