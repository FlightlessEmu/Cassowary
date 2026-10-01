#!/usr/bin/env python3
"""Build an NES test ROM that shows whether the Famicom microphone is heard.

The Famicom's second controller had a microphone, which games read as bit 2
of $4016. This ROM reads that bit over and over and fills the screen with
white while it is set, black otherwise. A few reads are combined because
FCEU flickers the bit on and off while the microphone is held, the way a
real voice would.

Usage:
    make-nes-mic-rom.py <output.nes>
"""

import sys

BASE = 0xC000

code = bytearray([
    0x78,                    # sei
    0xD8,                    # cld
    0xA2, 0xFF, 0x9A,        # ldx #$FF; txs
    0xA9, 0x00,              # lda #0
    0x8D, 0x00, 0x20,        # sta $2000   no NMI
    0x8D, 0x01, 0x20,        # sta $2001   rendering off: the backdrop fills the screen
    0x2C, 0x02, 0x20,        # bit $2002   wait for the PPU to warm up
    0x10, 0xFB,              # bpl -5
    0x2C, 0x02, 0x20,        # bit $2002
    0x10, 0xFB,              # bpl -5
])
loop = BASE + len(code)
code += bytes([
    0xA9, 0x01, 0x8D, 0x16, 0x40,    # strobe the pads
    0xA9, 0x00, 0x8D, 0x16, 0x40,
    0xAD, 0x16, 0x40,                # lda $4016
] + [0x0D, 0x16, 0x40] * 7 + [       # ora $4016, seven times
    0x29, 0x04,              # and #4      the microphone bit
    0xF0, 0x04,              # beq dark
    0xA9, 0x30,              # lda #$30    white
    0xD0, 0x02,              # bne store
    0xA9, 0x0F,              # dark: lda #$0F   black
    0xAA,                    # store: tax
    0x2C, 0x02, 0x20,        # bit $2002   reset the address latch
    0xA9, 0x3F, 0x8D, 0x06, 0x20, 0xA9, 0x00, 0x8D, 0x06, 0x20,   # $3F00, the backdrop
    0x8E, 0x07, 0x20,        # stx $2007
    0xA9, 0x3F, 0x8D, 0x06, 0x20, 0xA9, 0x00, 0x8D, 0x06, 0x20,   # point back at it to show it
    0x4C, loop & 0xFF, loop >> 8,    # jmp loop
])
interrupt = BASE + len(code)
code.append(0x40)            # rti

prg = code + bytearray(0x4000 - len(code))
prg[0x3FFA:] = bytes([interrupt & 0xFF, interrupt >> 8,  # NMI
                      BASE & 0xFF, BASE >> 8,            # reset
                      interrupt & 0xFF, interrupt >> 8]) # IRQ

header = b"NES\x1a" + bytes([1, 1, 0, 0]) + bytes(8)  # 16 KB code, 8 KB graphics, mapper 0
with open(sys.argv[1], "wb") as out:
    out.write(header + prg + bytes(0x2000))
