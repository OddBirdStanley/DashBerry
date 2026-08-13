# zero/ — the rear camera card

The rear camera is a **Pi Zero W + IMX219 wide clone**. It runs a
[showmewebcam](https://github.com/showmewebcam/showmewebcam) built by *this*
tree, and it appears to the Pi 4 as an **H.264 UVC webcam** with a control
port on the same cable.

This replaces `ZERO_SETUP.md`, which was a checklist for hand-modifying a
stock image. That document existed because the card was not built here and a
reflash silently reverted the rear camera, with no symptom but a worse
picture. The card is a build artifact now, so the checklist is a build script.

```sh
zero/build.sh                                  # → zero/out/dashberry-zero-<ver>.img.xz
sudo cli/dashberry-zero --flash /dev/sdX       # write it
sudo cli/dashberry-zero --check                # ask the card what it is
```

---

## 1. Why the Zero encodes

The Pi 4 could not. `INVESTIGATE-REAR-ENCODE.md` has the evidence; the short
version is that `openh264enc` runs one slice, one slice is one thread, and one
thread on that box does ~65,000 macroblocks/s on a rolling scene — measured
twice, within 1.5% of each other across a 2× bitrate change, which is also how
we know the bitrate was never the knob. 720p30 needs 108,000 and 1640×922@30
needs 179,220. **Every mode this project ever considered wanted more than one
core, 720p30 included.**

The Zero's VideoCore does 1080p30 in hardware and 1640×922@30 is ~45 MPix/s
against its ~62. Moving the encode there deletes ~1.2 cores of Pi 4 work —
both the decode and the encode thread — and drops USB traffic from tens of
Mbps of MJPEG to ~1 MB/s.

**This is the fourth deliberate deviation from the official image**, alongside
the three the card already carried: advertised resolutions, USB peripheral
mode, and memory allocation.

## 2. What the image contains

| | |
|---|---|
| **Kernel** | `raspberrypi/linux` **`rpi-6.16.y`**, repinned from showmewebcam's `6af8ae32` (5.10.11) |
| **Format** | H.264 over UVC, via the kernel's `framebased` configfs format |
| **Control** | `rear-ctld` on a second CDC-ACM function (`/dev/ttyGS1`) |
| **Console** | the first CDC-ACM function, unchanged — still a login prompt |
| **Modes** | `overlay/etc/video_formats.txt` |

**The kernel repin is the whole reason this is not a five-line patch.** In
5.10.11, `drivers/usb/gadget/function/uvc_configfs.c` reads:

```c
static const char * const uvcg_format_names[] = { "uncompressed", "mjpeg", };
```

No `framebased`, no H.264, no `guidFormat` — **there is no configfs directory
the gadget could advertise H.264 in**. Frame-based format support was accepted
upstream in September 2024 (`7b5a5895`) and lands in the RPi tree at
`rpi-6.13.y`. We take `rpi-6.16.y`: it needs **no kernel patch at all**, and it
still carries `drivers/staging/vc04_services/bcm2835-camera`, the legacy MMAL
driver this image depends on for the sensor and for every encoder control.

> **UNVERIFIED at the time of writing.** No ARMv6 Zero W has been built or
> booted on `rpi-6.16.y` here, showmewebcam's buildroot pin predates 6.x host
> tooling and may itself need bumping, and the legacy-camera firmware path
> (`start_x=1`, MMAL) has not been confirmed on that branch. **The documented
> fallback is `KERNEL_BRANCH=rpi-6.12.y` plus a backport of `7b5a5895`** —
> 6.12 is RPi's protected long-term branch and the line `bcm2835-v4l2` is
> known good on. Try it the moment 6.16 costs more than an afternoon.

Two userspace changes ride along, both anchored in `edits.sh`:

- **`uvc-gadget`** picks its V4L2 fourcc from the *first character* of the
  configfs format instance name — `m` → MJPEG, `u` → YUYV, and nothing else.
  A `h` → `V4L2_PIX_FMT_H264` branch is added.
- **`multi-gadget.sh`** parses `video_formats.txt` with
  `grep -E "^(mjpeg|uncompressed)…"`, so an `h264` line is silently dropped.
  The keyword is added, and h264 lines become `framebased/` instances.

## 3. The division of ownership

**The card is identical on every unit and holds no per-installation state.**
That is the design, not an accident of the build:

| Owned by | What |
|---|---|
| **The Zero, irreducibly** | the advertised mode list, the streaming format, the gadget itself — `video_formats.txt` is read at gadget-construction time, before any host exists to ask |
| **The Pi 4, pushed every session** | flips, bitrate, GOP/I-period, profile, exposure bias |

Everything in the second row is a `dashberry-install` flag or a
`/etc/dashberry.conf` value, carried across by `rear-ctl` as
`rear-rec.service`'s `ExecStartPre`. **No installer option is bound to this
card.** Reflash it and the Pi 4 heals it on the next start.

`rear-ctl` obeys four rules, each earned:

1. **Re-apply on every enumeration.** The Zero is stateless across replug; a
   boot-time push is worthless.
2. **Order: enumerate → push → verify → start capture.** Bitrate and the flips
   cannot be changed once the encoder is streaming.
3. **Verify by read-back, fault on mismatch.** The failure mode is silent —
   wrong settings, no error, a worse picture nobody notices until the footage
   matters.
4. **Bootstrap cannot move.** Hence the split above.

### The control protocol

Line based, on `/dev/ttyGS1` (the Pi 4 sees `/dev/rear-ctl`; a bench PC sees
the second `ttyACM`):

```
VERSION            -> DASHBERRY-ZERO <version> <kernel>
LIST               -> the real control surface + every advertised format
GET <control>      -> <value>            (menu controls answer with the label)
SET <control> <v>  -> OK | ERR <reason>
APPLY              -> OK
```

It shells out to `v4l2-ctl`, so it reaches **every** control on the capture
device. That matters: the seven controls the UVC gadget forwards to the host
are `uvc-gadget`'s fixed processing-unit map, not this camera's capability —
`camera.txt`'s `compression_quality` and `auto_exposure_bias` appear nowhere in
it, and its `red_balance` reports `min=0 max=0`, i.e. mapped but unwired. UVC
also has no standard control for flip and none for encoder bitrate, so the
things the Pi 4 actually needs to say could never have ridden that path.

## 4. What moved off the Pi 4

- **`INVERT_REAR`** → sensor `hflip`/`vflip` in the ISP. Free, and it replaces
  a full-frame `videoflip` copy of every frame. The front and rear finally
  agree: both flip at capture.
- **`REAR_GAMMA=1.4`** → **dropped**, replaced by `REAR_EXPOSURE_BIAS` at the
  source. Same problem (the rear reads dark at night, the front does not),
  better place: gamma lifted shadow *noise* along with shadow signal and then
  spent encoder bitrate on it. It is **not the same knob renamed** — gamma's
  curve is pinned at black *and* white, so one static value could serve day and
  night with no way to clip a bright sky. Exposure bias moves the whole
  metering target. Judge a real night segment.
- **`REAR_BITRATE` / `REAR_GOP`** → the Zero's `video_bitrate` and
  `h264_i_period`. The profile is **high** now, not `openh264`'s baseline-only
  — worth ~10–20% of the bitrate for nothing.
- **`camera.txt`'s shipped `video_bitrate=25000000`** is **removed by the
  build**. On an MJPEG card it was inert (an H.264 control on a gadget that
  never encoded H.264 — the origin of the retracted "~25 Mbps MJPEG floor").
  **The moment this image encodes it becomes live**, and it would quietly make
  the rear a 25 Mbps camera at ~11 GB/h.

## 5. Modes — undecided, deliberately

`video_formats.txt` advertises 1640×922, 1920×1080 and 1280×720 in H.264, plus
two MJPEG modes as a diagnostic fallback any laptop can read.

Now that the Pi 4 pays nothing to record, the choice is **purely optical
again** and is to be made **by eye**, off `cam/rear-modetest.sh` footage of a
parked, detailed target — not from arithmetic:

- **1640×1232@30** — the full 4:3 field, the widest this lens gives, and the
  mode worth having. **Not advertised yet.** It hung the entire gadget under
  MJPEG — camera *and* console, until a power cycle, which on the car a Pi 4
  reboot cannot deliver, since both boards share the 12 V injection. The
  theory is that ~48 Mbps of MJPEG plus the encode was the thing it could not
  sustain and that H.264 at ~1 MB/s lifts it. **That is bandwidth arithmetic,
  not a measurement.** Test it on the bench. If the hang is the sensor
  readout, it stays banned.
- **1640×922@30** — what `dashberry.conf` records today. Known to stream.
- **1920×1080@30** — the unbinned crop: 2× the detail per degree for 41.5% of
  the horizontal field. Reverted 2026-08-12 *only* because the Pi 4 could not
  encode it. That objection has expired.

`2048×1152` and `2560×1440` hang the gadget too, and H.264 does nothing about
it: the Zero cannot sustain the unbinned 3280×2464 readout plus an ISP
downscale.

## 6. The console stays

The first CDC-ACM function remains a login prompt (`root`/`root`), and
`/boot/enable-serial-debug` stays. showmewebcam's README suggests deleting it
after setup; this project keeps it, because it is the only way into a
read-only rootfs on a device that lives in a locked car.

```sh
ls -l /dev/serial/by-id/
sudo screen /dev/ttyACM0 115200
```

The console is a function on the same gadget as the camera, so if the camera
wedges the console wedges too. Unplug, wait 3 s, replug — the Zero is
stateless.

## 7. Checking a card

```sh
sudo cli/dashberry-zero --check          # version, controls, advertised formats
cam/rear-modetest.sh                     # shoot a mode through the real chain
```

`--check` is what the old "Checking a card" checklist became. On the Pi 4 the
same conversation is `rear-ctl check`.
