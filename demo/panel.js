/* panel.js — JavaScript port of sw/src/dashberry-panel.c (PLAN.md §3b, rev 6)
 * for the browser demo/visualizer. NOT part of the Pi runtime.
 *
 * Porting rule: everything above the hardware line — the §3b UI state
 * machine (PAGE 0/1/2, AUTO-BLANK, strict wake-key absorption, burn-in
 * shift), the health model, compose()/render(), the embedded font and the
 * install-mode glyphs (shield = production, wireless = debug — baked from
 * DEBUG in dashberry.conf, no runtime RF state) — is ported
 * statement-for-statement from the C. Everything below it (fb1 mmap,
 * gpiochip v2, gpsd socket + NMEA parse, statvfs, sd_notify) is replaced
 * by an injected `hw` object the harness simulates. If this file and the
 * C disagree about behavior, the C is the bug's home or this port is
 * wrong — diff them.
 *
 * hw contract (all required):
 *   now()                    -> monotonic ms (CLOCK_MONOTONIC stand-in)
 *   frontNewestMtimeMs()     -> ms of newest front segment write, 0 = none
 *   rearNewestMtimeMs()      -> ms of newest rear segment write, 0 = none
 *   rtcOk()                  -> bool (rtc0/since_epoch readable)
 *   cpuTempMc()              -> SoC temp in millidegrees C (thermal_zone0),
 *                               null = read failure (PAGE 2 shows TMP ---)
 *   statvfs()                -> null (/data not mounted) or
 *                               { rw, freePct, fsErrors }
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

/* -------------------------------------------------------------- display - */

const XRES = 128, YRES = 64;
const COLS = 16, ROWS = 4, CELL_W = 8, CELL_H = 16;

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

/* Hand-drawn 8x16 install-mode glyphs (bit 0 = leftmost, NOT doubled):
 * shield = production (sealed), wireless = debug — the user drawing in
 * DashBerry/wireless_glyph.txt ('x' = lit). Fixed per card, not runtime. */
const GLYPH_WIRELESS = [0x3C, 0x42, 0x81, 0x81, 0x3C, 0x42, 0x81, 0x81,
                        0x3C, 0x42, 0x81, 0x99, 0x24, 0x00, 0x18, 0x18];
const GLYPH_SHIELD  = [0x3E, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F,
                       0x7F, 0x3E, 0x3E, 0x1C, 0x1C, 0x08, 0x00, 0x00];

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
    let debug_card   = false;      /* DEBUG=1 -> wireless glyph; else shield */

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

    const ui = {
        error: false,              /* any health state ERR */
        page_idx: 0,
        blanked: false,
        last_key_ms: 0,
        burn_idx: 0,               /* PAGE 0 shift: 0,+1,0,-1 */
        burn_last_ms: 0,
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

    function handle_key(offset, press, now) {
        let key = -1;
        for (let i = 0; i < KEY_GPIO.length; i++)
            if (KEY_GPIO[i] === offset) {
                key = i;
                break;
            }
        if (key < 0)
            return;

        if (ui.error)
            return;                /* PAGE 0 is static: all input ignored */
        if (!press) {
            ui.last_key_ms = now;
            return;
        }
        if (ui.blanked) {
            wake(now);             /* absorbed: wake only, no paging */
            return;
        }
        ui.last_key_ms = now;
        if (key === KEY.LEFT)
            ui.page_idx = (ui.page_idx + NPAGES - 1) % NPAGES;
        else if (key === KEY.RIGHT)
            ui.page_idx = (ui.page_idx + 1) % NPAGES;
        /* A, B, UP, DOWN, CENTER: reserved — wake/reset-timer only */
    }

    /* ------------------------------------------------------- rendering -- */

    function compose() {
        const f = { blanked: false, yoff: 0, glyph: '',
                    rows: ["", "", "", ""] };

        if (ui.blanked && !ui.error) {
            f.blanked = true;      /* blank hides everything, glyph included */
            return f;
        }
        f.glyph = debug_card ? 'W' : 'S';  /* install mode, fixed per card */

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
            /* PAGE 2 — first line: Pi 4 SoC temperature, whole degrees C
             * (negative-safe round-to-nearest); remaining lines reserved */
            if (cpu_temp_valid) {
                const mc = cpu_temp_mc;
                const deg = Math.trunc((mc + (mc >= 0 ? 500 : -500)) / 1000);
                f.rows[0] = "TMP " + deg + " C";
            } else {
                f.rows[0] = "TMP ---";
            }
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

    /* 8x8 font cell doubled vertically to 8x16. */
    function draw_char(col, row, ch, yoff) {
        let code = ch.charCodeAt(0);
        if (code < 0x20 || code > 0x7E)
            code = 0x20;
        const g = FONT8X8[code - 0x20];
        const x0 = col * CELL_W;
        const y0 = row * CELL_H + yoff;
        for (let fy = 0; fy < 8; fy++) {
            const bits = g[fy];
            for (let fx = 0; fx < 8; fx++) {
                const on = (bits >> fx) & 1;    /* bit 0 = leftmost */
                putpixel(x0 + fx, y0 + 2 * fy, on);
                putpixel(x0 + fx, y0 + 2 * fy + 1, on);
            }
        }
    }

    function draw_glyph16(col, row, g, yoff) {
        const x0 = col * CELL_W;
        const y0 = row * CELL_H + yoff;
        for (let fy = 0; fy < 16; fy++)
            for (let fx = 0; fx < 8; fx++)
                putpixel(x0 + fx, y0 + fy, (g[fy] >> fx) & 1);
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
            /* row 3, col 15 is the reserved RF glyph cell on every screen */
            const maxc = (r === ROWS - 1) ? COLS - 1 : COLS;
            for (let c = 0; c < maxc && c < f.rows[r].length; c++)
                draw_char(c, r, f.rows[r][c], f.yoff);
        }
        if (f.glyph)
            draw_glyph16(COLS - 1, ROWS - 1,
                         f.glyph === 'S' ? GLYPH_SHIELD : GLYPH_WIRELESS,
                         f.yoff);
        hw.present({ blanked: false, fb });
    }

    /* ----------------------------------------------------------- main -- */

    /* main() before the loop: conf, first health pass, honest boot state. */
    function boot(units, debug) {
        if (units === "KMH") {     /* load_conf() */
            speed_factor = 1.852;
            speed_unit = "KMH";
        } else {
            speed_factor = 1.15078;
            speed_unit = "MPH";
        }
        debug_card = !!debug;      /* DEBUG= in dashberry.conf */
        const now = hw.now();
        ui.page_idx = 0;
        ui.last_key_ms = now;
        ui.burn_last_ms = now;
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

        if (++subtick >= HEALTH_TICKS) {
            subtick = 0;
            eval_health(now);
            const err = system_err();
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

        if (!ui.error && !ui.blanked && now - ui.last_key_ms >= BLANK_MS)
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
            return {
                error: ui.error, blanked: ui.blanked,
                page: ui.error ? 0 : PAGES[ui.page_idx],
                burn_idx: ui.burn_idx,
                yoff: ui.error ? BURN_OFFSETS[ui.burn_idx] : 0,
                blank_in_ms: ui.error || ui.blanked ? null :
                             Math.max(0, BLANK_MS - (hw.now() - ui.last_key_ms)),
                health: { ...health },
                debug_card,
                gps: { ...gps },
                df_pct,
                repaints, watchdog_pets,
            };
        },
    };
}

return { create, KEY, KEY_GPIO, XRES, YRES, COLS, ROWS,
         TICK_MS, BLANK_MS, STALE_MS, GPS_SILENT_MS,
         FONT8X8 };            /* exported so logic-test.js can decode fb */

})();

/* Node (logic-test.js) support; browsers just read the PANEL global. */
if (typeof module !== "undefined" && module.exports)
    module.exports = PANEL;
