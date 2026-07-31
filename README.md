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

- **Dual-camera H.264 recording** — 1080p30 front (CSI camera), 720p30 rear
  (Pi Zero UVC gadget), hardware-encoded, 60-second segments, ~110–120 h of
  retention on a 256 GB card
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
  mode (writable, ssh, persistent logs) exists for bench work, and the
  panel always shows which one you're looking at
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
| `cli/` | PC-side tools — `dashberry-install` (card builder) and `dashberry-cli` (catalog/render/gpx); neither is ever installed on the card |
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

# bench/development card (writable, ssh as dash)
sudo cli/dashberry-install --debug dash:changeme \
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
| `--debug NAME:PASS` | build a DEBUG card — writable OS, SSH with this user, journal kept and persistent, `--wifi` profile kept; without it the card is PRODUCTION — read-only OS, no user, no SSH, all network credentials wiped (sealed) |
| `--wifi SSID:PSK` | run the first boot over Wi-Fi instead of Ethernet; setup-only on a production card (the installer wipes the profile, DHCP leases and logs before the OS locks read-only), kept on a debug card, which rejoins the LAN every boot |
| `--wifi-country CC` | two-letter regulatory domain, required with `--wifi` (a stock image keeps Wi-Fi blocked without one) |

Both bypass options default to off; the default mode is PRODUCTION.

## Usage

### In the vehicle

Operation is hands-off: ignition on → recording within ~20 s; ignition off →
hard power cut, absorbed by design. The panel shows live
latitude/longitude/speed/free-space when healthy, blanks after 10 s, and
switches to a static error screen (`FRONT`, `REAR`, `GPS`, `TIME`,
`SD FULL`) when a component fails. LEFT/RIGHT cycle to a second page with
SoC temperature and firmware power status; holding B for ~2 s marks the
moment as an event, on any screen the panel is currently showing. The
bottom-right glyph shows the install mode: shield = production (sealed),
wireless = debug card.

To archive footage, pull the card and copy `/data`. The read-only OS makes
removal safe at any time.

### Processing footage

Runs on a PC against a copy of `/data`. Each per-boot session directory is
one *drive*.

```console
# list drives: start, duration, segment counts, GPS coverage
cli/dashberry-cli --data ~/dashcam-copy catalog

# add distance, average/top speed and the event markers you pressed B for
cli/dashberry-cli --data ~/dashcam-copy catalog --verbose

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
```

Times are relative to the drive's start throughout; `render` and `gpx` take
`--anchor` (assert the true wall-clock start, repairing a wrong-RTC drive)
and `--tz-offset` to display local time instead. `--units MPH|KMH` selects
the speed units shown by `catalog --verbose` and `render --annotate`.

Requires Python 3 and `ffmpeg`/`ffprobe`.

## License

DashBerry is released under the **GNU General Public License v3**. All
userland and kernel software used and produced here is free software. The
one exception is outside the project's control: the Raspberry Pi boot/GPU
firmware is a closed binary blob, as on essentially every practical SBC and
commercial dashcam. DashBerry's privacy claims (no cloud, no accounts, no
telemetry, nothing to connect to on a production card) hold without
qualification.
