#!/usr/bin/env python3
"""Builds a small Dreamcast test program (ELF) for Flycast.

It shows ATTIC and DC on a dark screen, with a block that blinks while the processor runs.
Flycast's own BIOS loads the ELF into memory; the program sets up the framebuffer, copies
the picture into video memory and then loops, so it needs no Sega code or libraries.
Usage: python3 TestPrograms/dc.py <out.elf>
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from font import pixels  # noqa: E402

CODE_ADDRESS = 0x8C010000     # where Flycast's BIOS starts an ELF
PICTURE_ADDRESS = 0x8C020000
VRAM = 0xA5000000             # video memory, as the CPU sees it, uncached
PVR = 0xA05F8000
WIDTH, HEIGHT = 640, 480
BLOCK = (288, 380, 64, 16)    # x, y, width, height of the blinking block


def rgb565(r, g, b):
    return (r >> 3) << 11 | (g >> 2) << 5 | b >> 3


def picture():
    pixels_ = [rgb565(13, 14, 18)] * (WIDTH * HEIGHT)

    def fill(x, y, width, height, colour):
        for row in range(y, y + height):
            pixels_[row * WIDTH + x:row * WIDTH + x + width] = [colour] * width

    for x, y in pixels("ATTIC"):
        fill(170 + x * 10, 100 + y * 20, 10, 20, rgb565(242, 243, 245))
    for x, y in pixels("DC"):
        fill(296 + x * 4, 280 + y * 8, 4, 8, rgb565(154, 160, 172))
    fill(*BLOCK, rgb565(255, 107, 61))
    return b"".join(struct.pack("<H", pixel) for pixel in pixels_)


class AssemblerSH4:
    """Just the SH4 instructions this program needs; 32-bit constants go in a pool after the code."""

    def __init__(self, origin):
        self.origin = origin
        self.halves = []
        self.labels = {}
        self.fixups = []

    def address(self):
        return self.origin + 2 * len(self.halves)

    def label(self, name):
        self.labels[name] = self.address()

    def emit(self, half):
        self.halves.append(half & 0xFFFF)

    def load_constant(self, rn, value):     # mov.l @(disp,PC),Rn
        self.fixups.append(("constant", len(self.halves), value))
        self.emit(0xD000 | rn << 8)

    def mov_imm(self, rn, value): self.emit(0xE000 | rn << 8 | (value & 0xFF))
    def mov(self, rm, rn): self.emit(0x6003 | rn << 8 | rm << 4)
    def load(self, rm, rn): self.emit(0x6002 | rn << 8 | rm << 4)     # mov.l @Rm,Rn
    def store(self, rm, rn): self.emit(0x2002 | rn << 8 | rm << 4)    # mov.l Rm,@Rn
    def add_imm(self, rn, value): self.emit(0x7000 | rn << 8 | (value & 0xFF))
    def add(self, rm, rn): self.emit(0x300C | rn << 8 | rm << 4)
    def xor(self, rm, rn): self.emit(0x200A | rn << 8 | rm << 4)
    def tst(self, rm, rn): self.emit(0x2008 | rn << 8 | rm << 4)      # T = (Rn & Rm) == 0
    def dt(self, rn): self.emit(0x4010 | rn << 8)                      # Rn -= 1, T = (Rn == 0)

    def bf(self, target):                   # branch if T is clear
        self.fixups.append(("bf", len(self.halves), target))
        self.emit(0x8B00)

    def bra(self, target):                  # with its delay slot
        self.fixups.append(("bra", len(self.halves), target))
        self.emit(0xA000)
        self.emit(0x0009)                   # nop

    def resolve(self):
        if len(self.halves) % 2:
            self.emit(0x0009)
        pool_start = self.address()
        pool = []
        for kind, _, value in self.fixups:
            if kind == "constant" and value not in pool:
                pool.append(value)
        for kind, index, target in self.fixups:
            pc = self.origin + 2 * index
            if kind == "constant":
                displacement = (pool_start + 4 * pool.index(target) - ((pc & ~3) + 4)) // 4
                assert 0 <= displacement < 256
                self.halves[index] |= displacement
            else:
                displacement = (self.labels[target] - (pc + 4)) // 2
                assert -128 <= displacement < 128 if kind == "bf" else -2048 <= displacement < 2048
                self.halves[index] |= displacement & (0xFF if kind == "bf" else 0xFFF)
        return (b"".join(struct.pack("<H", half) for half in self.halves)
                + b"".join(struct.pack("<I", value) for value in pool))


def program():
    a = AssemblerSH4(CODE_ADDRESS)
    # Framebuffer: on, RGB565, 640 pixels (320 words) by 480 lines, read as VGA.
    a.load_constant(1, PVR + 0x44)          # FB_R_CTRL
    a.load_constant(0, 1 << 23 | 1 << 2 | 1)
    a.store(0, 1)
    a.mov_imm(0, 0)
    a.load_constant(1, PVR + 0x50)          # FB_R_SOF1
    a.store(0, 1)
    a.load_constant(1, PVR + 0x54)          # FB_R_SOF2: the same lines
    a.store(0, 1)
    a.load_constant(1, PVR + 0x5C)          # FB_R_SIZE
    a.load_constant(0, 1 << 20 | (HEIGHT - 1) << 10 | (WIDTH // 2 - 1))
    a.store(0, 1)
    # VO_CONTROL: the video output starts blanked; games turn it on themselves.
    a.mov_imm(0, 0)
    a.load_constant(1, PVR + 0xE8)
    a.store(0, 1)

    # Copy the picture into video memory; writing there also tells Flycast to show it.
    a.load_constant(2, PICTURE_ADDRESS)
    a.load_constant(3, VRAM)
    a.load_constant(4, WIDTH * HEIGHT // 2)
    a.label("copy")
    a.load(2, 0)
    a.store(0, 3)
    a.add_imm(2, 4)
    a.add_imm(3, 4)
    a.dt(4)
    a.bf("copy")

    # Blink the block: flip its colour every 2^22 turns of the loop.
    x, y, width, height = BLOCK
    a.load_constant(4, VRAM + (y * WIDTH + x) * 2)
    a.load_constant(5, (rgb565(255, 107, 61) ^ rgb565(38, 42, 51)) * 0x10001)
    a.load_constant(11, (1 << 22) - 1)
    a.mov_imm(6, 0)
    a.label("main")
    a.add_imm(6, 1)
    a.tst(11, 6)
    a.bf("main")
    a.mov(4, 7)
    a.mov_imm(8, height)
    a.label("row")
    a.mov_imm(9, width // 2)
    a.mov(7, 10)
    a.label("column")
    a.load(10, 0)
    a.xor(5, 0)
    a.store(0, 10)
    a.add_imm(10, 4)
    a.dt(9)
    a.bf("column")
    a.load_constant(0, WIDTH * 2)
    a.add(0, 7)
    a.dt(8)
    a.bf("row")
    a.bra("main")
    return a.resolve()


def main():
    code = program()
    data = picture()
    code_offset, data_offset = 0x100, 0x1000
    assert code_offset + len(code) <= data_offset
    # Flycast's ELF reader also wants a section table: an empty section and the section names.
    names = b"\0.shstrtab\0"
    names_offset = data_offset + len(data)
    sections_offset = (names_offset + len(names) + 3) & ~3
    header = struct.pack("<4sBBBB8xHHIIIIIHHHHHH", b"\x7fELF", 1, 1, 1, 0,
                         2, 42, 1, CODE_ADDRESS, 52, sections_offset, 0, 52, 32, 2, 40, 2, 1)   # executable, Hitachi SH
    segments = b"".join(struct.pack("<IIIIIIII", 1, offset, address, address, len(body), len(body), flags, 4)
                        for offset, address, body, flags in [(code_offset, CODE_ADDRESS, code, 5),
                                                             (data_offset, PICTURE_ADDRESS, data, 4)])
    sections = bytes(40) + struct.pack("<IIIIIIIIII", 1, 3, 0, 0, names_offset, len(names), 0, 0, 1, 0)
    elf = (header + segments).ljust(code_offset, b"\0") + code
    elf = elf.ljust(data_offset, b"\0") + data + names
    elf = elf.ljust(sections_offset, b"\0") + sections
    with open(sys.argv[1], "wb") as file:
        file.write(elf)
    print(f"{sys.argv[1]} written ({len(code)} bytes of code)")


if __name__ == "__main__":
    main()
