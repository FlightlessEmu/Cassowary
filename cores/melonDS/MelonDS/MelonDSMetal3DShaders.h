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

    uint TexSlot;
    uint TexMode;
    uint TexWrap;
    uint TexWidth;
    uint TexHeight;
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

/// The rasterise mode, picked per variant on the CPU the way melonDS's own
/// renderer picks its shader: 0 draws vertex colours, 1 multiplies them with
/// the texture, 2 pastes an opaque texture over them, 3 and 4 run them through
/// the toon table, and 5 records only depth for a shadow mask.
constant uint kRasterNoTexture = 0;
constant uint kRasterModulate = 1;
constant uint kRasterDecal = 2;
constant uint kRasterToon = 3;
constant uint kRasterHighlight = 4;
constant uint kRasterShadow = 5;

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
    (void) irecip;

    if (y0 == y1 || idiff == 0)
        return y0;

    // melonDS's software rasteriser divides exactly here, rather than through
    // a reciprocal the way its compute renderer does. The two differ by a
    // step, which shows up as whole surfaces being a shade out, so the exact
    // division is the one to copy.
    if (y0 < y1)
        return y0 + int(((long)(y1 - y0) * long(i)) / long(idiff));

    return y1 + int(((long)(y0 - y1) * long(idiff - i)) / long(idiff));
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

/// The integer part of a 4.4 fixed-point texture coordinate, rounding down the
/// way the DS samples: an arithmetic shift right, written out because Metal
/// does not promise one for negative values.
inline int MelonDSFloorShift4(int t)
{
    if (t >= 0)
        return t >> 4;

    return -(((-t) + 15) >> 4);
}

/// Wraps a texel coordinate the way the DS does: 0 clamps to the texture, 1
/// repeats it, 2 mirrors it.
inline int MelonDSWrapTexel(int t, int size, uint mode)
{
    if (mode == 0U)
        return clamp(t, 0, size - 1);

    if (mode == 1U)
    {
        int m = t % size;
        return m < 0 ? m + size : m;
    }

    const int span = size * 2;
    int m = t % span;
    if (m < 0)
        m += span;

    return m < size ? m : span - 1 - m;
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
    device uint *colorBufferB [[buffer(4)]],
    device uint *depthBufferB [[buffer(5)]],
    device uint *attrBufferB [[buffer(6)]],
    uint2 pixel [[thread_position_in_grid]])
{
    if (pixel.x >= kScreenWidth || pixel.y >= kScreenHeight)
        return;

    const uint addr = pixel.y * kScreenWidth + pixel.x;

    colorBuffer[addr] = meta.ClearColor;
    depthBuffer[addr] = meta.ClearDepth;
    attrBuffer[addr] = meta.ClearAttr;

    // The buffer underneath is deliberately not cleared: the software
    // rasteriser only zeroes it once, when it is set up, and lets the pushed
    // pixels from each frame stay there. An edge pixel with zero coverage is
    // resolved to whatever that buffer holds, so clearing it here would show
    // up as a difference on those pixels.
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
    device uint *colorBufferB [[buffer(8)]],
    device uint *depthBufferB [[buffer(9)]],
    device uint *attrBufferB [[buffer(10)]],
    array<texture2d_array<uint, access::read>, 64> texTables [[texture(0)]],
    device uint *debugBuffer [[buffer(11)]],
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
        else if ((attr & 0xFU) != 0U)
        {
            // The polygon's inside, on its top or bottom scanline. The software
            // rasteriser calls the pixel fully covered here, "to avoid black
            // lines from anti-aliasing": the scanline above or below belongs to
            // another polygon, and the pixel is not really an edge of this one.
            attr |= 0x1FU << 8;
        }

        uint z;
        int vr, vg, vb, u, v;

        if (xspan.X0 == xspan.X1)
        {
            z = uint(xspan.Z0);
            vr = xspan.ColorR0;
            vg = xspan.ColorG0;
            vb = xspan.ColorB0;
            u = xspan.TexcoordU0;
            v = xspan.TexcoordV0;
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
                if (polygon.TexMode != kRasterNoTexture)
                {
                    u = MelonDSInterpolateAttrPersp(xspan.TexcoordU0, xspan.TexcoordU1, ifactor);
                    v = MelonDSInterpolateAttrPersp(xspan.TexcoordV0, xspan.TexcoordV1, ifactor);
                }
            }
            else
            {
                vr = MelonDSInterpolateAttrLinear(xspan.ColorR0, xspan.ColorR1, i, xspan.XRecip, idiff);
                vg = MelonDSInterpolateAttrLinear(xspan.ColorG0, xspan.ColorG1, i, xspan.XRecip, idiff);
                vb = MelonDSInterpolateAttrLinear(xspan.ColorB0, xspan.ColorB1, i, xspan.XRecip, idiff);
                if (polygon.TexMode != kRasterNoTexture)
                {
                    u = MelonDSInterpolateAttrLinear(xspan.TexcoordU0, xspan.TexcoordU1, i, xspan.XRecip, idiff);
                    v = MelonDSInterpolateAttrLinear(xspan.TexcoordV0, xspan.TexcoordV1, i, xspan.XRecip, idiff);
                }
            }
        }

        if (polygon.TexMode == kRasterShadow)
        {
            // Shadow masks only record depth, the way melonDS's own shadow
            // variant does.
            depthBuffer[pixeladdr] = z;
            continue;
        }

        const uint polyalpha = (polygon.Attr >> 16) & 0x1FU;

        uint vr6 = uint(vr >> 3);
        uint vg6 = uint(vg >> 3);
        uint vb6 = uint(vb >> 3);
        const uint vr6orig = vr6;
        uint r = vr6;
        uint g = vg6;
        uint b = vb6;
        uint a = polyalpha;

        if (polygon.TexMode == kRasterToon || polygon.TexMode == kRasterHighlight)
        {
            if (polygon.TexMode == kRasterHighlight)
            {
                // Highlight mode keeps the vertex colour for the texture and
                // adds the toon colour on top of the result. Only the toon
                // mode replaces the colour before sampling.
                vg6 = vr6;
                vb6 = vr6;
            }
            else
            {
                const uint tooncolor = meta.ToonTable[(vr6 >> 1) * 4];
                vr6 = tooncolor & 0xFFU;
                vg6 = (tooncolor >> 8) & 0xFFU;
                vb6 = (tooncolor >> 16) & 0xFFU;
            }
        }

        uint dbgTx = 0;
        uint dbgTy = 0;
        uint dbgTex = 0;

        if (polygon.TexMode != kRasterNoTexture)
        {
            // The texture coordinates are fixed point with four fractional
            // bits. The DS samples its textures nearest, so the texel is
            // fetched directly, with the wrap mode from the polygon's texture
            // parameters: 0 clamps, 1 repeats, 2 mirrors.
            const uint wrapS = polygon.TexWrap % 3;
            const uint wrapT = polygon.TexWrap / 3;
            const int tx = MelonDSWrapTexel(MelonDSFloorShift4(u), int(polygon.TexWidth), wrapS);
            const int ty = MelonDSWrapTexel(MelonDSFloorShift4(v), int(polygon.TexHeight), wrapT);
            const uint4 texcolor = texTables[polygon.TexSlot].read(uint2(uint(tx), uint(ty)), uint(polygon.TextureLayer));

            dbgTx = uint(tx);
            dbgTy = uint(ty);
            dbgTex = texcolor.r | (texcolor.g << 8) | (texcolor.b << 16) | (texcolor.a << 24);

            if (polygon.TexMode == kRasterDecal)
            {
                if (texcolor.a == 31)
                {
                    r = texcolor.r;
                    g = texcolor.g;
                    b = texcolor.b;
                }
                else if (texcolor.a > 0)
                {
                    r = (texcolor.r * texcolor.a + vr6 * (31 - texcolor.a)) >> 5;
                    g = (texcolor.g * texcolor.a + vg6 * (31 - texcolor.a)) >> 5;
                    b = (texcolor.b * texcolor.a + vb6 * (31 - texcolor.a)) >> 5;
                }
                a = polyalpha;
            }
            else
            {
                r = ((texcolor.r + 1) * (vr6 + 1) - 1) >> 6;
                g = ((texcolor.g + 1) * (vg6 + 1) - 1) >> 6;
                b = ((texcolor.b + 1) * (vb6 + 1) - 1) >> 6;
                a = ((texcolor.a + 1) * (polyalpha + 1) - 1) >> 5;
            }
        }

        if (polygon.TexMode == kRasterHighlight)
        {
            const uint tooncolor = meta.ToonTable[(vr6orig >> 1) * 4];

            r = min(r + (tooncolor & 0xFFU), 63U);
            g = min(g + ((tooncolor >> 8) & 0xFFU), 63U);
            b = min(b + ((tooncolor >> 16) & 0xFFU), 63U);
        }

        if (polyalpha == 0)
            a = 31;

        if (a <= meta.AlphaRef)
            continue;



        const uint color = r | (g << 8) | (b << 16) | (a << 24);

        // Diagnostic: what the shader saw for two fixed pixels.
        if ((pixel.x == 100 && pixel.y == 20) || (pixel.x == 60 && pixel.y == 20))
        {
            const uint slot = (pixel.x == 100) ? 0U : 1U;
            device uint *rec = debugBuffer + slot * 32;
            rec[0] = linePolyIndices[k];
            rec[1] = polygon.TexMode;
            rec[2] = polygon.TexSlot;
            rec[3] = uint(polygon.TextureLayer);
            rec[4] = uint(u);
            rec[5] = uint(v);
            rec[6] = dbgTx;
            rec[7] = dbgTy;
            rec[8] = dbgTex;
            rec[9] = color;
            rec[10] = uint(polygon.TexWidth) | (uint(polygon.TexHeight) << 16);
            rec[11] = polygon.TexWrap;
            rec[12] = uint(xspan.X0) | (uint(xspan.X1) << 16);
            rec[13] = uint(xspan.TexcoordU0) | (uint(xspan.TexcoordU1) << 16);
            rec[14] = uint(xspan.TexcoordV0) | (uint(xspan.TexcoordV1) << 16);
            rec[15] = 0xDEADBEEFU;
            rec[16] = uint(vr >> 3) | (uint(vg >> 3) << 8) | (uint(vb >> 3) << 16);
            rec[17] = colorBuffer[pixeladdr];
            rec[19] = attrBuffer[pixeladdr];
        }

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



            if ((meta.DispCnt & (1U << 4)) != 0U && (attr & 0xFU) != 0U)
            {
                // anti-aliasing: push the covered pixel down before drawing
                // over it, so the final pass can blend edge pixels with what
                // is underneath them. Only edge pixels need it — that is the
                // only place the buffer underneath is ever read.
                colorBufferB[pixeladdr] = colorBuffer[pixeladdr];
                depthBufferB[pixeladdr] = depthBuffer[pixeladdr];
                attrBufferB[pixeladdr] = attrBuffer[pixeladdr];
            }

            depthBuffer[pixeladdr] = z;
            colorBuffer[pixeladdr] = color;
            attrBuffer[pixeladdr] = polyattr | attr;
        }
        else
        {
            int blendz = int(z);
            if (!(polygon.Attr & (1U << 11)))
                blendz = -1;

            const uint entryAttr = attrBuffer[pixeladdr];
            MelonDSPlotTranslucentPixel(meta, colorBuffer, depthBuffer, attrBuffer,
                                        pixeladdr, color, blendz, polyattr, false);

            // blend with the pixel underneath too, if needed
            if ((entryAttr & 0xFU) != 0U)
            {
                MelonDSPlotTranslucentPixel(meta, colorBufferB, depthBufferB, attrBufferB,
                                            pixeladdr, color, blendz, polyattr, false);
            }
        }

        if ((pixel.x == 100 && pixel.y == 20) || (pixel.x == 60 && pixel.y == 20))
        {
            const uint slot = (pixel.x == 100) ? 0U : 1U;
            debugBuffer[slot * 32 + 18] = colorBuffer[pixeladdr];
            debugBuffer[slot * 32 + 20] = attrBuffer[pixeladdr];
        }
    }
}

/// melonDS's final pass (ScanlineFinalPass in GPU3D_Soft.cpp): edge marking
/// paints the edge table colour over pixels whose neighbour belongs to a
/// polygon nearer to the viewer, fog blends pixels toward the fog colour with
/// a density read from the fog table by depth, and anti-aliasing blends edge
/// pixels with the pixel pushed underneath them while they were drawn.
kernel void melonds_3d_final(
    constant MelonDSMetaUniform &meta [[buffer(0)]],
    device uint *colorBuffer [[buffer(1)]],
    device uint *depthBuffer [[buffer(2)]],
    device uint *attrBuffer [[buffer(3)]],
    device uint *colorBufferB [[buffer(4)]],
    device uint *depthBufferB [[buffer(5)]],
    device uint *attrBufferB [[buffer(6)]],
    uint2 pixel [[thread_position_in_grid]])
{
    if (pixel.x >= kScreenWidth || pixel.y >= kScreenHeight)
        return;

    const uint pixeladdr = pixel.y * kScreenWidth + pixel.x;

    if (meta.DispCnt & (1U << 5))
    {
        // edge marking, only applied to topmost pixels

        const uint attr = attrBuffer[pixeladdr];
        if ((attr & 0xFU) != 0U)
        {
            const uint polyid = attr >> 24;
            const uint z = depthBuffer[pixeladdr];

            bool edge = false;
            if (pixel.x > 0)
                edge = edge || ((polyid != (attrBuffer[pixeladdr - 1] >> 24)) && (z < depthBuffer[pixeladdr - 1]));
            if (pixel.x + 1 < kScreenWidth)
                edge = edge || ((polyid != (attrBuffer[pixeladdr + 1] >> 24)) && (z < depthBuffer[pixeladdr + 1]));
            if (pixel.y > 0)
                edge = edge || ((polyid != (attrBuffer[pixeladdr - kScreenWidth] >> 24)) && (z < depthBuffer[pixeladdr - kScreenWidth]));
            if (pixel.y + 1 < kScreenHeight)
                edge = edge || ((polyid != (attrBuffer[pixeladdr + kScreenWidth] >> 24)) && (z < depthBuffer[pixeladdr + kScreenWidth]));

            if (edge)
            {
                const uint edgecolor = meta.ToonTable[(polyid >> 3) * 4 + 2];

                const uint edgeR = edgecolor & 0xFFU;
                const uint edgeG = (edgecolor >> 8) & 0xFFU;
                const uint edgeB = (edgecolor >> 16) & 0xFFU;

                colorBuffer[pixeladdr] = edgeR | (edgeG << 8) | (edgeB << 16) | (colorBuffer[pixeladdr] & 0xFF000000U);

                // break antialiasing coverage (checkme)
                attrBuffer[pixeladdr] = (attr & 0xFFFFE0FFU) | 0x00001000U;
            }
        }
    }

    if (meta.DispCnt & (1U << 7))
    {
        // fog

        const bool fogcolor = (meta.DispCnt & (1U << 6)) == 0U;

        const uint fogR = meta.FogColor & 0xFFU;
        const uint fogG = (meta.FogColor >> 8) & 0xFFU;
        const uint fogB = (meta.FogColor >> 16) & 0xFFU;
        const uint fogA = (meta.FogColor >> 24) & 0xFFU;

        const uint attr = attrBuffer[pixeladdr];
        if ((attr & (1U << 15)) != 0U)
        {
            const uint z = depthBuffer[pixeladdr];
            uint density;
            if (z < meta.FogOffset)
            {
                density = 0;
            }
            else
            {
                uint zo = z - meta.FogOffset;
                zo = (zo >> 2) << meta.FogShift;

                const uint densityid = zo >> 17;
                if (densityid >= 32)
                {
                    density = meta.ToonTable[32 * 4 + 1];
                }
                else
                {
                    const uint densityfrac = zo & 0x1FFFFU;
                    density = ((meta.ToonTable[densityid * 4 + 1] * (0x20000U - densityfrac))
                             + (meta.ToonTable[(densityid + 1) * 4 + 1] * densityfrac)) >> 17;
                }
                if (density >= 127)
                    density = 128;
            }

            uint srcR = colorBuffer[pixeladdr] & 0x3FU;
            uint srcG = (colorBuffer[pixeladdr] >> 8) & 0x3FU;
            uint srcB = (colorBuffer[pixeladdr] >> 16) & 0x3FU;
            uint srcA = (colorBuffer[pixeladdr] >> 24) & 0x1FU;

            if (fogcolor)
            {
                srcR = ((fogR * density) + (srcR * (128 - density))) >> 7;
                srcG = ((fogG * density) + (srcG * (128 - density))) >> 7;
                srcB = ((fogB * density) + (srcB * (128 - density))) >> 7;
            }

            srcA = ((fogA * density) + (srcA * (128 - density))) >> 7;

            colorBuffer[pixeladdr] = srcR | (srcG << 8) | (srcB << 16) | (srcA << 24);
        }

        // fog for the pixel underneath
        if ((attr & 0xFU) != 0U)
        {
            const uint attrB = attrBufferB[pixeladdr];
            if ((attrB & (1U << 15)) != 0U)
            {
                const uint zB = depthBufferB[pixeladdr];
                uint densityB;
                if (zB < meta.FogOffset)
                {
                    densityB = 0;
                }
                else
                {
                    uint zoB = zB - meta.FogOffset;
                    zoB = (zoB >> 2) << meta.FogShift;

                    const uint densityidB = zoB >> 17;
                    if (densityidB >= 32)
                    {
                        densityB = meta.ToonTable[32 * 4 + 1];
                    }
                    else
                    {
                        const uint densityfracB = zoB & 0x1FFFFU;
                        densityB = ((meta.ToonTable[densityidB * 4 + 1] * (0x20000U - densityfracB))
                                 + (meta.ToonTable[(densityidB + 1) * 4 + 1] * densityfracB)) >> 17;
                    }
                    if (densityB >= 127)
                        densityB = 128;
                }

                uint srcRB = colorBufferB[pixeladdr] & 0x3FU;
                uint srcGB = (colorBufferB[pixeladdr] >> 8) & 0x3FU;
                uint srcBB = (colorBufferB[pixeladdr] >> 16) & 0x3FU;
                uint srcAB = (colorBufferB[pixeladdr] >> 24) & 0x1FU;

                if (fogcolor)
                {
                    srcRB = ((fogR * densityB) + (srcRB * (128 - densityB))) >> 7;
                    srcGB = ((fogG * densityB) + (srcGB * (128 - densityB))) >> 7;
                    srcBB = ((fogB * densityB) + (srcBB * (128 - densityB))) >> 7;
                }

                srcAB = ((fogA * densityB) + (srcAB * (128 - densityB))) >> 7;

                colorBufferB[pixeladdr] = srcRB | (srcGB << 8) | (srcBB << 16) | (srcAB << 24);
            }
        }
    }

    if ((meta.DispCnt & (1U << 4)) != 0U)
    {
        // anti-aliasing: blend edge pixels with the pixel underneath them.
        // The coverage was calculated while the edges were drawn.

        const uint attr = attrBuffer[pixeladdr];
        if ((attr & 0xFU) != 0U)
        {
            uint coverage = (attr >> 8) & 0x1FU;
            if (coverage != 0x1FU)
            {
                if (coverage == 0)
                {
                    colorBuffer[pixeladdr] = colorBufferB[pixeladdr];
                }
                else
                {
                    const uint topcolor = colorBuffer[pixeladdr];
                    uint topR = topcolor & 0x3FU;
                    uint topG = (topcolor >> 8) & 0x3FU;
                    uint topB = (topcolor >> 16) & 0x3FU;
                    uint topA = (topcolor >> 24) & 0x1FU;

                    const uint botcolor = colorBufferB[pixeladdr];
                    const uint botR = botcolor & 0x3FU;
                    const uint botG = (botcolor >> 8) & 0x3FU;
                    const uint botB = (botcolor >> 16) & 0x3FU;
                    const uint botA = (botcolor >> 24) & 0x1FU;

                    coverage++;

                    // only blend color if the bottom pixel isn't fully transparent
                    if (botA > 0)
                    {
                        topR = ((topR * coverage) + (botR * (32 - coverage))) >> 5;
                        topG = ((topG * coverage) + (botG * (32 - coverage))) >> 5;
                        topB = ((topB * coverage) + (botB * (32 - coverage))) >> 5;
                    }

                    // alpha is always blended
                    topA = ((topA * coverage) + (botA * (32 - coverage))) >> 5;

                    colorBuffer[pixeladdr] = topR | (topG << 8) | (topB << 16) | (topA << 24);
                }
            }
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
