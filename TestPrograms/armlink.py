"""Compiles freestanding ARM C with Xcode's clang and links it to a flat binary.

Apple's toolchain has no ELF linker, so this places the sections of the object
file (".start" first) at a fixed address and resolves the few relocation types
clang produces for such code. No initialised globals: the code runs from where
it is loaded, without startup code that copies .data.
"""
import os
import struct
import subprocess
import tempfile


def compile_object(source, target, cpu, output):
    subprocess.run([
        "xcrun", "clang", "-target", target, "-mcpu=" + cpu, "-marm", "-O2", "-ffreestanding", "-nostdlib",
        "-fno-builtin", "-fno-exceptions", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables",
        "-fno-pic", "-fno-common", "-c", source, "-o", output,
    ], check=True)


def _sections(elf):
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


def link(elf, base):
    """Returns the binary for an object file loaded at `base`; its .start section comes first."""
    sections = _sections(elf)
    for section in sections:
        if section["flags"] & 0x2 and section["flags"] & 0x1 and section["size"]:
            raise SystemExit(f"writable section {section['name']} is not supported (no initialised globals)")

    placed = [i for i, s in enumerate(sections) if s["name"] == ".start"]
    placed += [i for i, s in enumerate(sections) if s["type"] == 1 and s["flags"] & 0x2 and s["name"] != ".start"]
    image = bytearray()
    address = {}
    for index in placed:
        section = sections[index]
        while len(image) % max(section["align"], 4):
            image.append(0)
        address[index] = base + len(image)
        image += elf[section["offset"]:section["offset"] + section["size"]]

    symtab = next(s for s in sections if s["type"] == 2)
    strtab = sections[symtab["link"]]

    def symbol(index):
        name_offset, value, _, _, _, shndx = struct.unpack_from("<IIIBBH", elf, symtab["offset"] + index * 16)
        if shndx not in address:
            start = strtab["offset"] + name_offset
            name = elf[start:elf.index(b"\0", start)].decode()
            raise SystemExit(f"undefined symbol {name}")
        return address[shndx] + value

    for section in sections:
        if section["type"] != 9 or section["info"] not in address:  # SHT_REL
            continue
        target = section["info"]
        for entry in range(section["size"] // 8):
            offset, info = struct.unpack_from("<II", elf, section["offset"] + entry * 8)
            kind = info & 0xFF
            position = address[target] - base + offset
            word, = struct.unpack_from("<I", image, position)
            if kind == 2:  # R_ARM_ABS32
                word = (word + symbol(info >> 8)) & 0xFFFFFFFF
            elif kind in (28, 29):  # R_ARM_CALL, R_ARM_JUMP24
                addend = ((word & 0xFFFFFF) ^ 0x800000) - 0x800000
                delta = symbol(info >> 8) + (addend << 2) - (address[target] + offset)
                word = (word & 0xFF000000) | ((delta >> 2) & 0xFFFFFF)
            elif kind == 40:  # R_ARM_V4BX
                continue
            else:
                raise SystemExit(f"unsupported relocation type {kind}")
            struct.pack_into("<I", image, position, word)
    return bytes(image)


def build(source, target, cpu, base):
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "code.o")
        compile_object(source, target, cpu, path)
        with open(path, "rb") as file:
            return link(file.read(), base)
