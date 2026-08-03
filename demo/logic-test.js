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
    cpuTempMc: 30566,              /* 30.566 C, a real quantized reading */
    throttled: 0,
    mounted: true, rw: true, freePct: 90.1, fsErrors: false,
    eventLogWritable: true, events: 0,
    settingsFile: null,            /* /data/settings.conf, null = absent */
    /* rfkill + operstate stand-in, and the rf-ctl children it serves */
    rfBlocked: true, rfLinked: false,
    aps: ["HomeNet", "aardvark-guest-network-5G", "Zebra",
          "ExactlyFourteen", "0123456789ABCD", "HomeNet"],
    scanOk: true, correctPsk: "swordfish", rfJobMs: 2000, pending: [],
    downFailsLeft: 0,              /* make N `rf-ctl down` runs exit nonzero */
    lastConnect: null,
    logs: [],
    presented: null,
};

const hw = {
    now: () => vt.now,
    frontNewestMtimeMs: () => sim.frontLast,
    rearNewestMtimeMs: () => sim.rearLast,
    rtcOk: () => sim.rtcOk,
    cpuTempMc: () => sim.cpuTempMc,
    throttled: () => sim.throttled,
    statvfs: () => sim.mounted
        ? { rw: sim.rw, freePct: sim.freePct, fsErrors: sim.fsErrors }
        : null,
    rfState: () => sim.rfBlocked ? "killed" : (sim.rfLinked ? "link" : "idle"),
    /* Stands in for fork+exec of rf-ctl: the handle is mutated by
     * runRfJobs() once enough virtual time has passed. */
    rfCtl: (cmd, stdinText) => {
        const h = { done: false, ok: false, out: "" };
        sim.pending.push({ h, cmd, stdinText, at: vt.now + sim.rfJobMs });
        return h;
    },
    logEvent: () => { if (!sim.eventLogWritable) return false;
                      sim.events++; return true; },
    /* /data/settings.conf stand-in (atomic tmp+rename in the C). */
    settingsLoad: () => sim.settingsFile,
    settingsSave: (text) => { sim.settingsFile = text; return true; },
    present: (view) => { sim.presented = { blanked: view.blanked,
                                           fb: Uint8Array.from(view.fb) }; },
    notify: () => {},
    log: (m) => sim.logs.push(m),
};

/* What rf-ctl does on the card, condensed to its observable effects. */
function runRfJobs() {
    for (const j of sim.pending.slice()) {
        if (vt.now < j.at)
            continue;
        sim.pending.splice(sim.pending.indexOf(j), 1);
        if (j.cmd === "scan") {
            sim.rfBlocked = false;         /* scan unblocks the radios */
            j.h.ok = sim.scanOk;
            j.h.out = sim.scanOk ? sim.aps.join("\n") + "\n" : "";
        } else if (j.cmd === "down") {
            if (sim.downFailsLeft > 0) {
                sim.downFailsLeft--;   /* radios stay up: the kill failed */
                j.h.ok = false;
            } else {
                sim.rfBlocked = true;
                sim.rfLinked = false;
                j.h.ok = true;
            }
        } else if (j.cmd === "connect") {
            const [ssid, psk] = String(j.stdinText).split("\n");
            sim.lastConnect = { ssid, psk };
            sim.rfLinked = psk === sim.correctPsk;
            j.h.ok = sim.rfLinked;
        }
        j.h.done = true;
    }
}

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
        runRfJobs();
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

/* Full 8x16 readback of one cell, straight out of the presented fb. */
function cellBits(row, col) {
    const b = [];
    for (let y = 0; y < 16; y++) {
        let v = 0;
        for (let x = 0; x < 8; x++)
            v |= sim.presented.fb[(row * 16 + y) * 128 + col * 8 + x] << x;
        b.push(v);
    }
    return b;
}

/* Identify a cell by matching it against the font and the 8x16 glyphs,
 * upright and inverted — so the JW screens can be asserted as text.
 * Inverted cells come back with a leading '*', glyphs as [NAME]. */
function decodeCell(row, col) {
    const got = cellBits(row, col);
    for (const inv of [false, true]) {
        for (let i = 0; i < PANEL.FONT8X8.length; i++) {
            const g = PANEL.FONT8X8[i];
            let eq = true;
            for (let y = 0; y < 16 && eq; y++) {
                const want = g[y >> 1];
                eq = got[y] === (inv ? (~want) & 0xFF : want);
            }
            if (eq)
                return (inv ? "*" : "") + String.fromCharCode(0x20 + i);
        }
        for (const [name, g] of Object.entries(PANEL.GLYPHS)) {
            let eq = true;
            for (let y = 0; y < 16 && eq; y++)
                eq = got[y] === (inv ? (~g[y]) & 0xFF : g[y]);
            if (eq)
                return (inv ? "*" : "") + "[" + name + "]";
        }
    }
    return "?";
}

function decodeCells(row, maxc = 16) {
    const out = [];
    for (let c = 0; c < maxc; c++)
        out.push(decodeCell(row, c));
    return out;
}

/* Cell tokens joined back into a string, inversion markers dropped and
 * trailing blanks trimmed — the readable form for JW assertions. */
function decodeRowGlyphs(row, maxc = 16) {
    return decodeCells(row, maxc).map(t => t.replace(/^\*/, ""))
                                 .join("").replace(/ +$/, "");
}

function invMask(row, maxc = 16) {
    return decodeCells(row, maxc).map(t => t.startsWith("*") ? 1 : 0).join("");
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
ok(s.rf_join === false, "boot without RF_JOIN=1 leaves JOIN WIFI unarmed");
ok(s.rf_state === "killed", "every card boots RF-KILLED");
ok(glyphCellPixels().join("") === expectedGlyphPixels('S').join(""),
   "reserved cell (row 3, col 15) shows the shield glyph (RF-KILLED)");

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

/* Strict absorption of A: pressed while blanked it wakes and is absorbed,
 * so the JOIN WIFI hold must restart after the wake — and on this card
 * RF_JOIN is off, so even a full 5 s hold does nothing. */
press(PANEL.KEY.A);                /* wakes, absorbed */
advance(6000);                     /* well past the 5 s RF hold */
s = panel.state();
ok(s.blanked === false, "A pressed while blanked wakes");
ok(s.screen === "PAGE" && s.rf_state === "killed",
   "5 s A hold on an unarmed card changes nothing (RF_JOIN=0)");
ok(glyphCellPixels().join("") === expectedGlyphPixels('S').join(""),
   "…glyph still the shield");
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

/* ERROR page: all input is dead except the button-B EVENT hold. */
press(PANEL.KEY.RIGHT); release(PANEL.KEY.RIGHT);
ok(panel.state().page === 0, "PAGE 0 ignores the joystick");
press(PANEL.KEY.A);
advance(6000);
release(PANEL.KEY.A);
ok(panel.state().page === 0 && panel.state().screen === "PAGE",
   "PAGE 0 ignores the A hold (no JOIN WIFI from a faulted card)");
{
    const before = sim.events;
    press(PANEL.KEY.B);
    advance(2200);                 /* the one exception: EVENT still works */
    release(PANEL.KEY.B);
    ok(sim.events === before + 1, "PAGE 0 still takes the button-B EVENT hold");
    advance(2200);                 /* let the EVENT flash expire */
}

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

/* PAGE 2: RIGHT pages to it, TMP is whole degrees from millidegrees. */
press(PANEL.KEY.RIGHT); release(PANEL.KEY.RIGHT);
advance(200);
s = panel.state();
ok(s.page === 2, "RIGHT from PAGE 1 shows PAGE 2");
/* 30566 mC -> 30.566 C -> rounds to 31 */
ok(decodeRow(0) === "TMP 31 C",
   `PAGE 2 row 0 renders "TMP 31 C" (got "${decodeRow(0)}")`);
ok(decodeRow(1) === "PWR OK",
   `PAGE 2 row 1 renders "PWR OK" (got "${decodeRow(1)}")`);
ok(decodeRow(2) === "" && decodeRow(3, 15) === "",
   "PAGE 2 rows 2-3 are reserved (empty)");
ok(glyphCellPixels().join("") === expectedGlyphPixels('S').join(""),
   "RF glyph shows on PAGE 2 too");

/* PWR precedence: under-voltage NOW beats the latched bit. */
sim.throttled = 0x10001;
advance(1200);
ok(decodeRow(1) === "PWR UV NOW",
   `bit 0 set renders "PWR UV NOW" (got "${decodeRow(1)}")`);
sim.throttled = 0x10000;
advance(1200);
ok(decodeRow(1) === "PWR UV SEEN",
   `bit 16 alone renders "PWR UV SEEN" (got "${decodeRow(1)}")`);
sim.throttled = 0;

/* Negative-safe rounding and read-failure placeholder (1 Hz cadence). */
sim.cpuTempMc = -10499;            /* -10.499 C -> -10, not -11 or -9 */
advance(1200);
ok(decodeRow(0) === "TMP -10 C",
   `-10499 mC renders "TMP -10 C" (got "${decodeRow(0)}")`);
sim.cpuTempMc = null;              /* sysfs read failure */
advance(1200);
ok(decodeRow(0) === "TMP ---",
   `temp read failure renders "TMP ---" (got "${decodeRow(0)}")`);
ok(panel.state().error === false, "temp read failure is not a health ERR");
sim.cpuTempMc = 30566;

/* ---------------------------------------------------- settings (PAGE 3+) --
 * One page per setting: the name left on line 1, the choices right-aligned
 * below it, the LIVE one under an inverted bar. UP/DOWN move the bar, and
 * the move itself is the change — there is no commit key.
 */
function pageTo(n) {               /* RIGHT until PAGE n is up */
    for (let i = 0; i < 8 && panel.state().page !== n; i++) {
        press(PANEL.KEY.RIGHT); release(PANEL.KEY.RIGHT);
        advance(200);
    }
}
press(PANEL.KEY.RIGHT); release(PANEL.KEY.RIGHT);
advance(200);
ok(panel.state().page === 3, "RIGHT from PAGE 2 shows PAGE 3");
ok(decodeRow(0) === "Speed Unit",
   `PAGE 3 names the setting as written, not in caps (got "${decodeRow(0)}")`);
ok(decodeRowGlyphs(1, 15) === "            MPH",
   `the live choice is right-aligned (got "${decodeRowGlyphs(1, 15)}")`);
ok(invMask(1, 15) === "111111111111111" && invMask(2, 15) === "000000000000000",
   `…and only its row wears the bar (got ${invMask(1, 15)}/${invMask(2, 15)})`);
ok(decodeRow(2) === "            KMH",
   `the other choice sits under it, same column (got "${decodeRow(2)}")`);
ok(decodeRow(3, 15) === "", "unused choice rows stay empty");
ok(glyphCellPixels().join("") === expectedGlyphPixels('S').join(""),
   "the settings bar stops short of the RF glyph cell");

/* The bar IS the value: DOWN moves it, PAGE 1's speed line follows, and
 * the choice is on the card before the key is even released. */
press(PANEL.KEY.DOWN); release(PANEL.KEY.DOWN);
advance(200);
ok(panel.state().settings[0].value === "KMH", "DOWN selects KMH");
ok(sim.settingsFile === "speed_unit=KMH\nalways_on=Off\n",
   `the choice is persisted immediately (got ${JSON.stringify(sim.settingsFile)})`);
press(PANEL.KEY.DOWN); release(PANEL.KEY.DOWN);
advance(200);
ok(panel.state().settings[0].value === "KMH",
   "DOWN at the end of the list clamps, it does not wrap");
pageTo(1);
ok(decodeRow(2) === "SPD 145 KMH",
   `PAGE 1 speed follows the setting (got "${decodeRow(2)}")`);
pageTo(3);
press(PANEL.KEY.UP); release(PANEL.KEY.UP);
advance(200);
ok(panel.state().settings[0].value === "MPH" && decodeRow(3, 15) === "",
   "UP puts it back to MPH; a two-choice page leaves the fourth row empty");

/* PAGE 4 — Always On disables AUTO-BLANK, and takes PAGE 0's burn-in
 * shift with it (a page that never blanks IS the burn-in case). */
pageTo(4);
ok(decodeRow(0) === "Always On",
   `RIGHT from PAGE 3 shows PAGE 4 (got "${decodeRow(0)}")`);
ok(decodeRowGlyphs(1, 15) === "            Off" && invMask(1, 15).endsWith("1"),
   `"Off" is the default and is the barred row (got "${decodeRowGlyphs(1, 15)}")`);
advance(10400);
ok(panel.state().blanked === true, "with Always On off, PAGE 4 still blanks");
press(PANEL.KEY.CENTER); release(PANEL.KEY.CENTER);   /* wake -> PAGE 1 */
advance(200);
pageTo(4);
press(PANEL.KEY.DOWN); release(PANEL.KEY.DOWN);
advance(200);
ok(panel.state().settings[1].value === "On", "DOWN selects On");
advance(20000);
s = panel.state();
ok(s.blanked === false, "Always On disables AUTO-BLANK");
ok(s.blank_in_ms === null, "…so there is no blank countdown left to report");
panel.setBurnStepMs(3000);
const burnYoff = panel.state().yoff;
advance(3200);
ok(panel.state().yoff !== burnYoff,
   "…and the burn-in shift takes over on a page that never blanks");
panel.setBurnStepMs(PANEL.BURN_STEP_MS);

/* A settings page is not special to anything else: a fault still steals
 * the screen, and PAGE 0 still ignores the joystick. */
sim.frontWriting = false;
advance(11000);
s = panel.state();
ok(s.error === true && s.page === 0,
   "a fault still takes a settings page to PAGE 0");
press(PANEL.KEY.DOWN); release(PANEL.KEY.DOWN);
advance(200);
ok(panel.state().settings[1].value === "On",
   "…and nothing can be changed from a faulted card");
sim.frontWriting = true;
sim.frontLast = vt.now;
advance(1400);
ok(panel.state().error === false && panel.state().page === 1,
   "clearing the fault returns to PAGE 1");

/* A restart reads the stored choices back (the panel's settings_load). */
{
    sim.settingsFile = "speed_unit=KMH\nalways_on=On\n";
    const p2 = PANEL.create(hw);
    p2.boot("MPH");                /* the card was BUILT for MPH... */
    const st = p2.state();
    ok(st.settings[0].value === "KMH" && st.settings[1].value === "On",
       "a restarted panel comes back with the stored choices, not the built-in ones");
    sim.settingsFile = "speed_unit=NAUTICAL\nnonsense=1\n";
    const p3 = PANEL.create(hw);
    p3.boot("MPH");
    ok(p3.state().settings[0].value === "MPH",
       "an unknown key or value leaves the installed default standing");
    sim.settingsFile = "speed_unit=MPH\nalways_on=Off\n";
}

/* Back to the defaults the rest of the file assumes. */
pageTo(4);
press(PANEL.KEY.UP); release(PANEL.KEY.UP);
advance(200);
ok(panel.state().settings[1].value === "Off" &&
   panel.state().blank_in_ms !== null,
   "Always On back off: the blank timer returns");

/* Cyclic paging over the full list. */
pageTo(1);
press(PANEL.KEY.LEFT); release(PANEL.KEY.LEFT);
advance(200);
ok(panel.state().page === 4, "LEFT from PAGE 1 wraps to the last page");
press(PANEL.KEY.RIGHT); release(PANEL.KEY.RIGHT);
advance(200);
ok(panel.state().page === 1, "RIGHT from the last page wraps to PAGE 1");
press(PANEL.KEY.RIGHT); release(PANEL.KEY.RIGHT);
advance(200);
ok(panel.state().page === 2, "…and PAGE 2 is where the next tests resume");

/* Lighting up always starts at PAGE 1: blank while on PAGE 2, wake. */
advance(10200);
ok(panel.state().blanked === true, "blanks while parked on PAGE 2");
press(PANEL.KEY.CENTER); release(PANEL.KEY.CENTER);
advance(200);
s = panel.state();
ok(s.blanked === false && s.page === 1,
   "waking from blank always lands on PAGE 1, not the last page");

/* No-fix placeholders: gpsd delivering but RMC status V. */
sim.gpsHaveFix = false;
advance(1400);
s = panel.state();
ok(s.error === false, "no-fix is NOT a GPS ERR (sentences still flowing)");
ok(s.gps.have_fix === false, "…but PAGE 1 will show LAT/LON/SPD ---");

/* ------------------------------------------------- JOIN WIFI (§3d) ----- */

/* An RF_JOIN=1 card: everything else identical, but the 5 s button-A hold
 * is armed. Fresh panel so the earlier card's state cannot leak in. */
sim.gpsHaveFix = true;
const jp = PANEL.create(hw);
const jstate = () => jp.state();

function jadvance(ms) {
    const end = vt.now + ms;
    while (vt.now < end) {
        vt.now = Math.min(vt.now + PANEL.TICK_MS, end);
        sim.frontLast = vt.now;
        sim.rearLast = vt.now;
        jp.gpsFix(sim.lat, sim.lon, sim.knots);
        runRfJobs();
        jp.tick();
    }
}
function jpress(k)   { jp.keyEvent(PANEL.KEY_GPIO[k], true); }
function jrelease(k) { jp.keyEvent(PANEL.KEY_GPIO[k], false); }
/* Type the key under the POSITION: a press released inside the 2 s mark. */
function jtap(k) { jpress(k); jadvance(200); jrelease(k); }

jp.boot("MPH", true);
jadvance(1400);
ok(jstate().rf_join === true && jstate().error === false,
   "RF_JOIN=1 card boots armed and healthy");

/* The 5 s hold: radios on, JW-1 opens immediately showing SCANNING. */
jpress(PANEL.KEY.A);
jadvance(5200);
ok(jstate().screen === "JW-1" && jstate().jw.scanning === true,
   "5 s A hold opens JW-1 and starts the scan");
ok(decodeRowGlyphs(1) === " SCANNING...",
   `JW-1 shows SCANNING... on line 2, indented one (got "${decodeRowGlyphs(1)}")`);
ok(decodeRowGlyphs(0) === "", "…and line 1 is empty while it scans");

/* The joystick is inert while the scan runs: there is no list to navigate
 * and nothing to back out to, so LEFT must not offer a fake cancel. */
jtap(PANEL.KEY.LEFT);
jadvance(200);
ok(jstate().screen === "JW-1" && jstate().jw.scanning === true,
   "LEFT during the scan does nothing — no dishonest exit");
jtap(PANEL.KEY.RIGHT);
jadvance(200);
ok(jstate().screen === "JW-1", "…and RIGHT cannot open JW-2 with no list yet");
jrelease(PANEL.KEY.A);

/* Scan lands: sorted alphabetically, deduped, truncated + LDOTS. */
jadvance(2200);
let js = jstate();
ok(js.jw.scanning === false && js.rf_state === "idle",
   "scan finished; RF-ENABLED but not associated");
ok(js.jw.ssid.join("|") ===
   "0123456789ABCD|aardvark-guest-network-5G|ExactlyFourteen|HomeNet|Zebra",
   `SSIDs sorted alphabetically and deduped (got ${js.jw.ssid.join("|")})`);
ok(decodeRowGlyphs(0) === "0123456789ABCD", "JW-1 row 0 is the first SSID");
ok(invMask(0) === "1111111111111111",
   "the selected SSID is an INVERTED full-width bar");
ok(decodeRowGlyphs(1) === "aardvark-guest[LDOTS]",
   `overlong SSID cut at 14 columns + one LDOTS (got "${decodeRowGlyphs(1)}")`);
ok(decodeCell(1, 15) === " ",
   "column 15 stays clear on JW-1 (LDOTS sits in column 14)");

/* The JW screens give up the reserved cell — JW-2's DELETE key needs
 * column 15, and both screens are uniform about it. */
ok(decodeCell(3, 15) === " ", "the JW screens suppress the RF glyph cell");

/* UP/DOWN scroll and clamp; the viewport follows past four entries. */
jtap(PANEL.KEY.UP);
ok(jstate().jw.sel === 0, "UP at the top of the list clamps");
for (let i = 0; i < 4; i++) jtap(PANEL.KEY.DOWN);
js = jstate();
ok(js.jw.sel === 4 && js.jw.top === 1,
   "DOWN past the fourth row scrolls the viewport by one");
ok(decodeRowGlyphs(3) === "Zebra" && invMask(3) === "1111111111111111",
   "the last SSID renders on the bottom row, inverted");
jtap(PANEL.KEY.DOWN);
ok(jstate().jw.sel === 4, "DOWN at the end of the list clamps");

/* LEFT exits JW-1 back to the pages — and backing out of the flow takes
 * the radios down with it: arming was only ever a means to joining. */
jtap(PANEL.KEY.LEFT);
jadvance(200);
ok(jstate().screen === "PAGE", "LEFT exits JW-1");
ok(cellBits(3, 15).join(",") === PANEL.GLYPHS["RF-IDLE"].join(","),
   "…bare antenna for the moment rf-ctl down is still running");
jadvance(2400);
ok(jstate().rf_state === "killed",
   "backing out of JW-1 kills the radios again (no join was completed)");
ok(cellBits(3, 15).join(",") === PANEL.GLYPHS.SHIELD.join(","),
   "…and the glyph returns to the shield");

/* Which means one hold — not two — gets straight back to JW-1. */
jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
jadvance(2200);
jtap(PANEL.KEY.DOWN); jtap(PANEL.KEY.DOWN); jtap(PANEL.KEY.DOWN);
ok(jstate().jw.ssid[jstate().jw.sel] === "HomeNet", "selected HomeNet");
jtap(PANEL.KEY.RIGHT);
jadvance(200);
js = jstate();
ok(js.screen === "JW-2", "RIGHT on JW-1 opens JW-2");
ok(js.jw.kr === 0 && js.jw.kc === 0, "POSITION starts at line 2's leftmost");
ok(decodeRowGlyphs(1) === "abcdefghijklmnop", "JW-2 line 2 is a-p");
ok(decodeRowGlyphs(2) === "qrstuvwxyz123456", "JW-2 line 3 is q-z then 1-6");
ok(decodeRowGlyphs(3) === "7890-_.!@#$%&[SPACE][CAPSv][DEL]",
   `JW-2 line 4 is 7-9 0, nine symbols, SPACE/CAPS/DELETE (got "${decodeRowGlyphs(3)}")`);
ok(invMask(1) === "1000000000000000", "the POSITION cell is INVERTED");
ok(decodeRowGlyphs(0) === "", "the input area starts empty");

/* Typing: a tap types the key under the POSITION. */
jtap(PANEL.KEY.A);                 /* 'a' */
jtap(PANEL.KEY.RIGHT); jtap(PANEL.KEY.RIGHT);
jtap(PANEL.KEY.A);                 /* 'c' */
jadvance(200);
ok(jstate().jw.psk === "ac", "short A presses type the key at the POSITION");

/* CAPS is a toggle: it flips the key caps and the characters typed. */
jp.keyEvent(PANEL.KEY_GPIO[PANEL.KEY.DOWN], true);   /* to line 4 */
jrelease(PANEL.KEY.DOWN);
jp.keyEvent(PANEL.KEY_GPIO[PANEL.KEY.DOWN], true);
jrelease(PANEL.KEY.DOWN);
for (let i = 0; i < 12; i++) jtap(PANEL.KEY.RIGHT);  /* col 2 -> col 14 */
jadvance(200);
ok(jstate().jw.kr === 2 && jstate().jw.kc === 14, "navigated to the CAPS key");
jtap(PANEL.KEY.A);
jadvance(200);
ok(jstate().jw.caps === true, "A on the CAPS key toggles CAPS on");
ok(decodeRowGlyphs(1) === "ABCDEFGHIJKLMNOP", "CAPS on: the key caps go upper");
ok(decodeCell(3, 14) === "*[CAPS^]",
   "the CAPS glyph flips to the up arrow (and is the inverted POSITION)");
ok(jstate().jw.psk === "ac", "CAPS itself types nothing");

/* DELETE is the last cell; SPACE the third from the right. */
jtap(PANEL.KEY.RIGHT);             /* -> DELETE */
jtap(PANEL.KEY.A);
jadvance(200);
ok(jstate().jw.psk === "a", "DELETE removes the last character");

/* Input area: <=16 chars in full, longer = one LDOTS + the last 15. */
jtap(PANEL.KEY.UP);                /* back to line 3 */
jadvance(200);
while (jstate().jw.psk.length < 16) { jtap(PANEL.KEY.A); }
jadvance(200);
ok(jstate().jw.psk.length === 16 && decodeRowGlyphs(0).length === 16,
   "16 characters are displayed in full");
ok(decodeCell(0, 0) !== "[LDOTS]", "…with no truncation mark");
jtap(PANEL.KEY.A); jtap(PANEL.KEY.A);
jadvance(200);
js = jstate();
ok(js.jw.psk.length === 18, "typed two more (18 characters held)");
ok(decodeCell(0, 0) === "[LDOTS]",
   "past 16 the first cell becomes LDOTS");
ok(decodeRowGlyphs(0).slice(-15) === js.jw.psk.slice(-15),
   "…followed by exactly the last 15 characters");

/* STAGING: a 2 s A hold inverts the input area; typing leaves it. */
jpress(PANEL.KEY.A);
jadvance(2200);
ok(jstate().jw.staged === true, "a 2 s A hold on JW-2 enters STAGING");
ok(invMask(0) === "1111111111111111",
   "STAGING renders the whole input area INVERTED");
jrelease(PANEL.KEY.A);
jadvance(200);
ok(jstate().jw.staged === true && jstate().jw.psk.length === 18,
   "releasing after the hold does not also type");
jtap(PANEL.KEY.A);
jadvance(200);
ok(jstate().jw.staged === false && jstate().jw.psk.length === 19,
   "typing anything more exits STAGING");

/* Wrong passphrase: CONNECTING, then back to PAGE 1 with RF still on but
 * unassociated — the glyph is the only report. */
while (jstate().jw.psk.length) {    /* clear via DELETE */
    jp.keyEvent(PANEL.KEY_GPIO[PANEL.KEY.DOWN], true); jrelease(PANEL.KEY.DOWN);
    break;
}
jstate();
{
    /* Drive to DELETE (line 4, last cell) and empty the field. */
    while (jstate().jw.kr !== 2) { jtap(PANEL.KEY.DOWN); }
    while (jstate().jw.kc !== 15) { jtap(PANEL.KEY.RIGHT); }
    while (jstate().jw.psk.length) { jtap(PANEL.KEY.A); }
    ok(jstate().jw.psk === "", "DELETE empties the input area");
}
/* Type the wrong PSK by hand: 'z' (line 3, column 9). */
while (jstate().jw.kr !== 1) { jtap(PANEL.KEY.DOWN); }
while (jstate().jw.kc !== 9) { jtap(PANEL.KEY.RIGHT); }
jtap(PANEL.KEY.A);
jadvance(200);
ok(jstate().jw.psk === "Z", "typed a wrong single-character passphrase");

jpress(PANEL.KEY.A); jadvance(2200); jrelease(PANEL.KEY.A);   /* stage */
jpress(PANEL.KEY.A); jadvance(2200);                          /* commit */
ok(jstate().screen === "CONNECTING", "a second 2 s hold starts the attempt");
ok(decodeRow(1) === " CONNECTING...",
   `CONNECTING sits on line 2, indented one (got "${decodeRow(1)}")`);
jrelease(PANEL.KEY.A);

/* Button B is NOT absorbed while CONNECTING; button A is. */
{
    const before = sim.events;
    jpress(PANEL.KEY.B);
    jadvance(2200);
    jrelease(PANEL.KEY.B);
    ok(sim.events === before + 1,
       "button B still marks an EVENT while CONNECTING");
}
jadvance(3000);
js = jstate();
ok(js.screen === "PAGE" && js.page === 1,
   "a finished attempt returns to PAGE 1 either way");
ok(js.rf_state === "idle" && js.jw.pskLen === 0,
   "wrong PSK: RF stays enabled, unassociated; the passphrase is wiped");
ok(cellBits(3, 15).join(",") === PANEL.GLYPHS["RF-IDLE"].join(","),
   "failure reads as the bare antenna — no text hint");

/* Right passphrase: the glyph gains its waves. */
jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);   /* kill RF */
jadvance(2400);
jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);   /* re-arm */
jadvance(2400);
while (jstate().jw.ssid[jstate().jw.sel] !== "HomeNet") jtap(PANEL.KEY.DOWN);
jtap(PANEL.KEY.RIGHT);
jadvance(200);
for (const ch of sim.correctPsk) {
    /* every character of "swordfish" lives on line 3 (q-z) or line 2 */
    const line2 = ch >= "a" && ch <= "p";
    const wantR = line2 ? 0 : 1;
    const wantC = line2 ? ch.charCodeAt(0) - 97 : ch.charCodeAt(0) - 113;
    while (jstate().jw.kr !== wantR) jtap(PANEL.KEY.DOWN);
    while (jstate().jw.kc !== wantC) jtap(PANEL.KEY.RIGHT);
    jtap(PANEL.KEY.A);
}
jadvance(200);
ok(jstate().jw.psk === sim.correctPsk,
   `typed the passphrase on the keyboard (got "${jstate().jw.psk}")`);
jpress(PANEL.KEY.A); jadvance(2200); jrelease(PANEL.KEY.A);
jpress(PANEL.KEY.A); jadvance(2200); jrelease(PANEL.KEY.A);
jadvance(3000);
js = jstate();
ok(sim.lastConnect.ssid === "HomeNet" && sim.lastConnect.psk === sim.correctPsk,
   "rf-ctl connect received the SSID and passphrase on stdin");
ok(js.rf_state === "link" && js.screen === "PAGE",
   "a successful join lands back on PAGE 1, associated");
ok(cellBits(3, 15).join(",") === PANEL.GLYPHS.WIFI.join(","),
   "success reads as the wireless glyph — the only report of the outcome");

/* Exit rules: button B leaves JW-1 without marking an EVENT; 10 s of no
 * input leaves too, and the page it returns to blanks straight away.
 * The hold is a toggle off ANY enabled state, associated included — so
 * reaching JW-1 from here costs a kill and a re-arm. */
jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
jadvance(2400);
ok(jstate().screen === "PAGE" && jstate().rf_state === "killed",
   "the A hold kills RF from the associated state too (no JW-1)");
jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
jadvance(2400);
ok(jstate().screen === "JW-1", "re-arming opens JW-1 again");
{
    const before = sim.events;
    jpress(PANEL.KEY.B);
    jadvance(2400);                /* well past the 2 s EVENT hold */
    jrelease(PANEL.KEY.B);
    ok(jstate().screen === "PAGE", "button B exits JW-1");
    ok(sim.events === before,
       "…and its EVENT function is absorbed while a JW screen is up");
    jadvance(2400);
    ok(jstate().rf_state === "killed", "a button-B exit kills the radios too");
}
jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
jadvance(2400);
ok(jstate().screen === "JW-1", "JW-1 up once more");
jadvance(10400);                   /* no input at all */
js = jstate();
ok(js.screen === "PAGE" && js.blanked === true,
   "10 s without input exits the JW screens and the page blanks at once");
jadvance(2400);
ok(js.blanked && jstate().rf_state === "killed",
   "…and the idle exit kills the radios as well — walking away leaves it dark");

/* A fault mid-flow is an exit too, and takes the radios with it.
 * The screen is blanked after that idle exit, so the wake press is
 * absorbed first (§3b) — the hold has to start from an awake screen. */
jtap(PANEL.KEY.CENTER);
jadvance(200);
ok(jstate().blanked === false, "woken, ready to hold A again");
jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
jadvance(2400);
ok(jstate().screen === "JW-1" && jstate().rf_state === "idle",
   "armed once more, JW-1 up");
sim.frontLast = 0;                 /* stop proving the front recorder */
{
    const end = vt.now + 12000;    /* jadvance, minus the writer feed */
    while (vt.now < end) {
        vt.now = Math.min(vt.now + PANEL.TICK_MS, end);
        sim.rearLast = vt.now;
        jp.gpsFix(sim.lat, sim.lon, sim.knots);
        runRfJobs();
        jp.tick();
    }
}
js = jstate();
ok(js.error === true && js.screen === "PAGE",
   "a health fault drops JW-1 for PAGE 0");
ok(js.rf_state === "killed",
   "…and that exit kills the radios too (a faulted card joins nothing)");

/* …but button B still gets you out of a running scan — the joystick being
 * inert must not become a trap — and that exit still takes the radios. */
{
    jadvance(1600);                /* let the forced fault above clear —
                                      PAGE 0 swallows the A hold entirely */
    ok(jstate().error === false, "recovered from the forced fault");
    jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
    jadvance(400);                 /* scan takes 2 s: still running */
    ok(jstate().screen === "JW-1" && jstate().jw.scanning === true,
       "a scan is in flight");
    const before = sim.events;
    jpress(PANEL.KEY.B); jadvance(200); jrelease(PANEL.KEY.B);
    jadvance(200);
    ok(jstate().screen === "PAGE", "button B exits mid-scan");
    ok(sim.events === before, "…still marking no EVENT");
    jadvance(5000);                /* cancel, then the owed down */
    ok(jstate().rf_state === "killed",
       "…and a cancelled scan does not stall the kill behind it");
}

/* Getting the radios down is retried, not fired once and assumed: it is the
 * privacy-preserving direction, so "probably off" is not good enough. */
{
    jtap(PANEL.KEY.CENTER); jadvance(200);        /* wake if blanked */
    jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
    jadvance(2400);
    ok(jstate().screen === "JW-1", "armed for the retry check");

    sim.downFailsLeft = 2;         /* first two kills fail outright */
    jtap(PANEL.KEY.LEFT);          /* exit -> owes a down */
    jadvance(200);
    ok(jstate().rf_kill_pending === true, "the exit records the debt");
    jadvance(9000);                /* three jobs at ~2 s each */
    ok(sim.downFailsLeft === 0, "…and both failures really were consumed");
    ok(jstate().rf_state === "killed",
       "a failed rf-ctl down is retried until the radios are actually down");
    ok(jstate().rf_kill_pending === false, "…then the debt is settled");
}

/* But not retried forever — a card that truly cannot go dark says so on
 * the glyph rather than spawning rf-ctl until the end of time. */
{
    jtap(PANEL.KEY.CENTER); jadvance(200);
    jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
    jadvance(2400);
    ok(jstate().screen === "JW-1", "armed for the give-up check");

    sim.downFailsLeft = 99;        /* rf-ctl down can never succeed */
    jtap(PANEL.KEY.LEFT);
    jadvance(20000);
    const spent = 99 - sim.downFailsLeft;
    ok(spent === 3, `it gives up after RF_KILL_TRIES attempts (spent ${spent})`);
    ok(jstate().rf_kill_pending === false, "…and stops asking");
    ok(jstate().rf_state === "idle",
       "…leaving the glyph honest about radios it could not turn off");
    sim.downFailsLeft = 0;
    jtap(PANEL.KEY.CENTER); jadvance(200);   /* 20 s of idle blanked it */
    jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
    jadvance(2400);
    ok(jstate().rf_state === "killed", "button A still works after giving up");
}

/* Every full-screen status message shares one shape: line 2, indented by
 * a single column. Checked together so they cannot drift apart again. */
{
    const at = (fn) => { fn(); return decodeRow(1); };
    /* EVENT, from a plain page */
    jtap(PANEL.KEY.CENTER);
    jadvance(200);
    const ev = at(() => { jpress(PANEL.KEY.B); jadvance(2200);
                          jrelease(PANEL.KEY.B); });
    ok(ev === " EVENT", `EVENT renders " EVENT" (got "${ev}")`);
    jadvance(2200);                /* let the flash expire */

    /* EVENT ERROR — the health log unwritable, marker lost */
    sim.eventLogWritable = false;
    const everr = at(() => { jpress(PANEL.KEY.B); jadvance(2200);
                             jrelease(PANEL.KEY.B); });
    ok(everr === " EVENT ERROR",
       `an unwritable log renders " EVENT ERROR" (got "${everr}")`);
    sim.eventLogWritable = true;
    jadvance(2200);

    /* NO NETWORKS, from a scan that comes back empty */
    const savedAps = sim.aps;
    sim.aps = [];
    jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
    jadvance(2400);
    const nn = decodeRow(1);
    ok(nn === " NO NETWORKS", `empty scan renders " NO NETWORKS" (got "${nn}")`);
    sim.aps = savedAps;
    jtap(PANEL.KEY.LEFT);
    jadvance(2400);

    /* RF ERROR, from a scan that fails outright */
    sim.scanOk = false;
    jpress(PANEL.KEY.A); jadvance(5200); jrelease(PANEL.KEY.A);
    jadvance(2400);
    const rferr = decodeRow(1);
    ok(rferr === " RF ERROR", `failed scan renders " RF ERROR" (got "${rferr}")`);
    sim.scanOk = true;
    jtap(PANEL.KEY.LEFT);
    jadvance(2400);

    ok([ev, everr, nn, rferr, " CONNECTING...", " SCANNING..."]
        .every(t => t.startsWith(" ") && !t.startsWith("  ")),
       "all six status messages share the one-column indent");
}

console.log(`\n${checks - failures}/${checks} checks passed`);
process.exit(failures ? 1 : 0);
