#!/usr/bin/env python3
"""Compare two frames dumped by dump-psx-frame.py.

Reports how many pixels differ, by how much, and writes a picture of the
differences so they can be looked at rather than guessed at:

    Scripts/cassowary/compare-psx-frames.py metal.ppm soft.ppm
    Scripts/cassowary/compare-psx-frames.py metal.ppm soft.ppm --diff diff.ppm

The software renderer hands over RGB565 and the hardware one RGBA8, so a few
levels of rounding difference are expected everywhere. What matters is the
count of pixels that differ by more than that.

Usage:
    compare-psx-frames.py A.ppm B.ppm [--diff FILE] [--tolerance N]
                          [--rows] [--row-count N]
"""

import argparse
import sys


def read_ppm(path):
    with open(path, 'rb') as handle:
        data = handle.read()

    # P6 header: magic, width, height, maxval, then the pixels. Comments are
    # allowed between any of them, which is why this walks rather than splits.
    fields = []
    index = 0
    while len(fields) < 4:
        while index < len(data) and data[index:index + 1].isspace():
            index += 1
        if data[index:index + 1] == b'#':
            while index < len(data) and data[index:index + 1] != b'\n':
                index += 1
            continue
        start = index
        while index < len(data) and not data[index:index + 1].isspace():
            index += 1
        fields.append(data[start:index])

    if fields[0] != b'P6':
        raise ValueError(f'{path}: not a P6 PPM')
    width = int(fields[1])
    height = int(fields[2])
    index += 1  # the single whitespace byte after the maxval

    pixels = data[index:index + width * height * 3]
    if len(pixels) != width * height * 3:
        raise ValueError(f'{path}: truncated ({len(pixels)} of {width * height * 3} bytes)')
    return width, height, pixels


def write_ppm(path, width, height, pixels):
    with open(path, 'wb') as handle:
        handle.write(b'P6\n%d %d\n255\n' % (width, height))
        handle.write(pixels)


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument('a')
    parser.add_argument('b')
    parser.add_argument('--diff', default=None, help='write an amplified difference picture here')
    parser.add_argument('--tolerance', type=int, default=4,
                        help='per-channel difference that still counts as a match (default 4)')
    parser.add_argument('--rows', action='store_true', help='report the worst rows')
    parser.add_argument('--row-count', type=int, default=12)
    args = parser.parse_args()

    width_a, height_a, pixels_a = read_ppm(args.a)
    width_b, height_b, pixels_b = read_ppm(args.b)

    if (width_a, height_a) != (width_b, height_b):
        print(f'sizes differ: {width_a}x{height_a} vs {width_b}x{height_b}')
        return 1

    width, height = width_a, height_a
    total = width * height
    differing = 0
    exact = 0
    worst = 0
    worst_at = (0, 0)
    total_delta = 0
    row_differing = [0] * height
    diff = bytearray(total * 3)

    for i in range(total):
        ar, ag, ab = pixels_a[i * 3], pixels_a[i * 3 + 1], pixels_a[i * 3 + 2]
        br, bg, bb = pixels_b[i * 3], pixels_b[i * 3 + 1], pixels_b[i * 3 + 2]
        delta = max(abs(ar - br), abs(ag - bg), abs(ab - bb))
        total_delta += delta

        if delta == 0:
            exact += 1
        if delta > args.tolerance:
            differing += 1
            row_differing[i // width] += 1

        if delta > worst:
            worst = delta
            worst_at = (i % width, i // width)

        # Grey where they agree, red scaled by the difference where they do not.
        value = min(255, delta * 4)
        diff[i * 3 + 0] = value
        diff[i * 3 + 1] = 0 if delta > args.tolerance else value // 3
        diff[i * 3 + 2] = 0 if delta > args.tolerance else value // 3

    print(f'{width}x{height}, {total} pixels')
    print(f'  identical:            {exact} ({exact * 100.0 / total:.1f}%)')
    print(f'  differing by >{args.tolerance}:     {differing} ({differing * 100.0 / total:.2f}%)')
    print(f'  mean difference:      {total_delta / total:.2f}')
    print(f'  worst difference:     {worst} at {worst_at[0]},{worst_at[1]}')

    if args.rows and differing:
        ranked = sorted(range(height), key=lambda row: row_differing[row], reverse=True)
        print('  worst rows:')
        for row in ranked[:args.row_count]:
            if row_differing[row] == 0:
                break
            print(f'    row {row:4d}: {row_differing[row]} pixels differ')

    if args.diff:
        write_ppm(args.diff, width, height, diff)
        print(f'  wrote {args.diff}')

    return 0


if __name__ == '__main__':
    sys.exit(main())
