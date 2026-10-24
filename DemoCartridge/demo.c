// Attic demo cartridge: a tiny Game Boy Advance program to test picture, sound
// and buttons. Build it with build.py; the result is Attic/Resources/Demo/Attic Demo.gba.
//
// No C library and no initialised globals: build.py places the code in ROM as is.

typedef unsigned short u16;
typedef unsigned int u32;

#define REG_DISPCNT (*(volatile u16 *)0x04000000)
#define REG_VCOUNT (*(volatile u16 *)0x04000006)
#define REG_KEYINPUT (*(volatile u16 *)0x04000130)
#define REG_SOUND1CNT_L (*(volatile u16 *)0x04000060)
#define REG_SOUND1CNT_H (*(volatile u16 *)0x04000062)
#define REG_SOUND1CNT_X (*(volatile u16 *)0x04000064)
#define REG_SOUNDCNT_L (*(volatile u16 *)0x04000080)
#define REG_SOUNDCNT_H (*(volatile u16 *)0x04000082)
#define REG_SOUNDCNT_X (*(volatile u16 *)0x04000084)
#define VRAM ((volatile u16 *)0x06000000)

#define RGB(r, g, b) ((u16)(((r) >> 3) | (((g) >> 3) << 5) | (((b) >> 3) << 10)))

#define KEY_A 0x0001
#define KEY_B 0x0002
#define KEY_SELECT 0x0004
#define KEY_START 0x0008
#define KEY_RIGHT 0x0010
#define KEY_LEFT 0x0020
#define KEY_UP 0x0040
#define KEY_DOWN 0x0080
#define KEY_R 0x0100
#define KEY_L 0x0200

#define FIELD_X 8
#define FIELD_Y 92
#define FIELD_W 224
#define FIELD_H 42
#define BLOCK 10

// Rows of 5-pixel glyphs: A T I C D E M O.
static const unsigned char glyphs[8][7] = {
    {0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11},
    {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04},
    {0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E},
    {0x0F, 0x10, 0x10, 0x10, 0x10, 0x10, 0x0F},
    {0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E},
    {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F},
    {0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11},
    {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E},
};

static void fill(int x, int y, int w, int h, u16 color) {
    for (int j = y; j < y + h; j++) {
        volatile u16 *row = VRAM + j * 240;
        for (int i = x; i < x + w; i++) {
            row[i] = color;
        }
    }
}

static void glyph(int index, int x, int y, int scale, u16 color) {
    for (int row = 0; row < 7; row++) {
        unsigned bits = glyphs[index][row];
        for (int col = 0; col < 5; col++) {
            if (bits & (0x10 >> col)) {
                fill(x + col * scale, y + row * scale, scale, scale, color);
            }
        }
    }
}

static void waitForVBlank(void) {
    while (REG_VCOUNT >= 160) {}
    while (REG_VCOUNT < 160) {}
}

static void beep(u16 rate) {
    REG_SOUND1CNT_L = 0;
    REG_SOUND1CNT_H = 0xF780;  // full volume, fading out, 50% square wave
    REG_SOUND1CNT_X = rate | 0x8000;
}

void main(void) {
    const u16 background = RGB(13, 14, 18);
    const u16 panel = RGB(23, 25, 31);
    const u16 accent = RGB(255, 107, 61);
    const u16 yellow = RGB(255, 197, 61);
    const u16 muted = RGB(154, 160, 172);
    const u16 off = RGB(38, 42, 51);
    const u16 colors[4] = {RGB(255, 197, 61), RGB(61, 220, 151), RGB(77, 141, 255), RGB(242, 243, 245)};

    REG_DISPCNT = 0x0403;  // mode 3 (240×160 bitmap), background 2 on
    REG_SOUNDCNT_X = 0x0080;
    REG_SOUNDCNT_L = 0x1177;
    REG_SOUNDCNT_H = 0x0002;

    fill(0, 0, 240, 160, background);

    // Roof over the name, as on the app icon.
    for (int x = 84; x <= 156; x++) {
        int distance = x < 120 ? 120 - x : x - 120;
        fill(x, 12 + (distance >> 1), 1, 4, accent);
    }
    const int title[5] = {0, 1, 1, 2, 3};  // ATTIC
    for (int i = 0; i < 5; i++) {
        glyph(title[i], 62 + i * 24, 38, 4, RGB(242, 243, 245));
    }
    const int demo[4] = {4, 5, 6, 7};  // DEMO
    for (int i = 0; i < 4; i++) {
        glyph(demo[i], 97 + i * 12, 72, 2, muted);
    }
    fill(FIELD_X, FIELD_Y, FIELD_W, FIELD_H, panel);

    int x = FIELD_X + (FIELD_W - BLOCK) / 2;
    int y = FIELD_Y + (FIELD_H - BLOCK) / 2;
    int colorIndex = 0;
    u16 previous = 0;
    u16 lit = 0xFFFF;

    for (;;) {
        waitForVBlank();
        u16 keys = ~REG_KEYINPUT & 0x03FF;
        u16 pressed = keys & ~previous;
        previous = keys;

        int nx = x, ny = y;
        if (keys & KEY_LEFT && nx > FIELD_X) nx--;
        if (keys & KEY_RIGHT && nx < FIELD_X + FIELD_W - BLOCK) nx++;
        if (keys & KEY_UP && ny > FIELD_Y) ny--;
        if (keys & KEY_DOWN && ny < FIELD_Y + FIELD_H - BLOCK) ny++;
        if (pressed & KEY_START) {
            nx = FIELD_X + (FIELD_W - BLOCK) / 2;
            ny = FIELD_Y + (FIELD_H - BLOCK) / 2;
        }
        if (pressed & KEY_A) {
            colorIndex = (colorIndex + 1) & 3;
            beep(1899);  // about 880 Hz
        }
        if (pressed & KEY_B) {
            beep(1750);  // about 440 Hz
        }

        fill(x, y, BLOCK, BLOCK, panel);
        x = nx;
        y = ny;
        fill(x, y, BLOCK, BLOCK, colors[colorIndex]);

        // One lamp per button: left, up, down, right, B, A, L, R, Select, Start.
        if (keys != lit) {
            const u16 order[10] = {KEY_LEFT, KEY_UP, KEY_DOWN, KEY_RIGHT, KEY_B, KEY_A, KEY_L, KEY_R, KEY_SELECT, KEY_START};
            for (int i = 0; i < 10; i++) {
                fill(13 + i * 22, 142, 16, 10, (keys & order[i]) ? (i < 4 ? yellow : accent) : off);
            }
            lit = keys;
        }
    }
}

__attribute__((naked, section(".start"))) void start(void) {
    __asm__ volatile(
        "mov r0, #0x12\n"
        "msr cpsr_c, r0\n"
        "ldr sp, =0x03007FA0\n"
        "mov r0, #0x1F\n"
        "msr cpsr_c, r0\n"
        "ldr sp, =0x03007F00\n"
        "bl main\n"
        "1: b 1b\n"
        ".ltorg\n");
}
