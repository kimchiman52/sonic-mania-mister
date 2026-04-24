/*
 * Sonic Mania MiSTer test-frame writer (Phase 4 Step 5).
 *
 * Standalone armhf binary that mmaps the native-video DDR3 region at
 * 0x3A000000 and drives a 320x240 RGB565 test pattern into Buffer 0 / Buffer 1,
 * flipping the control word every ~16 ms. Used to validate the FPGA core
 * pipeline before the RSDKv5U Mania runtime exists.
 *
 * Memory layout (matches vendor/Menu_MiSTer/rtl/native_video_reader.sv):
 *   0x3A000000 + 0x00000 : control word [31:2]=frame_counter, [0]=active_buffer
 *   0x3A000000 + 0x00100 : buffer 0 (320*240*2 = 153,600 bytes = 0x25800)
 *   0x3A000000 + 0x25900 : buffer 1
 *
 * Build:
 *   arm-none-linux-gnueabihf-gcc -O2 -static -o test-frame-writer test-frame-writer.c
 * (or via the Docker build container from build-hps.sh if the host lacks the toolchain)
 *
 * Usage on MiSTer (assumes Sonic Mania core is already loaded):
 *   /media/fat/games/sonic-mania/test-frame-writer [pattern]
 *       pattern: "bars" (default), "checker", "solid-red",
 *                "solid-green", "solid-blue"
 *   SIGINT / Ctrl-C to stop.
 *
 * Note: The FPGA only reads DDR3 when NATIVE_VID_ACTIVE status bit is set.
 * The wrapper is expected to set it via cfg[15]. If this program runs before
 * the wrapper enables native video, the FPGA will blank the display.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define DDR_PHYS_BASE     0x3A000000
#define DDR_REGION_SIZE   0x00060000   /* 384 KB: two 320x240 buffers + ctrl + slack */

#define FRAME_WIDTH       320
#define FRAME_HEIGHT      240
#define FRAME_BYTES       (FRAME_WIDTH * FRAME_HEIGHT * 2)  /* 153,600 = 0x25800 */

#define CTRL_OFFSET       0x00000000
#define BUF0_OFFSET       0x00000100
#define BUF1_OFFSET       0x00025900

static volatile sig_atomic_t g_stop = 0;

static void handle_sigint(int sig)
{
    (void)sig;
    g_stop = 1;
}

/* RGB565 helpers. bit 15..11 = red (5), 10..5 = green (6), 4..0 = blue (5) */
static inline uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b)
{
    return (uint16_t)((r >> 3) << 11) | (uint16_t)((g >> 2) << 5) | (uint16_t)(b >> 3);
}

static void fill_color_bars(uint16_t *frame)
{
    /* 8 standard NTSC color bars: white, yellow, cyan, green, magenta, red, blue, black. */
    static const uint8_t bars[8][3] = {
        {255, 255, 255},  /* white */
        {255, 255,   0},  /* yellow */
        {  0, 255, 255},  /* cyan */
        {  0, 255,   0},  /* green */
        {255,   0, 255},  /* magenta */
        {255,   0,   0},  /* red */
        {  0,   0, 255},  /* blue */
        {  0,   0,   0},  /* black */
    };
    for (int y = 0; y < FRAME_HEIGHT; y++)
    {
        for (int x = 0; x < FRAME_WIDTH; x++)
        {
            int bar = (x * 8) / FRAME_WIDTH;
            uint8_t r = bars[bar][0];
            uint8_t g = bars[bar][1];
            uint8_t b = bars[bar][2];
            frame[y * FRAME_WIDTH + x] = rgb565(r, g, b);
        }
    }
}

static void fill_checker(uint16_t *frame, int phase)
{
    /* 16x16 checkerboard, two colors cycling with phase. */
    for (int y = 0; y < FRAME_HEIGHT; y++)
    {
        for (int x = 0; x < FRAME_WIDTH; x++)
        {
            int cell = ((x + phase) / 16 + y / 16) & 1;
            frame[y * FRAME_WIDTH + x] = cell ? rgb565(200, 200, 200) : rgb565(40, 40, 40);
        }
    }
}

static void fill_solid(uint16_t *frame, uint8_t r, uint8_t g, uint8_t b)
{
    uint16_t px = rgb565(r, g, b);
    for (int i = 0; i < FRAME_WIDTH * FRAME_HEIGHT; i++) frame[i] = px;
}

int main(int argc, char *argv[])
{
    const char *pattern = (argc > 1) ? argv[1] : "bars";

    signal(SIGINT, handle_sigint);
    signal(SIGTERM, handle_sigint);

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0)
    {
        fprintf(stderr, "open(/dev/mem) failed: %s\n", strerror(errno));
        return 1;
    }

    void *ddr = mmap(NULL, DDR_REGION_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DDR_PHYS_BASE);
    if (ddr == MAP_FAILED)
    {
        fprintf(stderr, "mmap(0x%x, 0x%x) failed: %s\n", DDR_PHYS_BASE, DDR_REGION_SIZE, strerror(errno));
        close(fd);
        return 1;
    }

    volatile uint32_t *ctrl = (volatile uint32_t *)((uint8_t *)ddr + CTRL_OFFSET);
    uint16_t *buf0 = (uint16_t *)((uint8_t *)ddr + BUF0_OFFSET);
    uint16_t *buf1 = (uint16_t *)((uint8_t *)ddr + BUF1_OFFSET);

    /* Clear both buffers once so stale data doesn't leak through before the
     * first pattern write. */
    memset(buf0, 0, FRAME_BYTES);
    memset(buf1, 0, FRAME_BYTES);

    uint32_t frame_counter = 1;
    int active = 0;   /* which buffer is "current" (just-written); FPGA reads the one the ctrl word points at */
    int phase = 0;

    fprintf(stderr, "test-frame-writer: pattern=%s 320x240 RGB565 region=0x%x..0x%x\n",
            pattern, DDR_PHYS_BASE, DDR_PHYS_BASE + DDR_REGION_SIZE);

    while (!g_stop)
    {
        uint16_t *target = active ? buf1 : buf0;

        if (!strcmp(pattern, "bars"))          fill_color_bars(target);
        else if (!strcmp(pattern, "checker"))  fill_checker(target, phase);
        else if (!strcmp(pattern, "solid-red"))   fill_solid(target, 255,   0,   0);
        else if (!strcmp(pattern, "solid-green")) fill_solid(target,   0, 255,   0);
        else if (!strcmp(pattern, "solid-blue"))  fill_solid(target,   0,   0, 255);
        else                                   fill_color_bars(target);

        /* Ensure pixel data is flushed before announcing the frame. On ARM
         * with MAP_SHARED /dev/mem this is typically strongly ordered, but
         * a compiler barrier keeps the sequence tight. */
        __sync_synchronize();

        /* Publish: ctrl[31:2] = frame_counter, ctrl[0] = which buffer to read.
         * The reader polls ctrl at every vblank. */
        *ctrl = (frame_counter << 2) | (active & 1);

        frame_counter++;
        active ^= 1;
        phase += 2;

        /* ~60 Hz. Not precise; the FPGA has its own timing. This is just
         * "update frames at roughly display cadence so animation visible". */
        struct timespec ts = { 0, 16666666L };
        nanosleep(&ts, NULL);
    }

    fprintf(stderr, "test-frame-writer: stopping (frame_counter=%u)\n", frame_counter);

    munmap(ddr, DDR_REGION_SIZE);
    close(fd);
    return 0;
}
