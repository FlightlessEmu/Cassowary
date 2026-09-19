#!/usr/bin/env python3
"""Build a Game Boy test ROM that shows whether a button is pressed.

The ROM fills the screen with white. While the A button is held it fills with
black instead. That gives the iOS port an end-to-end check: if a press reaches
the emulator, the screenshot changes.

This is a test fixture, not a game. It exists so the input path can be verified
without needing a real ROM.

Usage:
    make-test-rom.py <output.gb>
"""

import sys

# --- A very small Game Boy assembler -------------------------------------
#
# Only the instructions this ROM needs. Each helper appends bytes and returns
# the offset of the operand, so jumps can be patched afterwards.

code = bytearray()


def emit(*values):
    code.extend(values)


def ld_a(value):            emit(0x3E, value)
def ld_b(value):            emit(0x06, value)
def ld_de(value):           emit(0x11, value & 0xFF, value >> 8)
def ld_hl(value):           emit(0x21, value & 0xFF, value >> 8)
def ld_c_a():               emit(0x4F)
def ld_a_d():               emit(0x7A)
def ld_a_hl_inc():          emit(0x22)
def ldh_store(offset):      emit(0xE0, offset)
def ldh_load(offset):       emit(0xF0, offset)
def xor_a():                emit(0xAF)
def xor_n(value):           emit(0xEE, value)
def and_n(value):           emit(0xE6, value)
def or_e():                 emit(0xB3)
def dec_b():                emit(0x05)
def dec_de():               emit(0x1B)
def di():                   emit(0xF3)
def halt():                 emit(0x76)


def jr_nz(operand_offset):
    """Emit `JR NZ, r8` and return the offset of the displacement byte."""
    emit(0x20, 0x00)
    return operand_offset + 1


def jr(operand_offset):
    """Emit `JR r8` and return the offset of the displacement byte."""
    emit(0x18, 0x00)
    return operand_offset + 1


def patch_jump(displacement_offset, target):
    """Point a jump at `target`, relative to the instruction after it."""
    # The displacement is measured from the address after the two-byte jump.
    relative = target - (displacement_offset + 1)
    assert -128 <= relative <= 127, f"jump out of range: {relative}"
    code[displacement_offset] = relative & 0xFF


# --- The ROM -------------------------------------------------------------

START = 0x150

di()

# LCD off while VRAM is set up.
ld_a(0x00)
ldh_store(0x40)

# Tile 0: all colour 0.
ld_hl(0x8000)
ld_b(16)
xor_a()
tile0 = len(code)
ld_a_hl_inc()
dec_b()
tile0_jump = jr_nz(len(code))
patch_jump(tile0_jump, tile0)

# Tile 1: all colour 3.
ld_b(16)
ld_a(0xFF)
tile1 = len(code)
ld_a_hl_inc()
dec_b()
tile1_jump = jr_nz(len(code))
patch_jump(tile1_jump, tile1)

# Palette: colour 0 white, colour 3 black.
ld_a(0xE4)
ldh_store(0x47)

# LCD on, background enabled.
ld_a(0x91)
ldh_store(0x40)

# Main loop: pick a tile from the A button, then fill the tile map with it.
loop = len(code)

# Select the action buttons.
#
# JOYP bit 5 selects the action buttons and bit 4 the d-pad, and both are
# active low: writing a 0 to a bit selects that group. So 0x10 selects the
# action buttons, which puts A on bit 0.
ld_a(0x10)
ldh_store(0x00)

# The joypad register needs a couple of reads to settle.
ldh_load(0x00)
ldh_load(0x00)

# Bit 0 is the A button, and it reads 0 while pressed.
and_n(0x01)
xor_n(0x01)                 # 1 while pressed, 0 while not

ld_c_a()                    # C is now the tile number

# Fill the visible tile map (0x9800, 1024 bytes) with tile C.
ld_hl(0x9800)
ld_de(0x0400)
fill = len(code)
emit(0x79)                  # LD A, C
ld_a_hl_inc()
dec_de()
ld_a_d()
or_e()
fill_jump = jr_nz(len(code))
patch_jump(fill_jump, fill)

jump_back = jr(len(code))
patch_jump(jump_back, loop)


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

    title = b'OPENEMU INPUT TEST'
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
