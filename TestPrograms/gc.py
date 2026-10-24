#!/usr/bin/env python3
"""Builds a small GameCube test program (DOL) for Dolphin.

It shows ATTIC and GC on a dark screen, with a block that blinks while the processor
runs. The picture is a data section that the boot loader puts straight into the video
memory (XFB), and the program only sets up the video interface (VI) and then loops, so
it needs no Nintendo code or libraries.
Usage: python3 TestPrograms/gc.py <out.dol>
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from font import pixels  # noqa: E402

CODE_ADDRESS = 0x80003100
XFB_ADDRESS = 0x80C00000      # 12 MB into the 24 MB of memory
WIDTH, HEIGHT = 640, 240      # one field; both fields show the same lines
VI = 0xCC002000
BLOCK = (288, 200, 64, 16)    # x, y, width, height of the blinking block


def yuyv(r, g, b):
    """Two pixels of one colour as the VI reads them: Y0 U Y1 V."""
    y = int(16 + (65.738 * r + 129.057 * g + 25.064 * b) / 256)
    u = int(128 + (-37.945 * r - 74.494 * g + 112.439 * b) / 256)
    v = int(128 + (112.439 * r - 94.154 * g - 18.285 * b) / 256)
    return y << 24 | u << 16 | y << 8 | v


def picture():
    words = [yuyv(13, 14, 18)] * (WIDTH * HEIGHT // 2)

    def fill(x, y, width, height, colour):
        for row in range(y, y + height):
            for column in range(x // 2, (x + width) // 2):
                words[row * WIDTH // 2 + column] = colour

    for x, y in pixels("ATTIC"):
        fill(170 + x * 10, 50 + y * 10, 10, 10, yuyv(242, 243, 245))
    for x, y in pixels("GC"):
        fill(296 + x * 4, 140 + y * 4, 4, 4, yuyv(154, 160, 172))
    fill(*BLOCK, yuyv(255, 107, 61))
    return b"".join(struct.pack(">I", word) for word in words)


class AssemblerPPC:
    """Just the PowerPC instructions this program needs."""

    def __init__(self, origin):
        self.origin = origin
        self.words = []
        self.labels = {}
        self.fixups = []

    def address(self):
        return self.origin + 4 * len(self.words)

    def label(self, name):
        self.labels[name] = self.address()

    def emit(self, word):
        self.words.append(word & 0xFFFFFFFF)

    def lis(self, rd, value): self.emit(15 << 26 | rd << 21 | (value & 0xFFFF))
    def li(self, rd, value): self.emit(14 << 26 | rd << 21 | (value & 0xFFFF))
    def addi(self, rd, ra, value): self.emit(14 << 26 | rd << 21 | ra << 16 | (value & 0xFFFF))
    def ori(self, ra, rs, value): self.emit(24 << 26 | rs << 21 | ra << 16 | (value & 0xFFFF))
    def stw(self, rs, offset, ra): self.emit(36 << 26 | rs << 21 | ra << 16 | (offset & 0xFFFF))
    def sth(self, rs, offset, ra): self.emit(44 << 26 | rs << 21 | ra << 16 | (offset & 0xFFFF))
    def lwz(self, rd, offset, ra): self.emit(32 << 26 | rd << 21 | ra << 16 | (offset & 0xFFFF))
    def xor(self, ra, rs, rb): self.emit(31 << 26 | rs << 21 | ra << 16 | rb << 11 | 316 << 1)
    def mr(self, ra, rs): self.emit(31 << 26 | rs << 21 | ra << 16 | rs << 11 | 444 << 1)
    def mtctr(self, rs): self.emit(31 << 26 | rs << 21 | 9 << 16 | 467 << 1)
    def cmpwi(self, ra, value): self.emit(11 << 26 | ra << 16 | (value & 0xFFFF))

    def rlwinm_dot(self, ra, rs, shift, first, last):
        """ra = rs rotated left by `shift`, masked to bits first..last (bit 0 is the top bit); sets CR0."""
        self.emit(21 << 26 | rs << 21 | ra << 16 | shift << 11 | first << 6 | last << 1 | 1)

    def load(self, rd, value):
        self.lis(rd, value >> 16)
        self.ori(rd, rd, value & 0xFFFF)

    def branch(self, kind, target):
        self.fixups.append((kind, len(self.words), target))
        self.emit(0)

    def b(self, target): self.branch("b", target)
    def bne(self, target): self.branch("bne", target)
    def bdnz(self, target): self.branch("bdnz", target)

    def resolve(self):
        for kind, index, target in self.fixups:
            offset = self.labels[target] - (self.origin + 4 * index)
            if kind == "b":
                self.words[index] = 18 << 26 | (offset & 0x03FFFFFC)
            else:
                assert -0x8000 <= offset < 0x8000
                bo, bi = (4, 2) if kind == "bne" else (16, 0)
                self.words[index] = 16 << 26 | bo << 21 | bi << 16 | (offset & 0xFFFC)
        return b"".join(struct.pack(">I", word) for word in self.words)


def program():
    a = AssemblerPPC(CODE_ADDRESS)
    physical = XFB_ADDRESS & 0x1FFFFFFF
    a.load(7, VI)
    # Vertical timing of an NTSC field: 6 equalisation half-lines, 240 active lines.
    a.li(8, 240 << 4 | 6)
    a.sth(8, 0x00, 7)
    a.load(8, 3 << 16 | 24)                  # odd field: post- and pre-blanking
    a.stw(8, 0x0C, 7)
    a.load(8, 2 << 16 | 25)                  # even field
    a.stw(8, 0x10, 7)
    a.load(8, 1 << 28 | physical >> 5)       # top field address (in 32-byte units)
    a.stw(8, 0x1C, 7)
    a.load(8, physical >> 5)                 # bottom field: the same lines
    a.stw(8, 0x24, 7)
    a.li(8, (WIDTH // 16) << 8 | WIDTH // 16)  # 640 pixels per line, one line apart
    a.sth(8, 0x48, 7)
    a.li(8, 1)                               # interlaced NTSC, on
    a.sth(8, 0x02, 7)

    # Blink the block: flip its colour every 2^22 turns of the loop.
    x, y, width, height = BLOCK
    a.load(10, (XFB_ADDRESS | 0x40000000) + y * WIDTH * 2 + x * 2)   # uncached
    a.load(11, yuyv(255, 107, 61) ^ yuyv(38, 42, 51))
    a.li(9, 0)
    a.label("main")
    a.addi(9, 9, 1)
    a.rlwinm_dot(12, 9, 0, 10, 31)           # low 22 bits zero?
    a.bne("main")
    a.mr(13, 10)
    a.li(14, height)
    a.label("row")
    a.li(15, width // 2)
    a.mtctr(15)
    a.mr(16, 13)
    a.label("column")
    a.lwz(17, 0, 16)
    a.xor(17, 17, 11)
    a.stw(17, 0, 16)
    a.addi(16, 16, 4)
    a.bdnz("column")
    a.addi(13, 13, WIDTH * 2)
    a.addi(14, 14, -1)
    a.cmpwi(14, 0)
    a.bne("row")
    a.b("main")
    return a.resolve()


def main():
    code = program()
    data = picture()
    text_offset = 0x100
    data_offset = (text_offset + len(code) + 31) & ~31
    header = bytearray(0x100)
    struct.pack_into(">I", header, 0x00, text_offset)       # text section 0: file offset
    struct.pack_into(">I", header, 0x1C, data_offset)       # data section 0
    struct.pack_into(">I", header, 0x48, CODE_ADDRESS)      # text 0: address
    struct.pack_into(">I", header, 0x64, XFB_ADDRESS)       # data 0: address
    struct.pack_into(">I", header, 0x90, len(code))         # text 0: size
    struct.pack_into(">I", header, 0xAC, len(data))         # data 0: size
    struct.pack_into(">I", header, 0xE0, CODE_ADDRESS)      # entry point
    dol = bytes(header) + code.ljust(data_offset - text_offset, b"\0") + data
    with open(sys.argv[1], "wb") as file:
        file.write(dol)
    print(f"{sys.argv[1]} written ({len(code)} bytes of code)")


if __name__ == "__main__":
    main()
