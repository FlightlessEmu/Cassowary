#!/usr/bin/env python3
"""Measure how bright the middle of a screenshot is.

The iOS test ROM fills the screen with white, and with black while the A button
is held. Comparing the brightness of two screenshots therefore shows whether a
button press reached the emulator.

Only the middle band of the screen is sampled, so the on-screen controls at the
top and bottom do not affect the result.

Usage:
    screenshot-brightness.py <image.png>
"""

import struct
import sys
import zlib


def read_png(path):
    """Decode a PNG into (width, height, channels, pixels).

    Handles the five colour types and all filter types. That is more than this
    script strictly needs — the screenshots are always RGBA — but it means the
    tool does not silently produce wrong numbers on a different input.
    """
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit(f"{path}: not a PNG")

    pos, idat = 8, b''
    width = height = colour_type = None

    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        chunk_type = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]

        if chunk_type == b'IHDR':
            width, height, _, colour_type = struct.unpack('>IIBB', chunk[:10])
        elif chunk_type == b'IDAT':
            idat += chunk
        elif chunk_type == b'IEND':
            break

        pos += 12 + length

    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour_type]
    stride = width * channels

    pixels = bytearray()
    previous = bytearray(stride)
    offset = 0

    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset:offset + stride])
        offset += stride

        if filter_type == 1:      # Sub
            for x in range(channels, stride):
                line[x] = (line[x] + line[x - channels]) & 0xFF
        elif filter_type == 2:    # Up
            for x in range(stride):
                line[x] = (line[x] + previous[x]) & 0xFF
        elif filter_type == 3:    # Average
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((a + previous[x]) >> 1)) & 0xFF
        elif filter_type == 4:    # Paeth
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                b = previous[x]
                c = previous[x - channels] if x >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                predictor = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + predictor) & 0xFF

        pixels += line
        previous = line

    return width, height, channels, bytes(pixels)


def game_area_brightness(path):
    width, height, channels, pixels = read_png(path)

    total = 0
    count = 0
    for y in range(int(height * 0.30), int(height * 0.65), 7):
        for x in range(0, width, 7):
            offset = (y * width + x) * channels
            total += (pixels[offset] + pixels[offset + 1] + pixels[offset + 2]) // 3
            count += 1

    return total / count if count else 0.0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    print(f"{game_area_brightness(sys.argv[1]):.1f}")
