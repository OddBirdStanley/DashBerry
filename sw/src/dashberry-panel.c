/* dashberry-panel.c — DashBerry status panel daemon (PLAN.md §3b, rev 6).
 *
 * The runtime's single compiled C program. One poll()/timerfd event loop
 * owns everything §3b demands a single owner for:
 *   - all seven bonnet inputs (joystick + buttons A/B) via the GPIO
 *     character-device v2 API, with strict wake-key absorption;
 *   - PAGE 0 / PAGE 1 rendering to /dev/fb1 (ssd1307fb, 1 bpp mmap);
 *   - AUTO-BLANK (10 s, OK state only);
 *   - health evaluation from real signals (segments growing, NMEA flowing,
 *     RTC readable, /data writable-with-space);
 *   - systemd watchdog liveness (hand-rolled sd_notify, Type=notify).
 *
 * The bottom-right glyph cell reports the INSTALL MODE, baked at build of
 * the card (DEBUG in /etc/dashberry.conf): shield = production (sealed),
 * wireless = debug (radios/ssh live). There is no runtime RF toggling.
 *
 * No libgpiod, no libsystemd, no libm. Portable POSIX + Linux UAPI headers.
 * Build: cc -std=c11 -Wall -Wextra -O2 -o dashberry-panel dashberry-panel.c
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/un.h>

#include <arpa/inet.h>
#include <netinet/in.h>

#include <linux/fb.h>
#include <linux/gpio.h>

/* ---------------------------------------------------------------- paths - */

#define FB_DEV        "/dev/fb1"
#define GPIO_DEV      "/dev/gpiochip0"
#define CONF_PATH     "/etc/dashberry.conf"
#define SESSION_PATH  "/run/dashberry/session"
#define FRONT_BASE    "/data/front"
#define REAR_BASE     "/data/rear"
#define DATA_MNT      "/data"
#define RTC_EPOCH     "/sys/class/rtc/rtc0/since_epoch"

/* --------------------------------------------------------------- timing - */

#define TICK_MS          200      /* repaint/watchdog tick: 5 Hz cap (§3b) */
#define HEALTH_TICKS     5        /* health re-eval every 1 s */
#define BLANK_MS         10000    /* AUTO-BLANK after 10 s without keys */
#define STALE_SECS       10       /* segment considered stalled after this */
#define GPS_SILENT_MS    5000     /* NMEA silence -> GPS ERR */
#define GPS_BACKOFF_MAX  10000    /* gpsd reconnect backoff ceiling (ms) */
#define BURN_STEP_MS     60000    /* PAGE 0 pixel-shift cadence */

/* -------------------------------------------------------------- display - */

#define COLS 16
#define ROWS 4
#define CELL_W 8
#define CELL_H 16

/* VERIFY (bench): bit order within each 1 bpp framebuffer byte. The fbdev
 * mono convention is MSB = leftmost pixel; if the bench shows every 8-px
 * column group horizontally mirrored, set FB_MSB_LEFT to 0. Deliberately
 * isolated in putpixel() — nothing else knows about packing. */
#define FB_MSB_LEFT 1

static int      fb_fd = -1;
static uint8_t *fbmem;
static size_t   fb_size;        /* mapped length */
static size_t   fb_screen;      /* yres * line_length, what we clear */
static uint32_t fb_xres, fb_yres, fb_line;

/* ------------------------------------------------------------ utilities - */

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Read a small file into buf, NUL-terminated. Returns byte count or -1. */
static int read_small(const char *path, char *buf, size_t len)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t n = read(fd, buf, len - 1);
    close(fd);
    if (n < 0)
        return -1;
    buf[n] = '\0';
    return (int)n;
}

/* ---------------------------------------------------- sd_notify (inline) - */

/* Hand-rolled sd_notify: one datagram to $NOTIFY_SOCKET. Keeps the binary
 * free of libsystemd; abstract-namespace sockets ('@' prefix) handled. */
static void sd_notify_msg(const char *msg)
{
    static int fd = -2;
    static struct sockaddr_un addr;
    static socklen_t alen;

    if (fd == -2) {
        const char *path = getenv("NOTIFY_SOCKET");
        fd = -1;
        if (path && (path[0] == '/' || path[0] == '@') &&
            strlen(path) < sizeof addr.sun_path) {
            fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
            if (fd >= 0) {
                memset(&addr, 0, sizeof addr);
                addr.sun_family = AF_UNIX;
                strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);
                alen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) +
                                   strlen(path));
                if (path[0] == '@')
                    addr.sun_path[0] = '\0';
            }
        }
    }
    if (fd >= 0)
        sendto(fd, msg, strlen(msg), 0, (struct sockaddr *)&addr, alen);
}

/* ----------------------------------------------------------------- font - */

/* Public-domain 8x8 ASCII bitmaps (dhepper/font8x8 style: one byte per row,
 * bit 0 = leftmost pixel), pixel-doubled vertically to 8x16 at render time.
 * VERIFY-visual (bench): the UI only exercises A-Z, a few lowercase, digits
 * and - . % : — those must look right; fidelity of the rest of the printable
 * table is unchecked art, fix on sight. */
static const uint8_t font8x8[95][8] = {
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* ' ' */
    {0x18,0x3C,0x3C,0x18,0x18,0x00,0x18,0x00}, /* !   */
    {0x36,0x36,0x00,0x00,0x00,0x00,0x00,0x00}, /* "   */
    {0x36,0x36,0x7F,0x36,0x7F,0x36,0x36,0x00}, /* #   */
    {0x0C,0x3E,0x03,0x1E,0x30,0x1F,0x0C,0x00}, /* $   */
    {0x00,0x63,0x33,0x18,0x0C,0x66,0x63,0x00}, /* %   */
    {0x1C,0x36,0x1C,0x6E,0x3B,0x33,0x6E,0x00}, /* &   */
    {0x06,0x06,0x03,0x00,0x00,0x00,0x00,0x00}, /* '   */
    {0x18,0x0C,0x06,0x06,0x06,0x0C,0x18,0x00}, /* (   */
    {0x06,0x0C,0x18,0x18,0x18,0x0C,0x06,0x00}, /* )   */
    {0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00}, /* *   */
    {0x00,0x0C,0x0C,0x3F,0x0C,0x0C,0x00,0x00}, /* +   */
    {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C,0x06}, /* ,   */
    {0x00,0x00,0x00,0x3F,0x00,0x00,0x00,0x00}, /* -   */
    {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C,0x00}, /* .   */
    {0x60,0x30,0x18,0x0C,0x06,0x03,0x01,0x00}, /* /   */
    {0x3E,0x63,0x73,0x7B,0x6F,0x67,0x3E,0x00}, /* 0   */
    {0x0C,0x0E,0x0C,0x0C,0x0C,0x0C,0x3F,0x00}, /* 1   */
    {0x1E,0x33,0x30,0x1C,0x06,0x33,0x3F,0x00}, /* 2   */
    {0x1E,0x33,0x30,0x1C,0x30,0x33,0x1E,0x00}, /* 3   */
    {0x38,0x3C,0x36,0x33,0x7F,0x30,0x78,0x00}, /* 4   */
    {0x3F,0x03,0x1F,0x30,0x30,0x33,0x1E,0x00}, /* 5   */
    {0x1C,0x06,0x03,0x1F,0x33,0x33,0x1E,0x00}, /* 6   */
    {0x3F,0x33,0x30,0x18,0x0C,0x0C,0x0C,0x00}, /* 7   */
    {0x1E,0x33,0x33,0x1E,0x33,0x33,0x1E,0x00}, /* 8   */
    {0x1E,0x33,0x33,0x3E,0x30,0x18,0x0E,0x00}, /* 9   */
    {0x00,0x0C,0x0C,0x00,0x00,0x0C,0x0C,0x00}, /* :   */
    {0x00,0x0C,0x0C,0x00,0x00,0x0C,0x0C,0x06}, /* ;   */
    {0x18,0x0C,0x06,0x03,0x06,0x0C,0x18,0x00}, /* <   */
    {0x00,0x00,0x3F,0x00,0x00,0x3F,0x00,0x00}, /* =   */
    {0x06,0x0C,0x18,0x30,0x18,0x0C,0x06,0x00}, /* >   */
    {0x1E,0x33,0x30,0x18,0x0C,0x00,0x0C,0x00}, /* ?   */
    {0x3E,0x63,0x7B,0x7B,0x7B,0x03,0x1E,0x00}, /* @   */
    {0x0C,0x1E,0x33,0x33,0x3F,0x33,0x33,0x00}, /* A   */
    {0x3F,0x66,0x66,0x3E,0x66,0x66,0x3F,0x00}, /* B   */
    {0x3C,0x66,0x03,0x03,0x03,0x66,0x3C,0x00}, /* C   */
    {0x1F,0x36,0x66,0x66,0x66,0x36,0x1F,0x00}, /* D   */
    {0x7F,0x46,0x16,0x1E,0x16,0x46,0x7F,0x00}, /* E   */
    {0x7F,0x46,0x16,0x1E,0x16,0x06,0x0F,0x00}, /* F   */
    {0x3C,0x66,0x03,0x03,0x73,0x66,0x7C,0x00}, /* G   */
    {0x33,0x33,0x33,0x3F,0x33,0x33,0x33,0x00}, /* H   */
    {0x1E,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E,0x00}, /* I   */
    {0x78,0x30,0x30,0x30,0x33,0x33,0x1E,0x00}, /* J   */
    {0x67,0x66,0x36,0x1E,0x36,0x66,0x67,0x00}, /* K   */
    {0x0F,0x06,0x06,0x06,0x46,0x66,0x7F,0x00}, /* L   */
    {0x63,0x77,0x7F,0x7F,0x6B,0x63,0x63,0x00}, /* M   */
    {0x63,0x67,0x6F,0x7B,0x73,0x63,0x63,0x00}, /* N   */
    {0x1C,0x36,0x63,0x63,0x63,0x36,0x1C,0x00}, /* O   */
    {0x3F,0x66,0x66,0x3E,0x06,0x06,0x0F,0x00}, /* P   */
    {0x1E,0x33,0x33,0x33,0x3B,0x1E,0x38,0x00}, /* Q   */
    {0x3F,0x66,0x66,0x3E,0x36,0x66,0x67,0x00}, /* R   */
    {0x1E,0x33,0x07,0x0E,0x38,0x33,0x1E,0x00}, /* S   */
    {0x3F,0x2D,0x0C,0x0C,0x0C,0x0C,0x1E,0x00}, /* T   */
    {0x33,0x33,0x33,0x33,0x33,0x33,0x3F,0x00}, /* U   */
    {0x33,0x33,0x33,0x33,0x33,0x1E,0x0C,0x00}, /* V   */
    {0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00}, /* W   */
    {0x63,0x63,0x36,0x1C,0x1C,0x36,0x63,0x00}, /* X   */
    {0x33,0x33,0x33,0x1E,0x0C,0x0C,0x1E,0x00}, /* Y   */
    {0x7F,0x63,0x31,0x18,0x4C,0x66,0x7F,0x00}, /* Z   */
    {0x1E,0x06,0x06,0x06,0x06,0x06,0x1E,0x00}, /* [   */
    {0x03,0x06,0x0C,0x18,0x30,0x60,0x40,0x00}, /* \   */
    {0x1E,0x18,0x18,0x18,0x18,0x18,0x1E,0x00}, /* ]   */
    {0x08,0x1C,0x36,0x63,0x00,0x00,0x00,0x00}, /* ^   */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF}, /* _   */
    {0x0C,0x0C,0x18,0x00,0x00,0x00,0x00,0x00}, /* `   */
    {0x00,0x00,0x1E,0x30,0x3E,0x33,0x6E,0x00}, /* a   */
    {0x07,0x06,0x06,0x3E,0x66,0x66,0x3B,0x00}, /* b   */
    {0x00,0x00,0x1E,0x33,0x03,0x33,0x1E,0x00}, /* c   */
    {0x38,0x30,0x30,0x3E,0x33,0x33,0x6E,0x00}, /* d   */
    {0x00,0x00,0x1E,0x33,0x3F,0x03,0x1E,0x00}, /* e   */
    {0x1C,0x36,0x06,0x0F,0x06,0x06,0x0F,0x00}, /* f   */
    {0x00,0x00,0x6E,0x33,0x33,0x3E,0x30,0x1F}, /* g   */
    {0x07,0x06,0x36,0x6E,0x66,0x66,0x67,0x00}, /* h   */
    {0x0C,0x00,0x0E,0x0C,0x0C,0x0C,0x1E,0x00}, /* i   */
    {0x30,0x00,0x30,0x30,0x30,0x33,0x33,0x1E}, /* j   */
    {0x07,0x06,0x66,0x36,0x1E,0x36,0x67,0x00}, /* k   */
    {0x0E,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E,0x00}, /* l   */
    {0x00,0x00,0x33,0x7F,0x7F,0x6B,0x63,0x00}, /* m   */
    {0x00,0x00,0x1F,0x33,0x33,0x33,0x33,0x00}, /* n   */
    {0x00,0x00,0x1E,0x33,0x33,0x33,0x1E,0x00}, /* o   */
    {0x00,0x00,0x3B,0x66,0x66,0x3E,0x06,0x0F}, /* p   */
    {0x00,0x00,0x6E,0x33,0x33,0x3E,0x30,0x78}, /* q   */
    {0x00,0x00,0x3B,0x6E,0x66,0x06,0x0F,0x00}, /* r   */
    {0x00,0x00,0x3E,0x03,0x1E,0x30,0x1F,0x00}, /* s   */
    {0x08,0x0C,0x3E,0x0C,0x0C,0x2C,0x18,0x00}, /* t   */
    {0x00,0x00,0x33,0x33,0x33,0x33,0x6E,0x00}, /* u   */
    {0x00,0x00,0x33,0x33,0x33,0x1E,0x0C,0x00}, /* v   */
    {0x00,0x00,0x63,0x6B,0x7F,0x7F,0x36,0x00}, /* w   */
    {0x00,0x00,0x63,0x36,0x1C,0x36,0x63,0x00}, /* x   */
    {0x00,0x00,0x33,0x33,0x33,0x3E,0x30,0x1F}, /* y   */
    {0x00,0x00,0x3F,0x19,0x0C,0x26,0x3F,0x00}, /* z   */
    {0x38,0x0C,0x0C,0x07,0x0C,0x0C,0x38,0x00}, /* {   */
    {0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x00}, /* |   */
    {0x07,0x0C,0x0C,0x38,0x0C,0x0C,0x07,0x00}, /* }   */
    {0x6E,0x3B,0x00,0x00,0x00,0x00,0x00,0x00}, /* ~   */
};

/* Hand-drawn 8x16 mode glyphs (bit 0 = leftmost, one byte per pixel row —
 * NOT doubled). The cell reports the INSTALL MODE, fixed for the card's
 * lifetime: wireless = DEBUG build (radios/ssh live) — user drawing,
 * source of truth DashBerry/wireless_glyph.txt ('x' = lit); shield =
 * PRODUCTION build (sealed). VERIFY-visual: legibility + orientation. */
static const uint8_t glyph_wireless[16] = {
    0x3C, 0x42, 0x81, 0x81, 0x3C, 0x42, 0x81, 0x81,
    0x3C, 0x42, 0x81, 0x99, 0x24, 0x00, 0x18, 0x18,
};
static const uint8_t glyph_shield[16] = {
    0x3E, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F,
    0x7F, 0x3E, 0x3E, 0x1C, 0x1C, 0x08, 0x00, 0x00,
};

/* ---------------------------------------------------------- framebuffer - */

static int fb_init(void)
{
    struct fb_var_screeninfo vi;
    struct fb_fix_screeninfo fi;

    fb_fd = open(FB_DEV, O_RDWR | O_CLOEXEC);
    if (fb_fd < 0) {
        fprintf(stderr, "dashberry-panel: open %s: %s\n", FB_DEV,
                strerror(errno));
        return -1;
    }
    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &vi) < 0 ||
        ioctl(fb_fd, FBIOGET_FSCREENINFO, &fi) < 0) {
        fprintf(stderr, "dashberry-panel: screeninfo: %s\n", strerror(errno));
        return -1;
    }
    fb_xres = vi.xres;
    fb_yres = vi.yres;
    fb_line = fi.line_length;
    if (vi.bits_per_pixel != 1)
        fprintf(stderr, "dashberry-panel: warning: %s is %u bpp, expected "
                "1 bpp (ssd1307fb) — rendering will be wrong\n",
                FB_DEV, vi.bits_per_pixel);
    fb_size = fi.smem_len;
    fb_screen = (size_t)fb_yres * fb_line;
    if (fb_screen > fb_size)
        fb_screen = fb_size;
    fbmem = mmap(NULL, fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fbmem == MAP_FAILED) {
        fprintf(stderr, "dashberry-panel: mmap: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

static void putpixel(int x, int y, int on)
{
    if (x < 0 || y < 0 || (uint32_t)x >= fb_xres || (uint32_t)y >= fb_yres)
        return;                    /* clips the ±1 px burn-in shift rows */
    uint8_t *p = fbmem + (size_t)y * fb_line + (x >> 3);
#if FB_MSB_LEFT
    uint8_t bit = (uint8_t)(0x80u >> (x & 7));
#else
    uint8_t bit = (uint8_t)(1u << (x & 7));
#endif
    if (on)
        *p |= bit;
    else
        *p &= (uint8_t)~bit;
}

/* 8x8 font cell doubled vertically to 8x16. */
static void draw_char(int col, int row, char ch, int yoff)
{
    if (ch < 0x20 || ch > 0x7E)
        ch = 0x20;
    const uint8_t *g = font8x8[ch - 0x20];
    int x0 = col * CELL_W;
    int y0 = row * CELL_H + yoff;
    for (int fy = 0; fy < 8; fy++) {
        uint8_t bits = g[fy];
        for (int fx = 0; fx < 8; fx++) {
            int on = (bits >> fx) & 1;          /* bit 0 = leftmost */
            putpixel(x0 + fx, y0 + 2 * fy, on);
            putpixel(x0 + fx, y0 + 2 * fy + 1, on);
        }
    }
}

static void draw_glyph16(int col, int row, const uint8_t *g, int yoff)
{
    int x0 = col * CELL_W;
    int y0 = row * CELL_H + yoff;
    for (int fy = 0; fy < 16; fy++)
        for (int fx = 0; fx < 8; fx++)
            putpixel(x0 + fx, y0 + fy, (g[fy] >> fx) & 1);
}

/* ----------------------------------------------------------------- conf - */

static double      speed_factor = 1.15078;   /* knots -> mph (default) */
static const char *speed_unit   = "MPH";
static bool        bypass_time;    /* BYPASS_TIME=1: installed without DS3231 */
static bool        bypass_rear;    /* BYPASS_REAR=1: installed without rear cam */
static bool        debug_card;     /* DEBUG=1: debug build — wireless glyph;
                                      default 0 = production — shield glyph */

static void load_conf(void)
{
    FILE *f = fopen(CONF_PATH, "r");
    if (!f)
        return;                    /* defaults stand (production face) */
    char line[256];
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "UNITS=", 6) == 0) {
            if (strncmp(line + 6, "KMH", 3) == 0) {
                speed_factor = 1.852;        /* knots -> km/h */
                speed_unit = "KMH";
            } else {
                speed_factor = 1.15078;      /* knots -> mph */
                speed_unit = "MPH";
            }
        } else if (strncmp(line, "BYPASS_TIME=", 12) == 0) {
            bypass_time = line[12] == '1';
        } else if (strncmp(line, "BYPASS_REAR=", 12) == 0) {
            bypass_rear = line[12] == '1';
        } else if (strncmp(line, "DEBUG=", 6) == 0) {
            debug_card = line[6] == '1';
        }
    }
    fclose(f);
}

/* ----------------------------------------------------------- gpsd client - */

enum gps_conn { GPS_DOWN, GPS_CONNECTING, GPS_UP };

static struct {
    int      fd;
    enum gps_conn state;
    int64_t  next_try_ms;
    int      backoff_ms;
    int64_t  last_nmea_ms;         /* 0 = never */
    bool     have_fix;             /* RMC status == 'A' */
    double   lat, lon, knots;
    int      quality, sats;        /* from GGA; tracked, not displayed */
    char     buf[1024];
    size_t   len;
} gps = { .fd = -1, .state = GPS_DOWN, .backoff_ms = 1000 };

static void gps_drop(int64_t now)
{
    if (gps.fd >= 0)
        close(gps.fd);
    gps.fd = -1;
    gps.state = GPS_DOWN;
    gps.len = 0;
    gps.have_fix = false;
    gps.next_try_ms = now + gps.backoff_ms;
    gps.backoff_ms = gps.backoff_ms * 2 > GPS_BACKOFF_MAX ? GPS_BACKOFF_MAX
                                                          : gps.backoff_ms * 2;
}

static void gps_on_connected(int64_t now)
{
    static const char watch[] = "?WATCH={\"enable\":true,\"raw\":1}\n";
    if (send(gps.fd, watch, sizeof watch - 1, MSG_NOSIGNAL) < 0) {
        gps_drop(now);
        return;
    }
    gps.state = GPS_UP;
    gps.backoff_ms = 1000;
    gps.last_nmea_ms = now;        /* grace until first sentence */
}

static void gps_try_connect(int64_t now)
{
    gps.fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (gps.fd < 0) {
        gps_drop(now);
        return;
    }
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(2947);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(gps.fd, (struct sockaddr *)&sa, sizeof sa) == 0)
        gps_on_connected(now);
    else if (errno == EINPROGRESS)
        gps.state = GPS_CONNECTING;
    else
        gps_drop(now);
}

static double dm_to_deg(const char *s, char hemi)
{
    if (!s || !*s)
        return 0.0;
    double v = atof(s);            /* ddmm.mmmm / dddmm.mmmm */
    int deg = (int)(v / 100.0);
    double d = deg + (v - deg * 100.0) / 60.0;
    if (hemi == 'S' || hemi == 'W')
        d = -d;
    return d;
}

static void nmea_line(char *line, int64_t now)
{
    size_t l = strlen(line);
    while (l && (line[l - 1] == '\r' || line[l - 1] == '\n'))
        line[--l] = '\0';
    if (line[0] != '$' || l < 6)
        return;                    /* gpsd JSON greeting lines land here */
    gps.last_nmea_ms = now;

    char *f[32];
    int n = 0;
    char *p = line;
    while (n < 32 && p) {
        f[n++] = p;
        p = strchr(p, ',');
        if (p)
            *p++ = '\0';
    }
    char *star = strchr(f[n - 1], '*');
    if (star)
        *star = '\0';

    /* $GxRMC: 2=status(A/V) 3=lat 4=N/S 5=lon 6=E/W 7=speed(knots) */
    if (strncmp(f[0] + 3, "RMC", 3) == 0 && n > 9) {
        if (f[2][0] == 'A') {
            gps.have_fix = true;
            gps.lat = dm_to_deg(f[3], f[4][0]);
            gps.lon = dm_to_deg(f[5], f[6][0]);
            gps.knots = atof(f[7]);
        } else {
            gps.have_fix = false;
        }
    /* $GxGGA: 6=fix quality 7=satellites in use */
    } else if (strncmp(f[0] + 3, "GGA", 3) == 0 && n > 7) {
        gps.quality = atoi(f[6]);
        gps.sats = atoi(f[7]);
    }
}

static void gps_read(int64_t now)
{
    char tmp[512];
    for (;;) {
        ssize_t n = recv(gps.fd, tmp, sizeof tmp, 0);
        if (n > 0) {
            for (ssize_t i = 0; i < n; i++) {
                char c = tmp[i];
                if (c == '\n') {
                    gps.buf[gps.len] = '\0';
                    nmea_line(gps.buf, now);
                    gps.len = 0;
                } else if (gps.len < sizeof gps.buf - 1) {
                    gps.buf[gps.len++] = c;
                } else {
                    gps.len = 0;   /* oversized line: discard */
                }
            }
            continue;
        }
        if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
            gps_drop(now);
        return;
    }
}

/* --------------------------------------------------------------- health - */

static struct {
    bool front, rear, gpsok, timeok, storage;
} health = { false, false, false, false, false };

static double df_pct;              /* free space %, for the PAGE 1 DF line */

static time_t newest_mp4_mtime(const char *base, const char *session)
{
    if (!*session)
        return 0;
    char dir[512];
    snprintf(dir, sizeof dir, "%s/%s", base, session);
    DIR *d = opendir(dir);
    if (!d)
        return 0;
    time_t newest = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t len = strlen(e->d_name);
        if (len < 5 || strcmp(e->d_name + len - 4, ".mp4") != 0)
            continue;
        char p[768];
        snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        struct stat st;
        if (stat(p, &st) == 0 && st.st_mtime > newest)
            newest = st.st_mtime;
    }
    closedir(d);
    return newest;
}

static bool rtc_ok(void)
{
    char buf[32];
    return read_small(RTC_EPOCH, buf, sizeof buf) > 0 && isdigit((unsigned char)buf[0]);
}

/* Storage OK: /data mounted rw, statvfs free > 0, not remounted ro, and —
 * if ext4 exposes it — no accumulated fs errors (errors_count sysfs). */
static bool storage_ok(void)
{
    bool rw = false;
    char dev[128] = "";
    FILE *m = fopen("/proc/mounts", "r");
    if (!m)
        return false;
    char line[512];
    while (fgets(line, sizeof line, m)) {
        char d[128], mnt[128], typ[64], opt[256];
        if (sscanf(line, "%127s %127s %63s %255s", d, mnt, typ, opt) != 4)
            continue;
        if (strcmp(mnt, DATA_MNT) != 0)
            continue;              /* last matching line wins (overmounts) */
        snprintf(dev, sizeof dev, "%s", d);
        rw = false;
        char *tok = strtok(opt, ",");
        while (tok) {
            if (strcmp(tok, "rw") == 0) {
                rw = true;
                break;
            }
            tok = strtok(NULL, ",");
        }
    }
    fclose(m);
    if (!dev[0])
        return false;              /* /data not mounted at all */

    struct statvfs sv;
    if (statvfs(DATA_MNT, &sv) != 0)
        return false;
    df_pct = sv.f_blocks ? 100.0 * (double)sv.f_bavail / (double)sv.f_blocks
                         : 0.0;
    if (!rw || (sv.f_flag & ST_RDONLY))
        return false;
    if (sv.f_bavail == 0)
        return false;

    const char *b = strrchr(dev, '/');
    b = b ? b + 1 : dev;
    char p[256], buf[32];
    snprintf(p, sizeof p, "/sys/fs/ext4/%s/errors_count", b);
    if (read_small(p, buf, sizeof buf) > 0 && atoi(buf) > 0)
        return false;
    return true;
}

static void eval_health(int64_t now)
{
    char session[64] = "";
    char raw[64];
    if (read_small(SESSION_PATH, raw, sizeof raw) > 0) {
        size_t j = 0;
        for (size_t i = 0; raw[i] && j < sizeof session - 1; i++)
            if (!isspace((unsigned char)raw[i]))
                session[j++] = raw[i];
        session[j] = '\0';
    }

    time_t t = time(NULL);
    time_t mf = newest_mp4_mtime(FRONT_BASE, session);
    health.front = mf != 0 && (t - mf) <= STALE_SECS;
    /* Bypassed components (installed without the hardware) are pinned OK:
     * never ERR, so they can never reach PAGE 0 or fault the system. */
    if (bypass_rear) {
        health.rear = true;
    } else {
        time_t mr = newest_mp4_mtime(REAR_BASE, session);
        health.rear = mr != 0 && (t - mr) <= STALE_SECS;
    }
    health.gpsok = gps.state == GPS_UP &&
                   (now - gps.last_nmea_ms) <= GPS_SILENT_MS;
    health.timeok = bypass_time || rtc_ok();
    health.storage = storage_ok();
}

static bool system_err(void)
{
    return !(health.front && health.rear && health.gpsok &&
             health.timeok && health.storage);
}

/* ------------------------------------------------------------- UI state - */

enum key { KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_CENTER, KEY_A, KEY_B,
           KEY_COUNT };
static const uint32_t key_gpio[KEY_COUNT] = { 17, 22, 27, 23, 4, 5, 6 };

static const int pages[] = { 1 };  /* PAGE 1 is the only designed page today */
#define NPAGES ((int)(sizeof pages / sizeof pages[0]))

static struct {
    bool    error;                 /* any health state ERR */
    int     page_idx;
    bool    blanked;
    int64_t last_key_ms;
    int     burn_idx;              /* PAGE 0 shift: 0,+1,0,-1 */
    int64_t burn_last_ms;
} ui;

static const int burn_offsets[4] = { 0, 1, 0, -1 };

static void wake(int64_t now)
{
    ui.blanked = false;
    ui.page_idx = 0;               /* always wake to PAGE 1 (§3b) */
    ui.last_key_ms = now;
}

static void handle_key(uint32_t offset, bool press, int64_t now)
{
    int key = -1;
    for (int i = 0; i < KEY_COUNT; i++)
        if (key_gpio[i] == offset) {
            key = i;
            break;
        }
    if (key < 0)
        return;

    if (ui.error)
        return;                    /* PAGE 0 is static: all input ignored */
    if (!press) {
        ui.last_key_ms = now;
        return;
    }
    if (ui.blanked) {
        wake(now);                 /* absorbed: wake only, no paging */
        return;
    }
    ui.last_key_ms = now;
    if (key == KEY_LEFT)
        ui.page_idx = (ui.page_idx + NPAGES - 1) % NPAGES;
    else if (key == KEY_RIGHT)
        ui.page_idx = (ui.page_idx + 1) % NPAGES;
    /* A, B, UP, DOWN, CENTER: reserved — wake/reset-timer only */
}

/* ------------------------------------------------------------ rendering - */

struct frame {
    bool blanked;
    int  yoff;
    char glyph;                    /* 'W' wireless (debug), 'S' shield (prod) */
    char rows[ROWS][COLS + 1];
};

static void compose(struct frame *f)
{
    memset(f, 0, sizeof *f);       /* deterministic padding for memcmp */

    if (ui.blanked && !ui.error) {
        f->blanked = true;         /* blank hides everything, glyph included */
        return;
    }
    f->glyph = debug_card ? 'W' : 'S';   /* install mode, fixed per card */

    if (ui.error) {
        /* PAGE 0 — static, only failing groups, empty lines omitted */
        f->yoff = burn_offsets[ui.burn_idx];
        snprintf(f->rows[0], sizeof f->rows[0], "Errors:");
        int r = 1;
        if (!health.front || !health.rear)
            snprintf(f->rows[r++], sizeof f->rows[0], "%s%s%s",
                     health.front ? "" : "FRONT",
                     (!health.front && !health.rear) ? " " : "",
                     health.rear ? "" : "REAR");
        if ((!health.gpsok || !health.timeok) && r < ROWS)
            snprintf(f->rows[r++], sizeof f->rows[0], "%s%s%s",
                     health.gpsok ? "" : "GPS",
                     (!health.gpsok && !health.timeok) ? " " : "",
                     health.timeok ? "" : "TIME");
        if (!health.storage && r < ROWS)
            snprintf(f->rows[r++], sizeof f->rows[0], "SD FULL");
        return;
    }

    /* PAGE 1 — values aligned at column 4: 3-char labels take one space,
     * DF takes two; coordinates at 5 decimals */
    if (gps.have_fix) {
        snprintf(f->rows[0], sizeof f->rows[0], "LAT %.5f", gps.lat);
        snprintf(f->rows[1], sizeof f->rows[1], "LON %.5f", gps.lon);
        snprintf(f->rows[2], sizeof f->rows[2], "SPD %d %s",
                 (int)(gps.knots * speed_factor + 0.5), speed_unit);
    } else {
        snprintf(f->rows[0], sizeof f->rows[0], "LAT ---");
        snprintf(f->rows[1], sizeof f->rows[1], "LON ---");
        snprintf(f->rows[2], sizeof f->rows[2], "SPD ---");
    }
    snprintf(f->rows[3], sizeof f->rows[3], "DF  %.2f%%", df_pct);
}

static void render(const struct frame *f)
{
    static int hw_blanked = -1;

    if (f->blanked) {
        memset(fbmem, 0, fb_screen);
        if (hw_blanked != 1) {
            /* Best effort: ssd1307fb may not implement fb_blank (VERIFY);
             * the memset above already darkens a self-emissive OLED. */
            ioctl(fb_fd, FBIOBLANK, FB_BLANK_POWERDOWN);
            hw_blanked = 1;
        }
        return;
    }
    if (hw_blanked != 0) {
        ioctl(fb_fd, FBIOBLANK, FB_BLANK_UNBLANK);
        hw_blanked = 0;
    }
    memset(fbmem, 0, fb_screen);
    for (int r = 0; r < ROWS; r++) {
        /* row 3, col 15 is the reserved RF glyph cell on every screen */
        int maxc = (r == ROWS - 1) ? COLS - 1 : COLS;
        for (int c = 0; c < maxc && f->rows[r][c]; c++)
            draw_char(c, r, f->rows[r][c], f->yoff);
    }
    if (f->glyph)
        draw_glyph16(COLS - 1, ROWS - 1,
                     f->glyph == 'S' ? glyph_shield : glyph_wireless, f->yoff);
}

/* ----------------------------------------------------------------- GPIO - */

static int gpio_init(void)
{
    int chip = open(GPIO_DEV, O_RDWR | O_CLOEXEC);
    if (chip < 0) {
        fprintf(stderr, "dashberry-panel: open %s: %s\n", GPIO_DEV,
                strerror(errno));
        return -1;
    }
    struct gpio_v2_line_request req;
    memset(&req, 0, sizeof req);
    for (int i = 0; i < KEY_COUNT; i++)
        req.offsets[i] = key_gpio[i];
    req.num_lines = KEY_COUNT;
    strncpy(req.consumer, "dashberry-panel", sizeof req.consumer - 1);
    /* Buttons are active-low with pull-ups; ACTIVE_LOW makes logical edges
     * intuitive: RISING = press, FALLING = release. */
    req.config.flags = GPIO_V2_LINE_FLAG_INPUT |
                       GPIO_V2_LINE_FLAG_ACTIVE_LOW |
                       GPIO_V2_LINE_FLAG_BIAS_PULL_UP |
                       GPIO_V2_LINE_FLAG_EDGE_RISING |
                       GPIO_V2_LINE_FLAG_EDGE_FALLING;
    req.config.num_attrs = 1;
    req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_DEBOUNCE;
    req.config.attrs[0].attr.debounce_period_us = 5000;
    req.config.attrs[0].mask = (1u << KEY_COUNT) - 1;
    int r = ioctl(chip, GPIO_V2_GET_LINE_IOCTL, &req);
    close(chip);
    if (r < 0 || req.fd < 0) {
        fprintf(stderr, "dashberry-panel: GPIO line request: %s\n",
                strerror(errno));
        return -1;
    }
    return req.fd;
}

/* ----------------------------------------------------------------- main - */

int main(void)
{
    load_conf();
    if (fb_init() < 0)
        return 1;
    int gpio_fd = gpio_init();
    if (gpio_fd < 0)
        return 1;

    int tick_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (tick_fd < 0) {
        fprintf(stderr, "dashberry-panel: timerfd: %s\n", strerror(errno));
        return 1;
    }
    struct itimerspec tick;
    memset(&tick, 0, sizeof tick);
    tick.it_value.tv_nsec = TICK_MS * 1000000L;
    tick.it_interval.tv_nsec = TICK_MS * 1000000L;
    timerfd_settime(tick_fd, 0, &tick, NULL);

    int64_t now = now_ms();
    ui.page_idx = 0;
    ui.last_key_ms = now;
    ui.burn_last_ms = now;
    eval_health(now);
    ui.error = system_err();       /* boot: honest immediate evaluation */
    gps_try_connect(now);

    sd_notify_msg("READY=1");

    struct frame shown;
    memset(&shown, 0, sizeof shown);
    shown.glyph = '?';             /* force first paint */
    int subtick = 0;

    for (;;) {
        struct pollfd pfd[3];
        int n = 0;
        int i_gpio = n;
        pfd[n++] = (struct pollfd){ .fd = gpio_fd, .events = POLLIN };
        int i_tick = n;
        pfd[n++] = (struct pollfd){ .fd = tick_fd, .events = POLLIN };
        int i_gps = -1;
        if (gps.fd >= 0) {
            i_gps = n;
            pfd[n++] = (struct pollfd){
                .fd = gps.fd,
                .events = (short)(gps.state == GPS_CONNECTING ? POLLOUT
                                                              : POLLIN),
            };
        }

        if (poll(pfd, (nfds_t)n, -1) < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "dashberry-panel: poll: %s\n", strerror(errno));
            return 1;
        }
        now = now_ms();

        /* --- input events --- */
        if (pfd[i_gpio].revents & POLLIN) {
            struct gpio_v2_line_event ev[16];
            ssize_t rd = read(gpio_fd, ev, sizeof ev);
            for (size_t k = 0; rd > 0 && k + sizeof ev[0] <= (size_t)rd;
                 k += sizeof ev[0]) {
                const struct gpio_v2_line_event *e =
                    (const struct gpio_v2_line_event *)((char *)ev + k);
                handle_key(e->offset,
                           e->id == GPIO_V2_LINE_EVENT_RISING_EDGE, now);
            }
        }

        /* --- gpsd socket --- */
        if (i_gps >= 0 && pfd[i_gps].revents) {
            if (gps.state == GPS_CONNECTING) {
                int soerr = 0;
                socklen_t sl = sizeof soerr;
                if (getsockopt(gps.fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) < 0
                    || soerr != 0)
                    gps_drop(now);
                else
                    gps_on_connected(now);
            } else if (pfd[i_gps].revents & (POLLIN | POLLHUP | POLLERR)) {
                gps_read(now);
            }
        }

        /* --- tick: watchdog, health, blank, burn-in, repaint --- */
        if (pfd[i_tick].revents & POLLIN) {
            uint64_t exp;
            while (read(tick_fd, &exp, sizeof exp) == sizeof exp)
                ;
            sd_notify_msg("WATCHDOG=1");

            if (gps.state == GPS_DOWN && now >= gps.next_try_ms)
                gps_try_connect(now);

            if (++subtick >= HEALTH_TICKS) {
                subtick = 0;
                eval_health(now);
                bool err = system_err();
                if (err && !ui.error) {
                    ui.error = true;   /* forces screen on + PAGE 0 */
                    ui.blanked = false;
                } else if (!err && ui.error) {
                    ui.error = false;  /* back to PAGES: wake to PAGE 1 */
                    ui.page_idx = 0;
                    ui.blanked = false;
                    ui.last_key_ms = now;
                }
            }

            if (!ui.error && !ui.blanked &&
                now - ui.last_key_ms >= BLANK_MS)
                ui.blanked = true;

            if (now - ui.burn_last_ms >= BURN_STEP_MS) {
                ui.burn_last_ms = now;
                ui.burn_idx = (ui.burn_idx + 1) & 3;
            }

            /* repaint on change only, at most once per tick (5 Hz cap) */
            struct frame f;
            compose(&f);
            if (memcmp(&f, &shown, sizeof f) != 0) {
                render(&f);
                shown = f;
            }
        }
    }
}
