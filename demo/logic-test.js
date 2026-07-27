/* logic-test.js — headless exercise of panel.js against the §3b spec.
 * Run: node logic-test.js
 *
 * Virtual clock + simulated hardware; time only moves through advance(),
 * which steps in 200 ms ticks, so every timing rule (10 s blank, 10 s
 * stale, 5 s GPS silence) is exercised deterministically.
 */

"use strict";

const PANEL = require("./panel.js");

/* ------------------------------------------------------- simulated hw -- */

const vt = { now: 1000 };          /* monotonic ms; nonzero like the kernel */

const sim = {
    frontWriting: true, frontLast: 0,
    rearWriting: true,  rearLast: 0,
    gpsDelivering: true, gpsHaveFix: true,
    lat: -30.123456, lon: 111.222222, knots: 78.3,
    rtcOk: true,
    mounted: true, rw: true, freePct: 90.1, fsErrors: false,
    logs: [],
    presented: null,
};

const hw = {
    now: () => vt.now,
    frontNewestMtimeMs: () => sim.frontLast,
    rearNewestMtimeMs: () => sim.rearLast,
    rtcOk: () => sim.rtcOk,
    statvfs: () => sim.mounted
        ? { rw: sim.rw, freePct: sim.freePct, fsErrors: sim.fsErrors }
        : null,
    present: (view) => { sim.presented = { blanked: view.blanked,
                                           fb: Uint8Array.from(view.fb) }; },
    notify: () => {},
    log: (m) => sim.logs.push(m),
};

const panel = PANEL.create(hw);

/* Step virtual time in 200 ms ticks, feeding writers/GPS like the real
 * services would. */
function advance(ms) {
    const end = vt.now + ms;
    while (vt.now < end) {
        vt.now = Math.min(vt.now + PANEL.TICK_MS, end);
        if (sim.frontWriting) sim.frontLast = vt.now;
        if (sim.rearWriting)  sim.rearLast = vt.now;
        if (sim.gpsDelivering) {
            if (sim.gpsHaveFix)
                panel.gpsFix(sim.lat, sim.lon, sim.knots);
            else
                panel.gpsNoFix();
        }
        panel.tick();
    }
}

function press(key)   { panel.keyEvent(PANEL.KEY_GPIO[key], true); }
function release(key) { panel.keyEvent(PANEL.KEY_GPIO[key], false); }

/* ------------------------------------------------------------ asserts -- */

let failures = 0, checks = 0;
function ok(cond, name) {
    checks++;
    if (!cond) {
        failures++;
        console.error(`FAIL  ${name}`);
    } else {
        console.log(`ok    ${name}`);
    }
}

/* Decode a text row from the presented framebuffer by re-rendering: cheaper
 * to check the compose-level state, so pixel checks are limited to the
 * reserved glyph cell and blank-means-dark. */
function fbLit() {
    return sim.presented.fb.reduce((a, b) => a + b, 0);
}
function glyphCellPixels() {
    const out = [];
    for (let y = 48; y < 64; y++)
        for (let x = 120; x < 128; x++)
            out.push(sim.presented.fb[y * 128 + x]);
    return out;
}
/* Read a text row back out of the presented framebuffer: undouble each 8x16
 * cell to its 8x8 pattern and reverse-look it up in the font. Cells that
 * match no glyph (e.g. the RF icon) decode as '?'. */
function decodeRow(row, maxc = 16) {
    let s = "";
    for (let c = 0; c < maxc; c++) {
        const bytes = [];
        for (let fy = 0; fy < 8; fy++) {
            let v = 0;
            for (let fx = 0; fx < 8; fx++)
                v |= sim.presented.fb[(row * 16 + 2 * fy) * 128 + c * 8 + fx]
                     << fx;
            bytes.push(v);
        }
        const key = bytes.join(",");
        const i = PANEL.FONT8X8.findIndex(g => g.join(",") === key);
        s += i < 0 ? "?" : String.fromCharCode(0x20 + i);
    }
    return s.replace(/ +$/, "");
}

function expectedGlyphPixels(glyph) {
    if (glyph === 'W') {
        /* The wireless glyph's source of truth is the user drawing —
         * compare against the file itself, not a copy of the bytes. */
        const rows = require("fs")
            .readFileSync(require("path").join(__dirname, "..",
                                               "wireless_glyph.txt"), "utf8")
            .split("\n").filter(l => l.trim().length);
        if (rows.length !== 16)
            throw new Error("wireless_glyph.txt: want 16 rows");
        return rows.flatMap(r =>
            Array.from({ length: 8 }, (_, fx) => r[fx] === 'x' ? 1 : 0));
    }
    const g = [0x3E,0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x7F,0x3E,0x3E,0x1C,0x1C,0x08,0x00,0x00];
    const out = [];
    for (let fy = 0; fy < 16; fy++)
        for (let fx = 0; fx < 8; fx++)
            out.push((g[fy] >> fx) & 1);
    return out;
}

/* -------------------------------------------------------------- tests -- */

/* Boot: recorders/gpsd haven't proven themselves yet -> honest PAGE 0. */
panel.boot("MPH");
let s = panel.state();
ok(s.error === true, "boot: error until health is proven (nothing written yet)");

/* One second in, everything is flowing -> OK, PAGE 1. */
advance(1200);
s = panel.state();
ok(s.error === false, "1 s in: all signals proven -> OK");
ok(s.page === 1, "OK state shows PAGE 1");
ok(s.health.front && s.health.rear && s.health.gpsok && s.health.timeok &&
   s.health.storage, "all five health states ON");
ok(s.debug_card === false, "boot without DEBUG=1 is a production card");
ok(glyphCellPixels().join("") === expectedGlyphPixels('S').join(""),
   "reserved cell (row 3, col 15) shows the shield glyph (production)");

/* Formatting, decoded from the rendered framebuffer: 5-decimal coords,
 * rounded SPD, and values aligned at column 4 — 3-char labels take one
 * space, DF takes two, DF shows free % only at 2 decimals. */
ok(s.gps.lat === -30.123456, "gps state carries the raw fix");
/* -30.123456 -> "-30.12346"; 78.3 kn * 1.15078 = 90.106 -> 90 */
ok(decodeRow(0) === "LAT -30.12346",
   `PAGE 1 row 0 renders "LAT -30.12346" (got "${decodeRow(0)}")`);
ok(decodeRow(2) === "SPD 90 MPH",
   `PAGE 1 row 2 renders "SPD 90 MPH" (got "${decodeRow(2)}")`);
ok(decodeRow(3, 15) === "DF  90.10%",
   `PAGE 1 row 3 renders "DF  90.10%" (got "${decodeRow(3, 15)}")`);

/* AUTO-BLANK: 10 s without keys -> dark, everything hidden. */
advance(10000);
s = panel.state();
ok(s.blanked === true, "AUTO-BLANK after 10 s without keys");
ok(sim.presented.blanked === true && fbLit() === 0,
   "blank means a fully dark framebuffer (glyph hidden too)");

/* Strict absorption: a wake key wakes, does nothing else, resets timer. */
press(PANEL.KEY.B); release(PANEL.KEY.B);
advance(200);
s = panel.state();
ok(s.blanked === false && s.page === 1, "any key wakes to PAGE 1");
advance(9000);
ok(panel.state().blanked === false, "wake reset the 10 s timer");
advance(1200);
ok(panel.state().blanked === true, "…and blanks again 10 s after the key");

/* Strict absorption of A: pressed while blanked it wakes, nothing more —
 * button A is a plain reserved key now (no hold, no toggle). */
press(PANEL.KEY.A);                /* wakes, absorbed */
advance(3000);                     /* held well past any old hold window */
s = panel.state();
ok(s.blanked === false, "A pressed while blanked wakes");
ok(glyphCellPixels().join("") === expectedGlyphPixels('S').join(""),
   "holding A changes nothing: glyph still the shield");
release(PANEL.KEY.A);

/* PAGE 0 assembly: kill front cam -> stale after 10 s, error line FRONT. */
sim.frontWriting = false;
advance(PANEL.STALE_MS + 1400);    /* stale window + health cadence */
s = panel.state();
ok(s.error === true, "front writer stopped -> ERROR after 10 s stale");
ok(s.page === 0, "ERROR shows PAGE 0");
ok(s.blanked === false, "ERROR forces the screen on");

/* Line grouping: rear too -> "FRONT REAR" on one line; GPS silence 5 s
 * joins TIME's line only when TIME also fails. */
sim.rearWriting = false;
sim.gpsDelivering = false;
advance(11000);
s = panel.state();
ok(!s.health.front && !s.health.rear && !s.health.gpsok,
   "front+rear stale, GPS silent 5 s -> three ERRs");

/* ERROR page: all input is dead — A included. */
press(PANEL.KEY.RIGHT); release(PANEL.KEY.RIGHT);
press(PANEL.KEY.B); release(PANEL.KEY.B);
ok(panel.state().page === 0, "PAGE 0 ignores joystick/B");
press(PANEL.KEY.A);
advance(2200);
release(PANEL.KEY.A);
ok(panel.state().page === 0, "PAGE 0 ignores A too (no toggle exists)");

/* Storage: full -> its own line. */
sim.freePct = 0;
advance(1200);
ok(panel.state().health.storage === false, "0% free -> storage ERR (SD FULL)");

/* Recovery: everything back -> PAGE 1, awake, timer reset. */
sim.frontWriting = true;
sim.rearWriting = true;
sim.gpsDelivering = true;
sim.freePct = 90.1;
advance(1400);
s = panel.state();
ok(s.error === false && s.page === 1 && s.blanked === false,
   "recovery returns to PAGE 1, screen on, blank timer reset");

/* Repaint economy: static scene -> no repaints between changes. */
{
    advance(1000);
    const before = panel.state().repaints;
    advance(2000);                 /* same fix, same DF -> identical frames */
    const after = panel.state().repaints;
    ok(after === before, "unchanged frames are not re-rendered (memcmp)");
}

/* No-fix placeholders: gpsd delivering but RMC status V. */
sim.gpsHaveFix = false;
advance(1400);
s = panel.state();
ok(s.error === false, "no-fix is NOT a GPS ERR (sentences still flowing)");
ok(s.gps.have_fix === false, "…but PAGE 1 will show LAT/LON/SPD ---");

/* DEBUG card: boot with DEBUG=1 -> wireless glyph, fixed for the card's
 * lifetime (install mode is conf-baked, there is no runtime RF state). */
{
    const dbg = PANEL.create(hw);
    dbg.boot("MPH", true);
    dbg.tick();                    /* first paint (PAGE 0: nothing proven) */
    ok(dbg.state().debug_card === true, "DEBUG=1 boot is a debug card");
    ok(glyphCellPixels().join("") === expectedGlyphPixels('W').join(""),
       "debug card shows the wireless glyph (per wireless_glyph.txt)");
}

console.log(`\n${checks - failures}/${checks} checks passed`);
process.exit(failures ? 1 : 0);
