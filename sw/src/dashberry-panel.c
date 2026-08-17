/* dashberry-panel.c — DashBerry status panel daemon.
 *
 * The runtime's single compiled C program. One poll()/timerfd event loop
 * owns everything that needs a single owner:
 *   - all seven bonnet inputs (joystick + buttons A/B) via the GPIO
 *     character-device v2 API, with strict wake-key absorption;
 *   - button B EVENT capture: ~2 s hold on any non-blanked screen (PAGE 0
 *     included) appends an event marker to the health log;
 *   - PAGE 0 / PAGE 1 / PAGE 2 rendering to the OLED framebuffer, resolved by driver
 *     name at startup (fb number is probe order) and rendered per its
 *     reported format: 1 bpp (fbdev ssd1307fb) or 32 bpp XRGB8888 (DRM
 *     ssd130x fbdev emulation — what Trixie's kernel binds);
 *   - PAGE 3+ — the settings pages: one persistent multiple-choice setting
 *     per page, chosen on the panel and stored on /data (the OS is
 *     read-only in production, so /data is the only writable home);
 *   - AUTO-BLANK (10 s, OK state only, unless "Always On" is set);
 *   - PAGE SCRIPTS (armed only by RISKY_SCRIPTS=1, which only a --debug card
 *     can carry): a 5 s joystick-CENTER hold on any page INCLUDING PAGE 0
 *     stops the recorders and opens a list of the executables deposited in
 *     /usr/local/lib/dashberry/scripts at install time; CENTER runs the
 *     selected one as root, detached, with its output on /data. It is a
 *     ONE-WAY DOOR — no exit, no AUTO-BLANK, no PAGE 0 — and the only way
 *     out is a reboot;
 *   - JOIN WIFI (armed only by RF_JOIN=1 in /etc/dashberry.conf): a 5 s
 *     button-A hold turns the radios on and opens JW-1 (SSID list) → JW-2
 *     (on-screen keyboard) → CONNECTING; the radio work itself is done by
 *     /usr/local/bin/rf-ctl in a forked child whose stdout is polled, so
 *     the event loop never blocks on a scan or an association;
 *   - health evaluation from real signals (segments growing, NMEA flowing,
 *     RTC readable, /data writable-with-space) — logged, transitions and a
 *     10 s heartbeat, to /data/health/<session>/<session>.log for the
 *     PC-side renderer;
 *   - systemd watchdog liveness (hand-rolled sd_notify, Type=notify).
 *
 * The bottom-right glyph cell reports the LIVE RF STATE, read from
 * /sys/class/rfkill and the wireless interface's operstate: shield =
 * RF-KILLED (every card's boot state), bare antenna = RF-ENABLED but not
 * associated, antenna with waves = associated. It is the only report of
 * whether a JOIN WIFI attempt worked — there is no text hint.
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
#include <signal.h>
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
#include <sys/wait.h>

#include <arpa/inet.h>
#include <netinet/in.h>

#include <linux/fb.h>
#include <linux/gpio.h>

/* -------------------------------------------------------------- version - */

/* The DashBerry release this tree builds — the system's one version number,
 * kept in step with VERSION at the repo root. Shown on PAGE 2 line 4, which
 * is the only place a deployed card reports what it is running. */
#define DASHBERRY_VERSION "1.0"

/* ---------------------------------------------------------------- paths - */

#define FB_DRIVER     "ssd130"  /* /sys/class/graphics/fbN/name prefix */
#define GPIO_DEV      "/dev/gpiochip0"
#define CONF_PATH     "/etc/dashberry.conf"
#define SESSION_PATH  "/run/dashberry/session"
#define FRONT_BASE    "/data/front"
#define REAR_BASE     "/data/rear"
#define DATA_MNT      "/data"
#define RTC_EPOCH     "/sys/class/rtc/rtc0/since_epoch"
#define CPU_TEMP      "/sys/class/thermal/thermal_zone0/temp"  /* milli-degC */
#define PROC_STAT     "/proc/stat"                    /* cumulative jiffies */
/* Under-voltage comes from raspberrypi-hwmon, not from the firmware node
 * this used to read: rpi-6.12.y — the kernel Trixie ships — does not expose
 * get_throttled under soc:firmware at all, so that open failed on every
 * tick and PAGE 2 sat on PWR --- for the life of the card. hwmon numbering
 * follows probe order, so the node is resolved by driver name, the same
 * rule the framebuffer already uses. */
#define VOLT_HWMON    "/sys/class/hwmon"
#define VOLT_DRIVER   "rpi_volt"                /* raspberrypi-hwmon's name */
#define VOLT_ALARM    "in0_lcrit_alarm"
#define HEALTH_BASE   "/data/health"
#define SETTINGS_PATH "/data/settings.conf"     /* panel-chosen, persistent */
#define SETTINGS_TMP  "/data/settings.conf.tmp"
#define RFKILL_BASE   "/sys/class/rfkill"
#define NET_BASE      "/sys/class/net"
#define RF_CTL        "/usr/local/bin/rf-ctl"
#define SYSTEMCTL     "/usr/bin/systemctl"
#define SCRIPT_DIR    "/usr/local/lib/dashberry/scripts"  /* --risky-scripts */
#define SCRIPT_LOG    "/data/scripts"      /* one <name>.log per script */
#define RUN_DIR       "/run/dashberry"
/* PAGE SCRIPTS is a one-way door, but systemd restarts the panel on a crash
 * or a watchdog trip — which would drop the user back on PAGE 1 with the
 * recorders stopped and a script still running. This marker re-enters the
 * page at startup. It lives on tmpfs on purpose: a reboot clears it, and a
 * reboot is the only intended exit. */
#define SCRIPT_MARK   RUN_DIR "/script-mode"

/* --------------------------------------------------------------- timing - */

#define TICK_MS          200      /* repaint/watchdog tick: 5 Hz cap */
#define HEALTH_TICKS     5        /* health re-eval every 1 s */
#define BLANK_MS         10000    /* AUTO-BLANK after 10 s without keys */
#define STALE_SECS       10       /* segment considered stalled after this */
#define GPS_SILENT_MS    5000     /* NMEA silence -> GPS ERR */
#define GPS_BACKOFF_MAX  10000    /* gpsd reconnect backoff ceiling (ms) */
#define BURN_STEP_MS     60000    /* PAGE 0 pixel-shift cadence */
#define EVENT_HOLD_MS    2000     /* button B hold to mark an EVENT */
#define EVENT_FLASH_MS   2000     /* EVENT confirmation screen duration */
#define HB_MS            10000    /* health-log heartbeat cadence */
#define RF_HOLD_MS       5000     /* button A hold: arm / kill RF (JOIN WIFI) */
#define STAGE_HOLD_MS    2000     /* button A hold on JW-2: stage / connect */
#define JW_IDLE_MS       10000    /* JW-1/JW-2 exit after this without input */
#define SCAN_TO_MS       25000    /* rf-ctl scan watchdog */
#define RFDOWN_TO_MS     15000    /* rf-ctl down watchdog */
#define CONNECT_TO_MS    30000    /* rf-ctl connect watchdog: the hard cap
                                     on how long CONNECTING can hold the
                                     screen. rf-ctl's own nmcli --wait sits
                                     under it so the child normally exits
                                     first and this never fires. */
#define RF_KILL_TRIES    3        /* attempts to get the radios back down */
#define SCRIPT_HOLD_MS   5000     /* joystick CENTER hold: open PAGE SCRIPTS */
#define SCRIPT_STOP_MS   30000    /* `systemctl stop` watchdog. Two recorders
                                     at up to 10 s each (SIGINT -> EOS ->
                                     SIGKILL), plus slack. Best-effort: on
                                     expiry the list opens anyway, because the
                                     scripts are the point and a script that
                                     needs the camera can stop it itself. */

/* -------------------------------------------------------------- display - */

#define COLS 16
#define ROWS 4
#define CELL_W 8
#define CELL_H 16

/* Private cell codes: characters below 0x20 never appear in real text, so
 * they address the hand-drawn 8x16 glyphs straight out of frame.rows[]
 * without a second per-cell array. draw_char() dispatches on them. */
#define G_LDOTS    '\x01'   /* SSID/password truncation mark */
#define G_SPACE    '\x02'   /* JW-2 space key */
#define G_CAPS_OFF '\x03'   /* JW-2 caps key, OFF: arrow down */
#define G_CAPS_ON  '\x04'   /* JW-2 caps key, ON: arrow up */
#define G_DEL      '\x05'   /* JW-2 delete key */

/* JOIN WIFI sizing */
#define SSID_COLS  (COLS - 2)   /* SSID field width on JW-1; LDOTS follows */
#define SSID_MAX   32           /* IEEE 802.11 SSID octets */
#define PSK_MAX    63           /* WPA passphrase ceiling (64 = raw hex PSK) */
#define MAX_SSIDS  48

/* PAGE SCRIPTS sizing. Same field/truncation shape as JW-1's SSID list, so
 * the two lists read as one family. The cap is a display bound, not a
 * policy: the installer warns when it deposits more than this. */
#define SCRIPT_COLS  (COLS - 2) /* name field; LDOTS then the glyph follow */
#define SCRIPT_ROWS  ROWS       /* the whole screen: the list has no title */
#define SCRIPT_NAME  63
#define MAX_SCRIPTS  32

/* Bit order within each 1 bpp framebuffer byte. The fbdev mono
 * convention is MSB = leftmost pixel; if every 8-px column group shows
 * horizontally mirrored, set FB_MSB_LEFT to 0. Deliberately isolated
 * in putpixel() — nothing else knows about packing. */
#define FB_MSB_LEFT 1

static int      fb_fd = -1;
static uint8_t *fbmem;
static size_t   fb_size;        /* mapped length */
static size_t   fb_screen;      /* yres * line_length, what we clear */
static uint32_t fb_xres, fb_yres, fb_line, fb_bpp;

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
 * The UI only exercises A-Z, a few lowercase, digits and - . % : — those
 * must look right; fidelity of the rest of the printable table is
 * unchecked art, fix on sight. */
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

/* Hand-drawn 8x16 glyphs (bit 0 = leftmost, one byte per pixel row — NOT
 * doubled). The bottom-right cell reports the LIVE RF STATE:
 *   shield   = RF-KILLED — radios soft/hard-blocked (every card's boot state)
 *   rf_idle  = RF-ENABLED, not associated — the wireless glyph with its two
 *              outer arcs stripped, so "reaching out and getting nothing"
 *              reads as a visibly weaker version of the same symbol
 *   wireless = RF-ENABLED and associated (user drawing, source of truth
 *              DashBerry/wireless_glyph.txt, 'x' = lit)
 * A JOIN WIFI attempt reports its outcome here and nowhere else. */
static const uint8_t glyph_wireless[16] = {
    0x3C, 0x42, 0x81, 0x81, 0x3C, 0x42, 0x81, 0x81,
    0x3C, 0x42, 0x81, 0x99, 0x24, 0x00, 0x18, 0x18,
};
static const uint8_t glyph_rf_idle[16] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x3C, 0x42, 0x81, 0x99, 0x24, 0x00, 0x18, 0x18,
};
static const uint8_t glyph_shield[16] = {
    0x3E, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F,
    0x7F, 0x3E, 0x3E, 0x1C, 0x1C, 0x08, 0x00, 0x00,
};

/* JOIN WIFI cell glyphs. LDOTS is the truncation mark: two 2x2 blocks on
 * the text baseline, flush to the cell's right edge — one character wide,
 * so a truncated 14-column SSID plus its LDOTS still clears column 15. */
static const uint8_t glyph_ldots[16] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xD8, 0xD8, 0x00, 0x00,
};
/* CAPS: a solid triangle, point down = OFF (lower case), point up = ON. */
static const uint8_t glyph_caps_off[16] = {
    0x00, 0x00, 0x00, 0x00, 0x7F, 0x7F, 0x3E, 0x3E,
    0x1C, 0x1C, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00,
};
static const uint8_t glyph_caps_on[16] = {
    0x00, 0x00, 0x00, 0x00, 0x08, 0x08, 0x1C, 0x1C,
    0x3E, 0x3E, 0x7F, 0x7F, 0x00, 0x00, 0x00, 0x00,
};
static const uint8_t glyph_space[16] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x42, 0x42, 0x7E, 0x7E, 0x00, 0x00, 0x00, 0x00,
};
static const uint8_t glyph_del[16] = {
    0x00, 0x00, 0x00, 0x00, 0x08, 0x0C, 0x0E, 0xFF,
    0xFF, 0x0E, 0x0C, 0x08, 0x00, 0x00, 0x00, 0x00,
};

/* ---------------------------------------------------------- framebuffer - */

static char fb_dev[NAME_MAX + 8];   /* "/dev/fbN", filled by fb_resolve() */

/* Find the OLED framebuffer by driver name, not number: fb enumeration is
 * probe order, so the ssd1307fb node is /dev/fb1 when vc4 registered first
 * but /dev/fb0 on a headless boot (or when I2C probes first). Matches the
 * first /sys/class/graphics/fbN whose "name" starts with FB_DRIVER
 * ("ssd130" covers the ssd1306 overlay's ssd1307fb driver). */
static int fb_resolve(void)
{
    DIR *d = opendir("/sys/class/graphics");
    if (!d) {
        fprintf(stderr, "dashberry-panel: opendir /sys/class/graphics: %s\n",
                strerror(errno));
        return -1;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "fb", 2) != 0 ||
            !isdigit((unsigned char)e->d_name[2]))
            continue;
        char path[PATH_MAX], name[64];
        snprintf(path, sizeof path, "/sys/class/graphics/%s/name", e->d_name);
        if (read_small(path, name, sizeof name) < 0)
            continue;
        if (strncmp(name, FB_DRIVER, strlen(FB_DRIVER)) == 0) {
            snprintf(fb_dev, sizeof fb_dev, "/dev/%s", e->d_name);
            closedir(d);
            return 0;
        }
    }
    closedir(d);
    fprintf(stderr, "dashberry-panel: no framebuffer named '" FB_DRIVER
            "*' in /sys/class/graphics — is the ssd1306 overlay loaded?\n");
    return -1;
}

static int fb_init(void)
{
    struct fb_var_screeninfo vi;
    struct fb_fix_screeninfo fi;

    if (fb_resolve() < 0)
        return -1;
    fb_fd = open(fb_dev, O_RDWR | O_CLOEXEC);
    if (fb_fd < 0) {
        fprintf(stderr, "dashberry-panel: open %s: %s\n", fb_dev,
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
    fb_bpp  = vi.bits_per_pixel;
    if (fb_bpp != 1 && fb_bpp != 32)
        fprintf(stderr, "dashberry-panel: warning: %s is %u bpp, expected "
                "1 (ssd1307fb) or 32 (ssd130x fbdev emulation) — rendering "
                "will be wrong\n", fb_dev, fb_bpp);
    fb_size = fi.smem_len;
    fb_screen = (size_t)fb_yres * fb_line;
    if (fb_screen > fb_size)
        fb_screen = fb_size;
    fbmem = mmap(NULL, fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fbmem == MAP_FAILED) {
        fprintf(stderr, "dashberry-panel: mmap: %s\n", strerror(errno));
        return -1;
    }
    fprintf(stderr, "dashberry-panel: " DASHBERRY_VERSION
            ", display %s %ux%u @ %u bpp\n",
            fb_dev, fb_xres, fb_yres, vi.bits_per_pixel);
    return 0;
}

static void putpixel(int x, int y, int on)
{
    if (x < 0 || y < 0 || (uint32_t)x >= fb_xres || (uint32_t)y >= fb_yres)
        return;                    /* clips the ±1 px burn-in shift rows */
    if (fb_bpp == 32) {
        /* DRM ssd130x fbdev emulation (Trixie): XRGB8888 shadow buffer the
         * driver thresholds to mono on flush. memcpy — the mmap may not be
         * 4-aligned per row on other emulated fbs, and this is cold code. */
        uint32_t px = on ? 0x00FFFFFFu : 0x00000000u;
        memcpy(fbmem + (size_t)y * fb_line + (size_t)x * 4, &px, 4);
        return;
    }
    /* 1 bpp ssd1307fb path */
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

/* INVERTED cells write every pixel of the 8x16 cell, so the background
 * fills and the character itself stays dark — no separate fill pass. */
static void draw_glyph16(int col, int row, const uint8_t *g, int yoff, bool inv)
{
    int x0 = col * CELL_W;
    int y0 = row * CELL_H + yoff;
    for (int fy = 0; fy < 16; fy++)
        for (int fx = 0; fx < 8; fx++) {
            int on = (g[fy] >> fx) & 1;
            putpixel(x0 + fx, y0 + fy, inv ? !on : on);
        }
}

/* 8x8 font cell doubled vertically to 8x16; the private G_* codes below
 * 0x20 select a hand-drawn 8x16 glyph instead. */
static void draw_char(int col, int row, char ch, int yoff, bool inv)
{
    const uint8_t *g16 = NULL;
    switch (ch) {
    case G_LDOTS:    g16 = glyph_ldots;    break;
    case G_SPACE:    g16 = glyph_space;    break;
    case G_CAPS_OFF: g16 = glyph_caps_off; break;
    case G_CAPS_ON:  g16 = glyph_caps_on;  break;
    case G_DEL:      g16 = glyph_del;      break;
    default:         break;
    }
    if (g16) {
        draw_glyph16(col, row, g16, yoff, inv);
        return;
    }
    if (ch < 0x20 || ch > 0x7E)
        ch = 0x20;                          /* incl. UTF-8 SSID bytes */
    const uint8_t *g = font8x8[ch - 0x20];
    int x0 = col * CELL_W;
    int y0 = row * CELL_H + yoff;
    for (int fy = 0; fy < 8; fy++) {
        uint8_t bits = g[fy];
        for (int fx = 0; fx < 8; fx++) {
            int on = (bits >> fx) & 1;      /* bit 0 = leftmost */
            if (inv)
                on = !on;
            putpixel(x0 + fx, y0 + 2 * fy, on);
            putpixel(x0 + fx, y0 + 2 * fy + 1, on);
        }
    }
}

/* ----------------------------------------------------------------- conf - */

static double      speed_factor = 1.15078;   /* knots -> mph (default) */
static const char *speed_unit   = "MPH";
static bool        bypass_time;    /* BYPASS_TIME=1: installed without DS3231 */
static long long   clock_floor;    /* CLOCK_FLOOR: epoch the card cannot predate */
static bool        bypass_rear;    /* BYPASS_REAR=1: installed without rear cam */
static bool        risky_scripts;  /* RISKY_SCRIPTS=1: PAGE SCRIPTS armed.
                                      Only --debug cards can carry it; on
                                      every other card the CENTER hold does
                                      nothing and the page does not exist. */
static bool        rf_join;        /* RF_JOIN=1: JOIN WIFI armed (an --auth
                                      card without --debug). 0 = the 5 s
                                      button-A hold does nothing, as before */

/* ------------------------------------------------------------- settings - */

/* User-chosen configuration, one multiple-choice setting per page from
 * PAGE 3 on: the name on line 1, the choices right-aligned below it, the
 * active one under an INVERTED bar — JW-1's shape, with the list being the
 * choices instead of SSIDs. UP/DOWN move the bar and moving it IS the
 * change: with the live value always the one under the bar, the screen
 * cannot disagree with what the card is doing, and no key has to be spent
 * on a commit.
 *
 * ADDING A SETTING: append a row to settings[] (name, choices, default
 * index) and its page number to pages[]. Everything else — rendering,
 * paging, the viewport for more choices than fit, load, atomic save — is
 * generic. The compile-time check under pages[] catches the half-done job.
 *
 * Storage is /data, not /etc: the production OS is read-only, and /data is
 * the one volume that survives a write. Values are stored as the choice
 * TEXT (`speed_unit=KMH`), so the file explains itself to whoever pulls the
 * card, and an unrecognized key or value simply leaves the default. */

#define OPT_MAX 8                      /* choices per setting */
#define OPT_ROWS (ROWS - 1)            /* choice rows: everything below the name */
#define OPT_COLS (COLS - 1)            /* right-aligned field: clears the glyph cell */

struct setting {
    const char *key;                   /* settings.conf key */
    const char *name;                  /* line 1, left-aligned, as written */
    const char *opts[OPT_MAX + 1];     /* choices, NULL-terminated */
    int         value;                 /* index into opts[] — the live value */
};

enum { SET_UNITS, SET_ALWAYS_ON, SET_COUNT };

static struct setting settings[SET_COUNT] = {
    [SET_UNITS]     = { "speed_unit", "Speed Unit",
                        { "MPH", "KMH", NULL }, 0 },
    [SET_ALWAYS_ON] = { "always_on",  "Always On",
                        { "Off", "On", NULL }, 0 },
};

static int setting_nopts(const struct setting *s)
{
    int n = 0;
    while (n < OPT_MAX && s->opts[n])
        n++;
    return n;
}

/* Read a setting by the choice's text rather than its index, so callers
 * never encode the table's ordering. */
static bool setting_is(int idx, const char *opt)
{
    return strcmp(settings[idx].opts[settings[idx].value], opt) == 0;
}

/* Push the settings that other code caches into that code. Called after
 * load_conf(), after settings_load(), and after every change. */
static void settings_apply(void)
{
    if (setting_is(SET_UNITS, "KMH")) {
        speed_factor = 1.852;          /* knots -> km/h */
        speed_unit = "KMH";
    } else {
        speed_factor = 1.15078;        /* knots -> mph */
        speed_unit = "MPH";
    }
}

/* True once the stored values are in hand — or once /data is provably
 * mounted and simply has no settings file yet. `/data` carries `nofail`,
 * which explicitly does NOT order the mount before local-fs.target, so the
 * panel can start before it: a one-shot read at startup would silently fall
 * back to the installed defaults and then save them over the user's real
 * choices on the first key press. eval_health retries until this is true. */
static bool settings_loaded;

static bool settings_load(void)
{
    FILE *f = fopen(SETTINGS_PATH, "r");
    if (!f)
        return errno == ENOENT;        /* never been set: defaults stand */
    char line[128];
    while (fgets(line, sizeof line, f)) {
        char *nl = strpbrk(line, "\r\n");
        if (nl)
            *nl = '\0';
        char *eq = strchr(line, '=');
        if (!eq)
            continue;
        *eq++ = '\0';
        for (int i = 0; i < SET_COUNT; i++) {
            if (strcmp(line, settings[i].key) != 0)
                continue;
            for (int o = 0; settings[i].opts[o]; o++)
                if (strcmp(eq, settings[i].opts[o]) == 0)
                    settings[i].value = o;   /* unknown text: default stands */
        }
    }
    fclose(f);
    return true;
}

/* Atomic (tmp -> fsync -> rename), and best-effort like the health log: a
 * full or read-only /data loses the save, never the panel — the value is
 * already live in memory and the page still shows the truth. */
static void settings_save(void)
{
    char buf[256];
    size_t len = 0;
    for (int i = 0; i < SET_COUNT; i++) {
        int n = snprintf(buf + len, sizeof buf - len, "%s=%s\n",
                         settings[i].key, settings[i].opts[settings[i].value]);
        if (n < 0 || (size_t)n >= sizeof buf - len)
            return;                    /* table outgrew the buffer: skip */
        len += (size_t)n;
    }
    int fd = open(SETTINGS_TMP, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    bool ok = write(fd, buf, len) == (ssize_t)len && fsync(fd) == 0;
    close(fd);
    if (!ok || rename(SETTINGS_TMP, SETTINGS_PATH) != 0)
        unlink(SETTINGS_TMP);
}

/* ------------------------------------------------ conf (install-time) - */

/* /etc/dashberry.conf is what the CARD was built with; settings.conf above
 * is what the USER chose on the panel afterwards. Load order says which
 * wins: this first, settings_load() second. */
static void load_conf(void)
{
    FILE *f = fopen(CONF_PATH, "r");
    if (!f)
        return;                    /* defaults stand (production face) */
    char line[256];
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "UNITS=", 6) == 0) {
            /* The installed default for the PAGE 3 "Speed Unit" setting —
             * whatever the user last picked on the panel outranks it (see
             * settings_load, which runs after this). */
            settings[SET_UNITS].value = strncmp(line + 6, "KMH", 3) == 0;
        } else if (strncmp(line, "BYPASS_TIME=", 12) == 0) {
            bypass_time = line[12] == '1';
        } else if (strncmp(line, "BYPASS_REAR=", 12) == 0) {
            bypass_rear = line[12] == '1';
        } else if (strncmp(line, "RF_JOIN=", 8) == 0) {
            rf_join = line[8] == '1';
        } else if (strncmp(line, "RISKY_SCRIPTS=", 14) == 0) {
            risky_scripts = line[14] == '1';
        } else if (strncmp(line, "CLOCK_FLOOR=", 12) == 0) {
            /* Shared with session-init so the panel and the session name
             * can never disagree about what "implausible" means. */
            clock_floor = strtoll(line + 12, NULL, 10);
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
    /* nmea:true, NOT raw:1. raw passes the device's byte stream verbatim —
     * if the puck ever ends up in UBX binary mode (gpsd protocol-switches it
     * after sniffing a stray UBX ACK, see gps-rate), a raw watcher starves
     * of $-sentences while every nmea watcher still sees clean pseudo-NMEA.
     * nmea:true is protocol-agnostic: real NMEA passed through, pseudo-NMEA
     * synthesized when the device speaks binary. */
    static const char watch[] = "?WATCH={\"enable\":true,\"nmea\":true}\n";
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

/* ------------------------------------------------------------- RF state - */

/* Read, never assumed: the glyph reports what the kernel says right now,
 * so it stays honest whether RF moved via JOIN WIFI, NetworkManager, a
 * debug card's boot profile, or a link that dropped on its own. */
enum rf_state { RF_KILLED, RF_IDLE, RF_LINK };

static int  rf_state = RF_KILLED;
static char wl_if[32];             /* wireless interface, "" = none found */

/* First netdev with a phy80211/ or wireless/ node. Cached once FOUND, not
 * once tried: the interface appears when the driver binds, which need not
 * have happened by the panel's first health tick. The retry is an opendir
 * plus a couple of stats at 1 Hz, and only on a card that has no wireless
 * interface yet. */
static void wl_resolve(void)
{
    if (wl_if[0])
        return;
    DIR *d = opendir(NET_BASE);
    if (!d)
        return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        size_t nl = strlen(e->d_name);
        if (e->d_name[0] == '.' || nl >= sizeof wl_if)
            continue;              /* IFNAMSIZ is 16 — nothing real is cut */
        char path[PATH_MAX];
        struct stat st;
        snprintf(path, sizeof path, NET_BASE "/%s/phy80211", e->d_name);
        if (stat(path, &st) != 0) {
            snprintf(path, sizeof path, NET_BASE "/%s/wireless", e->d_name);
            if (stat(path, &st) != 0)
                continue;
        }
        memcpy(wl_if, e->d_name, nl + 1);
        break;
    }
    closedir(d);
}

/* RF-ENABLED means some wlan rfkill switch is clear both ways. A hard
 * block (no regulatory domain on the card) counts as killed — which is
 * exactly right: nothing can transmit. */
static bool rf_unblocked(void)
{
    DIR *d = opendir(RFKILL_BASE);
    if (!d)
        return false;
    bool live = false;
    struct dirent *e;
    while (!live && (e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "rfkill", 6) != 0)
            continue;
        char path[PATH_MAX], buf[32];
        snprintf(path, sizeof path, RFKILL_BASE "/%s/type", e->d_name);
        if (read_small(path, buf, sizeof buf) <= 0 ||
            strncmp(buf, "wlan", 4) != 0)
            continue;
        snprintf(path, sizeof path, RFKILL_BASE "/%s/soft", e->d_name);
        if (read_small(path, buf, sizeof buf) <= 0 || buf[0] != '0')
            continue;
        snprintf(path, sizeof path, RFKILL_BASE "/%s/hard", e->d_name);
        if (read_small(path, buf, sizeof buf) <= 0 || buf[0] != '0')
            continue;
        live = true;
    }
    closedir(d);
    return live;
}

/* operstate "up" on a wireless netdev == associated (the driver reports
 * carrier only once the link is established). */
static bool wl_linked(void)
{
    wl_resolve();
    if (!wl_if[0])
        return false;
    char path[PATH_MAX], buf[32];
    snprintf(path, sizeof path, NET_BASE "/%s/operstate", wl_if);
    return read_small(path, buf, sizeof buf) > 0 &&
           strncmp(buf, "up", 2) == 0;
}

static void rf_refresh(void)
{
    rf_state = !rf_unblocked() ? RF_KILLED
                               : (wl_linked() ? RF_LINK : RF_IDLE);
}

/* --------------------------------------------------------------- health - */

static struct {
    bool front, rear, gpsok, timeok, storage;
} health = { false, false, false, false, false };

static double df_pct;              /* free space %, for the PAGE 1 DF line */

/* SoC temperature for the PAGE 2 TMP line. The sysfs value is an integer in
 * millidegrees Celsius (kernel thermal contract); on the Pi 4 the BCM2711
 * sensor quantizes in ~0.487 degC steps, so whole degrees lose nothing real.
 * Not a health state — a failed read shows TMP --- and never faults. */
static int  cpu_temp_mc;
static bool cpu_temp_valid;

static void read_cpu_temp(void)
{
    char buf[16];
    cpu_temp_valid = read_small(CPU_TEMP, buf, sizeof buf) > 0 &&
                     (isdigit((unsigned char)buf[0]) || buf[0] == '-');
    if (cpu_temp_valid)
        cpu_temp_mc = atoi(buf);
}

/* Whole degrees C, round-to-nearest and negative-safe. One definition for
 * the PAGE 2 line and the health log, so they can never disagree. */
static int cpu_temp_c(void)
{
    return (cpu_temp_mc + (cpu_temp_mc >= 0 ? 500 : -500)) / 1000;
}

/* CPU load for the PAGE 2 CPU line, off /proc/stat's aggregate "cpu" row.
 * That row sums all four cores, so the figure is a share of the WHOLE Pi 4,
 * 0-100% — not top's per-core 0-400%. On 16 columns the normalized form is
 * the only one readable at a glance, and it is the one that answers "is
 * there headroom left".
 *
 * This line exists because the rear used to be encoded HERE, in software, and
 * nothing else on the car could see the cost: TMP shows heat AFTER the work,
 * and the health check (segments growing) cannot distinguish an encoder
 * keeping up from one quietly dropping frames. It caught exactly that —
 * 1920x1080@30 went in on 2026-08-12 and came back well under 30 fps.
 *
 * What it measured turned out to be a per-CORE ceiling wearing a whole-box
 * disguise, and reading it that way cost weeks: 40% busy here was ONE pinned
 * core (openh264enc runs one slice, one slice is one thread) plus front-rec,
 * with three cores idle. It read as headroom and there was none.
 * INVESTIGATE-REAR-ENCODE.md has the numbers.
 *
 * The rear encode moved to the Zero on 2026-08-13, taking ~1.2 cores of
 * decode+encode with it, so this figure should now sit far lower and this
 * line becomes the instrument that CONFIRMS that rather than the one watching
 * for strain. A rear that is still expensive here means the pipeline is not
 * the remux it is supposed to be (see rear-rec).
 *
 * The counters are cumulative since boot, so the FIRST tick has no delta to
 * divide and shows ---. A failed read keeps the last figure rather than
 * blanking, because a single unreadable /proc/stat is not news. Like TMP and
 * PWR, informational only: it never faults the system. */
static unsigned long long cpu_busy_prev, cpu_total_prev;
static int  cpu_load_pct;
static bool cpu_load_valid;

static void read_cpu_load(void)
{
    char buf[192];
    unsigned long long v[8] = { 0 };

    if (read_small(PROC_STAT, buf, sizeof buf) <= 0)
        return;
    /* The aggregate row is the first line, so parsing from the head of the
     * buffer is enough — no need to read all of /proc/stat. */
    int n = sscanf(buf, "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
                   &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]);
    if (n < 4)                     /* user/nice/system/idle are the minimum */
        return;

    unsigned long long total = 0;
    for (int i = 0; i < 8; i++)
        total += v[i];
    /* idle + iowait are the not-working columns. iowait is idle time that
     * merely has I/O outstanding, and counting it as busy would make every
     * card flush and every retention sweep read as load. */
    unsigned long long busy = total - v[3] - v[4];

    if (cpu_total_prev != 0 && total > cpu_total_prev) {
        unsigned long long dt = total - cpu_total_prev;
        unsigned long long db = busy - cpu_busy_prev;
        /* The counters are monotonic, so db <= dt always holds — clamp
         * anyway rather than print an unsigned underflow as 4294967295%. */
        if (db > dt)
            db = dt;
        cpu_load_pct = (int)((db * 100 + dt / 2) / dt);
        cpu_load_valid = true;
    }
    cpu_busy_prev  = busy;
    cpu_total_prev = total;
}

/* Under-voltage for the PAGE 2 PWR line, from raspberrypi-hwmon's low-crit
 * alarm. The driver polls the firmware every 2 s and hands it the
 * sticky-clear mask, so the alarm reads "under-voltage during the last poll
 * window" and drops back to 0 once the rail recovers; sampling it at 1 Hz
 * therefore cannot step over a window.
 *
 * That read-and-clear is also why UV SEEN is latched here rather than read:
 * the firmware's own since-boot bit is consumed by the driver before
 * userspace can see it, so nothing can still report it. The latch makes UV
 * SEEN mean "since the panel started", which is the narrower claim — a dip
 * during the seconds of boot before the panel is up will not be caught.
 * Like TMP, informational only: a failed read shows PWR --- and never
 * faults the system. */
static bool uv_now;                     /* alarm asserted on the last read */
static bool uv_seen;                    /* latched: asserted at least once */
static bool uv_valid;                   /* the alarm node answered */
static char uv_path[PATH_MAX];          /* empty until resolved */

/* hwmonN is assigned in probe order, so match on the driver's name. The
 * driver can also probe after the panel is up, which is why a failure here
 * is retried on the next tick rather than settled once at startup. */
static bool uv_resolve(void)
{
    DIR *d = opendir(VOLT_HWMON);
    if (!d)
        return false;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "hwmon", 5) != 0 ||
            !isdigit((unsigned char)e->d_name[5]))
            continue;
        char path[PATH_MAX], name[32];
        snprintf(path, sizeof path, VOLT_HWMON "/%s/name", e->d_name);
        if (read_small(path, name, sizeof name) <= 0)
            continue;
        name[strcspn(name, "\n")] = '\0';
        if (strcmp(name, VOLT_DRIVER) != 0)
            continue;
        snprintf(uv_path, sizeof uv_path, VOLT_HWMON "/%s/" VOLT_ALARM,
                 e->d_name);
        closedir(d);
        return true;
    }
    closedir(d);
    return false;
}

static void read_undervoltage(void)
{
    char buf[16];
    if (!uv_path[0] && !uv_resolve()) {
        uv_valid = false;
        return;
    }
    if (read_small(uv_path, buf, sizeof buf) <= 0 ||
        !isdigit((unsigned char)buf[0])) {
        uv_path[0] = '\0';              /* stale node — resolve again next tick */
        uv_valid = false;
        return;
    }
    uv_valid = true;
    uv_now   = buf[0] != '0';
    if (uv_now)
        uv_seen = true;                 /* the latch holds for the session */
}

/* Segments are MPEG-TS (%05d.ts) — the ".ts" below is a 3-char suffix, so the
 * length guard is "at least one character before it", not the 4-char form the
 * MP4 era used. */
static time_t newest_segment_mtime(const char *base, const char *session)
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
        if (len < 4 || strcmp(e->d_name + len - 3, ".ts") != 0)
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

/* TIME asks two questions of the DS3231, not one.
 *
 * Readable proves the rtc driver and the I2C device answer. It does NOT
 * prove the value is right — a DS3231 that firstinstall never managed to
 * set, or whose coin cell has died, answers perfectly with a well-formed
 * 2000-01-01. That is not cosmetic: session-init mints every session name
 * from that clock, retention deletes by oldest mtime and so eats the drive
 * being recorded before it touches last month's, and nothing on an offline
 * card ever corrects any of it. The fault is invisible until a card is
 * pulled months later and the folder names are all wrong.
 *
 * So the value is tested against CLOCK_FLOOR — the same epoch session-init
 * refuses to mint below (dashberry.conf). A dead cell lands on PAGE 0 the
 * first time it matters, which is the one place the driver would see it.
 * INVESTIGATE-TIMESTAMPS.md carries the full diagnosis. */
static bool rtc_ok(void)
{
    char buf[32];
    if (read_small(RTC_EPOCH, buf, sizeof buf) <= 0 ||
        !isdigit((unsigned char)buf[0]))
        return false;              /* absent, unreadable, or not a number */
    /* clock_floor == 0 means the key is absent from the conf (an older
     * card): fall back to the readability-only test rather than fault. */
    return clock_floor == 0 || strtoll(buf, NULL, 10) >= clock_floor;
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

/* ----------------------------------------------------------- health log - */

/* Append-only per-session health log on /data — the PC-side renderer's
 * source of truth for "what was wrong when" (dashberry-cli --continuous
 * turns it into No Signal / GPS Error overlays). One record per line,
 * space-separated, first field the wall-clock epoch:
 *   <epoch> boot                       log opened (≈ panel start)
 *   <epoch> ver <release>              the DashBerry release writing the log
 *   <epoch> <comp> <OK|ERR>            comp: front rear gps time storage
 *   <epoch> gpsfix <FIX|NOFIX>         RMC fix presence (OK-but-fixless)
 *   <epoch> event                      button-B marker
 *   <epoch> hb                         heartbeat — bounds session end
 *   <epoch> tmp <degC>                 SoC temperature, whole degrees
 * The tmp record rides the heartbeat (one per 10 s, plus one in the initial
 * dump) — the glovebox is an oven and a card that throttled, or died, in a
 * heat wave should say so off-card without anyone having watched PAGE 2.
 * A failed sensor read writes no record at all: absence means unknown, so
 * there is no sentinel value for a parser to mistake for a reading.
 * The full state set is written once after boot so a parser needs no
 * assumed defaults; after that only transitions, plus the 10 s heartbeat.
 * Each record is one unbuffered write(2) (durability rides on the 1 s
 * journal commit, same rationale as the NMEA log). Best-effort by
 * design: any failure closes the fd and the next health tick retries the
 * open — the log can never fault the panel. */
static struct {
    int     fd;
    char    session[64];
    bool    inited;                /* initial full state set written */
    bool    front, rear, gpsok, timeok, storage, fix;   /* last logged */
    int64_t last_hb_ms;
} hlog = { .fd = -1 };

static bool hlog_line(const char *rec)
{
    if (hlog.fd < 0)
        return false;
    char buf[96];
    int n = snprintf(buf, sizeof buf, "%lld %s\n", (long long)time(NULL), rec);
    if (n < 0 || (size_t)n >= sizeof buf ||
        write(hlog.fd, buf, (size_t)n) != n) {
        close(hlog.fd);
        hlog.fd = -1;              /* next eval_health retries the open */
        return false;
    }
    return true;
}

static void hlog_state(const char *comp, bool ok)
{
    char rec[32];
    snprintf(rec, sizeof rec, "%s %s", comp, ok ? "OK" : "ERR");
    hlog_line(rec);
}

static void hlog_temp(void)
{
    if (!cpu_temp_valid)
        return;                        /* no reading, no record */
    char rec[32];
    snprintf(rec, sizeof rec, "tmp %d", cpu_temp_c());
    hlog_line(rec);
}

static void hlog_open(const char *session, int64_t now)
{
    if (hlog.fd >= 0 && strcmp(session, hlog.session) == 0)
        return;
    if (hlog.fd >= 0) {
        close(hlog.fd);
        hlog.fd = -1;
    }
    if (!*session)
        return;
    char path[600];
    /* mkdir: session-init creates these, but a card installed before the
     * health log existed (or a by-hand session) may lack them. */
    mkdir(HEALTH_BASE, 0755);
    snprintf(path, sizeof path, HEALTH_BASE "/%s", session);
    mkdir(path, 0755);
    snprintf(path, sizeof path, HEALTH_BASE "/%s/%s.log", session, session);
    hlog.fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (hlog.fd < 0)
        return;
    snprintf(hlog.session, sizeof hlog.session, "%s", session);
    hlog.inited = false;           /* a reopen re-dumps state: parser-safe */
    hlog.last_hb_ms = now;
    hlog_line("boot");
    hlog_line("ver " DASHBERRY_VERSION);
}

static void hlog_sync(const char *session, int64_t now)
{
    hlog_open(session, now);
    if (hlog.fd < 0)
        return;
    bool fix = gps.have_fix;
    if (!hlog.inited) {
        hlog_state("front", health.front);
        hlog_state("rear", health.rear);
        hlog_state("gps", health.gpsok);
        hlog_state("time", health.timeok);
        hlog_state("storage", health.storage);
        hlog_line(fix ? "gpsfix FIX" : "gpsfix NOFIX");
        hlog_temp();                   /* the dump is a complete snapshot */
        hlog.front = health.front;
        hlog.rear = health.rear;
        hlog.gpsok = health.gpsok;
        hlog.timeok = health.timeok;
        hlog.storage = health.storage;
        hlog.fix = fix;
        hlog.inited = true;
    } else {
        if (health.front != hlog.front)
            hlog_state("front", hlog.front = health.front);
        if (health.rear != hlog.rear)
            hlog_state("rear", hlog.rear = health.rear);
        if (health.gpsok != hlog.gpsok)
            hlog_state("gps", hlog.gpsok = health.gpsok);
        if (health.timeok != hlog.timeok)
            hlog_state("time", hlog.timeok = health.timeok);
        if (health.storage != hlog.storage)
            hlog_state("storage", hlog.storage = health.storage);
        if (fix != hlog.fix)
            hlog_line((hlog.fix = fix) ? "gpsfix FIX" : "gpsfix NOFIX");
    }
    if (now - hlog.last_hb_ms >= HB_MS) {
        hlog.last_hb_ms = now;
        hlog_line("hb");
        hlog_temp();
    }
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
    time_t mf = newest_segment_mtime(FRONT_BASE, session);
    health.front = mf != 0 && (t - mf) <= STALE_SECS;
    /* Bypassed components (installed without the hardware) are pinned OK:
     * never ERR, so they can never reach PAGE 0 or fault the system. */
    if (bypass_rear) {
        health.rear = true;
    } else {
        time_t mr = newest_segment_mtime(REAR_BASE, session);
        health.rear = mr != 0 && (t - mr) <= STALE_SECS;
    }
    health.gpsok = gps.state == GPS_UP &&
                   (now - gps.last_nmea_ms) <= GPS_SILENT_MS;
    health.timeok = bypass_time || rtc_ok();
    health.storage = storage_ok();
    /* Settings live on /data, which may still have been mounting when the
     * panel started (nofail — see settings_loaded). Retry until it answers,
     * and only treat "no file" as final once storage is provably there. */
    if (!settings_loaded) {
        settings_loaded = settings_load() && health.storage;
        settings_apply();
    }
    read_cpu_temp();               /* 1 Hz, off the 5 Hz paint path */
    read_cpu_load();               /* same tick: the delta window IS 1 s */
    read_undervoltage();
    rf_refresh();                  /* glyph truth, not a health state */
    hlog_sync(session, now);
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

/* Wake order: index 0 is PAGE 1. PAGE 3 and up are the settings pages, one
 * per settings[] row IN TABLE ORDER — the assert below is what makes adding
 * a setting without giving it a page a compile error rather than a page
 * nobody can reach. */
#define SET_PAGE_FIRST 3
static const int pages[] = { 1, 2, SET_PAGE_FIRST, SET_PAGE_FIRST + 1 };
#define NPAGES ((int)(sizeof pages / sizeof pages[0]))
_Static_assert(NPAGES == 2 + SET_COUNT, "every setting needs a page in pages[]");

/* The setting a page number owns, or NULL for the fixed pages (0/1/2). */
static struct setting *page_setting(int page)
{
    int i = page - SET_PAGE_FIRST;
    return (i >= 0 && i < SET_COUNT) ? &settings[i] : NULL;
}

/* Which choices are on screen when there are more than OPT_ROWS of them.
 * Derived from the value alone (no stored scroll position): the live choice
 * is always visible, and the frame stays a pure function of state, which is
 * what the repaint-on-change comparison relies on. */
static int setting_top(const struct setting *s)
{
    int n = setting_nopts(s);
    if (n <= OPT_ROWS)
        return 0;
    int top = s->value - OPT_ROWS / 2;
    if (top > n - OPT_ROWS)
        top = n - OPT_ROWS;
    return top < 0 ? 0 : top;
}

/* UP/DOWN on a settings page. Wraps at both ends like JW-1's list and the
 * keyboard, so either key alone reaches every choice. Every accepted move
 * applies and persists immediately: there is no staging state that a power
 * cut could catch half-committed. */
static void setting_move(struct setting *s, int delta)
{
    int n = setting_nopts(s);
    int v = (s->value + delta + n) % n;
    if (v == s->value)
        return;
    s->value = v;
    settings_apply();
    settings_save();
}

/* Which screen owns the input. PAGE covers PAGE 0/1/2 (ui.error picks
 * PAGE 0); the three JOIN WIFI screens are their own modes; SCRIPT is the
 * one screen with no way back — see PAGE SCRIPTS below. */
enum screen { SCR_PAGE, SCR_JW1, SCR_JW2, SCR_CONN, SCR_SCRIPT };

static struct {
    bool    error;                 /* any health state ERR */
    int     screen;
    int     page_idx;
    bool    blanked;
    int64_t last_key_ms;
    int     burn_idx;              /* PAGE 0 shift: 0,+1,0,-1 */
    int64_t burn_last_ms;
    int64_t b_down_ms;             /* button B pressed since (0 = up) */
    bool    b_fired;               /* this hold already marked an event */
    int64_t a_down_ms;             /* button A pressed since (0 = up) */
    bool    a_fired;               /* this hold already fired its action */
    int64_t c_down_ms;             /* joystick CENTER pressed since (0 = up) */
    bool    c_fired;               /* this hold already opened PAGE SCRIPTS */
    int64_t flash_until_ms;        /* EVENT confirmation visible until */
    char    flash[COLS + 1];       /* EVENT confirmation text */
    bool    rf_kill_pending;       /* the radios are owed an rf-ctl down */
    int     rf_kill_tries;         /* attempts spent on it so far */
} ui;

/* JOIN WIFI screen state. jw.psk is the only secret the panel holds; it is
 * wiped on every exit and never logged, printed, or passed in argv. */
static struct {
    char ssid[MAX_SSIDS][SSID_MAX + 1];
    int  n;
    int  sel;                      /* JW-1 cursor (index into ssid[]) */
    int  top;                      /* JW-1 first visible row */
    bool scanning;
    bool scan_failed;
    char psk[PSK_MAX + 1];
    int  plen;
    int  kr, kc;                   /* JW-2 POSITION: keyboard row/column */
    bool caps;
    bool staged;                   /* input area INVERTED, armed to connect */
} jw;

static const int burn_offsets[4] = { 0, 1, 0, -1 };

static void wake(int64_t now)
{
    ui.blanked = false;
    ui.page_idx = 0;               /* always wake to PAGE 1 */
    ui.last_key_ms = now;
}

/* ---------------------------------------------------------- rf-ctl jobs - */

/* Every radio operation is a forked rf-ctl whose stdout joins the poll()
 * set: a scan takes seconds and an association tens of seconds, and the
 * panel must keep painting, keep petting the watchdog, and keep accepting
 * the exit keys throughout. One job at a time; each carries a deadline so
 * a wedged child can never wedge the UI. */
enum { RFJ_NONE, RFJ_SCAN, RFJ_DOWN, RFJ_CONNECT };

static struct {
    int     kind;
    pid_t   pid;
    int     fd;                    /* child stdout, -1 once drained */
    int64_t deadline_ms;
    bool    reaped;
    int     status;
    char    out[4096];
    size_t  len;
} job = { .kind = RFJ_NONE, .fd = -1 };

/* in: written to the child's stdin and closed — how the SSID and
 * passphrase travel, so neither ever appears in argv (/proc-readable).
 * Both fit far inside PIPE_BUF, so the single write cannot block. */
static bool rf_spawn(int kind, const char *cmd, const char *in, int64_t now,
                     int timeout_ms)
{
    if (job.kind != RFJ_NONE)
        return false;

    int op[2], ip[2] = { -1, -1 };
    if (pipe(op) < 0)
        return false;
    if (in && pipe(ip) < 0) {
        close(op[0]);
        close(op[1]);
        return false;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(op[0]);
        close(op[1]);
        if (in) {
            close(ip[0]);
            close(ip[1]);
        }
        return false;
    }
    if (pid == 0) {
        /* Own process group, so a cancel reaches the pipelines rf-ctl
         * forks and not just the shell wrapping them. Set on both sides of
         * the fork: whichever call wins, the group exists before either
         * process can need it. */
        setpgid(0, 0);
        /* Everything else the panel holds is O_CLOEXEC (fb, gpio, timerfd,
         * gpsd socket, health log, notify socket), so exec closes it. */
        if (in) {
            dup2(ip[0], 0);
            close(ip[0]);
            close(ip[1]);
        } else {
            int devnull = open("/dev/null", O_RDONLY);
            if (devnull >= 0) {
                dup2(devnull, 0);
                close(devnull);
            }
        }
        dup2(op[1], 1);
        dup2(op[1], 2);            /* diagnostics ride the same pipe */
        close(op[0]);
        close(op[1]);
        execl(RF_CTL, "rf-ctl", cmd, (char *)NULL);
        _exit(127);
    }

    setpgid(pid, pid);             /* harmless if the child got there first */
    close(op[1]);
    if (in) {
        close(ip[0]);
        ssize_t w = write(ip[1], in, strlen(in));
        (void)w;                   /* SIGPIPE ignored; a dead child fails
                                      through its exit status instead */
        close(ip[1]);
    }
    fcntl(op[0], F_SETFL, O_NONBLOCK);

    job.kind = kind;
    job.pid = pid;
    job.fd = op[0];
    job.deadline_ms = now + timeout_ms;
    job.reaped = false;
    job.status = -1;
    job.len = 0;
    return true;
}

/* rf-ctl forks pipelines (`nmcli | sed | grep | sort`), and those children
 * inherit our stdout pipe. Signalling the shell alone leaves them running,
 * holding the pipe open — which used to stall job completion until the
 * deadline, and with it anything queued behind the one job slot. Signal the
 * process group instead, and drop the output we no longer care about so the
 * job can finish on the next reap rather than on EOF. */
static void rf_job_cancel(void)
{
    if (job.kind == RFJ_NONE)
        return;
    if (!job.reaped) {
        kill(-job.pid, SIGKILL);   /* the group: pgid == pid, set at spawn */
        kill(job.pid, SIGKILL);    /* in case setpgid() lost its race */
    }
    if (job.fd >= 0) {
        close(job.fd);
        job.fd = -1;
    }
    job.deadline_ms = 0;           /* completes as soon as it is reaped */
}

static void rf_job_read(void)
{
    for (;;) {
        char tmp[512];
        ssize_t n = read(job.fd, tmp, sizeof tmp);
        if (n > 0) {
            size_t room = sizeof job.out - 1 - job.len;
            size_t take = (size_t)n < room ? (size_t)n : room;
            memcpy(job.out + job.len, tmp, take);
            job.len += take;       /* silently truncates: 4 KB is ~100 SSIDs */
            continue;
        }
        if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK &&
                       errno != EINTR)) {
            close(job.fd);
            job.fd = -1;
        }
        return;
    }
}

/* ------------------------------------------------------------ JOIN WIFI - */

/* The radios are owed a trip back down. Every caller goes through here so
 * the attempt is retried if rf-ctl fails, rather than fired once and
 * assumed to have worked — this is the privacy-preserving direction, so
 * "probably off" is not good enough. */
static void rf_kill_request(void)
{
    ui.rf_kill_pending = true;
    ui.rf_kill_tries = 0;
}

static void jw_clear(void)
{
    memset(jw.psk, 0, sizeof jw.psk);   /* the secret never outlives a screen */
    jw.n = 0;
    jw.sel = 0;
    jw.top = 0;
    jw.plen = 0;
    jw.kr = 0;
    jw.kc = 0;                     /* POSITION starts at 'A' */
    jw.caps = false;
    jw.staged = false;
    jw.scanning = false;
    jw.scan_failed = false;
}

/* Leaving JW-1/JW-2 without completing a join takes the radios back down
 * with it: arming was a means to an end, and a user who backed out (or
 * walked away, or whose card faulted mid-flow) never asked for a card that
 * keeps transmitting. Dark is the resting state and every exit returns to
 * it. The one path that does NOT come through here is a finished
 * connection attempt — there RF must survive, or the glyph could not tell
 * "failed" from "switched off".
 *
 * user = a key press asked for this (so the page gets its full 10 s); the
 * idle timeout leaves last_key_ms alone, and PAGE 1 blanks at once. */
static void jw_exit(int64_t now, bool user)
{
    /* A scan in flight is genuinely cancelled, not just orphaned — the
     * `down` below cannot spawn until the one job slot is free. */
    if (job.kind == RFJ_SCAN)
        rf_job_cancel();
    /* Deferred, not spawned here: the slot may still be occupied for a
     * tick or two. rf_kill_drain() picks it up. */
    rf_kill_request();
    ui.screen = SCR_PAGE;
    ui.page_idx = 0;
    ui.a_down_ms = 0;
    ui.a_fired = false;
    jw_clear();
    if (user)
        ui.last_key_ms = now;
}

static int ssid_cmp(const void *a, const void *b)
{
    const char *x = a, *y = b;
    for (size_t i = 0;; i++) {
        int cx = tolower((unsigned char)x[i]);
        int cy = tolower((unsigned char)y[i]);
        if (cx != cy)
            return cx - cy;
        if (!cx)
            return strcmp(x, y);   /* stable tiebreak on case alone */
    }
}

/* rf-ctl prints one SSID per line. Truncate to 32 octets, drop blanks and
 * duplicates (truncation can create new ones), then sort alphabetically. */
static void jw_take_scan(void)
{
    jw.n = 0;
    size_t i = 0;
    while (i < job.len && jw.n < MAX_SSIDS) {
        size_t e = i;
        while (e < job.len && job.out[e] != '\n')
            e++;
        size_t l = e - i;
        while (l && (job.out[i + l - 1] == '\r' || job.out[i + l - 1] == ' '))
            l--;
        if (l > SSID_MAX)
            l = SSID_MAX;
        if (l) {
            char cand[SSID_MAX + 1];
            memcpy(cand, job.out + i, l);
            cand[l] = '\0';
            bool dup = false;
            for (int k = 0; k < jw.n && !dup; k++)
                dup = strcmp(jw.ssid[k], cand) == 0;
            if (!dup)
                memcpy(jw.ssid[jw.n++], cand, l + 1);
        }
        i = e + 1;
    }
    qsort(jw.ssid, (size_t)jw.n, sizeof jw.ssid[0], ssid_cmp);
    jw.sel = 0;
    jw.top = 0;
}

static void jw_viewport(void)
{
    if (jw.sel < jw.top)
        jw.top = jw.sel;
    if (jw.sel >= jw.top + ROWS)
        jw.top = jw.sel - ROWS + 1;
    if (jw.top < 0)
        jw.top = 0;
}

static void rf_job_done(int64_t now)
{
    int kind = job.kind;
    bool ok = job.reaped && job.status >= 0 && WIFEXITED(job.status) &&
              WEXITSTATUS(job.status) == 0;

    job.kind = RFJ_NONE;
    rf_refresh();                  /* the glyph must not wait for the tick */

    if (kind == RFJ_SCAN && ui.screen == SCR_JW1) {
        jw.scanning = false;
        jw.scan_failed = !ok;
        if (ok)
            jw_take_scan();
    } else if (kind == RFJ_DOWN) {
        if (ok) {
            ui.rf_kill_pending = false;
            ui.rf_kill_tries = 0;
        }
        /* Not ok: the debt stands and rf_kill_drain() tries again, bounded
         * by RF_KILL_TRIES. The glyph is reading rfkill either way, so a
         * card that really cannot go dark says so on screen. */
    } else if (kind == RFJ_CONNECT) {
        /* Success or failure, the screen returns to PAGE 1 (or 0) and the
         * RF glyph is the whole answer — no text hint, by design. */
        ui.screen = SCR_PAGE;
        ui.page_idx = 0;
        ui.blanked = false;
        ui.last_key_ms = now;
        jw_clear();
    }
    memset(job.out, 0, sizeof job.out);
    job.len = 0;
}

static void rf_job_tick(int64_t now)
{
    if (job.kind == RFJ_NONE)
        return;
    if (!job.reaped) {
        int st;
        pid_t r = waitpid(job.pid, &st, WNOHANG);
        if (r == job.pid) {
            job.reaped = true;
            job.status = st;
        } else if (r < 0) {
            job.reaped = true;     /* already gone; treat as failed */
            job.status = -1;
        }
    }
    if (now >= job.deadline_ms) {
        if (!job.reaped) {
            kill(-job.pid, SIGKILL);   /* the group, not just the shell */
            kill(job.pid, SIGKILL);
            return;                /* reaped on a later tick */
        }
        if (job.fd >= 0) {         /* a grandchild is holding the pipe */
            close(job.fd);
            job.fd = -1;
        }
    }
    if (!job.reaped || job.fd >= 0)
        return;
    rf_job_done(now);
}

/* Run the `down` a JW exit owed us, once the job slot is free. Unconditional
 * on rf_state: it is the fail-safe direction, and a stale "already killed"
 * reading must never be what leaves a radio up. */
static void rf_kill_drain(int64_t now)
{
    if (!ui.rf_kill_pending || job.kind != RFJ_NONE)
        return;
    if (ui.rf_kill_tries >= RF_KILL_TRIES) {
        ui.rf_kill_pending = false;   /* out of tries; the glyph tells the
                                         truth and button A still works */
        return;
    }
    if (rf_spawn(RFJ_DOWN, "down", NULL, now, RFDOWN_TO_MS))
        ui.rf_kill_tries++;
}

/* 5 s button-A hold on a page: RF-KILLED -> radios on + JW-1, else kill. */
static void rf_toggle(int64_t now)
{
    if (job.kind != RFJ_NONE)
        return;
    if (rf_state != RF_KILLED) {
        rf_kill_request();         /* same retried path as a JW exit */
        return;
    }
    ui.rf_kill_pending = false;    /* arming supersedes an owed kill */
    ui.rf_kill_tries = 0;
    jw_clear();
    ui.screen = SCR_JW1;
    ui.blanked = false;
    ui.last_key_ms = now;
    jw.scanning = true;
    /* rf-ctl scan unblocks the radios itself, so the card reaches
     * RF-ENABLED even when the scan comes back empty. */
    if (!rf_spawn(RFJ_SCAN, "scan", NULL, now, SCAN_TO_MS)) {
        jw.scanning = false;
        jw.scan_failed = true;
    }
}

static void jw_connect(int64_t now)
{
    char in[SSID_MAX + PSK_MAX + 4];
    snprintf(in, sizeof in, "%s\n%s\n", jw.ssid[jw.sel], jw.psk);
    ui.screen = SCR_CONN;
    ui.blanked = false;
    ui.last_key_ms = now;
    if (!rf_spawn(RFJ_CONNECT, "connect", in, now, CONNECT_TO_MS)) {
        ui.screen = SCR_PAGE;
        ui.page_idx = 0;
        jw_clear();
    }
    memset(in, 0, sizeof in);
}

/* JW-2 keyboard: line 2 A-P, line 3 Q-Z then 1-6, line 4 7-9 0 then nine
 * symbols, then SPACE / CAPS / DELETE in the last three cells. */
static const char kb_sym[] = "-_.!@#$%&";

static char kb_char(int r, int c)
{
    if (r == 0)
        return (char)((jw.caps ? 'A' : 'a') + c);
    if (r == 1)
        return c < 10 ? (char)((jw.caps ? 'Q' : 'q') + c)
                      : (char)('1' + (c - 10));
    if (c < 3)
        return (char)('7' + c);
    if (c == 3)
        return '0';
    if (c < 13)
        return kb_sym[c - 4];
    return 0;                      /* the three glyph keys */
}

static char kb_cell(int r, int c)
{
    if (r == 2) {
        if (c == COLS - 1)
            return G_DEL;
        if (c == COLS - 2)
            return jw.caps ? G_CAPS_ON : G_CAPS_OFF;
        if (c == COLS - 3)
            return G_SPACE;
    }
    return kb_char(r, c);
}

/* Button A released before the 2 s mark: type the key at the POSITION.
 * Anything that touches the input area leaves STAGING; CAPS does not, it
 * changes no character. */
static void jw_type(void)
{
    int r = jw.kr, c = jw.kc;
    if (r == 2 && c == COLS - 2) {
        jw.caps = !jw.caps;
        return;
    }
    jw.staged = false;
    if (r == 2 && c == COLS - 1) {
        if (jw.plen > 0)
            jw.psk[--jw.plen] = '\0';
        return;
    }
    char ch = (r == 2 && c == COLS - 3) ? ' ' : kb_char(r, c);
    if (!ch)
        return;
    if (jw.plen < PSK_MAX) {
        jw.psk[jw.plen++] = ch;
        jw.psk[jw.plen] = '\0';
    }
}

static void jw_key(int key, bool press, int64_t now)
{
    ui.last_key_ms = now;          /* both edges keep the 10 s idle timer up */

    /* Button B exits from either screen, short or long — its EVENT
     * function is absorbed for as long as a JW screen is up. */
    if (key == KEY_B) {
        if (press)
            jw_exit(now, true);
        return;
    }
    if (key == KEY_A) {
        if (press) {
            ui.a_down_ms = now;
            ui.a_fired = false;
        } else {
            bool fired = ui.a_fired;
            ui.a_down_ms = 0;
            ui.a_fired = false;
            if (!fired && ui.screen == SCR_JW2)
                jw_type();
        }
        return;
    }
    if (!press)
        return;

    if (ui.screen == SCR_JW1) {
        /* While the scan runs there is no list to navigate and nothing to
         * back out to, so the whole joystick is inert — LEFT included.
         * Offering an exit here would be a lie: the screen says SCANNING
         * and the scan is what the card is actually doing. Button B is
         * still the way out (and the idle timeout, and a fault), which is
         * why the cancel path in jw_exit() still has to work. */
        if (jw.scanning)
            return;
        /* The list wraps at both ends, like the keyboard: UP from the top
         * lands on the last SSID, DOWN from the last on the first. */
        if (key == KEY_UP && jw.n > 0)
            jw.sel = (jw.sel + jw.n - 1) % jw.n;
        else if (key == KEY_DOWN && jw.n > 0)
            jw.sel = (jw.sel + 1) % jw.n;
        else if (key == KEY_LEFT)
            jw_exit(now, true);
        else if (key == KEY_RIGHT && jw.n > 0 && !jw.scanning) {
            ui.screen = SCR_JW2;
            ui.a_down_ms = 0;      /* a hold begun on JW-1 must not land on
                                      JW-2 as an instant STAGING */
            ui.a_fired = false;
        }
        jw_viewport();
        return;
    }
    /* SCR_JW2 — LEFT is a keyboard move here, not an exit; the keyboard
     * wraps on both axes so no direction is ever a dead end. */
    if (key == KEY_UP)
        jw.kr = (jw.kr + 2) % 3;
    else if (key == KEY_DOWN)
        jw.kr = (jw.kr + 1) % 3;
    else if (key == KEY_LEFT)
        jw.kc = (jw.kc + COLS - 1) % COLS;
    else if (key == KEY_RIGHT)
        jw.kc = (jw.kc + 1) % COLS;
}

/* ---------------------------------------------------------- PAGE SCRIPTS - */

/* A debug affordance, and deliberately a hostile one. --risky-scripts DIR
 * deposits every executable in DIR onto the card at install time; a 5 s
 * CENTER hold lists them and CENTER runs one AS ROOT. It exists so bench
 * debugging stops meaning "scp the script again", and the whole design is
 * shaped by that being worth a real cost:
 *
 *   - Entry STOPS BOTH RECORDERS. That is what makes it destructive rather
 *     than merely modal, and it is what most debug scripts want anyway —
 *     anything that opens a camera needs the recorders off it first. It also means
 *     health goes ERR within STALE_SECS by construction, which is why the
 *     PAGE 0 transition has to be suppressed while this screen is up — see
 *     the health block in main().
 *   - There is NO EXIT. Not a key, not a timeout, not a fault. The page
 *     does not AUTO-BLANK and does not fault to PAGE 0. A reboot is the
 *     only way out, and SCRIPT_MARK on tmpfs is what makes a panel restart
 *     land back here instead of quietly reopening the door.
 *   - The child is a SESSION leader (setsid), not merely its own process
 *     group like the rf-ctl children. panel.service is PartOf=dashberry.target,
 *     so a script that stops that target would otherwise take the panel down
 *     and itself with it. Detached, the script outlives its own blast radius
 *     and keeps writing to its log.
 *
 * Output goes to /data/scripts/<name>.log, appended with a timestamped
 * header so repeated runs accumulate. If /data cannot take it — read-only,
 * full, or simply the thing being debugged — the child inherits the panel's
 * own stdout/stderr and lands in the journal instead. Running with the
 * output somewhere is strictly better than refusing to run. */

enum { SCRST_STOPPING, SCRST_LIST, SCRST_RUNNING, SCRST_DONE };

static struct {
    char    name[MAX_SCRIPTS][SCRIPT_NAME + 1];
    int     n;
    int     sel;                   /* cursor (index into name[]) */
    int     top;                   /* first visible row */
    int     state;
    pid_t   pid;                   /* the stop job, then the script */
    bool    reaped;
    int     status;
    int64_t started_ms;            /* RUNNING since — the elapsed counter */
    int64_t deadline_ms;           /* STOPPING watchdog only */
} scr;

static int script_cmp(const void *a, const void *b)
{
    return strcmp((const char *)a, (const char *)b);
}

/* Regular, executable, not dotted. Anything else was already rejected on
 * the PC side by dashberry-install, which is the last place a human was
 * present to read why. */
static int script_scan(void)
{
    scr.n = 0;
    DIR *d = opendir(SCRIPT_DIR);
    if (!d)
        return 0;
    const struct dirent *e;
    while ((e = readdir(d)) != NULL && scr.n < MAX_SCRIPTS) {
        if (e->d_name[0] == '.')
            continue;
        char p[PATH_MAX];
        if (snprintf(p, sizeof p, "%s/%s", SCRIPT_DIR, e->d_name) >=
            (int)sizeof p)
            continue;
        struct stat st;
        if (stat(p, &st) != 0 || !S_ISREG(st.st_mode))
            continue;
        if (access(p, X_OK) != 0)
            continue;
        size_t l = strlen(e->d_name);
        if (l > SCRIPT_NAME)
            continue;              /* unstorable, so unrunnable: the
                                      installer rejects these already */
        memcpy(scr.name[scr.n], e->d_name, l + 1);
        scr.n++;
    }
    closedir(d);
    qsort(scr.name, (size_t)scr.n, sizeof scr.name[0], script_cmp);
    scr.sel = 0;
    scr.top = 0;
    return scr.n;
}

static void script_viewport(void)
{
    if (scr.sel < scr.top)
        scr.top = scr.sel;
    if (scr.sel >= scr.top + SCRIPT_ROWS)
        scr.top = scr.sel - SCRIPT_ROWS + 1;
    if (scr.top < 0)
        scr.top = 0;
}

/* stdin on /dev/null; stdout+stderr on outfd, or INHERITED (the journal)
 * when outfd < 0. Everything else the panel holds is O_CLOEXEC, so exec
 * closes it; dup2 clears CLOEXEC on the copies, so outfd survives on
 * purpose. */
static pid_t script_fork(const char *path, char *const argv[], int outfd,
                         bool detach)
{
    pid_t pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0) {
        if (detach)
            setsid();
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) {
            dup2(devnull, 0);
            close(devnull);
        }
        if (outfd >= 0) {
            dup2(outfd, 1);
            dup2(outfd, 2);
            close(outfd);
        }
        execv(path, argv);
        _exit(127);
    }
    return pid;
}

static int script_log_open(const char *name)
{
    mkdir(SCRIPT_LOG, 0755);       /* EEXIST is the normal case */
    char p[PATH_MAX];
    if (snprintf(p, sizeof p, "%s/%s.log", SCRIPT_LOG, name) >= (int)sizeof p)
        return -1;
    int fd = open(p, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return -1;
    char hdr[128];
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    int k = snprintf(hdr, sizeof hdr,
                     "\n=== %s %04d-%02d-%02d %02d:%02d:%02d"
                     " (DashBerry " DASHBERRY_VERSION ") ===\n", name,
                     tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                     tm.tm_hour, tm.tm_min, tm.tm_sec);
    if (k > 0) {
        ssize_t w = write(fd, hdr, (size_t)k);
        (void)w;                   /* best effort: a header we could not
                                      write must not cost us the run */
    }
    return fd;
}

static void script_mark(void)
{
    mkdir(RUN_DIR, 0755);          /* session-init normally made it already */
    int fd = open(SCRIPT_MARK, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0)
        close(fd);
}

/* The door. Enumerates FIRST: with no scripts to run there is nothing to
 * trade the recorders for, so the hold does nothing at all rather than
 * stranding the user on an empty inescapable page. */
static void script_enter(int64_t now)
{
    if (!risky_scripts || script_scan() == 0)
        return;

    script_mark();
    ui.screen = SCR_SCRIPT;
    ui.blanked = false;
    ui.last_key_ms = now;
    ui.flash_until_ms = 0;         /* an EVENT flash must not overlay this */

    scr.reaped = false;
    scr.status = -1;
    scr.state = SCRST_STOPPING;
    scr.deadline_ms = now + SCRIPT_STOP_MS;

    char *const argv[] = { "systemctl", "stop", "front-rec", "rear-rec",
                           NULL };
    scr.pid = script_fork(SYSTEMCTL, argv, -1, false);
    if (scr.pid < 0)
        scr.state = SCRST_LIST;    /* could not even try; the list still works
                                      and a script can stop them itself */
}

static void script_run(int64_t now)
{
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/%s", SCRIPT_DIR, scr.name[scr.sel]) >=
        (int)sizeof path)
        return;

    int logfd = script_log_open(scr.name[scr.sel]);

    char *const argv[] = { scr.name[scr.sel], NULL };
    scr.pid = script_fork(path, argv, logfd, true);
    if (logfd >= 0)
        close(logfd);

    scr.reaped = scr.pid < 0;
    scr.status = -1;
    scr.started_ms = now;
    scr.state = scr.pid < 0 ? SCRST_DONE : SCRST_RUNNING;
}

/* LIST navigates; every other state absorbs every key. DONE absorbs CENTER
 * too — one script per session, then a reboot, which is the whole contract
 * of the page. */
static void script_key(int key, bool press, int64_t now)
{
    if (!press || scr.state != SCRST_LIST || scr.n <= 0)
        return;
    if (key == KEY_UP || key == KEY_DOWN) {
        scr.sel = (scr.sel + (key == KEY_UP ? -1 : 1) + scr.n) % scr.n;
        script_viewport();
    } else if (key == KEY_CENTER) {
        script_run(now);
    }
}

static void script_tick(int64_t now)
{
    if (ui.screen != SCR_SCRIPT)
        return;
    if (scr.state != SCRST_STOPPING && scr.state != SCRST_RUNNING)
        return;

    if (scr.pid > 0 && !scr.reaped) {
        int st;
        pid_t r = waitpid(scr.pid, &st, WNOHANG);
        if (r == scr.pid) {
            scr.reaped = true;
            scr.status = st;
        } else if (r < 0) {
            scr.reaped = true;     /* already gone; rc unknown */
            scr.status = -1;
        }
    }

    if (scr.state == SCRST_STOPPING) {
        if (scr.reaped || now >= scr.deadline_ms)
            scr.state = SCRST_LIST;
        return;
    }
    /* RUNNING has no deadline on purpose: a script that never returns is
     * the user's to reboot out of, and killing it at some arbitrary mark
     * would throw away the run they came here for. */
    if (scr.reaped)
        scr.state = SCRST_DONE;
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

    /* CONNECTING owns the screen until rf-ctl answers: button A is
     * absorbed (a stray hold must not restage or kill the radios
     * mid-association), button B is NOT — the EVENT marker stays
     * available, since an incident does not wait for a Wi-Fi join. */
    if (ui.screen == SCR_CONN) {
        if (key != KEY_B)
            return;
    } else if (ui.screen == SCR_JW1 || ui.screen == SCR_JW2) {
        jw_key(key, press, now);
        return;
    } else if (ui.screen == SCR_SCRIPT) {
        /* Ahead of the button-B block below on purpose: PAGE SCRIPTS
         * absorbs A and B outright. EVENT capture is an incident marker
         * for a recording card, and this card has stopped recording. */
        script_key(key, press, now);
        return;
    }

    /* Button B: EVENT capture (~2 s hold, fired from the tick) — the one
     * key that acts on any NON-BLANKED screen, PAGE 0 included (an
     * exception to "PAGE 0 ignores all input": an incident that faults
     * the system is exactly when marking the moment matters; the JOIN
     * WIFI hold below is the other).
     * From blank it is still a pure wake key: the waking press is
     * absorbed, the hold must restart after the wake. */
    if (key == KEY_B) {
        if (press && ui.blanked && !ui.error) {
            wake(now);
            return;
        }
        if (press) {
            ui.b_down_ms = now;
            ui.b_fired = false;
        } else {
            ui.b_down_ms = 0;
        }
        if (!ui.error)
            ui.last_key_ms = now;
        return;
    }

    if (ui.error) {
        /* PAGE 0 is static: input ignored — except two holds. A production
         * card built with --auth has sshd waiting behind a join, and a
         * fault is exactly when getting in matters, so button A stays live;
         * the CENTER hold is live for the same reason on a --risky-scripts
         * card, since a faulted card is exactly when you want the debug
         * script. Any other key (or either release) still cancels a hold
         * in flight. */
        if (rf_join && key == KEY_A && press) {
            ui.a_down_ms = now;
            ui.a_fired = false;
        } else {
            ui.a_down_ms = 0;
        }
        if (risky_scripts && key == KEY_CENTER && press) {
            ui.c_down_ms = now;
            ui.c_fired = false;
        } else {
            ui.c_down_ms = 0;
        }
        return;
    }
    if (!press) {
        if (key == KEY_A)
            ui.a_down_ms = 0;
        if (key == KEY_CENTER)
            ui.c_down_ms = 0;
        ui.last_key_ms = now;
        return;
    }
    if (ui.blanked) {
        wake(now);                 /* absorbed: wake only, no paging —
                                      an A hold must restart after the wake */
        return;
    }
    ui.last_key_ms = now;
    struct setting *set = page_setting(pages[ui.page_idx]);
    if (key == KEY_LEFT)
        ui.page_idx = (ui.page_idx + NPAGES - 1) % NPAGES;
    else if (key == KEY_RIGHT)
        ui.page_idx = (ui.page_idx + 1) % NPAGES;
    else if (key == KEY_A) {
        ui.a_down_ms = now;        /* 5 s hold = JOIN WIFI, fired from the
                                      tick; short presses stay reserved */
        ui.a_fired = false;
    } else if (key == KEY_CENTER) {
        ui.c_down_ms = now;        /* 5 s hold = PAGE SCRIPTS, fired from the
                                      tick; short presses stay reserved */
        ui.c_fired = false;
    } else if (set && (key == KEY_UP || key == KEY_DOWN)) {
        setting_move(set, key == KEY_UP ? -1 : 1);
    }
    /* UP, DOWN (off a settings page): reserved — wake/reset-timer only */
}

/* ------------------------------------------------------------ rendering - */

struct frame {
    bool     blanked;
    int      yoff;
    char     glyph;                /* 'S' shield, 'R' bare antenna, 'W' waves;
                                      0 = the JW screens own all 16 columns */
    uint16_t inv[ROWS];            /* INVERTED cells, bit N = column N */
    char     rows[ROWS][COLS + 1];
};

/* JW-1: four SSIDs, the selected one an INVERTED bar. Names wider than 14
 * columns are cut there and marked with a single LDOTS in column 14. */
static void compose_jw1(struct frame *f)
{
    /* Every full-screen status message in the UI sits on line 2 indented
     * one column — EVENT, CONNECTING and these three read as one family. */
    if (jw.scanning) {
        snprintf(f->rows[1], sizeof f->rows[1], " SCANNING...");
        return;
    }
    if (jw.scan_failed) {
        snprintf(f->rows[1], sizeof f->rows[1], " RF ERROR");
        return;
    }
    if (jw.n == 0) {
        snprintf(f->rows[1], sizeof f->rows[1], " NO NETWORKS");
        return;
    }
    for (int r = 0; r < ROWS; r++) {
        int i = jw.top + r;
        if (i >= jw.n)
            break;
        size_t l = strlen(jw.ssid[i]);
        if (l > SSID_COLS) {
            memcpy(f->rows[r], jw.ssid[i], SSID_COLS);
            f->rows[r][SSID_COLS] = G_LDOTS;
            f->rows[r][SSID_COLS + 1] = '\0';
        } else {
            memcpy(f->rows[r], jw.ssid[i], l + 1);
        }
        if (i == jw.sel)
            f->inv[r] = 0xFFFF;
    }
}

/* JW-2: line 1 the input area, lines 2-4 the keyboard. The POSITION cell
 * is INVERTED; so is the whole input area while STAGING. */
static void compose_jw2(struct frame *f)
{
    if (jw.plen <= COLS) {
        memcpy(f->rows[0], jw.psk, (size_t)jw.plen + 1);
    } else {
        f->rows[0][0] = G_LDOTS;   /* one mark for everything scrolled off */
        memcpy(f->rows[0] + 1, jw.psk + jw.plen - (COLS - 1), COLS - 1);
        f->rows[0][COLS] = '\0';
    }
    if (jw.staged)
        f->inv[0] = 0xFFFF;

    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < COLS; c++)
            f->rows[r + 1][c] = kb_cell(r, c);
        f->rows[r + 1][COLS] = '\0';
    }
    f->inv[1 + jw.kr] |= (uint16_t)(1u << jw.kc);
}

/* Names wider than the field are cut and marked with a single LDOTS,
 * exactly as JW-1 does with a long SSID. */
static void script_label(char *dst, size_t len, const char *name)
{
    size_t l = strlen(name);
    if (l > SCRIPT_COLS && len > SCRIPT_COLS + 1) {
        memcpy(dst, name, SCRIPT_COLS);
        dst[SCRIPT_COLS] = G_LDOTS;
        dst[SCRIPT_COLS + 1] = '\0';
    } else {
        snprintf(dst, len, "%s", name);
    }
}

/* PAGE SCRIPTS. STOPPING borrows the full-screen shape EVENT and CONNECTING
 * use; LIST borrows JW-1's INVERTED bar; RUNNING and DONE share a two-row
 * word-over-number shape. */
static void compose_script(struct frame *f, int64_t now)
{
    if (scr.state == SCRST_STOPPING) {
        snprintf(f->rows[1], sizeof f->rows[1], " STOPPING REC");
        return;
    }
    if (scr.state == SCRST_LIST) {
        /* No title row. This is JW-1's shape exactly — four names, the
         * selected one under a full-width INVERTED bar — and it is the right
         * one for the same reason: a constant word spends a quarter of a
         * four-line display restating what the bar and the filenames already
         * say, and the row it costs is a whole entry. */
        for (int r = 0; r < SCRIPT_ROWS; r++) {
            int i = scr.top + r;
            if (i >= scr.n)
                break;
            script_label(f->rows[r], sizeof f->rows[r], scr.name[i]);
            if (i == scr.sel)
                f->inv[r] = 0xFFFF;
        }
        return;
    }
    /* RUNNING and DONE are the same two-row shape — a word on row 1, its
     * one number on row 2 — so the screen does not reflow when the child
     * exits; only the two lines' contents change. Rows 0 and 3 stay empty,
     * which is what centres the pair on a four-line display.
     *
     * Both rows carry the same ONE leading space STOPPING REC and JW-1's
     * SCANNING.../RF ERROR/NO NETWORKS carry: it is this panel's inset for a
     * full-screen message, as opposed to the flush-left data pages. The space
     * goes on the number row too, not just the word — the two rows are one
     * block, and insetting only the top of it reads as a misalignment. */
    if (scr.state == SCRST_RUNNING) {
        /* The elapsed counter is the liveness report: a script with nothing
         * to say still visibly has not finished. Clamped so the row cannot
         * grow past the display no matter how long it runs. */
        int secs = (int)((now - scr.started_ms) / 1000);
        if (secs < 0)
            secs = 0;
        if (secs > 9999)
            secs = 9999;
        snprintf(f->rows[1], sizeof f->rows[1], " RUNNING");
        snprintf(f->rows[2], sizeof f->rows[2], " %ds", secs);
        return;
    }

    snprintf(f->rows[1], sizeof f->rows[1], " DONE");
    /* A signal is not an exit status, so it keeps its own spelling rather
     * than being folded into 128+n — on a card you reboot to leave, the
     * difference between "the script returned 9" and "something killed it"
     * is the whole reason you are reading this row. */
    if (!scr.reaped || scr.status < 0)
        snprintf(f->rows[2], sizeof f->rows[2], " EXIT ?");
    else if (WIFEXITED(scr.status))
        snprintf(f->rows[2], sizeof f->rows[2], " EXIT %d",
                 WEXITSTATUS(scr.status));
    else if (WIFSIGNALED(scr.status))
        snprintf(f->rows[2], sizeof f->rows[2], " EXIT SIG%d",
                 WTERMSIG(scr.status));
    else
        snprintf(f->rows[2], sizeof f->rows[2], " EXIT ?");
}

static void compose(struct frame *f, int64_t now)
{
    memset(f, 0, sizeof *f);       /* deterministic padding for memcmp */

    if (ui.blanked && !ui.error && ui.screen == SCR_PAGE) {
        f->blanked = true;         /* blank hides everything, glyph included */
        return;
    }
    f->glyph = rf_state == RF_KILLED ? 'S' : rf_state == RF_LINK ? 'W' : 'R';

    if (ui.screen == SCR_SCRIPT) {
        /* Ahead of the EVENT flash and PAGE 0 both: the one-way door owns
         * the screen absolutely, or "cannot be exited" is not true. */
        compose_script(f, now);
        return;
    }

    if (now < ui.flash_until_ms) {
        /* EVENT confirmation — a deliberate 2 s full-screen interruption
         * of whatever page is up (PAGE 0 returns right after) */
        snprintf(f->rows[1], sizeof f->rows[1], " %.14s", ui.flash);
        return;
    }

    if (ui.screen == SCR_CONN) {
        /* Same full-screen shape as EVENT, but it lasts as long as the
         * association attempt does — and it outranks PAGE 0 for that
         * bounded window; the fault is still there when it returns. */
        snprintf(f->rows[1], sizeof f->rows[1], " CONNECTING...");
        return;
    }
    if (ui.screen == SCR_JW1 || ui.screen == SCR_JW2) {
        f->glyph = 0;              /* JW-2's DELETE key needs column 15 */
        if (ui.screen == SCR_JW1)
            compose_jw1(f);
        else
            compose_jw2(f);
        return;
    }

    /* Burn-in shift: PAGE 0 is static for as long as the fault lasts, and
     * with Always On so is every page — same static-picture risk, same
     * ±1 px mitigation. The pages that AUTO-BLANK still take none. */
    if (ui.error || (setting_is(SET_ALWAYS_ON, "On") && ui.screen == SCR_PAGE))
        f->yoff = burn_offsets[ui.burn_idx];

    if (ui.error) {
        /* PAGE 0 — static, only failing groups, empty lines omitted */
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

    /* PAGE 3+ — a settings page: the name on line 1 as written (left), the
     * choices right-aligned under it, the live one under a bar. The bar is
     * OPT_COLS wide, not the full 16, so it stops short of the glyph cell
     * and every choice row is the same width on every line. */
    const struct setting *set = page_setting(pages[ui.page_idx]);
    if (set) {
        snprintf(f->rows[0], sizeof f->rows[0], "%s", set->name);
        int n = setting_nopts(set), top = setting_top(set);
        for (int r = 0; r < OPT_ROWS && top + r < n; r++) {
            const char *o = set->opts[top + r];
            int pad = OPT_COLS - (int)strlen(o);
            snprintf(f->rows[r + 1], sizeof f->rows[r + 1], "%*s%s",
                     pad > 0 ? pad : 0, "", o);
            if (top + r == set->value)
                f->inv[r + 1] = (1u << OPT_COLS) - 1;
        }
        return;
    }

    if (pages[ui.page_idx] == 2) {
        /* PAGE 2 — line 1: Pi 4 SoC temperature, whole degrees C
         * (negative-safe round-to-nearest); line 2: rail under-voltage
         * (now beats latched); line 3: CPU load across all four cores;
         * line 4: the release version. Load sits under TMP deliberately —
         * heat is the consequence, load is the cause, and reading them
         * together is what tells a thermal soak from a merely busy
         * encoder. */
        if (cpu_temp_valid) {
            snprintf(f->rows[0], sizeof f->rows[0], "TMP %d C", cpu_temp_c());
        } else {
            snprintf(f->rows[0], sizeof f->rows[0], "TMP ---");
        }
        if (!uv_valid)
            snprintf(f->rows[1], sizeof f->rows[1], "PWR ---");
        else if (uv_now)
            snprintf(f->rows[1], sizeof f->rows[1], "PWR UV NOW");
        else if (uv_seen)
            snprintf(f->rows[1], sizeof f->rows[1], "PWR UV SEEN");
        else
            snprintf(f->rows[1], sizeof f->rows[1], "PWR OK");
        if (cpu_load_valid)
            snprintf(f->rows[2], sizeof f->rows[2], "CPU %d%%", cpu_load_pct);
        else
            snprintf(f->rows[2], sizeof f->rows[2], "CPU ---");
        snprintf(f->rows[3], sizeof f->rows[3], "VER %s", DASHBERRY_VERSION);
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
            /* Best effort: ssd1307fb may not implement fb_blank;
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
        /* row 3, col 15 is the reserved RF glyph cell — except on the JW
         * screens, which clear the glyph and take the full 16 columns */
        int maxc = (r == ROWS - 1 && f->glyph) ? COLS - 1 : COLS;
        int len = (int)strlen(f->rows[r]);
        for (int c = 0; c < maxc; c++) {
            bool inv = (f->inv[r] >> c) & 1;
            if (c >= len && !inv)
                continue;          /* already dark from the memset */
            draw_char(c, r, c < len ? f->rows[r][c] : ' ', f->yoff, inv);
        }
    }
    if (f->glyph)
        draw_glyph16(COLS - 1, ROWS - 1,
                     f->glyph == 'S' ? glyph_shield :
                     f->glyph == 'R' ? glyph_rf_idle : glyph_wireless,
                     f->yoff, false);
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
    /* rf-ctl can die with its stdin pipe unread; a SIGPIPE there must not
     * take the panel down with it. */
    signal(SIGPIPE, SIG_IGN);

    load_conf();                   /* the card's installed defaults; the
                                      user's PAGE 3+ choices land on top of
                                      them from the first eval_health, once
                                      /data has answered */
    settings_apply();
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

    /* Restart-in-PAGE-SCRIPTS. Restart=always means a crash or a watchdog
     * trip would otherwise reopen the door this page exists to close, on a
     * card whose recorders are already down. The marker is on tmpfs, so it
     * survives a panel restart and not a reboot — which is exactly the
     * distinction the page cares about. The stop is re-issued (idempotent);
     * a script that was already running is detached and keeps writing to
     * its log, but we are no longer its parent, so its exit code is gone —
     * the log is the record. */
    if (risky_scripts && access(SCRIPT_MARK, F_OK) == 0)
        script_enter(now);

    sd_notify_msg("READY=1");

    struct frame shown;
    memset(&shown, 0, sizeof shown);
    shown.glyph = '?';             /* force first paint */
    int subtick = 0;

    for (;;) {
        struct pollfd pfd[4];
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
        int i_job = -1;
        if (job.kind != RFJ_NONE && job.fd >= 0) {
            i_job = n;
            pfd[n++] = (struct pollfd){ .fd = job.fd, .events = POLLIN };
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

        /* --- rf-ctl child stdout --- */
        if (i_job >= 0 && pfd[i_job].revents)
            rf_job_read();

        /* --- tick: watchdog, health, blank, burn-in, repaint --- */
        if (pfd[i_tick].revents & POLLIN) {
            uint64_t exp;
            while (read(tick_fd, &exp, sizeof exp) == sizeof exp)
                ;
            sd_notify_msg("WATCHDOG=1");

            if (gps.state == GPS_DOWN && now >= gps.next_try_ms)
                gps_try_connect(now);

            rf_job_tick(now);
            rf_kill_drain(now);
            script_tick(now);

            if (++subtick >= HEALTH_TICKS) {
                subtick = 0;
                eval_health(now);   /* the health LOG keeps its record either
                                       way; only the screen is suppressed */
                /* PAGE SCRIPTS stopped the recorders itself, so health goes
                 * ERR within STALE_SECS by construction. Without this guard
                 * the page would fault to PAGE 0 ten seconds after entry,
                 * every single time. "It will not ERROR" is a requirement
                 * of the design, not a preference. */
                bool err = system_err();
                if (ui.screen == SCR_SCRIPT) {
                    /* neither transition: ui.error is frozen at whatever it
                       was on entry, and compose() never reaches it anyway */
                } else if (err && !ui.error) {
                    ui.error = true;   /* forces screen on + PAGE 0 */
                    ui.blanked = false;
                    /* A fault outranks a half-finished join: JW-1/JW-2 are
                     * dropped (an in-flight CONNECT still gets to finish). */
                    if (ui.screen == SCR_JW1 || ui.screen == SCR_JW2)
                        jw_exit(now, true);
                } else if (!err && ui.error) {
                    ui.error = false;  /* back to PAGES: wake to PAGE 1 */
                    ui.page_idx = 0;
                    ui.blanked = false;
                    ui.last_key_ms = now;
                }
            }

            /* Button A held to its mark. On JW-2 that is 2 s: first hold
             * STAGES the input area (INVERTED), a second one commits.
             * On a page it is 5 s: arm JOIN WIFI, or kill RF again. */
            if (ui.a_down_ms && !ui.a_fired) {
                if (ui.screen == SCR_JW2 &&
                    now - ui.a_down_ms >= STAGE_HOLD_MS) {
                    ui.a_fired = true;
                    if (jw.staged)
                        jw_connect(now);
                    else
                        jw.staged = true;
                } else if (ui.screen == SCR_PAGE && rf_join &&
                           !ui.blanked && now - ui.a_down_ms >= RF_HOLD_MS) {
                    ui.a_fired = true;
                    rf_toggle(now);
                }
            }

            /* Joystick CENTER held to 5 s on any page, PAGE 0 included:
             * open PAGE SCRIPTS. !ui.blanked is what makes the waking press
             * a pure wake — handle_key never records a c_down_ms from blank,
             * so the hold has to restart after the screen comes up, which is
             * the whole accidental-entry guard this gets for free. */
            if (ui.c_down_ms && !ui.c_fired && risky_scripts &&
                ui.screen == SCR_PAGE && !ui.blanked &&
                now - ui.c_down_ms >= SCRIPT_HOLD_MS) {
                ui.c_fired = true;
                script_enter(now);
            }

            /* JW-1/JW-2 time out to the pages rather than blanking. The
             * idle path leaves last_key_ms alone, so the page it returns
             * to blanks on this same tick — nobody is watching. */
            if ((ui.screen == SCR_JW1 || ui.screen == SCR_JW2) &&
                now - ui.last_key_ms >= JW_IDLE_MS)
                jw_exit(now, false);

            /* AUTO-BLANK, unless PAGE 4's "Always On" is set — that setting
             * exists precisely to keep the panel readable at a glance while
             * driving, so it outranks the 10 s timer (the burn-in shift in
             * compose() takes over as the mitigation). */
            if (ui.screen == SCR_PAGE && !ui.error && !ui.blanked &&
                !setting_is(SET_ALWAYS_ON, "On") &&
                now - ui.last_key_ms >= BLANK_MS)
                ui.blanked = true;

            /* Button B held to the 2 s mark: record the event, once per
             * hold. The marker line is the payload; the flash is feedback
             * (EVENT ERROR = the /data log is unwritable, marker lost). */
            if (ui.b_down_ms && !ui.b_fired &&
                now - ui.b_down_ms >= EVENT_HOLD_MS) {
                ui.b_fired = true;
                snprintf(ui.flash, sizeof ui.flash,
                         hlog_line("event") ? "EVENT" : "EVENT ERROR");
                ui.flash_until_ms = now + EVENT_FLASH_MS;
            }

            if (now - ui.burn_last_ms >= BURN_STEP_MS) {
                ui.burn_last_ms = now;
                ui.burn_idx = (ui.burn_idx + 1) & 3;
            }

            /* repaint on change only, at most once per tick (5 Hz cap) */
            struct frame f;
            compose(&f, now);
            if (memcmp(&f, &shown, sizeof f) != 0) {
                render(&f);
                shown = f;
            }
        }
    }
}
