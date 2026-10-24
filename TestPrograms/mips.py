"""A small MIPS assembler for the PlayStation (R3000) and N64 (R4300) test programs."""
import struct

REGISTERS = {name: number for number, name in enumerate(
    "zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7 t8 t9 k0 k1 gp sp fp ra".split())}


class AssemblerMIPS:
    """Branch delay slots, and the R3000's load delay slots, get a nop automatically."""

    def __init__(self, origin, endian="<"):
        self.origin = origin
        self.endian = endian
        self.words = []
        self.labels = {}
        self.fixups = []

    def label(self, name):
        self.labels[name] = self.address()

    def address(self):
        return self.origin + 4 * len(self.words)

    def emit(self, word):
        self.words.append(word & 0xFFFFFFFF)

    def i_type(self, op, rs, rt, immediate):
        self.emit(op << 26 | REGISTERS[rs] << 21 | REGISTERS[rt] << 16 | (immediate & 0xFFFF))

    def r_type(self, funct, rd="zero", rs="zero", rt="zero", shift=0):
        self.emit(REGISTERS[rs] << 21 | REGISTERS[rt] << 16 | REGISTERS[rd] << 11 | shift << 6 | funct)

    def nop(self):
        self.emit(0)

    def li(self, reg, value):
        self.i_type(0x0F, "zero", reg, value >> 16)        # lui
        self.i_type(0x0D, reg, reg, value & 0xFFFF)          # ori

    def ori(self, rt, rs, value): self.i_type(0x0D, rs, rt, value)
    def andi(self, rt, rs, value): self.i_type(0x0C, rs, rt, value)
    def addiu(self, rt, rs, value): self.i_type(0x09, rs, rt, value)
    def slti(self, rt, rs, value): self.i_type(0x0A, rs, rt, value)
    def sw(self, rt, offset, base): self.i_type(0x2B, base, rt, offset)
    def sh(self, rt, offset, base): self.i_type(0x29, base, rt, offset)
    def sb(self, rt, offset, base): self.i_type(0x28, base, rt, offset)
    def or_(self, rd, rs, rt): self.r_type(0x25, rd, rs, rt)
    def nor(self, rd, rs, rt): self.r_type(0x27, rd, rs, rt)
    def addu(self, rd, rs, rt): self.r_type(0x21, rd, rs, rt)
    def subu(self, rd, rs, rt): self.r_type(0x23, rd, rs, rt)
    def sll(self, rd, rt, shift): self.r_type(0x00, rd, "zero", rt, shift)
    def srl(self, rd, rt, shift): self.r_type(0x02, rd, "zero", rt, shift)
    def sra(self, rd, rt, shift): self.r_type(0x03, rd, "zero", rt, shift)

    def lw(self, rt, offset, base):
        self.i_type(0x23, base, rt, offset)
        self.nop()

    def lhu(self, rt, offset, base):
        self.i_type(0x25, base, rt, offset)
        self.nop()

    def lbu(self, rt, offset, base):
        self.i_type(0x24, base, rt, offset)
        self.nop()

    def lb(self, rt, offset, base):
        self.i_type(0x20, base, rt, offset)
        self.nop()

    def branch(self, op, rs, rt, target):
        self.fixups.append(("branch", len(self.words), target))
        self.i_type(op, rs, rt, 0)
        self.nop()

    def beq(self, rs, rt, target): self.branch(0x04, rs, rt, target)
    def bne(self, rs, rt, target): self.branch(0x05, rs, rt, target)

    def j(self, target):
        self.fixups.append(("jump", len(self.words), target))
        self.emit(0x02 << 26)
        self.nop()

    def jal(self, target):
        self.fixups.append(("jump", len(self.words), target))
        self.emit(0x03 << 26)
        self.nop()

    def jr(self, rs):
        self.r_type(0x08, rs=rs)
        self.nop()

    def resolve(self):
        for kind, index, target in self.fixups:
            address = self.labels[target]
            if kind == "branch":
                offset = (address - (self.origin + 4 * index + 4)) >> 2
                assert -0x8000 <= offset < 0x8000, target
                self.words[index] |= offset & 0xFFFF
            else:
                self.words[index] |= (address >> 2) & 0x3FFFFFF
        return b"".join(struct.pack(self.endian + "I", word) for word in self.words)
