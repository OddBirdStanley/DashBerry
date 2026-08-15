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

`build.sh` is a **buildroot** build driven by upstream's own
`build-showmewebcam.sh`: it fetches a toolchain and every package source, so
the first run takes hours and several GB. `zero/work/` is kept between runs,
so a second build is incremental. `BOARD=` defaults to `raspberrypi0w`.

### Building it on your machine

showmewebcam pins **buildroot 2021.02.8**, so this compiles 2021 sources with
whatever toolchain you have. That gap is where every build failure so far has
come from, and none of them looked like a version problem:

| Host | What breaks |
|---|---|
| cmake ≥ 4 | dropped pre-3.5 policy minimums; buildroot's lzo 2.10 declares one |
| gcc ≥ 14 | implicit-declaration, incompatible-pointer-types and int-conversion became errors |
| gcc ≥ 15 | defaults to C23, where `void f()` means `void f(void)` |

The gcc 14 change is the dangerous one, because it breaks **configure probes**,
not just compiles. fakeroot decides `setgroups()`'s argument type with a probe
that calls `puts()` without `<stdio.h>`; on a new host that probe fails for an
unrelated reason, configure writes `#define SETGROUPS_SIZE_TYPE unknown`, and
the build dies much later on a type that does not exist. Nothing in that chain
mentions the compiler.

**The build gates on the kernel config before it packages an image.** A
renamed CONFIG symbol is dropped silently by `olddefconfig`, and the first time
that happened it cost a card that flashed cleanly and then did nothing at all —
`CONFIG_MMC_BCM2835_SDHOST` became `CONFIG_MMC_BCM2835`, the SD driver vanished,
and the kernel panicked before USB init. `build.sh` now refuses to package an
image whose kernel lacks any boot- or function-critical option, and names what
each one breaks.

**Check your host before committing to a multi-hour build:**

```sh
CHECK_HOST_ONLY=1 zero/build.sh
```

It prints your gcc/g++/cmake/make/perl/python3 versions, names any known-hostile
one, shows the exact flags it will compensate with, and stops. Those flags are
**probed, not assumed** — each is offered to your compiler first and dropped
with a note if rejected, so the workaround cannot itself break a host with an
older gcc or with clang.

**If a build fights back**, the surer footing is a host whose toolchain
predates the changes above — Debian bookworm's gcc 12 and cmake 3.25 need none
of these workarounds at all. The workarounds are compensation, not immunity.

The manifest beside the built image records the gcc version, the cmake version
and the exact `HOST_CFLAGS` used, so a card that misbehaves can be traced back
to the environment that built it.

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

**This is the fourth deliberate deviation from the official image**, and the
build carries all four — the three the card already had were hand-edits that a
reflash silently lost, which is the whole reason `ZERO_SETUP.md` existed:

| Deviation | Where it lives now |
|---|---|
| Advertised resolutions | `overlay/etc/video_formats.txt` |
| **USB peripheral mode** | `dtoverlay=dwc2,dr_mode=peripheral`, appended by `edits.sh` to `post-image.sh`'s boot-config block |
| Memory allocation | `gpu_mem=256`, same block |
| H.264 encode | the kernel repin + the gadget changes below |
| **Radio silence** | Wi-Fi and Bluetooth built out of the kernel, disabled in the device tree, no firmware shipped — see below |

**`dr_mode=peripheral` is not cosmetic.** Upstream appends a bare
`dtoverlay=dwc2`, which leaves the controller in **OTG**, where the port's role
is decided by the ID pin in the cable. A micro-USB converter or right-angle
adapter that grounds ID tells the Zero to be a *host* — and it then never
enumerates as a camera at all, with nothing on either end saying why. The BOM
has two such adapters in the rear cable run. This board is only ever a
peripheral, so saying so is both correct and deterministic: the role stops
depending on which adapter is in the run that day.

## 2. What the image contains

| | |
|---|---|
| **Kernel** | `raspberrypi/linux` **`rpi-6.18.y`**, repinned from showmewebcam's `6af8ae32` (5.10.11) |
| **Format** | H.264 over UVC, via the kernel's `framebased` configfs format |
| **Control** | `rear-ctld` on a second CDC-ACM function (`/dev/ttyGS1`), a systemd unit ordered after the gadget comes up |
| **Console** | the first CDC-ACM function (`/dev/ttyGS0`), unchanged — `post-build.sh` puts an autologin getty there |
| **Modes** | `overlay/etc/video_formats.txt` |

**The kernel repin is the whole reason this is not a five-line patch.** In
5.10.11, `drivers/usb/gadget/function/uvc_configfs.c` reads:

```c
static const char * const uvcg_format_names[] = { "uncompressed", "mjpeg", };
```

No `framebased`, no H.264, no `guidFormat` — **there is no configfs directory
the gadget could advertise H.264 in**. Frame-based format support was accepted
upstream in September 2024 (`7b5a5895`) and lands in the RPi tree at
`rpi-6.13.y`. We take `rpi-6.18.y`: it needs **no kernel patch at all** for
H.264, and it still carries `drivers/staging/vc04_services/bcm2835-camera`, the
legacy MMAL driver this image depends on for the sensor and for every encoder
control.

**6.18 and not 6.16, which this first built on.** 6.13 reworked f_uvc to size
its USB requests from the frame interval, and 6.16 carries two bugs in that new
code — an unclamped `req_payload_size` that memcpys past a request buffer on a
large frame, and a `bInterval` treated as linear where dwc2 treats it as the
exponent it is. Both fixes are `Cc: stable`
([`2edc1acb1a25`](https://github.com/torvalds/linux/commit/2edc1acb1a25),
[`010dc57cb516`](https://github.com/torvalds/linux/commit/010dc57cb516),
[`56135c0c60b0`](https://github.com/torvalds/linux/commit/56135c0c60b0)) and
both landed after 6.16 went end-of-life, so 6.16 will never receive them.
`INVESTIGATE-REAR-CORRUPTION.response.md` has the reasoning; `zero/edits.sh`
section 1 has the short version.

**6.18 needs one kernel patch that has nothing to do with UVC**, and it is the
one that actually fixes the rear corruption. `vchiq`'s `create_pagelist()` walks
a kernel bulk buffer with the pointer cast to `unsigned int *`, so it strides
16384 bytes per page instead of 4096 — page 0 is correct and every page after it
names a page four times too far into the buffer. VideoCore duly DMAs each
encoded frame's second 4 KB to buffer offset 16384, and userspace reads 4096
real bytes followed by zeros with the frame length still reported correctly, so
nothing downstream can tell. Measured straight off `/dev/video0` with the USB
gadget not involved: **45.7% of captured bytes are non-zero, ~4092 real bytes
per frame**; in the recorded stream, 92% of P slices carry exactly 4096 live
bytes, IDR slices carry exactly 20453 (= 16384 + 4096), and interior zero runs
are exactly 12288 (= 16384 − 4096) bytes long. The bug arrived with the
`bulk_params` refactor that moved `create_pagelist()` into `vchiq_core.c` and is
present in `rpi-6.16.y`, `rpi-6.17.y` and `rpi-6.18.y`; `rpi-6.12.y` and 5.10
are clean, which is why stock showmewebcam never showed it. See
`patches/linux-custom/0002-vchiq-walk-bulk-pages-by-bytes-not-by-ints.patch`.

> **UNVERIFIED at the time of writing.** No ARMv6 Zero W has been built on
> `rpi-6.18.y` here — 6.16 is the branch this image was built and booted on.
> showmewebcam's buildroot pin predates 6.x host tooling and may itself need
> bumping. **Fallbacks, in order:** `KERNEL_BRANCH=rpi-6.16.y` is known good
> and is safe as long as `/boot/uvc-interval` stays at 1; below that,
> `KERNEL_BRANCH=rpi-6.12.y` plus a backport of `7b5a5895` — 6.12 is RPi's
> protected long-term branch, the line `bcm2835-v4l2` is known good on, and its
> f_uvc predates the whole request rework and so cannot exhibit any of it.
>
> **On the 6.12 fallback, drop `patches/linux-custom/0002`.** 6.12 already has
> the correct byte-stride page walk, in `vchiq_arm.c` rather than `vchiq_core.c`,
> so the patch will not apply and the build will stop. On 6.16 and 6.17 it does
> apply (the line sits at `vchiq_core.c:1593` there rather than 1590, which
> `patch` absorbs as an offset).

### Tuning knobs on the card

Three files on the boot partition, read at start-up, so a sweep costs a card
edit rather than an image rebuild:

| file | default | what it does |
| --- | --- | --- |
| `/boot/uvc-nbufs` | 8 | `-n` to uvc-gadget, the V4L2 buffer count. Upstream default is 2, the minimum the option accepts. |
| `/boot/uvc-interval` | **3** | the isochronous endpoint's `bInterval`. **The only knob that safely reduces the request rate** — it divides `nreq` and the service interval by the same factor, so dwc2's target-frame clock still tracks wall-clock. At 3 the Zero submits 2000 requests/s instead of 8000 and the endpoint still offers 68 KB/frame (16 Mbps). |
| `/boot/uvc-overspeed` | 1 — **leave it there** | divisor on the frame interval reported to `f_uvc`. Anything above 1 breaks dwc2, see below. Kept only because it produced the measurement that explained the failure. |

`nreq` is not a bandwidth budget. `dwc2_gadget_incr_frame_num()` advances the
endpoint's target frame by `hs_ep->interval` **per request submitted**, and
`dwc2_hsotg_start_req()` drops any request whose target frame has already passed
with `-ENODATA`. Submit fewer requests than there are service intervals and the
target falls behind wall-clock, after which every request is dropped on arrival:

| requests/s at 30 fps | vs the 8000/s dwc2 expects | result |
| --- | --- | --- |
| 8010 (`overspeed 1`) | matches | 30.6 fps |
| 4020 (`overspeed 2`) | half | 6 fps, minute-long freezes |
| 360 (fixed-size requests) | 22× behind | stream dead |

So `nreq = interval / (2^(bInterval-1) × 1250)` is **one request per service
interval**, and the 100.1% duty cycle is mandatory rather than unfortunate.
There is no slack to be won by planning fewer requests. Raising `bInterval`
is different in kind: it divides `nreq` *and* the service interval by the same
factor, so the clock still tracks and the submission rate genuinely falls.

**`bInterval` is the lever, and 3 is the measured answer.** At 3 the endpoint is
serviced every 500 µs, `nreq` falls to 67, and the Zero submits 2000 requests/s
instead of 8000 — four times less pressure on a 1 GHz ARM11 — while dwc2's
target-frame clock still advances in step. Measured 2026-08-15, 720p30 H.264
with motion in frame:

| | bInterval 1 | bInterval 3 |
| --- | --- | --- |
| truncated frames | 96 of 689 (13.9%) | **3 of 690 (0.4%)** |
| arriving in bursts of | 6 | 1, isolated |
| decoder errors | 125 | 4 |
| delivered rate | 30.6 fps | 30.01 fps |
| real payload | 2.56 Mbps | 3.85 Mbps |
| largest frame | 24,383 B | 37,849 B (ceiling 67,804) |

6 is too far: 9 slots per frame is a 2.2 Mbps ceiling and the frames do not fit,
which is what made it look worse than 1 when it was tried early on.

The pin is a GitHub **tarball**, not a git ref, and `edits.sh` resolves the
branch to a SHA before substituting it — a card you cannot rebuild byte for
byte is not a card you can debug. `KERNEL_SHA=` pins one directly.

**showmewebcam's own kernel patch is dropped, and that is safe only because it
is obsolete.** `patches/linux-custom/0001-linux-enable-more-video-controls.patch`
widens two descriptor bitfields that `f_uvc.c` hardcoded — camera terminal
`bmControls` `{2,0,0}` → `{10,0,0}`, processing unit `{1,0}` → `{219,4}` —
and those are what make the seven UVC controls visible to a host at all. Since
~5.15 both are **writable configfs attributes**
(`control/terminal/camera/default/bmControls`,
`control/processing/default/bmControls`; verified in `rpi-6.16.y` and
`rpi-6.18.y`'s
`uvc_configfs.c`), so `multi-gadget.sh` writes the identical values from
userspace and the host-visible control surface is unchanged. DashBerry does
not need those controls — `rear-ctl` reaches *every* v4l2 control over the
control port — but the bench rootscripts drive them from the Pi 4 and would
otherwise break silently.

Userspace changes, all in `edits.sh` except the first:

- **`uvc-gadget`** picks its V4L2 fourcc from the *first character* of the
  configfs format instance name — `m` → MJPEG, `u` → YUYV, and nothing else.
  A `h` → `V4L2_PIX_FMT_H264` branch is added. This one is a real patch file
  (`zero/patches/`), because `piwebcam.mk` fetches uvc-gadget from a pinned
  SHA rather than vendoring it; buildroot applies `package/<pkg>/*.patch`, and
  `edits.sh` refuses to build if that pin has moved out from under the patch.
  A second patch (`0010`) gives the gadget its **frame interval**, via
  `VIDIOC_S_PARM` on `/dev/video1`. That is not cosmetic: `video->interval` is
  what f_uvc divides by the endpoint service period to decide how many
  isochronous slots to cut a frame across, its only writer is that ioctl, and
  this daemon never called it — so the gadget planned every frame off its
  15 fps default, cut it into 534 requests of 91 bytes, and lost the whole
  remainder of the frame to the first missed slot. It is the fix for the
  corruption in `INVESTIGATE-REAR-CORRUPTION.md`.
- **`multi-gadget.sh`** needs four changes, and only the first is obvious:
  its parser greps `^(mjpeg|uncompressed)`, so an `h264` line is silently
  dropped; `config_frame` writes `dwMaxVideoFrameBufferSize`, which the
  frame-based format does not have (it carries `dwBytesPerLine` instead); the
  streaming header hardcodes symlinks to `mjpeg/m` and `uncompressed/u`, so a
  `framebased/h` format would exist in configfs and never be advertised; and
  the control port needs a second ACM function.
- **`post-image.sh`** appends `gpu_mem=256`. It cannot go in the rootfs
  overlay — `/boot` is a separate FAT partition assembled by genimage, and
  fstab mounts it over anything the overlay put there.

## 2b. Radio silence

The Pi Zero W has a BCM43438 — 2.4 GHz Wi-Fi and Bluetooth on one die. This
board sits in a locked car recording continuously, and has exactly one
interface it is meant to speak on: the USB gadget. Both radios are attack
surface and power draw for no function, and the Pi 4 beside it already boots
RF-KILLED as a project rule.

**Three independent layers**, because fail-closed means no single mistake
turns a radio back on:

1. **The drivers are not built.** `board/linux-base.config` loses
   `CONFIG_BRCMFMAC`, `CONFIG_CFG80211`, `CONFIG_MAC80211`, `CONFIG_BT` and the
   whole `CONFIG_BT_*` family, and gains explicit `is not set` lines. The code
   to drive the radio is not in the kernel, so nothing can load it and no
   userspace toggle can undo it. This is the layer that cannot be argued with —
   and it is why this is a kernel-config change and not an rfkill service:
   showmewebcam ships no `rfkill` binary, and a runtime kill is a thing that
   can fail to run.
2. **The hardware is off in the device tree.** `dtoverlay=disable-wifi` and
   `dtoverlay=disable-bt` in `config.txt`, so the SDIO link to the Wi-Fi side
   and the UART to the Bluetooth side are never brought up. Both `.dtbo` files
   ship with `rpi-firmware` — verified present at the revision buildroot pins.
3. **No firmware ships.** There is no `/lib/firmware/brcm` in this rootfs, so
   even a driver that somehow appeared could not bring the part out of reset.

Verified by running the kernel's own `olddefconfig` over the patched config:
the symbols stay off after dependency resolution, and `USB_CONFIGFS_F_UVC`,
`USB_CONFIGFS_ACM` and `VIDEO_BCM2835` are untouched. (`CONFIG_WIRELESS=y`
survives — it is the now-empty menu symbol, with no driver under it. So do
`CONFIG_BRCM_CHAR_DRIVERS` and `CONFIG_BTREE`, which are the VideoCore drivers
and a data structure, neither of them a radio.)

One side effect worth knowing: `disable-bt` frees the PL011 (`ttyAMA0`) for
the 40-pin header, which is where `BR2_TARGET_GENERIC_GETTY_PORT` points. The
console this project uses is the USB one (`ttyGS0`), so that is a bonus rather
than a change of plan.

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
the second `ttyACM`). The functions are linked UVC → acm.usb0 → acm.usb1, so
the control port is USB interface 4 — which is what the Pi 4's udev rule
matches on, and why the link order in `multi-gadget.sh` is not incidental:

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
  `h264_i_frame_period`. The profile is **high** now, not `openh264`'s baseline-only
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

## 8. Reading a card that has wedged

Section 6 notes that the console dies with the camera. That is worth stating
more precisely, because it decides which of these you need: `uvc-gadget`
answers the UVC class requests on **ep0**, so when it stops answering, ep0
stalls for *every* function on the gadget. The camera, the login console and
the control port all go at the same instant — and the journal that would say
why lives in tmpfs and dies with the next power cycle.

Note that the card still **enumerates** perfectly in that state. `f_uvc`
answers standard requests out of the kernel, straight from configfs, so the
descriptors are correct whether or not `uvc-gadget` parsed anything at all.
The descriptors and the daemon's format table are two independent readings of
the same tree. "It enumerates" is not evidence that the daemon is healthy.

Three ways to read one, cheapest first.

**The SD card.** Create `/boot/enable-uvc-trace`, boot, provoke the failure,
pull the power, put the card in a PC and read `/boot/uvc-trace.txt`. It holds
`uvc-webcam`'s journal and the gadget-related kernel lines, re-snapshotted
whenever they change — so the last write lands seconds before the wedge and
nothing else is needed. Post-mortem, and up to `UVC_TRACE_INTERVAL` (5 s)
stale. Off unless the marker is there: it writes to a FAT partition that a
dashcam can lose power at any moment, which is the same bargain
`/boot/enable-boot-report` makes.

**Mini-HDMI.** `cmdline.txt` carries `console=tty1` and `quiet` is gone, so a
monitor shows the boot with no image change. It shows kernel messages only —
`uvc-gadget`'s own output goes to the journal — so this diagnoses the driver
and gadget layers, not the daemon.

**The UART.** `enable_uart=1`, `console=ttyAMA0,115200` and
`dtoverlay=disable-bt` are all set, so the PL011 is on GPIO 14/15 and there is
a getty on it. This is the only one that owes nothing to `dwc2` or
`libcomposite`, and the only one that is **live** — `journalctl -fu
uvc-webcam` before provoking the failure shows the last line before the wedge.
Wiring: USB-TTL GND to pin 6, its RX to pin 8 (Zero TXD), its TX to pin 10
(Zero RXD), 115200 8N1.
