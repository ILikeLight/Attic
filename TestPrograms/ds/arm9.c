// Attic DS test, ARM9 side: draws on both screens.
// Top: ATTIC DS and a lamp per button. Bottom: dots where you touch; Start clears it.

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;

#define REG(type, address) (*(volatile type *)(address))
#define POWCNT1 REG(u16, 0x04000304)
#define DISPCNT_A REG(u32, 0x04000000)
#define DISPCNT_B REG(u32, 0x04001000)
#define VRAMCNT_A REG(u8, 0x04000240)
#define VRAMCNT_C REG(u8, 0x04000242)
#define BG3CNT_B REG(u16, 0x0400100E)
#define BG3PA_B REG(u16, 0x04001030)
#define BG3PB_B REG(u16, 0x04001032)
#define BG3PC_B REG(u16, 0x04001034)
#define BG3PD_B REG(u16, 0x04001036)
#define BG3X_B REG(u32, 0x04001038)
#define BG3Y_B REG(u32, 0x0400103C)
#define VCOUNT REG(u16, 0x04000006)
#define KEYINPUT REG(u16, 0x04000130)

#define TOP ((volatile u16 *)0x06800000)     // VRAM A, shown directly by engine A
#define BOTTOM ((volatile u16 *)0x06200000)  // VRAM C, a direct-colour bitmap of engine B
#define SHARED ((volatile u32 *)0x023F0000)  // written by the ARM7: touch position and pen/X/Y

#define RGB(r, g, b) ((u16)(((r) >> 3) | (((g) >> 3) << 5) | (((b) >> 3) << 10)))
#define OPAQUE 0x8000

static const unsigned char glyphs[6][7] = {
    {0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11},  // A
    {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04},  // T
    {0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E},  // I
    {0x0F, 0x10, 0x10, 0x10, 0x10, 0x10, 0x0F},  // C
    {0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E},  // D
    {0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E},  // S
};

static void fill(volatile u16 *screen, int x, int y, int w, int h, u16 color) {
    for (int j = y; j < y + h; j++) {
        if (j < 0 || j >= 192) continue;
        for (int i = x; i < x + w; i++) {
            if (i >= 0 && i < 256) screen[j * 256 + i] = color;
        }
    }
}

static void glyph(int index, int x, int y, int scale, u16 color) {
    for (int row = 0; row < 7; row++) {
        unsigned bits = glyphs[index][row];
        for (int col = 0; col < 5; col++) {
            if (bits & (0x10 >> col)) fill(TOP, x + col * scale, y + row * scale, scale, scale, color);
        }
    }
}

static void waitForVBlank(void) {
    while (VCOUNT >= 192) {}
    while (VCOUNT < 192) {}
}

void main(void) {
    const u16 background = RGB(13, 14, 18);
    const u16 panel = RGB(31, 34, 41);
    const u16 accent = RGB(255, 107, 61);
    const u16 white = RGB(242, 243, 245);
    const u16 off = RGB(38, 42, 51);

    POWCNT1 = 0x8203;        // LCDs, both 2D engines, engine A on the top screen
    VRAMCNT_A = 0x80;        // VRAM A for the CPU and the display
    DISPCNT_A = 0x00020000;  // engine A shows VRAM A as a bitmap
    VRAMCNT_C = 0x84;        // VRAM C as engine B background memory
    DISPCNT_B = 0x00010805;  // engine B: mode 5, background 3 on
    BG3CNT_B = 0x4084;       // 256×256 direct-colour bitmap
    BG3PA_B = 0x100;
    BG3PB_B = 0;
    BG3PC_B = 0;
    BG3PD_B = 0x100;
    BG3X_B = 0;
    BG3Y_B = 0;

    fill(TOP, 0, 0, 256, 192, background);
    for (int x = 92; x <= 164; x++) {
        int distance = x < 128 ? 128 - x : x - 128;
        fill(TOP, x, 28 + (distance >> 1), 1, 4, accent);
    }
    const int title[5] = {0, 1, 1, 2, 3};
    for (int i = 0; i < 5; i++) glyph(title[i], 70 + i * 24, 54, 4, white);
    glyph(4, 116, 94, 2, white);
    glyph(5, 128, 94, 2, white);
    fill(BOTTOM, 0, 0, 256, 192, panel | OPAQUE);

    u16 lit = 0xFFFF;
    for (;;) {
        waitForVBlank();
        u16 keys = ~KEYINPUT & 0x03FF;
        u32 status = SHARED[1];
        u32 extra = (status >> 8) & 3;  // X, Y
        u16 all = keys | (extra << 10);
        if (all != lit) {
            // Left, up, down, right, B, A, Y, X, L, R, Select, Start.
            const u16 order[12] = {0x20, 0x40, 0x80, 0x10, 0x02, 0x01, 0x800, 0x400, 0x200, 0x100, 0x04, 0x08};
            for (int i = 0; i < 12; i++) {
                fill(TOP, 14 + i * 20, 150, 14, 10, (all & order[i]) ? (i < 4 ? RGB(255, 197, 61) : accent) : off);
            }
            lit = all;
        }
        if (keys & 0x08) fill(BOTTOM, 0, 0, 256, 192, panel | OPAQUE);
        if (status & 1) {
            u32 touch = SHARED[0];
            int x = touch & 0xFFFF;
            int y = touch >> 16;
            fill(BOTTOM, x - 2, y - 2, 5, 5, accent | OPAQUE);
        }
    }
}

__attribute__((naked, section(".start"))) void start(void) {
    __asm__ volatile(
        "mov r0, #0x1F\n"
        "msr cpsr_c, r0\n"
        "ldr sp, =0x023E0000\n"
        "bl main\n"
        "1: b 1b\n"
        ".ltorg\n");
}
