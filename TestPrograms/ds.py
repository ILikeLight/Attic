#!/usr/bin/env python3
"""Builds a small Nintendo DS test program for melonDS (ds/arm9.c and ds/arm7.c).

Usage: python3 TestPrograms/ds.py <out.nds>
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import armlink  # noqa: E402

ARM9_ADDRESS = 0x02000000
ARM7_ADDRESS = 0x02380000


def crc16(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def main():
    arm9 = armlink.build(os.path.join(HERE, "ds", "arm9.c"), "armv5te-none-eabi", "arm946e-s", ARM9_ADDRESS)
    arm7 = armlink.build(os.path.join(HERE, "ds", "arm7.c"), "armv4t-none-eabi", "arm7tdmi", ARM7_ADDRESS)
    arm9_offset = 0x200
    arm7_offset = (arm9_offset + len(arm9) + 0x1FF) & ~0x1FF
    used = (arm7_offset + len(arm7) + 0x1FF) & ~0x1FF

    header = bytearray(0x200)
    header[0x00:0x0C] = b"ATTIC TEST\0\0"
    header[0x0C:0x10] = b"####"   # the homebrew code: real codes such as ATDP belong to a game
    header[0x10:0x12] = b"00"
    struct.pack_into("<IIII", header, 0x20, arm9_offset, ARM9_ADDRESS, ARM9_ADDRESS, len(arm9))
    struct.pack_into("<IIII", header, 0x30, arm7_offset, ARM7_ADDRESS, ARM7_ADDRESS, len(arm7))
    struct.pack_into("<I", header, 0x60, 0x00586000)  # normal card timing
    struct.pack_into("<I", header, 0x80, used)
    struct.pack_into("<I", header, 0x84, 0x4000)
    struct.pack_into("<H", header, 0x15C, 0xCF56)
    struct.pack_into("<H", header, 0x15E, crc16(header[:0x15E]))

    rom = bytearray(0x20000)
    rom[:0x200] = header
    rom[arm9_offset:arm9_offset + len(arm9)] = arm9
    rom[arm7_offset:arm7_offset + len(arm7)] = arm7
    with open(sys.argv[1], "wb") as file:
        file.write(rom)
    print(f"{sys.argv[1]} written (ARM9 {len(arm9)} bytes, ARM7 {len(arm7)} bytes)")


if __name__ == "__main__":
    main()
