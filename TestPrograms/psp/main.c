// A small PSP test program for Attic: ATTIC PSP in block letters, a turning cube drawn by the
// PSP's GPU, a lamp per button (bright while held, dimmed once it has been pressed) and a dot
// that follows the analog stick. Built with the open-source PSPSDK (pspdev); see TestPrograms/psp.py.

#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspctrl.h>
#include <pspgu.h>
#include <pspgum.h>

#include "text.h"

PSP_MODULE_INFO("Attic Test", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(THREAD_ATTR_USER);

#define BUF_WIDTH 512
#define SCR_WIDTH 480
#define SCR_HEIGHT 272

// Colours are ABGR.
#define BACKGROUND 0xff120e0d
#define LETTERS 0xfff5f3f2
#define LAMP_OFF 0xff332a26
#define LAMP_SEEN 0xff2a3a6e
#define LAMP_ON 0xff3d6bff

static unsigned int __attribute__((aligned(16))) list[262144];

struct ColorVertex {
    unsigned int color;
    float x, y, z;
};

// Two corners per sprite, in screen pixels.
struct Sprite {
    unsigned int color;
    short x, y, z;
};

#define QUAD(c, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz) \
    {c, ax, ay, az}, {c, bx, by, bz}, {c, cx, cy, cz}, {c, ax, ay, az}, {c, cx, cy, cz}, {c, dx, dy, dz}

static struct ColorVertex __attribute__((aligned(16))) cube[36] = {
    QUAD(0xff3d6bff, -1, -1, 1, -1, 1, 1, 1, 1, 1, 1, -1, 1),
    QUAD(0xff3dd2ff, -1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1),
    QUAD(0xff6bd23d, 1, -1, -1, 1, -1, 1, 1, 1, 1, 1, 1, -1),
    QUAD(0xffd2a03d, -1, -1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1),
    QUAD(0xffd23da0, -1, 1, -1, 1, 1, -1, 1, 1, 1, -1, 1, 1),
    QUAD(0xffa0a0a0, -1, -1, -1, -1, -1, 1, 1, -1, 1, 1, -1, -1),
};

// Select, Start, the D-pad, L, R, Triangle, Circle, Cross, Square.
static const unsigned int buttons[12] = {
    PSP_CTRL_SELECT, PSP_CTRL_START, PSP_CTRL_UP, PSP_CTRL_RIGHT, PSP_CTRL_DOWN, PSP_CTRL_LEFT,
    PSP_CTRL_LTRIGGER, PSP_CTRL_RTRIGGER, PSP_CTRL_TRIANGLE, PSP_CTRL_CIRCLE, PSP_CTRL_CROSS, PSP_CTRL_SQUARE,
};

static struct Sprite *sprite(struct Sprite *at, unsigned int color, int x, int y, int width, int height) {
    at[0] = (struct Sprite){color, x, y, 0};
    at[1] = (struct Sprite){color, x + width, y + height, 0};
    return at + 2;
}

int main(void) {
    sceCtrlSetSamplingCycle(0);
    sceCtrlSetSamplingMode(PSP_CTRL_MODE_ANALOG);

    void *draw = guGetStaticVramBuffer(BUF_WIDTH, SCR_HEIGHT, GU_PSM_8888);
    void *display = guGetStaticVramBuffer(BUF_WIDTH, SCR_HEIGHT, GU_PSM_8888);
    void *depth = guGetStaticVramBuffer(BUF_WIDTH, SCR_HEIGHT, GU_PSM_4444);

    sceGuInit();
    sceGuStart(GU_DIRECT, list);
    sceGuDrawBuffer(GU_PSM_8888, draw, BUF_WIDTH);
    sceGuDispBuffer(SCR_WIDTH, SCR_HEIGHT, display, BUF_WIDTH);
    sceGuDepthBuffer(depth, BUF_WIDTH);
    sceGuOffset(2048 - SCR_WIDTH / 2, 2048 - SCR_HEIGHT / 2);
    sceGuViewport(2048, 2048, SCR_WIDTH, SCR_HEIGHT);
    sceGuDepthRange(65535, 0);
    sceGuScissor(0, 0, SCR_WIDTH, SCR_HEIGHT);
    sceGuEnable(GU_SCISSOR_TEST);
    sceGuDepthFunc(GU_GEQUAL);
    sceGuShadeModel(GU_SMOOTH);
    sceGuEnable(GU_CLIP_PLANES);
    sceGuFinish();
    sceGuSync(GU_SYNC_FINISH, GU_SYNC_WHAT_DONE);
    sceDisplayWaitVblankStart();
    sceGuDisplay(GU_TRUE);

    unsigned int seen = 0;
    int frame = 0;
    for (;;) {
        SceCtrlData pad;
        sceCtrlReadBufferPositive(&pad, 1);
        seen |= pad.Buttons;

        sceGuStart(GU_DIRECT, list);
        sceGuClearColor(BACKGROUND);
        sceGuClearDepth(0);
        sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);

        // The cube, in 3D.
        sceGuEnable(GU_DEPTH_TEST);
        sceGumMatrixMode(GU_PROJECTION);
        sceGumLoadIdentity();
        sceGumPerspective(60.0f, 16.0f / 9.0f, 0.5f, 100.0f);
        sceGumMatrixMode(GU_VIEW);
        sceGumLoadIdentity();
        sceGumMatrixMode(GU_MODEL);
        sceGumLoadIdentity();
        ScePspFVector3 position = {0.0f, -0.05f, -4.2f};
        ScePspFVector3 rotation = {frame * 0.011f, frame * 0.017f, frame * 0.007f};
        sceGumTranslate(&position);
        sceGumRotateXYZ(&rotation);
        sceGumDrawArray(GU_TRIANGLES, GU_COLOR_8888 | GU_VERTEX_32BITF | GU_TRANSFORM_3D, 36, 0, cube);

        // Letters, lamps and the stick, in 2D on top.
        sceGuDisable(GU_DEPTH_TEST);
        int count = TEXT_PIXELS + 12 + 2;
        struct Sprite *sprites = sceGuGetMemory(count * 2 * sizeof(struct Sprite));
        struct Sprite *next = sprites;
        for (int i = 0; i < TEXT_PIXELS; i++) {
            next = sprite(next, LETTERS, TEXT_LEFT + text_pixels[i][0] * 4, 14 + text_pixels[i][1] * 4, 4, 4);
        }
        for (int i = 0; i < 12; i++) {
            unsigned int color = pad.Buttons & buttons[i] ? LAMP_ON : seen & buttons[i] ? LAMP_SEEN : LAMP_OFF;
            next = sprite(next, color, 30 + i * 36, 238, 28, 16);
        }
        next = sprite(next, LAMP_OFF, 24, 100, 72, 72);
        next = sprite(next, LAMP_ON, 24 + pad.Lx * 64 / 255, 100 + pad.Ly * 64 / 255, 8, 8);
        sceGuDrawArray(GU_SPRITES, GU_COLOR_8888 | GU_VERTEX_16BIT | GU_TRANSFORM_2D, count * 2, 0, sprites);

        sceGuFinish();
        sceGuSync(GU_SYNC_FINISH, GU_SYNC_WHAT_DONE);
        sceDisplayWaitVblankStart();
        sceGuSwapBuffers();
        frame++;
    }
    return 0;
}
