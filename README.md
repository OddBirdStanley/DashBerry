# DashBerry

**Open-source, privacy-hardened, minimal dashcam for Raspberry Pi.**

DashBerry is a self-built, two-camera vehicle dashcam running exclusively
free software. It records front and rear video with a synchronized 5 Hz GPS
track, stores everything locally on a microSD card, and transmits nothing:
a production card is sealed at install time — it carries no network
credentials, no user account and no remote-access service, so there is
nothing for the radios to do and nothing to log into. There is no cloud,
no account, no companion app, and no telemetry.

## Features

- **Dual-camera H.264 recording** — 1080p30 front (CSI camera, hardware-encoded)
  and 1080p30 rear (Pi Zero UVC gadget, software-encoded), 60-second MPEG-TS
  segments, ~110–120 h of retention on a 256 GB card. Setting up the rear
  camera's card: [ZERO_SETUP.md](ZERO_SETUP.md).
- **5 Hz GPS logging** — raw NMEA per drive; Doppler-derived speed accurate
  to well under 1 km/h
- **Crash-only design** — ignition off is a hard power cut, and the system
  is built to absorb one on every single drive; a cut costs ~1–2 s of
  footage and GPS data, not tens of seconds
- **Read-only OS** — the operating system never modifies itself, so cutting
  power or pulling the card is safe at any moment
- **OLED status panel** — 128×64 glance display that reports what actually
  matters — footage really accumulating, GPS really flowing — rather than
  whether software claims to be running; auto-blanks when all is well
- **One-button event marking** — holding B for ~2 s stamps the drive's
  health log and flashes a confirmation, so an incident can be found later
  without scrubbing hours of footage
- **Sealed production install** — the shipped card has no Wi-Fi
  credentials, no login account and no ssh; its only interfaces are the
  OLED panel and physically pulling the card. A separate DEBUG install
  mode (writable, ssh, persistent logs) exists for bench work
- **JOIN WIFI, opt-in and never persistent** — a card built with `--auth`
  keeps the sealed read-only OS but adds an account and an on-panel way to
  reach it: hold A for 5 s and the OLED becomes an SSID picker and an
  on-screen keyboard. Nothing about it survives a reboot — the radios come
  back blocked and the passphrase is gone — so the privacy default is
  still "dark", just no longer permanent. The bottom-right glyph reports
  the live radio state at a glance
- **Minimal software** — the card carries only what recording requires;
  all heavier tooling runs on your PC and never ships in the vehicle

## Architecture

A Raspberry Pi 4 is the hub. Four peripherals attach to it: the front CSI
camera over a ~2 m CSI-over-HDMI extender, the rear camera — a Pi Zero W
presenting itself as a UVC gadget — over a 5 m data-only USB extension, a
USB GPS receiver, and the 128×64 OLED panel (with joystick and buttons) on
a 40-pin GPIO ribbon. Everything is stored on a single 256 GB microSD card,
partitioned into a read-only OS volume and a `/data` footage volume. Power
comes from an ignition-switched 12 V→5 V buck converter, with separate
branches for the Pi and each camera.

One session directory per ignition cycle groups the video segments, the
NMEA log and the panel's health log into a "drive", consumed offline by the
PC-side CLI.

## Repository

| Path | Contents |
|---|---|
| `sw/` | everything that ships on the card: recorder scripts, systemd units, config snippets, and `dashberry-panel` (the one compiled C program) |
| `cli/` | PC-side tools — `dashberry-install` (card builder) and `dashberry-cli` (catalog/render/gpx/csv); neither is ever installed on the card |
| `demo/` | browser visualizer of the panel's UI state machine, for exercising the interaction spec without hardware |

## Hardware

### Required

| Component | Notes |
|---|---|
| Raspberry Pi 4 (2 GB) | used units work fine |
| Passive aluminum case for Pi 4 | Flirc / Argon NEO |
| Camera Module 3 Wide (front) | IMX708, 120° HFOV, HDR |
| CSI-over-HDMI extension kit, ~2 m | Arducam-style |
| Front camera enclosure w/ ball mount | commercial or 3D-printed (ASA/PETG) |
| USB GPS receiver | u-blox VK-162 class |
| microSD, 256 GB high-endurance | SanDisk High Endurance |
| Adafruit 128×64 OLED Bonnet | product #3531, open hardware |
| 40-pin GPIO ribbon (~50 cm) + 1→2 splitter | connectorized, no crimps |
| Panel enclosure | 3D-printed (ASA/PETG) |
| 12 V→5 V buck converter, 5–6 A | screw-terminal, synchronous, adjustable |
| Mini 2-way fuse block + 3 A / 2 A fuses | per-branch fault isolation |
| USB-C power pigtail | buck → Pi 4 |
| Add-a-circuit fuse tap + inline fuse | match the vehicle's fuse format |
| Install consumables | 3M VHB / Dual Lock, 18 AWG pair, ring terminal, loom, ties |

### Rear camera stack (omit with `--bypass-rear`)

| Component | Notes |
|---|---|
| Raspberry Pi Zero W | runs [showmewebcam](https://github.com/showmewebcam/showmewebcam) (open firmware, UVC gadget) |
| IMX219 wide camera module | standard Zero-footprint board |
| Official Pi Zero case (camera lid) | sealed camera brick |
| microSD, 8 GB | written once, stateless |
| USB 2.0 active extension, 5 m | data only |
| Right-angle micro-USB adapters ×2 | strain relief |
| Micro-USB power pigtail + lever nuts | terminates the 5 V injection run |

### Recommended

| Component | Notes |
|---|---|
| DS3231 RTC module + coin cell | correct timestamps from boot until GPS lock; omit with `--bypass-time` (GPS then disciplines the clock) |

### Tools

| Tool | Notes |
|---|---|
| Multimeter or test light | identifying an ignition-switched circuit |
| Plastic trim tools | panel and pillar removal |
| Fish tape | routing behind trim |
| Wire strippers / crimper | 18 AWG runs and ring terminal |

## Installation

### Prerequisites

- A Linux PC (the installer checks for the standard disk tools it needs and
  tells you if anything is missing)
- A stock **Raspberry Pi OS Lite (64-bit, Trixie)** image, downloaded
  manually
- A microSD card of **16 GB or larger**
- Network for the Pi's first boot (it downloads its packages once):
  Ethernet by default, or a Wi-Fi network staged with `--wifi` — on a
  production card the credentials are wiped before the OS locks read-only;
  a debug card keeps them

### Building the card

```console
# production card (sealed)
sudo cli/dashberry-install raspios-trixie-arm64-lite.img.xz /dev/sdX

# production card + JOIN WIFI (sealed OS, but the panel can join a
# network on demand and you can ssh in as dash while it is up)
sudo cli/dashberry-install --auth dash:changeme --wifi-country US \
    raspios-trixie-arm64-lite.img.xz /dev/sdX

# bench/development card (writable, ssh as dash)
sudo cli/dashberry-install --debug --auth dash:changeme \
    raspios-trixie-arm64-lite.img.xz /dev/sdX
```

The installer displays the target device and requires the device path to be
typed back before writing anything — it will not touch a disk you have not
explicitly confirmed. This one command turns the stock image into a
finished DashBerry card: a small OS partition that ends up locked
read-only, with all remaining space becoming the `/data` footage partition.
Plug the card into the Pi with Ethernet connected (or none at all if you
staged `--wifi`); the first boot completes setup on its own and reboots.
From then on the system records on every ignition — no keyboard, monitor,
or manual configuration is ever needed.

| Option | Effect |
|---|---|
| `--bypass-rear` | install without the rear camera; the panel never flags it as missing |
| `--bypass-time` | install without the DS3231 RTC; the clock is set from GPS after each boot instead |
| `--root-size N` | OS partition size in GiB (default 8, minimum 8) |
| `--auth NAME:PASS` | create this login account and enable SSH. On its own (no `--debug`) the card stays PRODUCTION — read-only OS, no stored network credentials — but the panel's JOIN WIFI screen is armed, so you can bring the card onto a network by hand and ssh in; requires `--wifi-country` |
| `--debug` | build a DEBUG card — writable OS, journal kept and persistent, `--wifi` profile kept so it rejoins the LAN every boot. Requires `--auth`; JOIN WIFI is not armed (the card already knows a network) |
| `--wifi SSID[:PSK]` | run the first boot over Wi-Fi instead of Ethernet; setup-only on a production card (the installer wipes the profile, DHCP leases and logs before the OS locks read-only), kept on a debug card. Omit `:PSK` (or leave it empty) for an OPEN network — the confirmation summary says `OPEN - no passphrase` before anything is written, so a forgotten passphrase is caught there rather than at a first boot that never associates |
| `--wifi-country CC` | two-letter regulatory domain, required with `--wifi` and on a JOIN WIFI card (a stock image keeps Wi-Fi blocked without one) |
| `--invert-front AXES`, `--invert-rear AXES` | correct how that camera is mounted: a comma-separated list of `v` (mounted upside down) and `h` (its image comes out mirrored) — `v`, `h` or `v,h`, either case, each axis once. The video is flipped at capture, so recordings are already upright and un-mirrored |

Both bypass options default to off. With neither `--auth` nor `--debug` the
card is a SEALED production card — no account, no SSH, no radios.

## Usage

### In the vehicle

Operation is hands-off: ignition on → recording within ~20 s; ignition off →
hard power cut, absorbed by design. The panel shows live
latitude/longitude/speed/free-space when healthy, blanks after 10 s, and
switches to a static error screen (`FRONT`, `REAR`, `GPS`, `TIME`,
`SD FULL`) when a component fails. LEFT/RIGHT cycle through three more
pages: SoC temperature and firmware power status, then two settings —
**Speed Unit** (MPH/KMH) and **Always On** (keep the panel lit instead of
blanking after 10 s). On a settings page UP/DOWN pick the choice; the
highlighted line is the live one, and the card remembers it across
reboots. Holding B for ~2 s marks the
moment as an event, on any screen the panel is currently showing. The
bottom-right glyph reports the radios: shield = blocked (how every card
boots), bare antenna = on but not connected, antenna with waves =
associated.

To archive footage, pull the card and copy `/data`. The read-only OS makes
removal safe at any time.

### Joining a Wi-Fi network (cards built with `--auth`)

Everything happens on the panel; nothing is stored.

1. Hold **A** for 5 seconds. The radios come up and the screen lists the
   networks in range, sorted alphabetically. **UP/DOWN** scroll.
2. **RIGHT** opens the passphrase screen: an on-screen keyboard with the
   joystick moving between keys and a tap of **A** typing the highlighted
   one. The last three keys are space, caps and delete.
3. Hold **A** for 2 seconds to arm the entry (the passphrase line inverts),
   then hold **A** for 2 seconds again to connect. Typing anything more
   disarms it, so a mistyped passphrase cannot be sent by accident.
4. The screen returns to the normal display. The glyph tells you whether it
   worked — waves for connected, a bare antenna for not.

**LEFT** (once the list is up) or **B** (anywhere, including while it is
still scanning) backs out; so does ten seconds of not touching it — and **backing out switches the radios off again**,
so walking away mid-way leaves the card dark rather than transmitting.
The radios only stay on once an attempt has actually been made, and a
5 second hold turns them off from there. A reboot does it for you too: the
passphrase you typed was never written to the read-only OS, so the card
always comes back up dark.

### Processing footage

Runs on a PC against a copy of `/data`. Each per-boot session directory is
one *drive*.

```console
# list drives: start, duration, segment counts, GPS coverage
cli/dashberry-cli --data ~/dashcam-copy catalog

# add distance, average/top speed and the event markers you pressed B for
cli/dashberry-cli --data ~/dashcam-copy catalog --verbose

# just one drive (same columns, skips the work for all the others)
cli/dashberry-cli --data ~/dashcam-copy catalog --drive 20260721-1830-0042

# render a clip — the continuous boot-to-shutdown timeline: footage holes
# show "No Signal", GPS trouble is labeled from the health log; --annotate
# burns time/position/speed; --camera both-prio-front adds the rear camera
# picture-in-picture (near-transparent re-encode; --from/--to count from boot)
cli/dashberry-cli --data ~/dashcam-copy render \
    --drive 20260721-1830-0042 --camera front \
    --from 00:12:00 --to 00:14:30 --annotate -o incident.mp4

# export the GPS track (GPX 1.0, native speed element)
cli/dashberry-cli --data ~/dashcam-copy gpx \
    --drive 20260721-1830-0042 -o track.gpx

# the same track as a spreadsheet: one row per GPS fix, with SoC temperature
# joined on from the health log and your button-B presses flagged
cli/dashberry-cli --data ~/dashcam-copy csv \
    --drive 20260721-1830-0042 -o track.csv
```

Times are relative to the drive's start throughout; `render`, `gpx` and `csv`
take `--anchor` (assert the true wall-clock start, repairing a wrong-RTC
drive) and `--tz-offset` to display local time instead. `--units MPH|KMH`
selects the speed units shown by `catalog --verbose`, `render --annotate` and
the `csv` `speed_mph`/`speed_kmh` column.

`csv` columns are `timestamp, epoch, lat, lon, speed_mph|speed_kmh, speed_ms,
temp_c, event`. `speed_ms` is always present, so a consumer never has to know
which `--units` produced the file. `temp_c` is the most recent reading from
the health log's 10 s heartbeat and is left EMPTY rather than guessed where
that log has nothing within 30 s — every row on a drive recorded before the
panel logged temperature, and any row inside a logging gap. `event` is `1` on
the fix nearest each button-B press.

Requires Python 3 and `ffmpeg`/`ffprobe`.

## License

DashBerry is released under the **GNU General Public License v3**. All
userland and kernel software used and produced here is free software. The
one exception is outside the project's control: the Raspberry Pi boot/GPU
firmware is a closed binary blob, as on essentially every practical SBC and
commercial dashcam. DashBerry's privacy claims (no cloud, no accounts, no
telemetry, nothing to connect to on a sealed card) hold without
qualification. On a `--auth` card the radios exist but stay blocked until
somebody physically holds a button on the panel, and nothing they learn is
written to disk.
