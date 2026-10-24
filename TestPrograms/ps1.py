#!/usr/bin/env python3
"""Builds a small PlayStation test program (PS-EXE) for PCSX ReARMed.

It draws ATTIC and a lamp for each of the 16 controller buttons: bright while
the button is held, dim once it has been pressed, so a short tap stays visible.
The square in the middle lights up while any button is held. The controller is
read directly through the serial port, so the program needs no BIOS.
Usage: python3 TestPrograms/ps1.py <out.exe>
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from font import pixels  # noqa: E402
from mips import AssemblerMIPS  # noqa: E402

LOAD_ADDRESS = 0x80010000


def rgb(r, g, b):
    return b << 16 | g << 8 | r


def program():
    a = AssemblerMIPS(LOAD_ADDRESS)

    def gp0(value):
        a.li("t0", value)
        a.sw("t0", 0x1810, "s0")

    def gp1(value):
        a.li("t0", value)
        a.sw("t0", 0x1814, "s0")

    def rect(x, y, w, h, colour):
        gp0(0x60000000 | colour)
        gp0(y << 16 | x)
        gp0(h << 16 | w)

    a.label("start")
    a.i_type(0x0F, "zero", "s0", 0x1F80)   # s0 = I/O base
    a.sw("zero", 0x1074, "s0")             # no interrupts
    gp1(0x00000000)                        # reset the GPU
    gp1(0x08000001)                        # 320×240, NTSC, 15-bit
    gp1(0x06C60260)                        # horizontal display range
    gp1(0x07040010)                        # vertical display range
    gp1(0x05000000)                        # display starts at 0,0
    gp0(0xE1000400)                        # drawing to the displayed area is allowed
    gp0(0xE3000000)                        # drawing area from 0,0
    gp0(0xE4000000 | 239 << 10 | 319)      # … to 319,239
    gp0(0xE5000000)                        # no drawing offset
    gp1(0x03000000)                        # display on
    rect(0, 0, 320, 240, rgb(13, 14, 18))
    for x, y in pixels("ATTIC"):
        rect(70 + x * 6, 40 + y * 6, 6, 6, rgb(242, 243, 245))
    for x, y in pixels("PS1"):
        rect(142 + x * 2, 92 + y * 2, 2, 2, rgb(154, 160, 172))
    a.or_("s2", "zero", "zero")            # s2 = buttons pressed so far

    a.label("frame")
    a.label("wait_vblank")
    a.lw("t1", 0x1070, "s0")
    a.andi("t1", "t1", 1)
    a.beq("t1", "zero", "wait_vblank")
    a.li("t1", 0xFFFFFFFE)
    a.sw("t1", 0x1070, "s0")               # acknowledge vblank

    a.jal("read_pad")                      # s1 = buttons, a set bit means released
    a.nor("t1", "s1", "zero")
    a.andi("t1", "t1", 0xFFFF)
    a.or_("s2", "s2", "t1")
    for index in range(16):
        x = 16 + index * 18
        a.andi("t1", "s1", 1 << index)
        a.bne("t1", "zero", f"released_{index}")
        rect(x, 200, 14, 10, rgb(255, 107, 61))
        a.j(f"next_{index}")
        a.label(f"released_{index}")
        a.andi("t1", "s2", 1 << index)
        a.beq("t1", "zero", f"off_{index}")
        rect(x, 200, 14, 10, rgb(122, 58, 38))
        a.j(f"next_{index}")
        a.label(f"off_{index}")
        rect(x, 200, 14, 10, rgb(38, 42, 51))
        a.label(f"next_{index}")
    a.li("t1", 0xFFFF)
    a.beq("s1", "t1", "idle")
    rect(128, 120, 64, 64, rgb(255, 197, 61))
    a.j("frame")
    a.label("idle")
    rect(128, 120, 64, 64, rgb(31, 34, 41))
    a.j("frame")

    # Reads controller 1: s1 = 16 button bits (0 = pressed).
    a.label("read_pad")
    a.li("t1", 0x000D)
    a.sh("t1", 0x1048, "s0")               # JOY_MODE
    a.li("t1", 0x0088)
    a.sh("t1", 0x104E, "s0")               # JOY_BAUD
    a.li("t1", 0x1003)
    a.sh("t1", 0x104A, "s0")               # JOY_CTRL: transmit, select port 1
    a.li("t2", 400)
    a.label("select_delay")
    a.addiu("t2", "t2", -1)
    a.bne("t2", "zero", "select_delay")
    for index, byte in enumerate((0x01, 0x42, 0x00, 0x00, 0x00)):
        a.li("t1", byte)
        a.sb("t1", 0x1040, "s0")
        a.li("t2", 2000)
        a.label(f"wait_rx_{index}")
        a.addiu("t2", "t2", -1)
        a.beq("t2", "zero", "pad_timeout")
        a.lhu("t3", 0x1044, "s0")
        a.andi("t3", "t3", 0x2)            # receive buffer not empty
        a.beq("t3", "zero", f"wait_rx_{index}")
        a.lbu("t4", 0x1040, "s0")
        if index == 3:
            a.or_("s1", "t4", "zero")
        elif index == 4:
            a.sll("t4", "t4", 8)
            a.or_("s1", "s1", "t4")
    a.sh("zero", 0x104A, "s0")
    a.jr("ra")
    a.label("pad_timeout")
    a.sh("zero", 0x104A, "s0")
    a.li("s1", 0xFFFF)
    a.jr("ra")
    return a.resolve()


def main():
    code = program()
    size = (len(code) + 0x7FF) & ~0x7FF
    header = bytearray(0x800)
    header[0:8] = b"PS-X EXE"
    struct.pack_into("<IIII", header, 0x10, LOAD_ADDRESS, 0, LOAD_ADDRESS, size)
    struct.pack_into("<II", header, 0x30, 0x801FFFF0, 0)
    marker = b"Sony Computer Entertainment Inc. for Europe area"
    header[0x4C:0x4C + len(marker)] = marker
    with open(sys.argv[1], "wb") as file:
        file.write(header + code.ljust(size, b"\0"))
    print(f"{sys.argv[1]} written ({len(code)} bytes of code)")


if __name__ == "__main__":
    main()
