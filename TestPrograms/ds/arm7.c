// Attic DS test, ARM7 side: reads the touch screen and the X/Y buttons, which only
// the ARM7 can see, and leaves them in main RAM for the ARM9.

typedef unsigned short u16;
typedef unsigned int u32;

#define REG(type, address) (*(volatile type *)(address))
#define SPICNT REG(u16, 0x040001C0)
#define SPIDATA REG(u16, 0x040001C2)
#define EXTKEYIN REG(u16, 0x04000136)
#define SHARED ((volatile u32 *)0x023F0000)

static void spiWait(void) {
    while (SPICNT & 0x80) {}
}

// One 12-bit measurement of the touch controller.
static u32 touchRead(u32 command) {
    spiWait();
    SPICNT = 0x8A01;  // enable, touch controller, keep it selected
    SPIDATA = command;
    spiWait();
    SPIDATA = 0;
    spiWait();
    u32 high = SPIDATA;
    SPICNT = 0x8201;  // last transfer
    SPIDATA = 0;
    spiWait();
    u32 low = SPIDATA >> 3;
    return ((high & 0x7F) << 5) | low;
}

void main(void) {
    for (;;) {
        u16 ext = EXTKEYIN;
        int pen = !(ext & 0x40);
        if (pen) {
            // The controller reports 16 steps per pixel.
            u32 x = touchRead(0xD1) >> 4;
            u32 y = touchRead(0x91) >> 4;
            SHARED[0] = x | (y << 16);
        }
        SHARED[1] = (pen ? 1 : 0) | ((~ext & 3) << 8);
        for (volatile int i = 0; i < 2000; i++) {}
    }
}

__attribute__((naked, section(".start"))) void start(void) {
    __asm__ volatile(
        "mov r0, #0x1F\n"
        "msr cpsr_c, r0\n"
        "ldr sp, =0x0380FD80\n"
        "bl main\n"
        "1: b 1b\n"
        ".ltorg\n");
}
