#!/usr/bin/env python3
"""Builds the Attic demo cartridge (a .gba file) from demo.c.

Xcode's clang compiles demo.c to an ARM ELF object; this script then does the
small amount of linking the program needs: it places the sections in ROM after
the cartridge header and resolves the few relocations clang leaves behind.

Usage: python3 build.py <output.gba>
"""
import os
import struct
import subprocess
import sys
import tempfile

ROM_BASE = 0x08000000
HEADER_SIZE = 0xC0
HERE = os.path.dirname(os.path.abspath(__file__))


def compile_object(path):
    subprocess.run([
        "xcrun", "clang", "-target", "armv4t-none-eabi", "-marm", "-O2", "-ffreestanding", "-nostdlib",
        "-fno-builtin", "-fno-exceptions", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables",
        "-fno-pic", "-fno-common", "-c", os.path.join(HERE, "demo.c"), "-o", path,
    ], check=True)


def read_sections(elf):
    assert elf[:4] == b"\x7fELF" and elf[4] == 1 and elf[5] == 1, "expected a 32-bit little-endian ELF file"
    shoff, = struct.unpack_from("<I", elf, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", elf, 0x2E)
    sections = []
    for i in range(shnum):
        fields = struct.unpack_from("<IIIIIIIIII", elf, shoff + i * shentsize)
        sections.append(dict(zip(["name", "type", "flags", "addr", "offset", "size", "link", "info", "align", "entsize"], fields)))
    names = sections[shstrndx]
    for section in sections:
        start = names["offset"] + section["name"]
        section["name"] = elf[start:elf.index(b"\0", start)].decode()
    return sections


def link(elf):
    sections = read_sections(elf)
    alloc = 0x2
    write = 0x1
    for section in sections:
        if section["flags"] & alloc and section["flags"] & write and section["size"]:
            sys.exit(f"writable section {section['name']} is not supported (no initialised globals)")

    # .start first, then code and read-only data.
    placed = [i for i, s in enumerate(sections) if s["name"] == ".start"]
    placed += [i for i, s in enumerate(sections) if s["type"] == 1 and s["flags"] & alloc and s["name"] != ".start"]
    image = bytearray(HEADER_SIZE)
    base = {}
    for index in placed:
        section = sections[index]
        while len(image) % max(section["align"], 4):
            image.append(0)
        base[index] = ROM_BASE + len(image)
        image += elf[section["offset"]:section["offset"] + section["size"]]

    symtab = next(s for s in sections if s["type"] == 2)
    strtab = sections[symtab["link"]]

    def symbol_address(index):
        name_offset, value, _, _, _, shndx = struct.unpack_from("<IIIBBH", elf, symtab["offset"] + index * 16)
        if shndx not in base:
            start = strtab["offset"] + name_offset
            name = elf[start:elf.index(b"\0", start)].decode()
            sys.exit(f"undefined symbol {name}")
        return base[shndx] + value

    for section in sections:
        if section["type"] != 9 or section["info"] not in base:  # SHT_REL
            continue
        target = section["info"]
        for entry in range(section["size"] // 8):
            offset, info = struct.unpack_from("<II", elf, section["offset"] + entry * 8)
            kind = info & 0xFF
            position = base[target] - ROM_BASE + offset
            address = base[target] + offset
            word, = struct.unpack_from("<I", image, position)
            if kind == 2:  # R_ARM_ABS32
                word = (word + symbol_address(info >> 8)) & 0xFFFFFFFF
            elif kind in (28, 29):  # R_ARM_CALL, R_ARM_JUMP24
                addend = ((word & 0xFFFFFF) ^ 0x800000) - 0x800000
                delta = symbol_address(info >> 8) + (addend << 2) - address
                word = (word & 0xFF000000) | ((delta >> 2) & 0xFFFFFF)
            elif kind == 40:  # R_ARM_V4BX
                continue
            else:
                sys.exit(f"unsupported relocation type {kind}")
            struct.pack_into("<I", image, position, word)

    start = base[placed[0]]
    struct.pack_into("<I", image, 0, 0xEA000000 | (((start - ROM_BASE - 8) >> 2) & 0xFFFFFF))  # b start
    image[0xA0:0xAC] = b"ATTIC DEMO\0\0"
    image[0xAC:0xB0] = b"ATDH"
    image[0xB0:0xB2] = b"00"
    image[0xB2] = 0x96
    checksum = 0
    for byte in image[0xA0:0xBD]:
        checksum = (checksum - byte) & 0xFF
    image[0xBD] = (checksum - 0x19) & 0xFF
    while len(image) % 0x100:
        image.append(0)
    return bytes(image)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "demo.o")
        compile_object(path)
        with open(path, "rb") as file:
            rom = link(file.read())
    with open(sys.argv[1], "wb") as file:
        file.write(rom)
    print(f"{sys.argv[1]}: {len(rom)} bytes")


if __name__ == "__main__":
    main()
