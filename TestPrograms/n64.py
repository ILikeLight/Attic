#!/usr/bin/env python3
"""Builds a small Nintendo 64 test cartridge for Mupen64Plus with GLideN64.

It draws ATTIC and N64 and a lamp for each of the 16 controller bits: bright while the
button is held, dim once it has been pressed. A square follows the analog stick, and four
lamps below show where the stick has been pushed: left, right, up and down.
Everything is drawn with RDP fill rectangles sent straight from the CPU, and the
controller is read through the PIF, so the cartridge needs no Nintendo boot code or
microcode. Its own small boot code copies the program into memory.
Usage: python3 TestPrograms/n64.py <out.z64>
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from font import pixels  # noqa: E402
from mips import AssemblerMIPS  # noqa: E402

BOOT_ADDRESS = 0xA4000040      # the console runs the boot code from the RSP's memory
PROGRAM_ADDRESS = 0x80000400   # where the boot code copies the program
PROGRAM_OFFSET = 0x1000        # offset of the program in the cartridge
ROM_SIZE = 0x200000            # the boot checksum covers the first 1 MB after the header
FRAMEBUFFERS = (0x00100000, 0x00140000)
WIDTH, HEIGHT = 320, 240
VI, MI, SI, PI, DPC = 0xA4400000, 0xA4300000, 0xA4800000, 0xA4600000, 0xA4100000
PIF_RAM = 0x1FC007C0


def physical(address):
    return address & 0x1FFFFFFF


def uncached(address):
    return 0xA0000000 | physical(address)


def fill_color(r, g, b):
    pixel = (r >> 3) << 11 | (g >> 3) << 6 | (b >> 3) << 1 | 1
    return pixel << 16 | pixel


class DisplayList:
    """RDP commands as 32-bit words; returns word indexes for the parts the program changes."""

    def __init__(self):
        self.words = []

    def command(self, high, low):
        self.words += [high & 0xFFFFFFFF, low & 0xFFFFFFFF]
        return len(self.words) - 2

    def color_image(self):
        return self.command(0xFF000000 | 2 << 19 | (WIDTH - 1), 0) + 1   # RGBA, 16 bits per pixel

    def fill_color(self, color):
        self.command(0xE7000000, 0)                                      # sync pipe
        return self.command(0xF7000000, color) + 1

    def fill_rect(self, x, y, width, height):
        # In fill mode the lower-right corner is inclusive; coordinates are 10.2 fixed point.
        right, bottom = x + width - 1, y + height - 1
        return self.command(0xF6000000 | (right * 4) << 12 | bottom * 4, (x * 4) << 12 | y * 4)

    def data(self):
        return b"".join(struct.pack(">I", word) for word in self.words)


def display_list():
    dl = DisplayList()
    places = {"image": dl.color_image()}
    dl.command(0xED000000, (WIDTH * 4) << 12 | HEIGHT * 4)                # scissor: whole screen
    dl.command(0xEF000000 | 3 << 20, 0)                                    # other modes: fill
    dl.fill_color(fill_color(13, 14, 18))
    dl.fill_rect(0, 0, WIDTH, HEIGHT)
    dl.fill_color(fill_color(242, 243, 245))
    for x, y in pixels("ATTIC"):
        dl.fill_rect(70 + x * 6, 40 + y * 6, 6, 6)
    dl.fill_color(fill_color(154, 160, 172))
    for x, y in pixels("N64"):
        dl.fill_rect(142 + x * 2, 92 + y * 2, 2, 2)
    places["lamps"] = []
    for index in range(16):
        places["lamps"].append(dl.fill_color(0))
        dl.fill_rect(16 + index * 18, 200, 14, 10)
    places["stick_lamps"] = []
    for index in range(4):
        places["stick_lamps"].append(dl.fill_color(0))
        dl.fill_rect(124 + index * 18, 218, 14, 10)
    dl.fill_color(fill_color(255, 197, 61))
    places["stick"] = dl.fill_rect(152, 112, 16, 16)
    dl.command(0xE9000000, 0)                                               # sync full
    return dl, places


def boot_code(length):
    """Copies the program from the cartridge into memory and starts it."""
    a = AssemblerMIPS(BOOT_ADDRESS, endian=">")
    a.li("t0", PI)
    a.li("t1", physical(PROGRAM_ADDRESS))
    a.sw("t1", 0x00, "t0")                    # PI_DRAM_ADDR
    a.li("t1", 0x10000000 + PROGRAM_OFFSET)
    a.sw("t1", 0x04, "t0")                    # PI_CART_ADDR
    a.li("t1", ((length + 7) & ~7) - 1)
    a.sw("t1", 0x0C, "t0")                    # PI_WR_LEN: cartridge to memory
    a.label("wait")
    a.lw("t1", 0x10, "t0")                    # PI_STATUS
    a.andi("t1", "t1", 3)
    a.bne("t1", "zero", "wait")
    a.li("t1", PROGRAM_ADDRESS)
    a.jr("t1")
    return a.resolve()


def program(list_address, pad_address):
    dl, places = display_list()
    lamp_on, lamp_seen, lamp_off = fill_color(255, 107, 61), fill_color(122, 58, 38), fill_color(38, 42, 51)
    a = AssemblerMIPS(PROGRAM_ADDRESS, endian=">")

    a.label("start")
    a.li("sp", 0x803FFFF0)
    a.li("s0", VI)
    for offset, value in [(0x00, 0x320E), (0x08, WIDTH), (0x0C, 2), (0x10, 0), (0x14, 0x03E52239),
                          (0x18, 0x20D), (0x1C, 0xC15), (0x20, 0x0C150C15), (0x24, 0x006C02EC),
                          (0x28, 0x002501FF), (0x2C, 0x000E0204), (0x30, 0x200), (0x34, 0x400),
                          (0x04, FRAMEBUFFERS[0])]:
        a.li("t0", value)
        a.sw("t0", offset, "s0")               # NTSC, 320×240, 16 bits per pixel
    a.li("s3", uncached(list_address))
    a.or_("s2", "zero", "zero")                # buttons pressed so far
    a.or_("s4", "zero", "zero")                # which framebuffer to draw next
    a.or_("s7", "zero", "zero")                # stick directions so far

    a.label("frame")
    a.li("t0", MI)
    a.label("wait_vi")
    a.lw("t1", 0x08, "t0")                     # MI_INTR: wait for the VI interrupt
    a.andi("t1", "t1", 0x08)
    a.beq("t1", "zero", "wait_vi")
    a.sw("zero", 0x10, "s0")                   # VI_V_CURRENT: acknowledge it

    a.jal("read_pad")                          # s1 = buttons, s5 = stick x, s6 = stick y
    a.or_("s2", "s2", "s1")
    for index, place in enumerate(places["lamps"]):
        mask = 0x8000 >> index
        a.andi("t1", "s1", mask)
        a.bne("t1", "zero", f"held_{index}")
        a.andi("t1", "s2", mask)
        a.bne("t1", "zero", f"seen_{index}")
        a.li("t0", lamp_off)
        a.j(f"store_{index}")
        a.label(f"seen_{index}")
        a.li("t0", lamp_seen)
        a.j(f"store_{index}")
        a.label(f"held_{index}")
        a.li("t0", lamp_on)
        a.label(f"store_{index}")
        a.sw("t0", place * 4, "s3")

    # Stick directions as bits (left, right, up, down; up is positive on the N64): t8 now, s7 so far.
    a.slti("t8", "s5", -40)
    a.subu("t2", "zero", "s5")
    a.slti("t1", "t2", -40)
    a.sll("t1", "t1", 1)
    a.or_("t8", "t8", "t1")
    a.subu("t2", "zero", "s6")
    a.slti("t1", "t2", -40)
    a.sll("t1", "t1", 2)
    a.or_("t8", "t8", "t1")
    a.slti("t1", "s6", -40)
    a.sll("t1", "t1", 3)
    a.or_("t8", "t8", "t1")
    a.or_("s7", "s7", "t8")
    for index, place in enumerate(places["stick_lamps"]):
        a.andi("t1", "t8", 1 << index)
        a.bne("t1", "zero", f"pushed_{index}")
        a.andi("t1", "s7", 1 << index)
        a.bne("t1", "zero", f"was_pushed_{index}")
        a.li("t0", lamp_off)
        a.j(f"stick_store_{index}")
        a.label(f"was_pushed_{index}")
        a.li("t0", lamp_seen)
        a.j(f"stick_store_{index}")
        a.label(f"pushed_{index}")
        a.li("t0", lamp_on)
        a.label(f"stick_store_{index}")
        a.sw("t0", place * 4, "s3")

    # The square: centred, moved by half the stick's value (up is positive on the N64).
    a.sra("t1", "s5", 1)
    a.addiu("t1", "t1", 152)                   # left
    a.sra("t2", "s6", 1)
    a.li("t3", 112)
    a.subu("t2", "t3", "t2")                   # top
    a.sll("t4", "t1", 14)
    a.sll("t5", "t2", 2)
    a.or_("t4", "t4", "t5")
    a.sw("t4", places["stick"] * 4 + 4, "s3")
    a.addiu("t1", "t1", 15)
    a.addiu("t2", "t2", 15)
    a.sll("t4", "t1", 14)
    a.sll("t5", "t2", 2)
    a.or_("t4", "t4", "t5")
    a.li("t6", 0xF6000000)
    a.or_("t4", "t4", "t6")
    a.sw("t4", places["stick"] * 4, "s3")

    # Draw into one framebuffer while the other one is shown.
    a.li("t0", FRAMEBUFFERS[0])
    a.beq("s4", "zero", "chosen")
    a.li("t0", FRAMEBUFFERS[1])
    a.label("chosen")
    a.sw("t0", places["image"] * 4, "s3")
    a.li("t1", DPC)
    a.li("t2", 1)
    a.sw("t2", 0x0C, "t1")                     # DPC_STATUS: commands come from memory
    a.li("t2", physical(list_address))
    a.sw("t2", 0x00, "t1")                     # DPC_START
    a.li("t2", physical(list_address) + len(dl.words) * 4)
    a.sw("t2", 0x04, "t1")                     # DPC_END: the RDP starts
    a.sw("t0", 0x04, "s0")                     # VI_ORIGIN: show the new frame
    a.li("t1", 1)
    a.subu("s4", "t1", "s4")
    a.j("frame")

    # Reads controller 1 through the PIF: s1 = 16 button bits (1 = held), s5/s6 = stick.
    a.label("read_pad")
    a.li("t0", SI)
    a.li("t1", physical(pad_address))
    a.sw("t1", 0x00, "t0")                     # SI_DRAM_ADDR
    a.li("t1", PIF_RAM)
    a.sw("t1", 0x10, "t0")                     # SI_PIF_ADDR_WR64B: send the request
    a.label("wait_write")
    a.lw("t1", 0x18, "t0")                     # SI_STATUS
    a.andi("t1", "t1", 3)
    a.bne("t1", "zero", "wait_write")
    a.li("t1", physical(pad_address) + 64)
    a.sw("t1", 0x00, "t0")
    a.li("t1", PIF_RAM)
    a.sw("t1", 0x04, "t0")                     # SI_PIF_ADDR_RD64B: fetch the reply
    a.label("wait_read")
    a.lw("t1", 0x18, "t0")
    a.andi("t1", "t1", 3)
    a.bne("t1", "zero", "wait_read")
    a.li("t2", uncached(pad_address) + 64)
    a.lbu("t3", 4, "t2")
    a.lbu("t4", 5, "t2")
    a.sll("t3", "t3", 8)
    a.or_("s1", "t3", "t4")
    a.lb("s5", 6, "t2")
    a.lb("s6", 7, "t2")
    a.jr("ra")
    return a, dl


def build():
    # The data follows the code; its address is only known once the code is laid out,
    # so the program is assembled twice.
    code_size = 0
    for _ in range(2):
        list_address = PROGRAM_ADDRESS + ((code_size + 15) & ~15)
        dl, _ = display_list()
        pad_address = list_address + ((len(dl.words) * 4 + 15) & ~15)
        a, dl = program(list_address, pad_address)
        code = a.resolve()
        code_size = len(code)
    # Joybus request: read buttons (command 1) from channel 1, then end; byte 63 starts it.
    pad = bytearray([0xFF, 0x01, 0x04, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE] + [0] * 54 + [0x01])
    blob = code.ljust(list_address - PROGRAM_ADDRESS, b"\0") + dl.data()
    blob = blob.ljust(pad_address - PROGRAM_ADDRESS, b"\0") + bytes(pad) + bytes(64)
    return blob


def checksum(rom):
    """The header checksum the CIC-6102 boot code checks (not needed here, but proper)."""
    mask = 0xFFFFFFFF
    t1 = t2 = t3 = t4 = t5 = t6 = 0xF8CA4DDC
    for offset in range(0x1000, 0x101000, 4):
        d = struct.unpack_from(">I", rom, offset)[0]
        if (t6 + d) & mask < t6:
            t4 = (t4 + 1) & mask
        t6 = (t6 + d) & mask
        t3 ^= d
        r = ((d << (d & 0x1F)) | (d >> (32 - (d & 0x1F)))) & mask if d & 0x1F else d
        t5 = (t5 + r) & mask
        t2 = t2 ^ r if t2 > d else t2 ^ t6 ^ d
        t1 = (t1 + (t5 ^ d)) & mask
    return t6 ^ t4 ^ t3, t5 ^ t2 ^ t1


def main():
    rom = bytearray(ROM_SIZE)
    struct.pack_into(">IIII", rom, 0, 0x80371240, 0x0000000F, PROGRAM_ADDRESS, 0x0000144C)
    rom[0x20:0x34] = b"ATTIC TEST".ljust(20)
    rom[0x3B:0x40] = b"NATE\0"                 # cartridge, game code AT, USA
    blob = build()
    boot = boot_code(len(blob))
    rom[0x40:0x40 + len(boot)] = boot
    rom[PROGRAM_OFFSET:PROGRAM_OFFSET + len(blob)] = blob
    struct.pack_into(">II", rom, 0x10, *checksum(rom))
    with open(sys.argv[1], "wb") as file:
        file.write(rom)
    print(f"{sys.argv[1]} written ({len(blob)} bytes of program and data)")


if __name__ == "__main__":
    main()
