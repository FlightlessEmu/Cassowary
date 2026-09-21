#!/usr/bin/env python3
"""Build a Commodore 64 test program for the end-to-end check.

The program is a BASIC SYS stub plus machine language that shows the
joystick-2 fire button on the background color (white while up, black
while held). It reads CIA1 Port A directly because Open ROMs BASIC has
no PEEK and ignores SYS targets it cannot reach — plain BASIC cannot
observe the joystick with the built-in ROMs.

This is a test fixture, not a game.

Usage:
    make-c64-test-rom.py <output.prg>
"""

import sys

# The fire-button test cannot use BASIC: Open ROMs BASIC has no PEEK
# (SYNTAX ERROR) and no AND/division path that works here. So the test
# program is a BASIC SYS stub plus machine language that reads CIA1
# Port A ($DC00, joystick 2 = the Fire button) and shows bit 4 on the
# background color: white while fire is up, black while held.
#
#   $0810: AD 00 DC  LDA $DC00
#   $0813: 29 10     AND #$10      (isolate the fire bit)
#   $0815: 4A x4     LSR x4        (move it to bit 0: 1 or 0)
#   $0819: 8D 21 D0  STA $D021     (background: white or black)
#   $081C: 4C 10 08  JMP $0810     (do it forever)
SYS = 0x9E

stub = bytes([SYS, 0x20]) + b"2064"
machine = bytes([0xAD, 0x00, 0xDC, 0x29, 0x10, 0x4A, 0x4A, 0x4A, 0x4A,
                 0x8D, 0x21, 0xD0, 0x4C, 0x10, 0x08])

lines = [(10, stub)]

# Assemble the program, patching each line's forward link as we go.
program = bytearray()
address = 0x0801
for index, (number, body) in enumerate(lines):
    end = address + 4 + len(body) + 1
    next_address = 0 if index == len(lines) - 1 else end
    program += bytes([next_address & 0xFF, next_address >> 8,
                      number & 0xFF, number >> 8])
    program += body
    program += b"\x00"
    address = end

program += b"\x00\x00"  # end of the program

# Pad out to the machine-language origin and append it.
origin = 0x0810
assert address <= origin, "stub ran into the machine code"
program += bytes(origin - address) + machine

# A PRG starts with the two-byte load address.
image = bytes([0x01, 0x08]) + bytes(program)

if len(sys.argv) != 2:
    print(__doc__, file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1], "wb") as handle:
    handle.write(image)

print(f"wrote {sys.argv[1]} ({len(image)} bytes)")
