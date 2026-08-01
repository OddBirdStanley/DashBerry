/* panel.js — JavaScript port of sw/src/dashberry-panel.c (PLAN.md §3b/§3d,
 * rev 8) for the browser demo/visualizer. NOT part of the Pi runtime.
 *
 * Porting rule: everything above the hardware line — the §3b UI state
 * machine (PAGE 0/1/2, AUTO-BLANK, strict wake-key absorption, burn-in
 * shift), the button-B EVENT hold, the §3d JOIN WIFI screens (JW-1, JW-2,
 * CONNECTING) with their holds/staging/inversion, the health model,
 * compose()/render(), the embedded font and every 8x16 glyph — is ported
 * statement-for-statement from the C. Everything below it (fb1 mmap,
 * gpiochip v2, gpsd socket + NMEA parse, statvfs, rfkill/operstate sysfs,
 * forking rf-ctl, sd_notify) is replaced by an injected `hw` object the
 * harness simulates. If this file and the C disagree about behavior, the
 * C is the bug's home or this port is wrong — diff them.
 *
 * hw contract (all required):
 *   now()                    -> monotonic ms (CLOCK_MONOTONIC stand-in)
 *   frontNewestMtimeMs()     -> ms of newest front segment write, 0 = none
 *   rearNewestMtimeMs()      -> ms of newest rear segment write, 0 = none
 *   rtcOk()                  -> bool (rtc0/since_epoch readable)
 *   cpuTempMc()              -> SoC temp in millidegrees C (thermal_zone0),
 *                               null = read failure (PAGE 2 shows TMP ---)
 *   throttled()              -> get_throttled bitmask, null = read failure
 *   statvfs()                -> null (/data not mounted) or
 *                               { rw, freePct, fsErrors }
 *   rfState()                -> 'killed' | 'idle' | 'link' — stands in for
 *                               the rfkill soft/hard + operstate reads
 *   rfCtl(cmd, stdinText)    -> job handle { done, ok, out }, mutated by the
 *                               harness when the simulated child exits;
 *                               stands in for fork+exec of rf-ctl
 *   logEvent()               -> bool: append an `event` record (health log);
 *                               false = unwritable, panel flashes EVENT ERROR
 *   present(view)               render sink: { blanked, fb (Uint8Array) }
 *   notify(msg)                 sd_notify stand-in ("READY=1"/"WATCHDOG=1")
 *   log(msg)                    stderr stand-in
 */

"use strict";

const PANEL = (() => {

/* --------------------------------------------------------------- timing - */

const TICK_MS       = 200;      /* repaint/watchdog tick: 5 Hz cap (§3b) */
const HEALTH_TICKS  = 5;        /* health re-eval every 1 s */
const BLANK_MS      = 10000;    /* AUTO-BLANK after 10 s without keys */
const STALE_MS      = 10000;    /* segment considered stalled after this */
const GPS_SILENT_MS = 5000;     /* NMEA silence -> GPS ERR */
const BURN_STEP_MS  = 60000;    /* PAGE 0 pixel-shift cadence */
const EVENT_HOLD_MS = 2000;     /* button B hold to mark an EVENT */
const EVENT_FLASH_MS= 2000;     /* EVENT confirmation screen duration */
const RF_HOLD_MS    = 5000;     /* button A hold: arm / kill RF (JOIN WIFI) */
const STAGE_HOLD_MS = 2000;     /* button A hold on JW-2: stage / connect */
const JW_IDLE_MS    = 10000;    /* JW-1/JW-2 exit after this without input */
const SCAN_TO_MS    = 25000;    /* rf-ctl scan watchdog */
const RFDOWN_TO_MS  = 15000;    /* rf-ctl down watchdog */
const CONNECT_TO_MS = 30000;    /* rf-ctl connect watchdog: the hard cap on
                                   how long CONNECTING can hold the screen */
const RF_KILL_TRIES = 3;        /* attempts to get the radios back down */

/* -------------------------------------------------------------- display - */

const XRES = 128, YRES = 64;
const COLS = 16, ROWS = 4, CELL_W = 8, CELL_H = 16;

/* Private cell codes — see the C. Characters below 0x20 never appear in
 * real text, so they address the hand-drawn 8x16 glyphs from f.rows[]. */
const G_LDOTS    = "\u0001";
const G_SPACE    = "\u0002";
const G_CAPS_OFF = "\u0003";
const G_CAPS_ON  = "\u0004";
const G_DEL      = "\u0005";

/* JOIN WIFI sizing */
const SSID_COLS = COLS - 2;     /* SSID field on JW-1; LDOTS follows */
const SSID_MAX  = 32;
const PSK_MAX   = 63;
const MAX_SSIDS = 48;

/* ----------------------------------------------------------------- font - */

/* Extracted verbatim from dashberry-panel.c (dhepper/font8x8 style:
 * one byte per row, bit 0 = leftmost pixel; doubled vertically to 8x16). */
const FONT8X8 = [
  [0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00], // ' '
  [0x18,0x3C,0x3C,0x18,0x18,0x00,0x18,0x00], // !
  [0x36,0x36,0x00,0x00,0x00,0x00,0x00,0x00], // "
  [0x36,0x36,0x7F,0x36,0x7F,0x36,0x36,0x00], // #
  [0x0C,0x3E,0x03,0x1E,0x30,0x1F,0x0C,0x00], // $
  [0x00,0x63,0x33,0x18,0x0C,0x66,0x63,0x00], // %
  [0x1C,0x36,0x1C,0x6E,0x3B,0x33,0x6E,0x00], // &
  [0x06,0x06,0x03,0x00,0x00,0x00,0x00,0x00], // '
  [0x18,0x0C,0x06,0x06,0x06,0x0C,0x18,0x00], // (
  [0x06,0x0C,0x18,0x18,0x18,0x0C,0x06,0x00], // )
  [0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00], // *
  [0x00,0x0C,0x0C,0x3F,0x0C,0x0C,0x00,0x00], // +
  [0x00,0x00,0x00,0x00,0x00,0x0C,0x0C,0x06], // ,
  [0x00,0x00,0x00,0x3F,0x00,0x00,0x00,0x00], // -
  [0x00,0x00,0x00,0x00,0x00,0x0C,0x0C,0x00], // .
  [0x60,0x30,0x18,0x0C,0x06,0x03,0x01,0x00], // /
  [0x3E,0x63,0x73,0x7B,0x6F,0x67,0x3E,0x00], // 0
  [0x0C,0x0E,0x0C,0x0C,0x0C,0x0C,0x3F,0x00], // 1
  [0x1E,0x33,0x30,0x1C,0x06,0x33,0x3F,0x00], // 2
  [0x1E,0x33,0x30,0x1C,0x30,0x33,0x1E,0x00], // 3
  [0x38,0x3C,0x36,0x33,0x7F,0x30,0x78,0x00], // 4
  [0x3F,0x03,0x1F,0x30,0x30,0x33,0x1E,0x00], // 5
  [0x1C,0x06,0x03,0x1F,0x33,0x33,0x1E,0x00], // 6
  [0x3F,0x33,0x30,0x18,0x0C,0x0C,0x0C,0x00], // 7
  [0x1E,0x33,0x33,0x1E,0x33,0x33,0x1E,0x00], // 8
  [0x1E,0x33,0x33,0x3E,0x30,0x18,0x0E,0x00], // 9
  [0x00,0x0C,0x0C,0x00,0x00,0x0C,0x0C,0x00], // :
  [0x00,0x0C,0x0C,0x00,0x00,0x0C,0x0C,0x06], // ;
  [0x18,0x0C,0x06,0x03,0x06,0x0C,0x18,0x00], // <
  [0x00,0x00,0x3F,0x00,0x00,0x3F,0x00,0x00], // =
  [0x06,0x0C,0x18,0x30,0x18,0x0C,0x06,0x00], // >
  [0x1E,0x33,0x30,0x18,0x0C,0x00,0x0C,0x00], // ?
  [0x3E,0x63,0x7B,0x7B,0x7B,0x03,0x1E,0x00], // @
  [0x0C,0x1E,0x33,0x33,0x3F,0x33,0x33,0x00], // A
  [0x3F,0x66,0x66,0x3E,0x66,0x66,0x3F,0x00], // B
  [0x3C,0x66,0x03,0x03,0x03,0x66,0x3C,0x00], // C
  [0x1F,0x36,0x66,0x66,0x66,0x36,0x1F,0x00], // D
  [0x7F,0x46,0x16,0x1E,0x16,0x46,0x7F,0x00], // E
  [0x7F,0x46,0x16,0x1E,0x16,0x06,0x0F,0x00], // F
  [0x3C,0x66,0x03,0x03,0x73,0x66,0x7C,0x00], // G
  [0x33,0x33,0x33,0x3F,0x33,0x33,0x33,0x00], // H
  [0x1E,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E,0x00], // I
  [0x78,0x30,0x30,0x30,0x33,0x33,0x1E,0x00], // J
  [0x67,0x66,0x36,0x1E,0x36,0x66,0x67,0x00], // K
  [0x0F,0x06,0x06,0x06,0x46,0x66,0x7F,0x00], // L
  [0x63,0x77,0x7F,0x7F,0x6B,0x63,0x63,0x00], // M
  [0x63,0x67,0x6F,0x7B,0x73,0x63,0x63,0x00], // N
  [0x1C,0x36,0x63,0x63,0x63,0x36,0x1C,0x00], // O
  [0x3F,0x66,0x66,0x3E,0x06,0x06,0x0F,0x00], // P
  [0x1E,0x33,0x33,0x33,0x3B,0x1E,0x38,0x00], // Q
  [0x3F,0x66,0x66,0x3E,0x36,0x66,0x67,0x00], // R
  [0x1E,0x33,0x07,0x0E,0x38,0x33,0x1E,0x00], // S
  [0x3F,0x2D,0x0C,0x0C,0x0C,0x0C,0x1E,0x00], // T
  [0x33,0x33,0x33,0x33,0x33,0x33,0x3F,0x00], // U
  [0x33,0x33,0x33,0x33,0x33,0x1E,0x0C,0x00], // V
  [0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00], // W
  [0x63,0x63,0x36,0x1C,0x1C,0x36,0x63,0x00], // X
  [0x33,0x33,0x33,0x1E,0x0C,0x0C,0x1E,0x00], // Y
  [0x7F,0x63,0x31,0x18,0x4C,0x66,0x7F,0x00], // Z
  [0x1E,0x06,0x06,0x06,0x06,0x06,0x1E,0x00], // [
  [0x03,0x06,0x0C,0x18,0x30,0x60,0x40,0x00], // \
  [0x1E,0x18,0x18,0x18,0x18,0x18,0x1E,0x00], // ]
  [0x08,0x1C,0x36,0x63,0x00,0x00,0x00,0x00], // ^
  [0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF], // _
  [0x0C,0x0C,0x18,0x00,0x00,0x00,0x00,0x00], // `
  [0x00,0x00,0x1E,0x30,0x3E,0x33,0x6E,0x00], // a
  [0x07,0x06,0x06,0x3E,0x66,0x66,0x3B,0x00], // b
  [0x00,0x00,0x1E,0x33,0x03,0x33,0x1E,0x00], // c
  [0x38,0x30,0x30,0x3E,0x33,0x33,0x6E,0x00], // d
  [0x00,0x00,0x1E,0x33,0x3F,0x03,0x1E,0x00], // e
  [0x1C,0x36,0x06,0x0F,0x06,0x06,0x0F,0x00], // f
  [0x00,0x00,0x6E,0x33,0x33,0x3E,0x30,0x1F], // g
  [0x07,0x06,0x36,0x6E,0x66,0x66,0x67,0x00], // h
  [0x0C,0x00,0x0E,0x0C,0x0C,0x0C,0x1E,0x00], // i
  [0x30,0x00,0x30,0x30,0x30,0x33,0x33,0x1E], // j
  [0x07,0x06,0x66,0x36,0x1E,0x36,0x67,0x00], // k
  [0x0E,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E,0x00], // l
  [0x00,0x00,0x33,0x7F,0x7F,0x6B,0x63,0x00], // m
  [0x00,0x00,0x1F,0x33,0x33,0x33,0x33,0x00], // n
  [0x00,0x00,0x1E,0x33,0x33,0x33,0x1E,0x00], // o
  [0x00,0x00,0x3B,0x66,0x66,0x3E,0x06,0x0F], // p
  [0x00,0x00,0x6E,0x33,0x33,0x3E,0x30,0x78], // q
  [0x00,0x00,0x3B,0x6E,0x66,0x06,0x0F,0x00], // r
  [0x00,0x00,0x3E,0x03,0x1E,0x30,0x1F,0x00], // s
  [0x08,0x0C,0x3E,0x0C,0x0C,0x2C,0x18,0x00], // t
  [0x00,0x00,0x33,0x33,0x33,0x33,0x6E,0x00], // u
  [0x00,0x00,0x33,0x33,0x33,0x1E,0x0C,0x00], // v
  [0x00,0x00,0x63,0x6B,0x7F,0x7F,0x36,0x00], // w
  [0x00,0x00,0x63,0x36,0x1C,0x36,0x63,0x00], // x
  [0x00,0x00,0x33,0x33,0x33,0x3E,0x30,0x1F], // y
  [0x00,0x00,0x3F,0x19,0x0C,0x26,0x3F,0x00], // z
  [0x38,0x0C,0x0C,0x07,0x0C,0x0C,0x38,0x00], // {
  [0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x00], // |
  [0x07,0x0C,0x0C,0x38,0x0C,0x0C,0x07,0x00], // }
  [0x6E,0x3B,0x00,0x00,0x00,0x00,0x00,0x00], // ~
];

/* Hand-drawn 8x16 glyphs (bit 0 = leftmost, NOT doubled). The bottom-right
 * cell reports the LIVE RF STATE (rev 8): shield = RF-KILLED, rf_idle =
 * RF-ENABLED but not associated, wireless = associated — the user drawing
 * in DashBerry/wireless_glyph.txt ('x' = lit). */
const GLYPH_WIRELESS = [0x3C, 0x42, 0x81, 0x81, 0x3C, 0x42, 0x81, 0x81,
                        0x3C, 0x42, 0x81, 0x99, 0x24, 0x00, 0x18, 0x18];
const GLYPH_RF_IDLE = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                       0x3C, 0x42, 0x81, 0x99, 0x24, 0x00, 0x18, 0x18];
const GLYPH_SHIELD  = [0x3E, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F,
                       0x7F, 0x3E, 0x3E, 0x1C, 0x1C, 0x08, 0x00, 0x00];

/* JOIN WIFI cell glyphs. LDOTS: two 2x2 blocks on the text baseline,
 * flush right — one character wide, so a truncated 14-column SSID plus
 * its LDOTS still clears column 15. */
const GLYPH_LDOTS = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                     0x00, 0x00, 0x00, 0x00, 0xD8, 0xD8, 0x00, 0x00];
/* CAPS: a solid triangle, point down = OFF (lower case), point up = ON. */
const GLYPH_CAPS_OFF = [0x00, 0x00, 0x00, 0x00, 0x7F, 0x7F, 0x3E, 0x3E,
                        0x1C, 0x1C, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00];
const GLYPH_CAPS_ON  = [0x00, 0x00, 0x00, 0x00, 0x08, 0x08, 0x1C, 0x1C,
                        0x3E, 0x3E, 0x7F, 0x7F, 0x00, 0x00, 0x00, 0x00];
const GLYPH_SPACE = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                     0x42, 0x42, 0x7E, 0x7E, 0x00, 0x00, 0x00, 0x00];
const GLYPH_DEL   = [0x00, 0x00, 0x00, 0x00, 0x08, 0x0C, 0x0E, 0xFF,
                     0xFF, 0x0E, 0x0C, 0x08, 0x00, 0x00, 0x00, 0x00];

const CELL_GLYPH = {
    [G_LDOTS]: GLYPH_LDOTS,       [G_SPACE]: GLYPH_SPACE,
    [G_CAPS_OFF]: GLYPH_CAPS_OFF, [G_CAPS_ON]: GLYPH_CAPS_ON,
    [G_DEL]: GLYPH_DEL,
};

/* ------------------------------------------------------------- UI state - */

/* Bonnet GPIO offsets, same order as the C enum:
 * UP, DOWN, LEFT, RIGHT, CENTER, A, B */
const KEY = { UP: 0, DOWN: 1, LEFT: 2, RIGHT: 3, CENTER: 4, A: 5, B: 6 };
const KEY_GPIO = [17, 22, 27, 23, 4, 5, 6];

const BURN_OFFSETS = [0, 1, 0, -1];
const PAGES = [1, 2];              /* wake order: index 0 is PAGE 1 */
const NPAGES = PAGES.length;

function create(hw) {

    /* 1 bpp framebuffer stand-in: one byte per pixel, 0/1. The C's
     * byte-packing + FB_MSB_LEFT question is bench-only (putpixel isolates
     * it there); the demo visualizes pixels, not packing. */
    const fb = new Uint8Array(XRES * YRES);

    /* conf (load_conf) */
    let speed_factor = 1.15078;    /* knots -> mph (default) */
    let speed_unit   = "MPH";
    let rf_join      = false;      /* RF_JOIN=1: JOIN WIFI armed. 0 = the 5 s
                                      button-A hold does nothing, as before */

    /* Live RF state, read never assumed (rfkill soft/hard + operstate in
     * the C; hw.rfState() here): 'killed' | 'idle' | 'link'. */
    let rf_state = "killed";
    function rf_refresh() { rf_state = hw.rfState(); }

    /* gpsd client state the UI consumes. The demo has no socket: the
     * harness calls gpsFix()/gpsNoFix() at 5 Hz, which land exactly where
     * nmea_line() left off in the C (post-parse RMC state). */
    const gps = { last_nmea_ms: 0, have_fix: false, lat: 0, lon: 0, knots: 0 };

    const health = { front: false, rear: false, gpsok: false,
                     timeok: false, storage: false };
    let df_pct = 0;                /* free space %, for the PAGE 1 DF line */

    /* SoC temperature for the PAGE 2 TMP line (read_cpu_temp in the C):
     * millidegrees C from sysfs; not a health state, never faults. */
    let cpu_temp_mc = 0;
    let cpu_temp_valid = false;

    function read_cpu_temp() {
        const mc = hw.cpuTempMc();
        cpu_temp_valid = mc !== null;
        if (cpu_temp_valid)
            cpu_temp_mc = mc;
    }

    /* Firmware throttle flags for the PAGE 2 PWR line — bit 0 =
     * under-voltage NOW, bit 16 = under-voltage seen since boot.
     * Informational like TMP, never a health state. */
    let throttled = 0;
    let throttled_valid = false;

    function read_throttled() {
        const t = hw.throttled();
        throttled_valid = t !== null;
        if (throttled_valid)
            throttled = t;
    }

    /* Which screen owns the input. PAGE covers PAGE 0/1/2 (ui.error picks
     * PAGE 0); the three JOIN WIFI screens are their own modes. */
    const SCR = { PAGE: 0, JW1: 1, JW2: 2, CONN: 3 };

    const ui = {
        error: false,              /* any health state ERR */
        screen: SCR.PAGE,
        page_idx: 0,
        blanked: false,
        last_key_ms: 0,
        burn_idx: 0,               /* PAGE 0 shift: 0,+1,0,-1 */
        burn_last_ms: 0,
        b_down_ms: 0,              /* button B pressed since (0 = up) */
        b_fired: false,            /* this hold already marked an event */
        a_down_ms: 0,              /* button A pressed since (0 = up) */
        a_fired: false,            /* this hold already fired its action */
        flash_until_ms: 0,         /* EVENT confirmation visible until */
        flash: "",
        rf_kill_pending: false,    /* the radios are owed an rf-ctl down */
        rf_kill_tries: 0,          /* attempts spent on it so far */
    };

    /* JOIN WIFI screen state. jw.psk is the only secret the panel holds;
     * it is wiped on every exit and never logged or printed. */
    const jw = {
        ssid: [], sel: 0, top: 0,
        scanning: false, scan_failed: false,
        psk: "", kr: 0, kc: 0, caps: false, staged: false,
    };

    let burn_step_ms = BURN_STEP_MS;   /* demo aid: harness may shorten */
    let subtick = 0;
    let shown = null;              /* JSON of last rendered frame (memcmp) */
    let hw_blanked = -1;
    let repaints = 0, watchdog_pets = 0;

    /* --------------------------------------------------------- health -- */

    function eval_health(now) {
        const mf = hw.frontNewestMtimeMs();
        const mr = hw.rearNewestMtimeMs();
        health.front = mf !== 0 && (now - mf) <= STALE_MS;
        health.rear  = mr !== 0 && (now - mr) <= STALE_MS;
        health.gpsok = gps.last_nmea_ms !== 0 &&
                       (now - gps.last_nmea_ms) <= GPS_SILENT_MS;
        health.timeok = hw.rtcOk();
        health.storage = storage_ok();
        read_cpu_temp();           /* 1 Hz, off the 5 Hz paint path */
        read_throttled();
        rf_refresh();              /* glyph truth, not a health state */
    }

    /* Storage OK: /data mounted rw, free > 0, no accumulated fs errors.
     * df_pct updates whenever statvfs succeeds, exactly as in the C
     * (stale when /data is not mounted at all). */
    function storage_ok() {
        const sv = hw.statvfs();
        if (sv === null)
            return false;          /* /data not mounted at all */
        df_pct = sv.freePct;
        if (!sv.rw)
            return false;
        if (sv.freePct <= 0)
            return false;
        if (sv.fsErrors)
            return false;
        return true;
    }

    function system_err() {
        return !(health.front && health.rear && health.gpsok &&
                 health.timeok && health.storage);
    }

    /* ---------------------------------------------------------- input -- */

    function wake(now) {
        ui.blanked = false;
        ui.page_idx = 0;           /* always wake to PAGE 1 (§3b) */
        ui.last_key_ms = now;
    }

    /* ------------------------------------------------------ rf-ctl jobs -- */

    /* Every radio operation is a simulated rf-ctl child polled from the
     * tick: a scan takes seconds and an association tens of seconds, and
     * the panel must keep painting and keep accepting the exit keys
     * throughout. One job at a time, each with a deadline. */
    const RFJ = { NONE: 0, SCAN: 1, DOWN: 2, CONNECT: 3 };
    let job = { kind: RFJ.NONE, h: null, deadline_ms: 0 };

    function rf_spawn(kind, cmd, stdinText, now, timeout_ms) {
        if (job.kind !== RFJ.NONE)
            return false;
        const h = hw.rfCtl(cmd, stdinText);
        if (!h)
            return false;
        job = { kind, h, deadline_ms: now + timeout_ms };
        return true;
    }

    /* --------------------------------------------------------- JOIN WIFI - */

    /* The radios are owed a trip back down. Every caller goes through here
     * so the attempt is retried if rf-ctl fails, rather than fired once and
     * assumed to have worked — this is the privacy-preserving direction, so
     * "probably off" is not good enough. */
    function rf_kill_request() {
        ui.rf_kill_pending = true;
        ui.rf_kill_tries = 0;
    }

    function jw_clear() {
        jw.psk = "";               /* the secret never outlives a screen */
        jw.ssid = [];
        jw.sel = 0;
        jw.top = 0;
        jw.kr = 0;
        jw.kc = 0;                 /* POSITION starts at 'A' */
        jw.caps = false;
        jw.staged = false;
        jw.scanning = false;
        jw.scan_failed = false;
    }

    /* Leaving JW-1/JW-2 without completing a join takes the radios back
     * down with it: arming was a means to an end, and a user who backed
     * out (or walked away, or whose card faulted mid-flow) never asked for
     * a card that keeps transmitting. The one path that does NOT come
     * through here is a finished connection attempt — there RF must
     * survive, or the glyph could not tell "failed" from "switched off".
     *
     * user = a key press asked for this (so the page gets its full 10 s);
     * the idle timeout leaves last_key_ms alone and PAGE 1 blanks at once. */
    function jw_exit(now, user) {
        /* The C SIGKILLs an unreaped scan child; dropping the handle is
         * the same thing here — its result is discarded either way. */
        if (job.kind === RFJ.SCAN)
            job = { kind: RFJ.NONE, h: null, deadline_ms: 0 };
        /* Deferred, not spawned here: a scan may still hold the one job
         * slot. The tick drains this within 200 ms. */
        rf_kill_request();
        ui.screen = SCR.PAGE;
        ui.page_idx = 0;
        ui.a_down_ms = 0;
        ui.a_fired = false;
        jw_clear();
        if (user)
            ui.last_key_ms = now;
    }

    /* rf-ctl prints one SSID per line. Truncate to 32 octets, drop blanks
     * and duplicates, then sort alphabetically (case-insensitive). */
    function jw_take_scan(out) {
        const seen = [];
        for (const raw of String(out).split("\n")) {
            const s = raw.replace(/[\r ]+$/, "").slice(0, SSID_MAX);
            if (s && !seen.includes(s) && seen.length < MAX_SSIDS)
                seen.push(s);
        }
        seen.sort((a, b) => {
            const la = a.toLowerCase(), lb = b.toLowerCase();
            if (la !== lb) return la < lb ? -1 : 1;
            return a < b ? -1 : a > b ? 1 : 0;
        });
        jw.ssid = seen;
        jw.sel = 0;
        jw.top = 0;
    }

    function jw_viewport() {
        if (jw.sel < jw.top)
            jw.top = jw.sel;
        if (jw.sel >= jw.top + ROWS)
            jw.top = jw.sel - ROWS + 1;
        if (jw.top < 0)
            jw.top = 0;
    }

    function rf_job_done(now) {
        const kind = job.kind;
        const ok = !!job.h && job.h.done && job.h.ok;
        const out = job.h ? job.h.out : "";
        job = { kind: RFJ.NONE, h: null, deadline_ms: 0 };
        rf_refresh();              /* the glyph must not wait for the tick */

        if (kind === RFJ.SCAN && ui.screen === SCR.JW1) {
            jw.scanning = false;
            jw.scan_failed = !ok;
            if (ok)
                jw_take_scan(out);
        } else if (kind === RFJ.DOWN) {
            if (ok) {
                ui.rf_kill_pending = false;
                ui.rf_kill_tries = 0;
            }
            /* Not ok: the debt stands and rf_kill_drain retries, bounded by
             * RF_KILL_TRIES. The glyph reads the radio state either way. */
        } else if (kind === RFJ.CONNECT) {
            /* Success or failure, the screen returns to PAGE 1 (or 0) and
             * the RF glyph is the whole answer — no text hint, by design. */
            ui.screen = SCR.PAGE;
            ui.page_idx = 0;
            ui.blanked = false;
            ui.last_key_ms = now;
            jw_clear();
        }
    }

    function rf_job_tick(now) {
        if (job.kind === RFJ.NONE)
            return;
        if (!job.h.done && now >= job.deadline_ms)
            job.h = { done: true, ok: false, out: "" };   /* SIGKILL in the C */
        if (!job.h.done)
            return;
        rf_job_done(now);
    }

    /* Run the `down` a JW exit owed us, once the job slot is free.
     * Unconditional on rf_state: it is the fail-safe direction, and a
     * stale "already killed" reading must never leave a radio up. */
    function rf_kill_drain(now) {
        if (!ui.rf_kill_pending || job.kind !== RFJ.NONE)
            return;
        if (ui.rf_kill_tries >= RF_KILL_TRIES) {
            ui.rf_kill_pending = false;   /* out of tries; the glyph tells
                                             the truth and A still works */
            return;
        }
        if (rf_spawn(RFJ.DOWN, "down", null, now, RFDOWN_TO_MS))
            ui.rf_kill_tries++;
    }

    /* 5 s button-A hold on a page: RF-KILLED -> radios on + JW-1, else kill. */
    function rf_toggle(now) {
        if (job.kind !== RFJ.NONE)
            return;
        if (rf_state !== "killed") {
            rf_kill_request();        /* same retried path as a JW exit */
            return;
        }
        ui.rf_kill_pending = false;   /* arming supersedes an owed kill */
        ui.rf_kill_tries = 0;
        jw_clear();
        ui.screen = SCR.JW1;
        ui.blanked = false;
        ui.last_key_ms = now;
        jw.scanning = true;
        /* rf-ctl scan unblocks the radios itself, so the card reaches
         * RF-ENABLED even when the scan comes back empty. */
        if (!rf_spawn(RFJ.SCAN, "scan", null, now, SCAN_TO_MS)) {
            jw.scanning = false;
            jw.scan_failed = true;
        }
    }

    function jw_connect(now) {
        const stdinText = jw.ssid[jw.sel] + "\n" + jw.psk + "\n";
        ui.screen = SCR.CONN;
        ui.blanked = false;
        ui.last_key_ms = now;
        if (!rf_spawn(RFJ.CONNECT, "connect", stdinText, now, CONNECT_TO_MS)) {
            ui.screen = SCR.PAGE;
            ui.page_idx = 0;
            jw_clear();
        }
    }

    /* JW-2 keyboard: line 2 A-P, line 3 Q-Z then 1-6, line 4 7-9 0 then
     * nine symbols, then SPACE / CAPS / DELETE in the last three cells. */
    const KB_SYM = "-_.!@#$%&";

    function kb_char(r, c) {
        if (r === 0)
            return String.fromCharCode((jw.caps ? 65 : 97) + c);
        if (r === 1)
            return c < 10 ? String.fromCharCode((jw.caps ? 81 : 113) + c)
                          : String.fromCharCode(49 + (c - 10));
        if (c < 3)
            return String.fromCharCode(55 + c);
        if (c === 3)
            return "0";
        if (c < 13)
            return KB_SYM[c - 4];
        return "";                 /* the three glyph keys */
    }

    function kb_cell(r, c) {
        if (r === 2) {
            if (c === COLS - 1) return G_DEL;
            if (c === COLS - 2) return jw.caps ? G_CAPS_ON : G_CAPS_OFF;
            if (c === COLS - 3) return G_SPACE;
        }
        return kb_char(r, c);
    }

    /* Button A released before the 2 s mark: type the key at the POSITION.
     * Anything that touches the input area leaves STAGING; CAPS does not,
     * it changes no character. */
    function jw_type() {
        const r = jw.kr, c = jw.kc;
        if (r === 2 && c === COLS - 2) {
            jw.caps = !jw.caps;
            return;
        }
        jw.staged = false;
        if (r === 2 && c === COLS - 1) {
            jw.psk = jw.psk.slice(0, -1);
            return;
        }
        const ch = (r === 2 && c === COLS - 3) ? " " : kb_char(r, c);
        if (!ch)
            return;
        if (jw.psk.length < PSK_MAX)
            jw.psk += ch;
    }

    function jw_key(key, press, now) {
        ui.last_key_ms = now;      /* both edges keep the 10 s idle timer up */

        /* Button B exits from either screen, short or long — its EVENT
         * function is absorbed for as long as a JW screen is up. */
        if (key === KEY.B) {
            if (press)
                jw_exit(now, true);
            return;
        }
        if (key === KEY.A) {
            if (press) {
                ui.a_down_ms = now;
                ui.a_fired = false;
            } else {
                const fired = ui.a_fired;
                ui.a_down_ms = 0;
                ui.a_fired = false;
                if (!fired && ui.screen === SCR.JW2)
                    jw_type();
            }
            return;
        }
        if (!press)
            return;

        if (ui.screen === SCR.JW1) {
            if (key === KEY.UP && jw.sel > 0)
                jw.sel--;
            else if (key === KEY.DOWN && jw.sel + 1 < jw.ssid.length)
                jw.sel++;
            else if (key === KEY.LEFT)
                jw_exit(now, true);
            else if (key === KEY.RIGHT && jw.ssid.length > 0 && !jw.scanning) {
                ui.screen = SCR.JW2;
                ui.a_down_ms = 0;  /* a hold begun on JW-1 must not land on
                                      JW-2 as an instant STAGING */
                ui.a_fired = false;
            }
            jw_viewport();
            return;
        }
        /* SCR.JW2 — LEFT is a keyboard move here, not an exit; the keyboard
         * wraps on both axes so no direction is ever a dead end. */
        if (key === KEY.UP)
            jw.kr = (jw.kr + 2) % 3;
        else if (key === KEY.DOWN)
            jw.kr = (jw.kr + 1) % 3;
        else if (key === KEY.LEFT)
            jw.kc = (jw.kc + COLS - 1) % COLS;
        else if (key === KEY.RIGHT)
            jw.kc = (jw.kc + 1) % COLS;
    }

    function handle_key(offset, press, now) {
        let key = -1;
        for (let i = 0; i < KEY_GPIO.length; i++)
            if (KEY_GPIO[i] === offset) {
                key = i;
                break;
            }
        if (key < 0)
            return;

        /* CONNECTING owns the screen until rf-ctl answers: button A is
         * absorbed, button B is NOT — the EVENT marker stays available,
         * since an incident does not wait for a Wi-Fi join. */
        if (ui.screen === SCR.CONN) {
            if (key !== KEY.B)
                return;
        } else if (ui.screen === SCR.JW1 || ui.screen === SCR.JW2) {
            jw_key(key, press, now);
            return;
        }

        /* Button B: EVENT capture (~2 s hold, fired from the tick) — the
         * one key that acts on any NON-BLANKED screen, PAGE 0 included.
         * From blank it is still a pure wake key. */
        if (key === KEY.B) {
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
            ui.a_down_ms = 0;      /* PAGE 0 is static: other input ignored */
            return;
        }
        if (!press) {
            if (key === KEY.A)
                ui.a_down_ms = 0;
            ui.last_key_ms = now;
            return;
        }
        if (ui.blanked) {
            wake(now);             /* absorbed: wake only, no paging — an A
                                      hold must restart after the wake */
            return;
        }
        ui.last_key_ms = now;
        if (key === KEY.LEFT)
            ui.page_idx = (ui.page_idx + NPAGES - 1) % NPAGES;
        else if (key === KEY.RIGHT)
            ui.page_idx = (ui.page_idx + 1) % NPAGES;
        else if (key === KEY.A) {
            ui.a_down_ms = now;    /* 5 s hold = JOIN WIFI, fired from the
                                      tick; short presses stay reserved */
            ui.a_fired = false;
        }
        /* UP, DOWN, CENTER: reserved — wake/reset-timer only */
    }

    /* ------------------------------------------------------- rendering -- */

    /* JW-1: four SSIDs, the selected one an INVERTED bar. Names wider than
     * 14 columns are cut there and marked with a single LDOTS. */
    function compose_jw1(f) {
        /* Every full-screen status message in the UI sits on line 2
         * indented one column — EVENT, CONNECTING and these three read as
         * one family. */
        if (jw.scanning)    { f.rows[1] = " SCANNING..."; return; }
        if (jw.scan_failed) { f.rows[1] = " RF ERROR";    return; }
        if (jw.ssid.length === 0) { f.rows[1] = " NO NETWORKS"; return; }
        for (let r = 0; r < ROWS; r++) {
            const i = jw.top + r;
            if (i >= jw.ssid.length)
                break;
            const s = jw.ssid[i];
            f.rows[r] = s.length > SSID_COLS
                        ? s.slice(0, SSID_COLS) + G_LDOTS : s;
            if (i === jw.sel)
                f.inv[r] = 0xFFFF;
        }
    }

    /* JW-2: line 1 the input area, lines 2-4 the keyboard. The POSITION
     * cell is INVERTED; so is the whole input area while STAGING. */
    function compose_jw2(f) {
        f.rows[0] = jw.psk.length <= COLS
                    ? jw.psk
                    : G_LDOTS + jw.psk.slice(jw.psk.length - (COLS - 1));
        if (jw.staged)
            f.inv[0] = 0xFFFF;
        for (let r = 0; r < 3; r++) {
            let line = "";
            for (let c = 0; c < COLS; c++)
                line += kb_cell(r, c);
            f.rows[r + 1] = line;
        }
        f.inv[1 + jw.kr] |= 1 << jw.kc;
    }

    function compose() {
        const f = { blanked: false, yoff: 0, glyph: '',
                    inv: [0, 0, 0, 0], rows: ["", "", "", ""] };

        if (ui.blanked && !ui.error && ui.screen === SCR.PAGE) {
            f.blanked = true;      /* blank hides everything, glyph included */
            return f;
        }
        f.glyph = rf_state === "killed" ? 'S'
                : rf_state === "link"   ? 'W' : 'R';

        if (hw.now() < ui.flash_until_ms) {
            /* EVENT confirmation — a deliberate 2 s full-screen
             * interruption of whatever page is up (PAGE 0 returns after) */
            f.rows[1] = " " + ui.flash.slice(0, 14);
            return f;
        }

        if (ui.screen === SCR.CONN) {
            /* Same full-screen shape as EVENT, but it lasts as long as the
             * association attempt does — and it outranks PAGE 0 for that
             * bounded window; the fault is still there when it returns. */
            f.rows[1] = " CONNECTING...";
            return f;
        }
        if (ui.screen === SCR.JW1 || ui.screen === SCR.JW2) {
            f.glyph = '';          /* JW-2's DELETE key needs column 15 */
            if (ui.screen === SCR.JW1)
                compose_jw1(f);
            else
                compose_jw2(f);
            return f;
        }

        if (ui.error) {
            /* PAGE 0 — static, only failing groups, empty lines omitted */
            f.yoff = BURN_OFFSETS[ui.burn_idx];
            f.rows[0] = "Errors:";
            let r = 1;
            if (!health.front || !health.rear)
                f.rows[r++] = (health.front ? "" : "FRONT") +
                              (!health.front && !health.rear ? " " : "") +
                              (health.rear ? "" : "REAR");
            if ((!health.gpsok || !health.timeok) && r < ROWS)
                f.rows[r++] = (health.gpsok ? "" : "GPS") +
                              (!health.gpsok && !health.timeok ? " " : "") +
                              (health.timeok ? "" : "TIME");
            if (!health.storage && r < ROWS)
                f.rows[r++] = "SD FULL";
            return f;
        }

        if (PAGES[ui.page_idx] === 2) {
            /* PAGE 2 — line 1: Pi 4 SoC temperature, whole degrees C
             * (negative-safe round-to-nearest); line 2: firmware power
             * flags (under-voltage now beats latched); rest reserved */
            if (cpu_temp_valid) {
                const mc = cpu_temp_mc;
                const deg = Math.trunc((mc + (mc >= 0 ? 500 : -500)) / 1000);
                f.rows[0] = "TMP " + deg + " C";
            } else {
                f.rows[0] = "TMP ---";
            }
            if (!throttled_valid)            f.rows[1] = "PWR ---";
            else if (throttled & 0x1)        f.rows[1] = "PWR UV NOW";
            else if (throttled & 0x10000)    f.rows[1] = "PWR UV SEEN";
            else                             f.rows[1] = "PWR OK";
            return f;
        }

        /* PAGE 1 — values aligned at column 4: 3-char labels take one
         * space, DF takes two; coordinates at 5 decimals */
        if (gps.have_fix) {
            f.rows[0] = "LAT " + gps.lat.toFixed(5);
            f.rows[1] = "LON " + gps.lon.toFixed(5);
            f.rows[2] = "SPD " +
                        Math.trunc(gps.knots * speed_factor + 0.5) + " " +
                        speed_unit;
        } else {
            f.rows[0] = "LAT ---";
            f.rows[1] = "LON ---";
            f.rows[2] = "SPD ---";
        }
        f.rows[3] = "DF  " + df_pct.toFixed(2) + "%";
        /* char rows[ROWS][COLS + 1]: snprintf truncates at 16 chars */
        for (let r = 0; r < ROWS; r++)
            f.rows[r] = f.rows[r].slice(0, COLS);
        return f;
    }

    function putpixel(x, y, on) {
        if (x < 0 || y < 0 || x >= XRES || y >= YRES)
            return;                /* clips the ±1 px burn-in shift rows */
        fb[y * XRES + x] = on ? 1 : 0;
    }

    /* INVERTED cells write every pixel of the 8x16 cell, so the background
     * fills and the character itself stays dark — no separate fill pass. */
    function draw_glyph16(col, row, g, yoff, inv) {
        const x0 = col * CELL_W;
        const y0 = row * CELL_H + yoff;
        for (let fy = 0; fy < 16; fy++)
            for (let fx = 0; fx < 8; fx++) {
                const on = (g[fy] >> fx) & 1;
                putpixel(x0 + fx, y0 + fy, inv ? !on : on);
            }
    }

    /* 8x8 font cell doubled vertically to 8x16; the private G_* codes
     * below 0x20 select a hand-drawn 8x16 glyph instead. */
    function draw_char(col, row, ch, yoff, inv) {
        const g16 = CELL_GLYPH[ch];
        if (g16) {
            draw_glyph16(col, row, g16, yoff, inv);
            return;
        }
        let code = ch.charCodeAt(0);
        if (code < 0x20 || code > 0x7E)
            code = 0x20;           /* incl. UTF-8 SSID bytes */
        const g = FONT8X8[code - 0x20];
        const x0 = col * CELL_W;
        const y0 = row * CELL_H + yoff;
        for (let fy = 0; fy < 8; fy++) {
            const bits = g[fy];
            for (let fx = 0; fx < 8; fx++) {
                let on = (bits >> fx) & 1;      /* bit 0 = leftmost */
                if (inv)
                    on = on ? 0 : 1;
                putpixel(x0 + fx, y0 + 2 * fy, on);
                putpixel(x0 + fx, y0 + 2 * fy + 1, on);
            }
        }
    }

    function render(f) {
        if (f.blanked) {
            fb.fill(0);
            if (hw_blanked !== 1)
                hw_blanked = 1;    /* FBIOBLANK POWERDOWN in the C */
            hw.present({ blanked: true, fb });
            return;
        }
        if (hw_blanked !== 0)
            hw_blanked = 0;        /* FBIOBLANK UNBLANK in the C */
        fb.fill(0);
        for (let r = 0; r < ROWS; r++) {
            /* row 3, col 15 is the reserved RF glyph cell — except on the
             * JW screens, which clear the glyph and take all 16 columns */
            const maxc = (r === ROWS - 1 && f.glyph) ? COLS - 1 : COLS;
            const len = f.rows[r].length;
            for (let c = 0; c < maxc; c++) {
                const inv = (f.inv[r] >> c) & 1;
                if (c >= len && !inv)
                    continue;      /* already dark from the fill(0) */
                draw_char(c, r, c < len ? f.rows[r][c] : " ", f.yoff, inv);
            }
        }
        if (f.glyph)
            draw_glyph16(COLS - 1, ROWS - 1,
                         f.glyph === 'S' ? GLYPH_SHIELD :
                         f.glyph === 'R' ? GLYPH_RF_IDLE : GLYPH_WIRELESS,
                         f.yoff, false);
        hw.present({ blanked: false, fb });
    }

    /* ----------------------------------------------------------- main -- */

    /* main() before the loop: conf, first health pass, honest boot state. */
    function boot(units, rfJoin) {
        if (units === "KMH") {     /* load_conf() */
            speed_factor = 1.852;
            speed_unit = "KMH";
        } else {
            speed_factor = 1.15078;
            speed_unit = "MPH";
        }
        rf_join = !!rfJoin;        /* RF_JOIN= in dashberry.conf */
        const now = hw.now();
        ui.screen = SCR.PAGE;
        ui.page_idx = 0;
        ui.last_key_ms = now;
        ui.burn_last_ms = now;
        job = { kind: RFJ.NONE, h: null, deadline_ms: 0 };
        ui.rf_kill_pending = false;
        ui.rf_kill_tries = 0;
        jw_clear();
        eval_health(now);
        ui.error = system_err();   /* boot: honest immediate evaluation */
        hw.notify("READY=1");
        shown = null;              /* force first paint (glyph='?' in C) */
    }

    /* One 200 ms tick: watchdog, health cadence, blank, burn-in, repaint.
     * The body of `if (pfd[i_tick].revents & POLLIN)` in the C. */
    function tick() {
        const now = hw.now();
        hw.notify("WATCHDOG=1");
        watchdog_pets++;

        rf_job_tick(now);
        rf_kill_drain(now);

        if (++subtick >= HEALTH_TICKS) {
            subtick = 0;
            eval_health(now);
            const err = system_err();
            if (err && !ui.error) {
                ui.error = true;   /* forces screen on + PAGE 0 */
                ui.blanked = false;
                /* A fault outranks a half-finished join: JW-1/JW-2 are
                 * dropped (an in-flight CONNECT still gets to finish). */
                if (ui.screen === SCR.JW1 || ui.screen === SCR.JW2)
                    jw_exit(now, true);
            } else if (!err && ui.error) {
                ui.error = false;  /* back to PAGES: wake to PAGE 1 */
                ui.page_idx = 0;
                ui.blanked = false;
                ui.last_key_ms = now;
            }
        }

        /* Button B held to the 2 s mark: record the event, once per hold. */
        if (ui.b_down_ms && !ui.b_fired && now - ui.b_down_ms >= EVENT_HOLD_MS) {
            ui.b_fired = true;
            ui.flash = hw.logEvent() ? "EVENT" : "EVENT ERROR";
            ui.flash_until_ms = now + EVENT_FLASH_MS;
        }

        /* Button A held to its mark. On JW-2 that is 2 s: first hold
         * STAGES the input area (INVERTED), a second one commits.
         * On a page it is 5 s: arm JOIN WIFI, or kill RF again. */
        if (ui.a_down_ms && !ui.a_fired) {
            if (ui.screen === SCR.JW2 && now - ui.a_down_ms >= STAGE_HOLD_MS) {
                ui.a_fired = true;
                if (jw.staged)
                    jw_connect(now);
                else
                    jw.staged = true;
            } else if (ui.screen === SCR.PAGE && rf_join && !ui.error &&
                       !ui.blanked && now - ui.a_down_ms >= RF_HOLD_MS) {
                ui.a_fired = true;
                rf_toggle(now);
            }
        }

        /* JW-1/JW-2 time out to the pages rather than blanking. The idle
         * path leaves last_key_ms alone, so the page it returns to blanks
         * on this same tick — nobody is watching. */
        if ((ui.screen === SCR.JW1 || ui.screen === SCR.JW2) &&
            now - ui.last_key_ms >= JW_IDLE_MS)
            jw_exit(now, false);

        if (ui.screen === SCR.PAGE && !ui.error && !ui.blanked &&
            now - ui.last_key_ms >= BLANK_MS)
            ui.blanked = true;

        if (now - ui.burn_last_ms >= burn_step_ms) {
            ui.burn_last_ms = now;
            ui.burn_idx = (ui.burn_idx + 1) & 3;
        }

        /* repaint on change only, at most once per tick (5 Hz cap) */
        const f = compose();
        const j = JSON.stringify(f);
        if (j !== shown) {
            render(f);
            shown = j;
            repaints++;
        }
    }

    /* ------------------------------------------------------ public API -- */

    return {
        TICK_MS, KEY, KEY_GPIO, XRES, YRES,

        boot, tick,

        /* GPIO edge, gpiochip semantics: press=true is the rising edge. */
        keyEvent(offset, press) { handle_key(offset, press, hw.now()); },

        /* Harness feed — lands where nmea_line() leaves the C state. */
        gpsFix(lat, lon, knots) {
            gps.last_nmea_ms = hw.now();
            gps.have_fix = true;
            gps.lat = lat;
            gps.lon = lon;
            gps.knots = knots;
        },
        gpsNoFix() {               /* RMC status 'V': sentence, no fix */
            gps.last_nmea_ms = hw.now();
            gps.have_fix = false;
        },

        setBurnStepMs(ms) { burn_step_ms = ms; },   /* demo aid only */

        state() {
            const scrName = ["PAGE", "JW-1", "JW-2", "CONNECTING"][ui.screen];
            return {
                error: ui.error, blanked: ui.blanked,
                screen: scrName,
                page: ui.screen !== SCR.PAGE ? null
                                             : (ui.error ? 0 : PAGES[ui.page_idx]),
                burn_idx: ui.burn_idx,
                yoff: ui.error ? BURN_OFFSETS[ui.burn_idx] : 0,
                blank_in_ms: ui.error || ui.blanked || ui.screen !== SCR.PAGE
                             ? null
                             : Math.max(0, BLANK_MS - (hw.now() - ui.last_key_ms)),
                health: { ...health },
                rf_join, rf_state,
                jw: {
                    ssid: [...jw.ssid], sel: jw.sel, top: jw.top,
                    scanning: jw.scanning, scan_failed: jw.scan_failed,
                    pskLen: jw.psk.length, psk: jw.psk,
                    kr: jw.kr, kc: jw.kc, caps: jw.caps, staged: jw.staged,
                },
                job: job.kind,
                rf_kill_pending: ui.rf_kill_pending,
                rf_kill_tries: ui.rf_kill_tries,
                flashing: hw.now() < ui.flash_until_ms,
                gps: { ...gps },
                df_pct,
                repaints, watchdog_pets,
            };
        },
    };
}

return { create, KEY, KEY_GPIO, XRES, YRES, COLS, ROWS,
         TICK_MS, BLANK_MS, STALE_MS, GPS_SILENT_MS,
         EVENT_HOLD_MS, RF_HOLD_MS, STAGE_HOLD_MS, JW_IDLE_MS,
         SCAN_TO_MS, CONNECT_TO_MS,
         G_LDOTS, G_SPACE, G_CAPS_OFF, G_CAPS_ON, G_DEL,
         FONT8X8,              /* exported so logic-test.js can decode fb */
         GLYPHS: { LDOTS: GLYPH_LDOTS, SPACE: GLYPH_SPACE,
                   "CAPSv": GLYPH_CAPS_OFF, "CAPS^": GLYPH_CAPS_ON,
                   DEL: GLYPH_DEL, SHIELD: GLYPH_SHIELD,
                   "RF-IDLE": GLYPH_RF_IDLE, WIFI: GLYPH_WIRELESS } };

})();

/* Node (logic-test.js) support; browsers just read the PANEL global. */
if (typeof module !== "undefined" && module.exports)
    module.exports = PANEL;
