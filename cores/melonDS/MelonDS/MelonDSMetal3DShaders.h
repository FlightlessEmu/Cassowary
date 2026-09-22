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

/// The Metal 3D rasteriser's compute shaders, kept as source and compiled when
/// the renderer starts, the same way the compositor is.
///
/// This is a port of melonDS's compute rasteriser (`Rasterise` and the shared
/// helpers in `GPU3D_Compute_shaders.h`). The span setup happens on the CPU
/// (`MelonDSMetal::Rasterizer3D`), so the shaders here only walk a span a
/// pixel at a time: interpolate its attributes, test depth, blend and write.
///
/// The structures below have to keep the same field order as the C++ ones in
/// `MelonDSMetalRenderer.h`, because they are the same buffers.
static const char *kMelonDSMetal3DSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

// MARK: - The buffers

struct MelonDSRenderPolygon
{
    uint FirstXSpan;
    int YTop, YBot;

    int XMin, XMax;
    int XMinY, XMaxY;

    uint Variant;
    uint Attr;

    float TextureLayer;
    uint WBuffer;
};

struct MelonDSMetaUniform
{
    uint NumPolygons;
    uint NumVariants;

    uint AlphaRef;
    uint DispCnt;

    uint ToonTable[4*34];

    uint ClearColor, ClearDepth, ClearAttr;

    uint FogOffset, FogShift, FogColor;
};

struct MelonDSSpanSetupX
{
    int X0, X1;

    int InsideStart, InsideEnd, EdgeCovL, EdgeCovR;

    int XRecip;

    uint Flags;

    int Z0, Z1, W0, W1;
    int ColorR0, ColorG0, ColorB0;
    int ColorR1, ColorG1, ColorB1;
    int TexcoordU0, TexcoordV0;
    int TexcoordU1, TexcoordV1;

    int CovLInitial, CovRInitial;
};

constant uint kXSpanSetup_Linear     = 1U << 0;
constant uint kXSpanSetup_FillInside = 1U << 1;
constant uint kXSpanSetup_FillLeft   = 1U << 2;
constant uint kXSpanSetup_FillRight  = 1U << 3;

constant uint kScreenWidth = 256;
constant uint kScreenHeight = 192;

/// The shift the rasteriser interpolates along a span with. The span setup
/// uses nine bits, the rasteriser eight, as melonDS does.
constant int kYFactorShift = 8;

// MARK: - Interpolation
//
// melonDS's, with its 32-bit division tricks written as 64-bit arithmetic.
// Metal has 64-bit integers, so the shortcuts are not needed here.

inline int MelonDSInterpolateAttrPersp(int y0, int y1, int ifactor)
{
    if (y0 == y1)
        return y0;

    if (y0 < y1)
        return y0 + int(((long)(y1 - y0) * ifactor) >> kYFactorShift);

    return y1 + int(((long)(y0 - y1) * ((1 << kYFactorShift) - ifactor)) >> kYFactorShift);
}

inline int MelonDSInterpolateAttrLinear(int y0, int y1, int i, int irecip, int idiff)
{
    if (y0 == y1)
        return y0;

    irecip = abs(irecip);

    ulong mul;
    if (y0 < y1)
        mul = (ulong)(y1 - y0) * (ulong)abs(i) * (ulong)irecip;
    else
        mul = (ulong)(y0 - y1) * (ulong)abs(idiff - i) * (ulong)irecip;

    mul += 3UL << 24;

    if (y0 < y1)
        return y0 + int(mul >> 30);

    return y1 + int(mul >> 30);
}

inline uint MelonDSInterpolateZZBuffer(int z0, int z1, int i, int irecip, int idiff)
{
    if (z0 == z1)
        return uint(z0);

    uint base, disp, factor;
    if (z0 < z1)
    {
        base = uint(z0);
        disp = uint(z1 - z0);
        factor = uint(abs(i));
    }
    else
    {
        base = uint(z1);
        disp = uint(z0 - z1);
        factor = uint(abs(idiff - i));
    }

    disp >>= 9;
    const int shiftl = 0;
    const int shiftr = 13;

    const ulong mul = (ulong)(disp * factor) * (ulong)(abs(irecip) >> 8);

    return base + uint((mul >> shiftr) << shiftl);
}

inline uint MelonDSInterpolateZWBuffer(int z0, int z1, int ifactor)
{
    if (z0 == z1)
        return uint(z0);

    // since the precision along x spans is only 8 bit the result will always fit in 32-bit
    if (z0 < z1)
        return uint(z0) + uint(((z1 - z0) * ifactor) >> kYFactorShift);

    return uint(z1) + uint(((z0 - z1) * ((1 << kYFactorShift) - ifactor)) >> kYFactorShift);
}

inline int MelonDSCalcYFactorX(MelonDSSpanSetupX span, int x)
{
    x -= span.X0;

    if (span.X0 != span.X1)
    {
        const ulong num = ((ulong)(uint(x) * uint(span.W0))) << kYFactorShift;
        const uint den = uint(x) * uint(span.W0) + uint(span.X1 - span.X0 - x) * uint(span.W1);

        if (den == 0)
            return 0;

        return int(num / (ulong)den);
    }

    return 0;
}

// MARK: - Blending and depth

/// melonDS's `AlphaBlend` (GPU3D_Soft.cpp), which is also what its compute
/// renderer's depth-and-blend pass does.
inline uint MelonDSAlphaBlend(constant MelonDSMetaUniform &meta, uint srccolor, uint dstcolor, uint alpha)
{
    uint dstalpha = dstcolor >> 24;

    if (dstalpha == 0)
        return srccolor;

    uint srcR = srccolor & 0x3F;
    uint srcG = (srccolor >> 8) & 0x3F;
    uint srcB = (srccolor >> 16) & 0x3F;

    if (meta.DispCnt & (1 << 3))
    {
        const uint dstR = dstcolor & 0x3F;
        const uint dstG = (dstcolor >> 8) & 0x3F;
        const uint dstB = (dstcolor >> 16) & 0x3F;

        alpha++;
        srcR = ((srcR * alpha) + (dstR * (32 - alpha))) >> 5;
        srcG = ((srcG * alpha) + (dstG * (32 - alpha))) >> 5;
        srcB = ((srcB * alpha) + (dstB * (32 - alpha))) >> 5;
        alpha--;
    }

    if (alpha > dstalpha)
        dstalpha = alpha;

    return srcR | (srcG << 8) | (srcB << 16) | (dstalpha << 24);
}

inline bool MelonDSDepthTest_Z(int dstz, int z)
{
    const int diff = dstz - z;
    return uint(diff + 0x200) <= 0x400;
}

inline bool MelonDSDepthTest_W(int dstz, int z)
{
    const int diff = dstz - z;
    return uint(diff + 0xFF) <= 0x1FE;
}

inline bool MelonDSDepthTest_LessThan(int dstz, int z)
{
    return z < dstz;
}

inline bool MelonDSDepthTest_LessThan_FrontFacing(int dstz, int z, uint dstattr)
{
    if ((dstattr & 0x00400010) == 0x00000010) // opaque, back facing
        return z <= dstz;

    return z < dstz;
}

/// melonDS's `PlotTranslucentPixel`: blend a translucent pixel over what is
/// already there, unless the same polygon already drew one.
inline void MelonDSPlotTranslucentPixel(
    constant MelonDSMetaUniform &meta,
    device uint *colorBuffer, device uint *depthBuffer, device uint *attrBuffer,
    uint pixeladdr, uint color, int z, uint polyattr, bool shadow)
{
    const uint dstattr = attrBuffer[pixeladdr];
    uint attr = (polyattr & 0xE0F0) | ((polyattr >> 8) & 0xFF0000) | (1 << 22) | (dstattr & 0xFF001F0F);

    if (shadow)
    {
        // for shadows, opaque pixels are also checked
        if (dstattr & (1 << 22))
        {
            if ((dstattr & 0x007F0000) == (attr & 0x007F0000))
                return;
        }
        else
        {
            if ((dstattr & 0x3F000000) == (polyattr & 0x3F000000))
                return;
        }
    }
    else
    {
        // skip if translucent polygon IDs are equal
        if ((dstattr & 0x007F0000) == (attr & 0x007F0000))
            return;
    }

    // fog flag
    if (!(dstattr & (1 << 15)))
        attr &= ~(1 << 15);

    color = MelonDSAlphaBlend(meta, color, colorBuffer[pixeladdr], color >> 24);

    if (z != -1)
        depthBuffer[pixeladdr] = uint(z);

    colorBuffer[pixeladdr] = color;
    attrBuffer[pixeladdr] = attr;
}

// MARK: - The passes

/// Fills the 3D layer with what the DS clears it to. The depth and attribute
/// buffers matter as much as the colour: a game that clears to a depth of zero
/// draws over everything.
kernel void melonds_3d_clear(
    constant MelonDSMetaUniform &meta [[buffer(0)]],
    device uint *colorBuffer [[buffer(1)]],
    device uint *depthBuffer [[buffer(2)]],
    device uint *attrBuffer [[buffer(3)]],
    uint2 pixel [[thread_position_in_grid]])
{
    if (pixel.x >= kScreenWidth || pixel.y >= kScreenHeight)
        return;

    const uint addr = pixel.y * kScreenWidth + pixel.x;

    colorBuffer[addr] = meta.ClearColor;
    depthBuffer[addr] = meta.ClearDepth;
    attrBuffer[addr] = meta.ClearAttr;
}

/// Walks every polygon in submission order and draws the pixels of its spans.
///
/// The polygons are walked in the order the game submitted them, which is what
/// the software rasteriser does and what the DS does: the depth test and the
/// blending of translucent polygons both depend on what was drawn before them.
/// One thread draws one pixel, so the order is kept without any locks.
kernel void melonds_rasterise(
    device const MelonDSRenderPolygon *polygons [[buffer(0)]],
    device const MelonDSSpanSetupX *spans [[buffer(1)]],
    constant MelonDSMetaUniform &meta [[buffer(2)]],
    device uint *colorBuffer [[buffer(3)]],
    device uint *depthBuffer [[buffer(4)]],
    device uint *attrBuffer [[buffer(5)]],
    device const uint *linePolyOffsets [[buffer(6)]],
    device const uint *linePolyIndices [[buffer(7)]],
    uint2 pixel [[thread_position_in_grid]])
{
    if (pixel.x >= kScreenWidth || pixel.y >= kScreenHeight)
        return;

    const uint pixeladdr = pixel.y * kScreenWidth + pixel.x;

    // Only the polygons that touch this line, in the order the game submitted
    // them — which is what the depth test and the translucent blending need.
    const uint lineStart = linePolyOffsets[pixel.y];
    const uint lineEnd = linePolyOffsets[pixel.y + 1];

    for (uint k = lineStart; k < lineEnd; k++)
    {
        const MelonDSRenderPolygon polygon = polygons[linePolyIndices[k]];

        if (pixel.x < uint(max(polygon.XMin, 0)) || pixel.x > uint(max(polygon.XMax, 0)))
            continue;

        const MelonDSSpanSetupX xspan = spans[polygon.FirstXSpan + (pixel.y - uint(polygon.YTop))];

        const bool insideLeftEdge = pixel.x < uint(xspan.InsideStart);
        const bool insideRightEdge = pixel.x >= uint(xspan.InsideEnd);
        const bool insidePolygonInside = !insideLeftEdge && !insideRightEdge;

        if (pixel.x < uint(max(xspan.X0, 0)) || pixel.x >= uint(max(xspan.X1, 0)))
            continue;

        if (!((insideLeftEdge && (xspan.Flags & kXSpanSetup_FillLeft) != 0U)
              || (insideRightEdge && (xspan.Flags & kXSpanSetup_FillRight) != 0U)
              || (insidePolygonInside && (xspan.Flags & kXSpanSetup_FillInside) != 0U)))
            continue;


        // The edge flags the final pass uses to mark edges.
        uint attr = 0;
        if (pixel.y == uint(polygon.YTop))
            attr |= 0x4U;
        else if (pixel.y == uint(polygon.YBot - 1))
            attr |= 0x8U;

        if (insideLeftEdge)
        {
            attr |= 0x1U;

            int cov = xspan.EdgeCovL;
            if (cov < 0)
            {
                const int xcov = xspan.CovLInitial + (xspan.EdgeCovL & 0x3FF) * int(pixel.x - uint(xspan.X0));
                cov = min(xcov >> 5, 31);
            }

            attr |= uint(cov) << 8;
        }
        else if (insideRightEdge)
        {
            attr |= 0x2U;

            int cov = xspan.EdgeCovR;
            if (cov < 0)
            {
                const int xcov = xspan.CovRInitial + (xspan.EdgeCovR & 0x3FF) * int(pixel.x - uint(xspan.InsideEnd));
                cov = max(0x1F - (xcov >> 5), 0);
            }

            attr |= uint(cov) << 8;
        }

        uint z;
        int vr, vg, vb;

        if (xspan.X0 == xspan.X1)
        {
            z = uint(xspan.Z0);
            vr = xspan.ColorR0;
            vg = xspan.ColorG0;
            vb = xspan.ColorB0;
        }
        else
        {
            const int ifactor = MelonDSCalcYFactorX(xspan, int(pixel.x));
            const int idiff = xspan.X1 - xspan.X0;
            const int i = int(pixel.x) - xspan.X0;

            if (polygon.WBuffer != 0)
                z = MelonDSInterpolateZWBuffer(xspan.Z0, xspan.Z1, ifactor);
            else
                z = MelonDSInterpolateZZBuffer(xspan.Z0, xspan.Z1, i, xspan.XRecip, idiff);

            if ((xspan.Flags & kXSpanSetup_Linear) == 0U)
            {
                vr = MelonDSInterpolateAttrPersp(xspan.ColorR0, xspan.ColorR1, ifactor);
                vg = MelonDSInterpolateAttrPersp(xspan.ColorG0, xspan.ColorG1, ifactor);
                vb = MelonDSInterpolateAttrPersp(xspan.ColorB0, xspan.ColorB1, ifactor);
            }
            else
            {
                vr = MelonDSInterpolateAttrLinear(xspan.ColorR0, xspan.ColorR1, i, xspan.XRecip, idiff);
                vg = MelonDSInterpolateAttrLinear(xspan.ColorG0, xspan.ColorG1, i, xspan.XRecip, idiff);
                vb = MelonDSInterpolateAttrLinear(xspan.ColorB0, xspan.ColorB1, i, xspan.XRecip, idiff);
            }
        }

        const uint polyalpha = (polygon.Attr >> 16) & 0x1FU;

        // Textures are not drawn yet, so the colour comes from the vertices
        // alone. The texture cache and the textured variants come next.
        uint r = uint(vr >> 3);
        uint g = uint(vg >> 3);
        uint b = uint(vb >> 3);
        uint a = polyalpha;

        if (polyalpha == 0)
            a = 31;

        if (a <= meta.AlphaRef)
            continue;


        const bool isShadowMask = (polygon.Attr & 0x3F000030U) == 0x00000030U;

        if (isShadowMask)
        {
            // Shadow masks only record depth and attributes.
            depthBuffer[pixeladdr] = z;
            attrBuffer[pixeladdr] = attr;
            continue;
        }

        const uint color = r | (g << 8) | (b << 16) | (a << 24);

        // What the software rasteriser calls polyattr: the polygon's identity,
        // its facing and its alpha, which the depth test and the blending read
        // back out of the attribute buffer.
        uint polyattr = polygon.Attr & 0x3F008000U;
        if (!(polygon.Attr & (1U << 6))) // not facing the view: back facing
            polyattr |= (1U << 4);

        if (a == 31)
        {
            const int dstz = int(depthBuffer[pixeladdr]);
            const uint dstattr = attrBuffer[pixeladdr];

            bool pass;
            if (polygon.Attr & (1U << 14))
                pass = polygon.WBuffer != 0 ? MelonDSDepthTest_W(dstz, int(z))
                                            : MelonDSDepthTest_Z(dstz, int(z));
            else if (polygon.Attr & (1U << 6))
                pass = MelonDSDepthTest_LessThan_FrontFacing(dstz, int(z), dstattr);
            else
                pass = MelonDSDepthTest_LessThan(dstz, int(z));

            if (!pass)
                continue;

            depthBuffer[pixeladdr] = z;
            colorBuffer[pixeladdr] = color;
            attrBuffer[pixeladdr] = polyattr | attr;
        }
        else
        {
            int blendz = int(z);
            if (!(polygon.Attr & (1U << 11)))
                blendz = -1;

            MelonDSPlotTranslucentPixel(meta, colorBuffer, depthBuffer, attrBuffer,
                                        pixeladdr, color, blendz, polyattr, false);
        }
    }
}

/// Hands the finished 3D layer to the compositor. The layer holds the DS's own
/// six bits per colour and five of alpha; the compositor samples the texture as
/// eight-bit values, so each channel is widened here by repeating its top bits.
kernel void melonds_3d_output(
    device const uint *colorBuffer [[buffer(0)]],
    texture2d<float, access::write> output [[texture(0)]],
    uint2 pixel [[thread_position_in_grid]])
{
    if (pixel.x >= kScreenWidth || pixel.y >= kScreenHeight)
        return;

    const uint c = colorBuffer[pixel.y * kScreenWidth + pixel.x];

    const uint r = c & 0x3F;
    const uint g = (c >> 8) & 0x3F;
    const uint b = (c >> 16) & 0x3F;
    const uint a = (c >> 24) & 0x1F;

    const uint r8 = (r << 2) | (r >> 4);
    const uint g8 = (g << 2) | (g >> 4);
    const uint b8 = (b << 2) | (b >> 4);
    const uint a8 = (a << 3) | (a >> 2);

    output.write(float4(float(r8) / 255.0, float(g8) / 255.0, float(b8) / 255.0, float(a8) / 255.0), pixel);
}
)MSL";
