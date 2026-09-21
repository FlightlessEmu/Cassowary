#!/usr/bin/env python3
"""Build a Game Boy demo ROM: a ball you steer with the d-pad.

This exists so the iOS port has something visible to show. It draws a patterned
background, puts a ball sprite on top, and moves the ball while a direction is
held. That exercises the whole pipeline: video, the sprite layer, and input.

This is a test fixture, not a game.

Usage:
    make-demo-rom.py <output.gb>
"""

import sys

# --- A very small Game Boy assembler -------------------------------------
#
# Only the instructions this ROM needs. Jumps are written against named labels
# and patched at the end, so their offsets never have to be counted by hand —
# getting that wrong silently corrupts execution.

code = bytearray()
labels = {}
pending_jumps = []          # (offset of the displacement byte, label name)

JR_CONDITIONS = {'nz': 0x20, 'z': 0x28, 'nc': 0x30, 'c': 0x38}


def emit(*values):
    code.extend(values)


def label(name):
    assert name not in labels, f"duplicate label {name}"
    labels[name] = len(code)


def jr_to(condition, name):
    emit(JR_CONDITIONS[condition], 0x00)
    pending_jumps.append((len(code) - 1, name))


def jr_always(name):
    emit(0x18, 0x00)
    pending_jumps.append((len(code) - 1, name))


def resolve_jumps():
    for offset, name in pending_jumps:
        target = labels[name]
        # The displacement is measured from the instruction after the jump.
        relative = target - (offset + 1)
        assert -128 <= relative <= 127, f"jump to {name} out of range: {relative}"
        code[offset] = relative & 0xFF


# Loads and stores.
def ld_a(value):        emit(0x3E, value)
def ld_b(value):        emit(0x06, value)
def ld_c(value):        emit(0x0E, value)
def ld_d(value):        emit(0x16, value)
def ld_bc(value):       emit(0x01, value & 0xFF, value >> 8)
def ld_de(value):       emit(0x11, value & 0xFF, value >> 8)
def ld_hl(value):       emit(0x21, value & 0xFF, value >> 8)

def ld_a_from_hl_inc(): emit(0x2A)
def ld_a_to_hl_inc():   emit(0x22)
def ld_a_to_hl():       emit(0x77)
def ld_b_a():           emit(0x47)
def ld_c_a():           emit(0x4F)
def ld_a_d():           emit(0x7A)

def ldh_store(offset):  emit(0xE0, offset)
def ldh_load(offset):   emit(0xF0, offset)

def ld_a_from_abs(addr): emit(0xFA, addr & 0xFF, addr >> 8)
def ld_a_to_abs(addr):   emit(0xEA, addr & 0xFF, addr >> 8)

# Arithmetic and logic.
def inc_a():            emit(0x3C)
def inc_d():            emit(0x14)
def dec_a():            emit(0x3D)
def dec_b():            emit(0x05)
def dec_bc():           emit(0x0B)
def dec_de():           emit(0x1B)
def add_n(value):       emit(0xC6, value)
def cp_n(value):        emit(0xFE, value)
def and_n(value):       emit(0xE6, value)
def or_c():             emit(0xB1)
def or_e():             emit(0xB3)
def xor_a():            emit(0xAF)
def bit_b(index):       emit(0xCB, 0x40 + index * 8)
def rrca():             emit(0x0F)
def di():               emit(0xF3)


# --- Tiles ---------------------------------------------------------------

# Two bytes of tile data per row: the low bit plane then the high bit plane.
# A pixel's colour is (high << 1) | low, so 0b11 gives colour 3.
def tile(rows):
    out = bytearray()
    for low, high in rows:
        out.append(low)
        out.append(high)
    assert len(out) == 16, "a tile is 16 bytes"
    return bytes(out)


TILES = {
    'blank': tile([(0x00, 0x00)] * 8),
    'light': tile([(0xFF, 0x00)] * 8),
    'dark':  tile([(0x00, 0xFF)] * 8),
    'black': tile([(0xFF, 0xFF)] * 8),

    # A round ball, used for the sprite.
    'ball': tile([
        (0x00, 0x00),
        (0x3C, 0x3C),
        (0x7E, 0x7E),
        (0x7E, 0x7E),
        (0x7E, 0x7E),
        (0x7E, 0x7E),
        (0x3C, 0x3C),
        (0x00, 0x00),
    ]),
}

TILE_ORDER = ['blank', 'light', 'dark', 'black', 'ball']
BLANK, LIGHT, DARK, BLACK, BALL = range(len(TILE_ORDER))

# Work RAM addresses for the ball's position.
VAR_X = 0xC000
VAR_Y = 0xC001

# The play area, in game pixels.
MIN_X, MAX_X = 0, 152
MIN_Y, MAX_Y = 0, 136

START = 0x150

# --- Program -------------------------------------------------------------

di()

# LCD off while VRAM is set up.
xor_a()
ldh_store(0x40)

# Load the tiles at 0x8000, in TILE_ORDER.
ld_hl(0x8000)
for name in TILE_ORDER:
    for byte in TILES[name]:
        ld_a(byte)
        ld_a_to_hl_inc()

# Fill the background tile map (0x9800, 1024 bytes).
#
# The tile is taken from a counter, not from the map contents, because the map
# starts as zeros. Bits 3 and 4 of the counter change every eight cells, which
# gives a repeating band of the four shades.
ld_hl(0x9800)
ld_bc(32 * 32)
ld_d(0)
label('fill')
ld_a_d()
and_n(0x18)
rrca()
rrca()
rrca()                  # 0x18 -> 0x03
ld_a_to_hl_inc()
inc_d()
dec_bc()
emit(0x78)              # LD A, B
or_c()
jr_to('nz', 'fill')

# The ball starts in the middle.
ld_a(72)
ld_a_to_abs(VAR_X)
ld_a(64)
ld_a_to_abs(VAR_Y)

# Hide every sprite first by setting Y to 0, which puts it above the screen.
# OAM starts as zeros anyway, but being explicit means a stray sprite can never
# show up if that assumption is wrong.
ld_hl(0xFE00)
ld_bc(40 * 4)
label('clear_oam')
# A has to be re-zeroed every pass: the loop test below overwrites it.
xor_a()
ld_a_to_hl_inc()
dec_bc()
emit(0x78)              # LD A, B
or_c()
jr_to('nz', 'clear_oam')

# Sprite 0: Y, X, tile, attributes.
ld_a(64 + 16)
ld_a_to_abs(0xFE00)
ld_a(72 + 8)
ld_a_to_abs(0xFE01)
ld_a(BALL)
ld_a_to_abs(0xFE02)
xor_a()
ld_a_to_abs(0xFE03)

# Palettes: the same four shades for the background and the sprite.
ld_a(0xE4)
ldh_store(0x47)         # BGP
ld_a(0xE4)
ldh_store(0x48)         # OBP0

# Scroll to the origin.
xor_a()
ldh_store(0x42)         # SCY
xor_a()
ldh_store(0x43)         # SCX

# LCD on, background on, sprites on, tiles at 0x8000, 8x8 sprites.
ld_a(0x93)
ldh_store(0x40)

# --- Main loop -----------------------------------------------------------
#
# Read the d-pad, nudge the ball, write the sprite position back, then wait for
# the frame to end so the ball moves at a readable speed.

label('loop')

# Select the direction buttons: JOYP bit 4 low.
ld_a(0x20)
ldh_store(0x00)
# The register needs a couple of reads to settle.
ldh_load(0x00)
ldh_load(0x00)
ld_b_a()                # B = the button state; 0 means pressed

# Right, on bit 0.
bit_b(0)
jr_to('nz', 'after_right')
ld_a_from_abs(VAR_X)
cp_n(MAX_X)
jr_to('nc', 'after_right')
inc_a()
ld_a_to_abs(VAR_X)
label('after_right')

# Left, on bit 1.
bit_b(1)
jr_to('nz', 'after_left')
ld_a_from_abs(VAR_X)
cp_n(MIN_X)
jr_to('z', 'after_left')
dec_a()
ld_a_to_abs(VAR_X)
label('after_left')

# Up, on bit 2.
bit_b(2)
jr_to('nz', 'after_up')
ld_a_from_abs(VAR_Y)
cp_n(MIN_Y)
jr_to('z', 'after_up')
dec_a()
ld_a_to_abs(VAR_Y)
label('after_up')

# Down, on bit 3.
bit_b(3)
jr_to('nz', 'after_down')
ld_a_from_abs(VAR_Y)
cp_n(MAX_Y)
jr_to('nc', 'after_down')
inc_a()
ld_a_to_abs(VAR_Y)
label('after_down')

# Copy the position into the sprite, adding the hardware's origin offset:
# sprites are placed relative to (8, 16).
ld_a_from_abs(VAR_Y)
add_n(16)
ld_a_to_abs(0xFE00)
ld_a_from_abs(VAR_X)
add_n(8)
ld_a_to_abs(0xFE01)

# Wait for vblank to start.
label('wait_vblank')
ldh_load(0x44)          # LY
cp_n(144)
jr_to('nz', 'wait_vblank')

# Then wait for it to end, so the loop runs once per frame.
label('wait_end')
ldh_load(0x44)
cp_n(144)
jr_to('z', 'wait_end')

jr_always('loop')

resolve_jumps()


def build_rom(path):
    ROM_SIZE = 32768
    rom = bytearray(ROM_SIZE)

    # Entry point.
    rom[0x100:0x104] = bytes([0x00, 0xC3, START & 0xFF, START >> 8])

    # Nintendo logo, checked by the boot ROM.
    rom[0x104:0x134] = bytes([
        0xCE,0xED,0x66,0x66,0xCC,0x0D,0x00,0x0B,0x03,0x73,0x00,0x83,0x00,0x0C,0x00,0x0D,
        0x00,0x08,0x11,0x1F,0x88,0x89,0x00,0x0E,0xDC,0xCC,0x6E,0xE6,0xDD,0xDD,0xD9,0x99,
        0xBB,0xBB,0x67,0x63,0x6E,0x0E,0xEC,0xCC,0xDD,0xDC,0x99,0x9F,0xBB,0xB9,0x33,0x3E,
    ])

    title = b'OPENEMU DEMO'
    rom[0x134:0x134 + len(title)] = title
    rom[0x147] = 0x00    # ROM only
    rom[0x148] = 0x00    # 32 KB
    rom[0x149] = 0x00    # no cartridge RAM

    checksum = 0
    for i in range(0x134, 0x14D):
        checksum = (checksum - rom[i] - 1) & 0xFF
    rom[0x14D] = checksum

    rom[START:START + len(code)] = code
    assert START + len(code) < ROM_SIZE, "program is too large"

    total = sum(rom) & 0xFFFF
    rom[0x14E] = (total >> 8) & 0xFF
    rom[0x14F] = total & 0xFF

    with open(path, 'wb') as fh:
        fh.write(rom)

    return len(code)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    size = build_rom(sys.argv[1])
    print(f"wrote {sys.argv[1]} ({size} bytes of code)")
