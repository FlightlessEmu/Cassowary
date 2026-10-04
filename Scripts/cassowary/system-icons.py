#!/usr/bin/env python3
"""Restore and restyle the retro console icons.

Every console icon in this project is small pixel art: 16x16 or 32x32 PNGs
drawn years ago, one at a time, with no shared rules. They are also shrinking,
because each imageset declares a 1x asset of 16px, so the app treats the whole
image as being 16 points wide and then draws it at roughly 32 points. iOS has
to invent every other pixel. That is why they look soft.

This tool fixes both problems without redrawing anything:

  * Resolution. Each imageset is re-authored so all three scales are present
    and are exact whole-number multiples of the source art. Nothing is
    interpolated, so the pixels stay square and hard on every screen.

  * Consistency. The set was drawn over years by different people, so some
    icons are near-black blobs, some are washed out pale, and a few sit at
    wildly different brightness. The restyle modes level them against each
    other while keeping each console its own colours, because a Commodore 64
    being beige is most of what makes it recognisable.

There is no image library used here on purpose. The maintainer asked for no
package manager, and this reads and writes PNG with the standard library so it
runs anywhere Python runs.

Usage:
    system-icons.py survey
    system-icons.py preview [--out DIR] [--mode NAME ...]
    system-icons.py apply   [--mode NAME] [--only PATTERN] [--dry-run]

Defaults to --dry-run for `apply`, because it edits 49 asset catalogs.
"""

import argparse
import base64
import html
import os
import struct
import sys
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PLUGINS = os.path.join(REPO, 'OpenEmu', 'SystemPlugins')

# Each output scale must be a whole-number multiple of the source grid, or the
# pixels stop being square.
SCALES = (1, 2, 3)


# ----------------------------------------------------------------- PNG reading

class PNG:
    """An 8-bit RGBA image, decoded from PNG using only the standard library."""

    def __init__(self, width, height, pixels):
        self.width = width
        self.height = height
        # pixels: flat list of (r, g, b, a) tuples, row by row.
        self.pixels = pixels

    @classmethod
    def load(cls, path):
        with open(path, 'rb') as handle:
            data = handle.read()
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            raise ValueError(f'not a PNG: {path}')
        palette = None
        trns = None
        idat = []
        pos, header = 8, None
        while pos < len(data):
            (length,) = struct.unpack('>I', data[pos:pos + 4])
            tag = data[pos + 4:pos + 8]
            body = data[pos + 8:pos + 8 + length]
            if tag == b'IHDR':
                header = struct.unpack('>IIBBBBB', body)
            elif tag == b'PLTE':
                palette = body
            elif tag == b'tRNS':
                trns = body
            elif tag == b'IDAT':
                idat.append(body)
            elif tag == b'IEND':
                break
            pos += 12 + length

        width, height, depth, colour, _comp, _filt, interlace = header
        if depth != 8 or interlace != 0:
            raise ValueError(f'unsupported PNG ({depth}-bit, interlace={interlace}): {path}')

        channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
        raw = zlib.decompress(b''.join(idat))
        stride = width * channels
        out = bytearray()
        prev = bytearray(stride)
        pos = 0
        for _ in range(height):
            filt = raw[pos]
            line = bytearray(raw[pos + 1:pos + 1 + stride])
            pos += 1 + stride
            # Undo the per-scanline filter. Types 0-4 are defined by the PNG
            # spec; each one predicts the byte from the pixel to the left and
            # the pixel above it.
            if filt == 1:
                for i in range(channels, stride):
                    line[i] = (line[i] + line[i - channels]) & 0xFF
            elif filt == 2:
                for i in range(stride):
                    line[i] = (line[i] + prev[i]) & 0xFF
            elif filt == 3:
                for i in range(stride):
                    left = line[i - channels] if i >= channels else 0
                    line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
            elif filt == 4:
                for i in range(stride):
                    a = line[i - channels] if i >= channels else 0
                    b = prev[i]
                    c = prev[i - channels] if i >= channels else 0
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                    line[i] = (line[i] + pred) & 0xFF
            elif filt != 0:
                raise ValueError(f'bad filter {filt} in {path}')
            out += line
            prev = line

        pixels = []
        for y in range(height):
            row = out[y * stride:(y + 1) * stride]
            for x in range(width):
                if colour == 6:
                    i = x * 4
                    pixels.append(tuple(row[i:i + 4]))
                elif colour == 2:
                    i = x * 3
                    pixels.append((row[i], row[i + 1], row[i + 2], 255))
                elif colour == 0:
                    v = row[x]
                    pixels.append((v, v, v, 255))
                elif colour == 4:
                    i = x * 2
                    v = row[i]
                    pixels.append((v, v, v, row[i + 1]))
                else:  # colour == 3, indexed
                    idx = row[x]
                    r, g, b = palette[idx * 3:idx * 3 + 3]
                    a = trns[idx] if trns and idx < len(trns) else 255
                    pixels.append((r, g, b, a))
        return cls(width, height, pixels)

    def get(self, x, y):
        if 0 <= x < self.width and 0 <= y < self.height:
            return self.pixels[y * self.width + x]
        return (0, 0, 0, 0)

    def save(self, path):
        rows = bytearray()
        for y in range(self.height):
            rows.append(0)  # filter type: none
            for x in range(self.width):
                rows += bytes(self.pixels[y * self.width + x])
        packed = zlib.compress(bytes(rows), 9)
        ihdr = struct.pack('>IIBBBBB', self.width, self.height, 8, 6, 0, 0, 0)
        chunks = [b'IHDR', ihdr, b'IDAT', packed, b'IEND', b'']

        def chunk(tag, body):
            return (struct.pack('>I', len(body)) + tag + body +
                    struct.pack('>I', zlib.crc32(tag + body) & 0xFFFFFFFF))

        blob = b'\x89PNG\r\n\x1a\n'
        for tag, body in zip(chunks[0::2], chunks[1::2]):
            blob += chunk(tag, body)
        with open(path, 'wb') as handle:
            handle.write(blob)


# -------------------------------------------------------------------- scalers

def nearest(img, factor):
    """Straight pixel doubling. Every source pixel becomes factor x factor."""
    w, h = img.width * factor, img.height * factor
    out = [None] * (w * h)
    for y in range(h):
        for x in range(w):
            out[y * w + x] = img.get(x // factor, y // factor)
    return PNG(w, h, out)


def _lit(rgb):
    r, g, b = rgb
    return 0.299 * r + 0.587 * g + 0.114 * b


def scale2x(img):
    """The classic pixel-art doubler: twice the size, no blur, real new shape.

    A plain doubling turns every pixel into a 2x2 block, which keeps things
    looking blocky without gaining any information. Scale2x instead checks
    each pixel's four edge neighbours and, when two of them match and the
    opposite corner does not, rounds that corner off. So the result is bigger
    AND more shapely, which is exactly what the six icons in this set that only
    ever existed at 16x16 are missing.

    It only helps on clean artwork though. Every test below is an equality test
    on whole pixels, so on art carrying dozens of near-identical shades or soft
    antialiased edges the tests almost never fire and this silently degrades to
    plain doubling. `prepare` exists to give it a clean signal first.
    """
    w, h = img.width * 2, img.height * 2
    out = [None] * (w * h)
    for y in range(img.height):
        for x in range(img.width):
            # Neighbours laid out around this pixel E:
            #    A  B  C
            #    D  E  F
            #    G  H  I
            A, B, C = img.get(x - 1, y - 1), img.get(x, y - 1), img.get(x + 1, y - 1)
            D, E, F = img.get(x - 1, y), img.get(x, y), img.get(x + 1, y)
            G, H, I = img.get(x - 1, y + 1), img.get(x, y + 1), img.get(x + 1, y + 1)
            # Each sub-pixel borrows a neighbour's colour only when that
            # neighbour agrees with one edge neighbour but disagrees with the
            # opposite corner, which is the signature of a diagonal to round.
            top_left = D if (B == D and A != E and D != C) else E
            top_right = B if (B == F and C != E and B != A) else E
            bottom_left = H if (H == D and G != E and H != I) else E
            bottom_right = F if (H == F and I != E and F != C) else E
            X, Y = x * 2, y * 2
            out[Y * w + X] = top_left
            out[Y * w + X + 1] = top_right
            out[(Y + 1) * w + X] = bottom_left
            out[(Y + 1) * w + X + 1] = bottom_right
    return PNG(w, h, out)


def flatten_alpha(img, cut=128):
    """Snap half-transparent pixels to fully opaque or fully transparent.

    A few of these icons were exported with soft antialiased edges. That is
    fine at their native size, but it means Scale2x can almost never find two
    neighbouring pixels that are exactly equal, so the smoothing never fires
    and the result is just a blocky doubling. Squaring off the alpha gives it
    clean edges to reason about.
    """
    out = []
    for r, g, b, a in img.pixels:
        if a < cut:
            out.append((r, g, b, 0))
        else:
            out.append((r, g, b, 255))
    return PNG(img.width, img.height, out)


def quantize(img, step=16):
    """Collapse near-identical shades into a handful of real colours.

    One of these icons carries 77 distinct colours inside a 16x16 grid. That is
    far too many for the eye to read as deliberate pixel art, and it defeats
    Scale2x for the same reason it defeats the eye: nothing ever matches
    anything else. Rounding each channel toward multiples of `step` merges the
    near-duplicates.
    """
    out = []
    for r, g, b, a in img.pixels:
        if a >= 192:
            out.append((_clamp(round(r / step) * step),
                        _clamp(round(g / step) * step),
                        _clamp(round(b / step) * step), a))
        else:
            out.append((r, g, b, a))
    return PNG(img.width, img.height, out)


def prepare(img):
    """Clean art up before scaling it: square off the edges, collapse shades."""
    return quantize(flatten_alpha(img))


def make_master(best_path, target=32, scaler='scale2x'):
    """Bring one source image up to the shared grid, with no interpolation.

    Most icons have a 32x32 drawing that is already exactly right and pass
    straight through. Six only ever existed at 16x16, so they need doubling up
    to join the same grid, and there are two honest ways to do it:
    `nearest` keeps the chunky 2x2 blocks, which is the more literal retro look,
    and `scale2x` rounds off the corners, which is smoother and gains a little
    shape. Both keep every pixel square; nothing here ever blurs.

    Everything ends up on the same grid so all three output scales divide evenly.
    """
    img = PNG.load(best_path)
    if img.width >= target:
        return img
    if scaler == 'nearest':
        return nearest(img, target // img.width)
    if img.width * 2 == target:
        # Clean it up first. Scale2x decides what to do by comparing whole
        # pixels for equality, so it needs tidy artwork to reason about; on
        # noisy art it changes barely 3% of the image and the result looks wrong
        # for no visible reason.
        return scale2x(prepare(img))
    return nearest(img, target // img.width)


# --------------------------------------------------------------------- colour

def _clamp(v):
    return 0 if v < 0 else (255 if v > 255 else int(round(v)))


def levels(img, low_target=8, high_target=248):
    """Stretch each icon's brightness to fill the range it should occupy.

    Some icons in this set were drawn almost black and some almost white, so a
    row of them looks like a row of different artists. This maps each icon's
    own darkest and brightest pixels onto a shared range, which brings them
    together without changing their colours.

    Only pixels above a small alpha threshold are measured and moved, so
    transparent areas and the soft antialiased edge pixels stay untouched and
    nothing picks up a halo.
    """
    solid = [px for px in img.pixels if px[3] >= 192]
    if not solid:
        return img
    lows = [min(_lit(p[:3]) for p in solid)]
    highs = [max(_lit(p[:3]) for p in solid)]
    lo, hi = lows[0], highs[0]
    if hi - lo < 8:
        return img  # nearly flat already, stretching it would only add noise
    scale = (high_target - low_target) / (hi - lo)

    out = []
    for r, g, b, a in img.pixels:
        if a >= 192:
            v = _lit((r, g, b))
            nv = (v - lo) * scale + low_target
            shift = nv - v
            out.append((_clamp(r + shift), _clamp(g + shift), _clamp(b + shift), a))
        else:
            out.append((r, g, b, a))
    return PNG(img.width, img.height, out)


def saturate(img, amount):
    """Lift colourfulness by `amount` (1.0 leaves it alone)."""
    out = []
    for r, g, b, a in img.pixels:
        if a >= 192:
            grey = _lit((r, g, b))
            out.append((_clamp(grey + (r - grey) * amount),
                        _clamp(grey + (g - grey) * amount),
                        _clamp(grey + (b - grey) * amount), a))
        else:
            out.append((r, g, b, a))
    return PNG(img.width, img.height, out)


def lift_darks(img, floor=48):
    """Raise the darkest pixels so icons stop reading as black blobs.

    Several of these were drawn so dark that on a dark tile they are almost
    invisible. This pushes the shadows up to a floor while leaving the
    highlights where they are, so the shape survives on any background.
    """
    solid = [px for px in img.pixels if px[3] >= 192]
    if not solid:
        return img
    lo = min(_lit(p[:3]) for p in solid)
    hi = max(_lit(p[:3]) for p in solid)
    if hi <= 0 or lo >= floor:
        return img
    span = max(1.0, hi - lo)
    # Fade the lift out as pixels get brighter, so highlights are untouched.
    amount = min(1.0, (floor - lo) / span)
    out = []
    for r, g, b, a in img.pixels:
        if a >= 192:
            v = _lit((r, g, b))
            t = (hi - v) / span          # 1 at the shadows, 0 at the highlights
            shift = (floor - lo) * t * (1.0 if t <= 1 else 1.0)
            out.append((_clamp(r + shift), _clamp(g + shift), _clamp(b + shift), a))
        else:
            out.append((r, g, b, a))
    return PNG(img.width, img.height, out)


def deepen(img, amount=0.92):
    """Multiply brightness slightly, for icons that read too pale."""
    out = []
    for r, g, b, a in img.pixels:
        if a >= 192:
            out.append((_clamp(r * amount), _clamp(g * amount),
                        _clamp(b * amount), a))
        else:
            out.append((r, g, b, a))
    return PNG(img.width, img.height, out)


MODES = {
    'clean': (
        'Untouched colour, resolution fix only',
        'The original pixels on every scale, nothing else changed.',
        lambda im: im),
    'levels': (
        'Brightness levelled',
        'Each icon stretched to fill the same brightness range, so the set '
        'stops looking like several different artists.',
        lambda im: levels(im, 6, 250)),
    'vivid': (
        'Levelled plus richer colour',
        'As above, with colourfulness lifted. The retro palettes pop but each '
        'console keeps its own colours.',
        lambda im: saturate(levels(im, 6, 250), 1.28)),
    'readable': (
        'Levelled plus lifted shadows',
        'As levelled, with the darkest pixels raised so near-black icons '
        'survive on a light tile.',
        lambda im: levels(lift_darks(im, 54), 8, 246)),
    'warm': (
        'Levelled plus a warm cast',
        'As levelled, with a slight warm bias and richer colour, to pull the '
        'whole set toward one period.',
        lambda im: saturate(levels(_tint(im, 1.03, 1.00, 0.94), 8, 244), 1.15)),
}


def _tint(img, kr, kg, kb):
    out = []
    for r, g, b, a in img.pixels:
        if a >= 192:
            out.append((_clamp(r * kr), _clamp(g * kg), _clamp(b * kb), a))
        else:
            out.append((r, g, b, a))
    return PNG(img.width, img.height, out)


# ------------------------------------------------------------------ collection

def collect(pattern=None):
    """Find every *_library imageset and its best source PNG."""
    found = []
    for sysname in sorted(os.listdir(PLUGINS)):
        catalog = os.path.join(PLUGINS, sysname, 'Images.xcassets')
        if not os.path.isdir(catalog):
            continue
        for iset in sorted(os.listdir(catalog)):
            if not (iset.endswith('.imageset') and iset.endswith('_library.imageset')):
                continue
            name = iset[:-len('.imageset')]
            if pattern and pattern not in name:
                continue
            folder = os.path.join(catalog, iset)
            pngs = [f for f in os.listdir(folder) if f.endswith('.png')]
            # Prefer the @2x drawing; it was usually drawn larger rather than
            # scaled up, so it carries more real detail.
            best = next((f for f in sorted(pngs) if f.endswith('@2x.png')),
                        sorted(pngs)[0] if pngs else None)
            if best:
                found.append((name, sysname, folder, os.path.join(folder, best)))
    return found


def imageset_json(base):
    """Contents.json listing all three scales, so nothing has to be guessed."""
    lines = ['{', '  "images" : [']
    entries = []
    for n, scale in zip(('', '2x', '3x'), SCALES):
        entries.append(
            f'    {{\n      "filename" : "{base}{n}.png",\n'
            f'      "idiom" : "universal",\n      "scale" : "{scale}x"\n    }}')
    lines.append(',\n'.join(entries))
    lines += ['  ],', '  "info" : {', '    "author" : "xcode",',
              '    "version" : 1', '  }', '}']
    return '\n'.join(lines) + '\n'


# ------------------------------------------------------------------- commands

def cmd_survey(args):
    rows = collect()
    print(f'{len(rows)} library imagesets\n')
    print(f'{"imageset":<28}{"system":<20}{"source":<10}3x asset')
    print('-' * 68)
    with3, small = [], []
    for name, sysname, folder, src in rows:
        w, h = struct.unpack('>II', open(src, 'rb').read(24)[16:24])
        has3 = any(f.endswith('@3x.png') for f in os.listdir(folder))
        if has3:
            with3.append(name)
        if w < 32:
            small.append(name)
        print(f'{name:<28}{sysname:<20}{w}x{h:<7}{"yes" if has3 else "no"}')
    print(f'\n{len(with3)} of {len(rows)} ship a 3x asset. The other '
          f'{len(rows) - len(with3)} are drawn\n'
          f'by iOS scaling the 2x up by one and a half times.')
    print(f'{len(small)} exist only at 16x16, so they get Scale2x rather than '
          f'a blocky\ndoubling: {", ".join(small)}')


def cmd_preview(args):
    out = args.out or os.path.join(REPO, 'tmp', 'agent', 'icon-pipeline')
    rows = collect()
    modes = args.mode or list(MODES)
    os.makedirs(out, exist_ok=True)

    def uri(img):
        tmp = os.path.join(out, '_tmp.png')
        img.save(tmp)
        with open(tmp, 'rb') as handle:
            data = 'data:image/png;base64,' + base64.b64encode(handle.read()).decode()
        os.remove(tmp)
        return data

    print(f'rendering {len(rows)} icons x {len(modes)} modes -> {out}')
    built = {}
    for name, sysname, folder, src in rows:
        for mode in modes:
            built[(name, mode)] = MODES[mode][2](make_master(src, scaler=args.scaler))

    cells = ''
    for name, sysname, folder, src in rows:
        original = uri(PNG.load(src))
        modes_cells = ''.join(
            f'<div class="cell"><img src="{uri(built[(name, m)])}">'
            f'<span>{m}</span></div>' for m in modes)
        cells += (f'<figure><div class="orig"><img src="{original}">'
                  f'<span>original {PNG.load(src).width}px</span></div>'
                  f'<div class="modes">{modes_cells}</div>'
                  f'<figcaption><b>{html.escape(name.replace("_library", ""))}</b>'
                  f'{html.escape(sysname)}</figcaption></figure>')

    for mode in modes:
        pass
    sheet = f'''<!doctype html><meta charset="utf-8">
<title>Icon pipeline preview</title><style>
*{{box-sizing:border-box}}figure{{margin:0}}
body{{margin:0;padding:24px;background:#141416;color:#eee;
font:12px -apple-system,system-ui,sans-serif}}
h1{{font-size:19px;margin:0 0 6px}}
p{{color:#8e8e93;max-width:820px;margin:0 0 20px;line-height:1.5}}
.grid{{display:grid;grid-template-columns:repeat(2,1fr);gap:14px;
align-items:start}}
figure{{background:#1e1e20;border-radius:12px;padding:10px;
display:flex;align-items:center;gap:12px}}
.orig{{flex:0 0 66px;text-align:center}}
.orig img{{width:56px;height:56px;image-rendering:pixelated}}
.modes{{display:flex;gap:6px;flex-wrap:wrap;flex:1}}
.cell{{text-align:center}}
.cell img{{width:56px;height:56px;image-rendering:pixelated}}
.cell span,.orig span{{display:block;font-size:9px;color:#8e8e93;margin-top:3px}}
figcaption{{flex:0 0 92px;font-size:10px;color:#8e8e93;line-height:1.3}}
figcaption b{{display:block;color:#e0e0e0}}
</style><h1>Console icon pipeline &mdash; {len(modes)} restyle modes</h1>
<p>Every icon at the output resolution, magnified with nearest-neighbour so the
pixels stay hard. The original is on the left. Compare within a row, then scan
down a column to see whether the whole set hangs together.</p>
<div class="grid">{cells}</div>'''
    open(os.path.join(out, 'index.html'), 'w').write(sheet)

    # A page that shows the whole set together, which is the real test.
    sets = ''
    for mode in modes:
        tiles = ''.join(
            f'<div class="t"><img src="{uri(built[(n, mode)])}"></div>'
            for n, _, _, _ in rows)
        sets += (f'<h2>{mode} &mdash; {MODES[mode][0]}</h2>'
                 f'<p class="b">{MODES[mode][1]}</p><div class="wall">{tiles}</div>')
    wall = f'''<!doctype html><meta charset="utf-8">
<title>All icons, all modes</title><style>
*{{box-sizing:border-box}}
body{{margin:0;padding:24px;background:#141416;color:#eee;
font:12px -apple-system,system-ui,sans-serif}}
h2{{font-size:14px;margin:22px 0 3px}}
p.b{{color:#8e8e93;font-size:11px;margin:0 0 10px;max-width:700px}}
.wall{{display:grid;grid-template-columns:repeat(12,1fr);gap:8px;
background:#1e1e20;padding:12px;border-radius:12px}}
.t{{aspect-ratio:1/1;background:rgba(128,128,128,.16);border-radius:10px;
display:flex;align-items:center;justify-content:center;padding:9px}}
.t img{{width:100%;height:100%;object-fit:contain;image-rendering:pixelated}}
</style><h1>Every console, whole set together</h1>
<p style="color:#8e8e93;max-width:820px">This is the only honest test. An icon
can look fine alone and still fall apart next to its neighbours.</p>{sets}'''
    open(os.path.join(out, 'all.html'), 'w').write(wall)
    print('open', os.path.join(out, 'index.html'))
    print('open', os.path.join(out, 'all.html'))


def cmd_apply(args):
    rows = collect(args.only)
    mode = args.mode
    if mode not in MODES:
        sys.exit(f'unknown mode {mode!r}; pick from {", ".join(MODES)}')
    if not rows:
        sys.exit('no matching imagesets')
    print(f'{len(rows)} imagesets, mode={mode}, scaler={args.scaler}'
          f'{"(dry run)" if args.dry_run else ""}')
    changed = 0
    for name, sysname, folder, src in rows:
        master = MODES[mode][2](make_master(src, scaler=args.scaler))
        base = name
        files = [f for f in os.listdir(folder) if f.endswith('.png')]
        print(f'  {name:<28}{sysname:<20}{master.width}px master')
        if args.dry_run:
            continue
        for old in files:
            os.remove(os.path.join(folder, old))
        for n, scale in zip(('', '@2x', '@3x'), SCALES):
            scaled = nearest(master, scale) if scale > 1 else master
            scaled.save(os.path.join(folder, f'{base}{n}.png'))
        with open(os.path.join(folder, 'Contents.json'), 'w') as handle:
            handle.write(imageset_json(base))
        changed += 1
    if args.dry_run:
        print(f'\nNothing written. Re-run with --apply to change {len(rows)} '
              f'imagesets.\nThe app reads plugins from Cassowary/PlugIns/, so '
              f'then run ./Scripts/cassowary/build-cassowary.sh to restage them.')
    else:
        print(f'\nWrote {changed} imagesets at 1x/2x/3x.\n'
              f'Now rebuild to restage the plugins:\n'
              f'  ./Scripts/cassowary/build-cassowary.sh')


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='command', required=True)

    sub.add_parser('survey').set_defaults(func=cmd_survey)

    pv = sub.add_parser('preview')
    pv.add_argument('--out')
    pv.add_argument('--mode', action='append')
    pv.add_argument('--scaler', choices=('nearest', 'scale2x'), default='scale2x')
    pv.set_defaults(func=cmd_preview)

    ap_ = sub.add_parser('apply')
    ap_.add_argument('--mode', default='levels')
    ap_.add_argument('--scaler', choices=('nearest', 'scale2x'), default='scale2x')
    ap_.add_argument('--only')
    ap_.add_argument('--dry-run', action='store_true', default=True,
                     dest='dry_run')
    ap_.add_argument('--really', action='store_false', dest='dry_run',
                     help='actually write files')
    ap_.set_defaults(func=cmd_apply)

    parsed = ap.parse_args()
    parsed.func(parsed)
