#!/usr/bin/env python3
"""Builds a small Super Nintendo test cartridge for bsnes.

The screen colour shows the button pressed last, so a short tap also stays visible:
A blue, B green, X white, Y yellow, L purple, R pink, D-pad red; orange at the start.
ATTIC is written in tiles.
Usage: python3 TestPrograms/snes.py <out.sfc>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from font import GLYPHS  # noqa: E402


def bgr555(r, g, b):
    return (r >> 3) | (g >> 3) << 5 | (b >> 3) << 10


class Assembler65816:
    """Just enough 65816 for this program, with A in 8-bit and X/Y in 16-bit mode."""

    def __init__(self, origin):
        self.origin = origin
        self.code = bytearray()
        self.labels = {}
        self.fixups = []

    def label(self, name):
        self.labels[name] = self.origin + len(self.code)

    def emit(self, *values):
        self.code += bytes(values)

    def absolute(self, opcode, address):
        self.emit(opcode)
        if isinstance(address, str):
            self.fixups.append(("abs", len(self.code), address))
            self.emit(0, 0)
        else:
            self.emit(address & 0xFF, address >> 8 & 0xFF)

    def branch(self, opcode, target):
        self.emit(opcode)
        self.fixups.append(("rel", len(self.code), target))
        self.emit(0)

    def resolve(self):
        for kind, position, target in self.fixups:
            address = self.labels[target]
            if kind == "rel":
                delta = address - (self.origin + position + 1)
                assert -128 <= delta <= 127, target
                self.code[position] = delta & 0xFF
            else:
                self.code[position:position + 2] = (address & 0xFFFF).to_bytes(2, "little")
        return bytes(self.code)


def program():
    a = Assembler65816(0x8000)
    a.label("reset")
    a.emit(0x78)              # sei
    a.emit(0x18, 0xFB)        # clc, xce: native mode
    a.emit(0xC2, 0x10)        # rep #$10: 16-bit X/Y
    a.emit(0xE2, 0x20)        # sep #$20: 8-bit A
    a.emit(0xA2, 0xFF, 0x1F)  # ldx #$1FFF
    a.emit(0x9A)              # txs
    a.emit(0xA9, 0x8F); a.absolute(0x8D, 0x2100)  # forced blank
    a.absolute(0x9C, 0x4200)                       # stz: no interrupts yet

    # Background 1: 32×32 tile map at VRAM $0000, 2bpp tiles at VRAM $1000.
    a.emit(0xA9, 0x00); a.absolute(0x8D, 0x2105)   # mode 0
    a.emit(0xA9, 0x00); a.absolute(0x8D, 0x2107)   # BG1 map at word $0000
    a.emit(0xA9, 0x01); a.absolute(0x8D, 0x210B)   # BG1 tiles at word $1000
    a.emit(0xA9, 0x80); a.absolute(0x8D, 0x2115)   # increment after the high byte
    # Clear the tile map (32×32 words).
    a.absolute(0x9C, 0x2116); a.absolute(0x9C, 0x2117)
    a.emit(0xA2, 0x00, 0x04)                       # ldx #1024
    a.label("clear")
    a.absolute(0x9C, 0x2118); a.absolute(0x9C, 0x2119)
    a.emit(0xCA)                                   # dex
    a.branch(0xD0, "clear")
    # Letter tiles from tile 1 (word $1008) onwards, 8 words each.
    tile_words = []
    for letter in "ATIC":
        for row in range(8):
            bits = (GLYPHS[letter][row] << 2) & 0xFF if row < 7 else 0
            tile_words.append(bits | bits << 8)  # both planes: colour 3
    a.emit(0xA9, 0x08); a.absolute(0x8D, 0x2116); a.emit(0xA9, 0x10); a.absolute(0x8D, 0x2117)
    for word in tile_words:
        a.emit(0xA9, word & 0xFF); a.absolute(0x8D, 0x2118)
        a.emit(0xA9, word >> 8); a.absolute(0x8D, 0x2119)
    # ATTIC in the middle of the map: row 13, column 13.
    address = 13 * 32 + 13
    a.emit(0xA9, address & 0xFF); a.absolute(0x8D, 0x2116); a.emit(0xA9, address >> 8); a.absolute(0x8D, 0x2117)
    for letter in "ATTIC":
        a.emit(0xA9, 1 + "ATIC".index(letter)); a.absolute(0x8D, 0x2118)
        a.emit(0xA9, 0x00); a.absolute(0x8D, 0x2119)
    # Letter colour (palette 0, colour 3): white.
    a.emit(0xA9, 3); a.absolute(0x8D, 0x2121)
    a.emit(0xA9, 0xFF); a.absolute(0x8D, 0x2122); a.emit(0xA9, 0x7F); a.absolute(0x8D, 0x2122)
    a.emit(0xA9, 0x01); a.absolute(0x8D, 0x212C)   # BG1 on the main screen
    a.emit(0xA9, 0x0F); a.absolute(0x8D, 0x2100)   # screen on, full brightness
    a.emit(0xA9, 0x01); a.absolute(0x8D, 0x4200)   # automatic joypad reading
    colour = bgr555(255, 107, 61)
    a.emit(0xA2, colour & 0xFF, colour >> 8)       # ldx: orange until a button is pressed
    a.emit(0x86, 0x12)                             # stx $12 (16-bit)

    a.label("main")
    a.label("wait_vblank"); a.absolute(0xAD, 0x4212); a.branch(0x10, "wait_vblank")
    a.label("wait_joypad"); a.absolute(0xAD, 0x4212); a.emit(0x29, 0x01); a.branch(0xD0, "wait_joypad")
    a.absolute(0xAD, 0x4219); a.emit(0x85, 0x10)   # B Y Select Start Up Down Left Right
    a.absolute(0xAD, 0x4218); a.emit(0x85, 0x11)   # A X L R
    a.emit(0xA6, 0x12)                             # ldx $12: the colour so far
    checks = [
        (0x10, 0x0F, bgr555(255, 90, 82), "dpad"),
        (0x11, 0x10, bgr555(255, 150, 200), "r"),
        (0x11, 0x20, bgr555(170, 110, 255), "l"),
        (0x10, 0x40, bgr555(255, 197, 61), "y"),
        (0x11, 0x40, bgr555(242, 243, 245), "x"),
        (0x10, 0x80, bgr555(61, 220, 151), "b"),
        (0x11, 0x80, bgr555(77, 141, 255), "a"),
    ]
    for page, mask, value, name in checks:
        a.emit(0xA5, page); a.emit(0x29, mask); a.branch(0xF0, "skip_" + name)
        a.emit(0xA2, value & 0xFF, value >> 8)
        a.label("skip_" + name)
    a.emit(0x86, 0x12)                             # stx $12 (16-bit)
    a.absolute(0x9C, 0x2121)
    a.emit(0xA5, 0x12); a.absolute(0x8D, 0x2122)
    a.emit(0xA5, 0x13); a.absolute(0x8D, 0x2122)
    a.label("wait_display"); a.absolute(0xAD, 0x4212); a.branch(0x30, "wait_display")
    a.branch(0x80, "main")                         # bra
    a.label("interrupt"); a.emit(0x40)             # rti
    return a


def main():
    a = program()
    code = a.resolve()
    rom = bytearray(b"\xFF" * 0x8000)
    rom[:len(code)] = code
    header = 0x7FC0
    rom[header:header + 21] = b"ATTIC TEST".ljust(21)
    rom[header + 0x15] = 0x20   # LoROM
    rom[header + 0x16] = 0x00   # ROM only
    rom[header + 0x17] = 0x05   # 32 KB
    rom[header + 0x18] = 0x00   # no SRAM
    rom[header + 0x19] = 0x01   # North America (NTSC)
    rom[header + 0x1A] = 0x00
    rom[header + 0x1B] = 0x00
    interrupt = a.labels["interrupt"]
    vectors = {0x7FEA: interrupt, 0x7FEE: interrupt, 0x7FFA: interrupt, 0x7FFC: a.labels["reset"], 0x7FFE: interrupt}
    for offset, address in vectors.items():
        rom[offset:offset + 2] = address.to_bytes(2, "little")
    rom[header + 0x1C:header + 0x20] = b"\xFF\xFF\x00\x00"
    checksum = sum(rom) & 0xFFFF
    rom[header + 0x1C:header + 0x1E] = (checksum ^ 0xFFFF).to_bytes(2, "little")
    rom[header + 0x1E:header + 0x20] = checksum.to_bytes(2, "little")
    with open(sys.argv[1], "wb") as file:
        file.write(rom)
    print(f"{sys.argv[1]} written")


if __name__ == "__main__":
    main()
