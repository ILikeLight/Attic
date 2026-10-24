#!/usr/bin/env python3
"""Builds a small NES test cartridge for Nestopia.

It shows ATTIC and NES, a block you move with the D-pad, A changes the block's
colour and beeps, B beeps lower. Usage: python3 TestPrograms/nes.py <out.nes>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from font import GLYPHS  # noqa: E402


class Assembler6502:
    """Just enough 6502 for this program: fixed opcodes, labels and relative branches."""

    OPCODES = {
        "sei": 0x78, "cld": 0xD8, "txs": 0x9A, "inx": 0xE8, "dex": 0xCA, "dey": 0x88, "rti": 0x40,
        "pha": 0x48, "pla": 0x68, "lsr": 0x4A, "nop": 0xEA,
        "lda#": 0xA9, "ldx#": 0xA2, "ldy#": 0xA0, "cmp#": 0xC9, "cpx#": 0xE0, "and#": 0x29,
        "lda_zp": 0xA5, "sta_zp": 0x85, "cmp_zp": 0xC5, "inc_zp": 0xE6, "rol_zp": 0x26,
        "lda": 0xAD, "sta": 0x8D, "stx": 0x8E, "bit": 0x2C, "inc": 0xEE, "dec": 0xCE, "jmp": 0x4C,
        "lda,x": 0xBD, "sta,x": 0x9D,
        "bpl": 0x10, "bne": 0xD0, "beq": 0xF0,
    }

    def __init__(self, origin):
        self.origin = origin
        self.code = bytearray()
        self.labels = {}
        self.fixups = []

    @property
    def here(self):
        return self.origin + len(self.code)

    def label(self, name):
        self.labels[name] = self.here

    def __call__(self, op, operand=None):
        self.code.append(self.OPCODES[op])
        if operand is None:
            return
        if op in ("bpl", "bne", "beq"):
            self.fixups.append(("rel", len(self.code), operand))
            self.code.append(0)
        elif op.endswith("#") or op.endswith("_zp"):
            self.code.append(operand & 0xFF)
        else:
            self.fixups.append(("abs", len(self.code), operand))
            self.code += b"\0\0"

    def data(self, name, values):
        self.label(name)
        self.code += bytes(values)

    def resolve(self, extra=None):
        labels = dict(self.labels, **(extra or {}))
        for kind, position, target in self.fixups:
            address = labels[target] if isinstance(target, str) else target
            if kind == "rel":
                delta = address - (self.origin + position + 1)
                assert -128 <= delta <= 127, target
                self.code[position] = delta & 0xFF
            else:
                self.code[position:position + 2] = address.to_bytes(2, "little")
        return bytes(self.code)


def program():
    a = Assembler6502(0xC000)
    a.label("reset")
    a("sei"); a("cld")
    a("ldx#", 0x40); a("stx", 0x4017)  # no APU frame interrupt
    a("ldx#", 0xFF); a("txs"); a("inx")
    a("stx", 0x2000); a("stx", 0x2001); a("stx", 0x4010)
    a("bit", 0x2002)
    a.label("vblank1"); a("bit", 0x2002); a("bpl", "vblank1")
    a("lda#", 0xFF); a("ldx#", 0)
    a.label("clear"); a("sta,x", 0x0200); a("inx"); a("bne", "clear")  # all sprites off screen
    a.label("vblank2"); a("bit", 0x2002); a("bpl", "vblank2")

    a("lda", 0x2002); a("lda#", 0x3F); a("sta", 0x2006); a("lda#", 0x00); a("sta", 0x2006)
    a("ldx#", 0)
    a.label("palette_loop"); a("lda,x", "palette"); a("sta", 0x2007); a("inx"); a("cpx#", 32); a("bne", "palette_loop")

    a("lda", 0x2002); a("lda#", 0x20); a("sta", 0x2006); a("lda#", 0x00); a("sta", 0x2006)
    a("lda#", 0); a("ldy#", 4)
    a.label("nt_outer"); a("ldx#", 0)
    a.label("nt_inner"); a("sta", 0x2007); a("inx"); a("bne", "nt_inner"); a("dey"); a("bne", "nt_outer")

    for row, column, text in ((11, 13, "ATTIC"), (13, 14, "NES")):
        address = 0x2000 + row * 32 + column
        a("lda#", address >> 8); a("sta", 0x2006); a("lda#", address & 0xFF); a("sta", 0x2006)
        for letter in text:
            a("lda#", 2 + LETTERS.index(letter)); a("sta", 0x2007)

    a("lda#", 150); a("sta", 0x0200); a("lda#", 1); a("sta", 0x0201)  # sprite 0: y, tile
    a("lda#", 0); a("sta", 0x0202); a("lda#", 124); a("sta", 0x0203)  # attributes, x
    a("lda#", 0x01); a("sta", 0x4015)  # square channel 1 on
    a("lda#", 0); a("sta", 0x2005); a("sta", 0x2005)
    a("lda#", 0x80); a("sta", 0x2000)  # NMI on
    a("lda#", 0x1E); a("sta", 0x2001)  # background and sprites on

    a.label("main")
    a("lda_zp", 0x10)
    a.label("wait"); a("cmp_zp", 0x10); a("beq", "wait")  # until the NMI counts a frame
    a("lda#", 1); a("sta", 0x4016); a("lda#", 0); a("sta", 0x4016)
    a("ldx#", 8)
    a.label("read"); a("lda", 0x4016); a("lsr"); a("rol_zp", 0x11); a("dex"); a("bne", "read")
    # $11: A B Select Start Up Down Left Right (bit 7 to 0)
    for bit, op, address, name in ((0x08, "dec", 0x0200, "up"), (0x04, "inc", 0x0200, "down"),
                                   (0x02, "dec", 0x0203, "left"), (0x01, "inc", 0x0203, "right")):
        a("lda_zp", 0x11); a("and#", bit); a("beq", "skip_" + name); a(op, address); a.label("skip_" + name)
    for bit, timer, name in ((0x80, 0xFD, "a"), (0x40, 0xFB, "b")):
        a("lda_zp", 0x11); a("and#", bit); a("beq", "no_" + name)
        a("lda_zp", 0x12); a("and#", bit); a("bne", "no_" + name)  # only on a new press
        if name == "a":
            a("inc", 0x0202); a("lda", 0x0202); a("and#", 0x03); a("sta", 0x0202)
        # 50% square at full volume; the length counter ends the note after about 1/3 second.
        a("lda#", 0x9F); a("sta", 0x4000); a("lda#", timer); a("sta", 0x4002); a("lda#", 0x20 if name == "a" else 0x21)
        a("sta", 0x4003)
        a.label("no_" + name)
    a("lda_zp", 0x11); a("sta_zp", 0x12)
    a("jmp", "main")

    a.label("nmi")
    a("pha"); a("lda#", 0); a("sta", 0x2003); a("lda#", 0x02); a("sta", 0x4014); a("inc_zp", 0x10); a("pla"); a("rti")
    a.label("irq"); a("rti")
    a.data("palette", [0x0F, 0x00, 0x10, 0x27] * 4 + [0x0F, 0x28, 0x28, 0x28, 0x0F, 0x2A, 0x2A, 0x2A,
                                                       0x0F, 0x21, 0x21, 0x21, 0x0F, 0x30, 0x30, 0x30])
    code = a.resolve()
    prg = bytearray(code.ljust(0x4000 - 6, b"\xFF"))
    for name in ("nmi", "reset", "irq"):
        prg += a.labels[name].to_bytes(2, "little")
    return bytes(prg)


LETTERS = "ATICNES"


def tiles():
    chr_rom = bytearray(8192)
    chr_rom[16:24] = b"\xFF" * 8  # tile 1: solid block in colour 1
    for index, letter in enumerate(LETTERS):
        base = (2 + index) * 16
        for row, bits in enumerate(GLYPHS[letter]):
            line = (bits << 2) & 0xFF
            chr_rom[base + row] = line  # both planes: colour 3
            chr_rom[base + 8 + row] = line
    return bytes(chr_rom)


def main():
    header = b"NES\x1a" + bytes([1, 1, 0, 0]) + bytes(8)
    with open(sys.argv[1], "wb") as file:
        file.write(header + program() + tiles())
    print(f"{sys.argv[1]} written")


if __name__ == "__main__":
    main()
