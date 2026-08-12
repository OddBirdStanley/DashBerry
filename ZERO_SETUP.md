# ZERO_SETUP.md — rear camera card

The rear camera is a **Pi Zero W + IMX219 wide clone running
[showmewebcam](https://github.com/showmewebcam/showmewebcam)**, appearing to the
Pi 4 as an MJPEG UVC webcam.

That card is **not built by this tree** — `dashberry-install` never touches it.
This file is the complete list of changes to make to a **fresh showmewebcam
image**, so the card can be reproduced after a reflash. Without it a reflash
silently reverts the rear camera, and the only symptom is a worse picture.

Rationale for the **1640×922@30** mode choice is in PLAN.md **rev 8.2** (it
replaced rev 8.1's 1920×1080@30, which the Pi 4 could not encode at 30 fps);
recording-side settings are in `sw/etc/dashberry.conf`.

Everything below is on the **FAT `/boot` partition** — put the card in any PC.
No console or network needed.

---

## 1. `/boot/camera.txt` — camera

This file ships. Keep every line it comes with and **add one**:

```
compression_quality=<VALUE>
```

The JPEG quantizer, and the only control that governs the source's picture at
every resolution. The driver default is **30**, which is low.

> ⚠ **The value used on the current card is not recorded.** Read it back and fill
> it in here: `v4l2-ctl -d /dev/video0 -C compression_quality`

Do **not** touch the shipped `video_bitrate=25000000`. It is
`V4L2_CID_MPEG_VIDEO_BITRATE`, an **H.264** control; the gadget streams MJPEG, so
it is inert. (It is the origin of the retracted "~25 Mbps MJPEG floor" claim.)

Note that the shipped `auto_exposure_bias=12` already brightens the source, and
`REAR_GAMMA=1.4` on the Pi 4 brightens it again.

## 2. `/boot/config.txt` — GPU

```
gpu_mem=256
```

Raised from the default on a 512 MB Zero W. Not to be confused with the Pi 4's
own `gpu_mem=256` (`boot/config-snippet.txt`), which is unrelated.

## 3. `/boot/video_formats.txt` — USB gadget modes

**The card must advertise `1640x922`** — that is the mode `rear-rec` asks
`v4l2src` for, and a `v4l2src` caps request the gadget does not advertise fails
the pipeline outright (rear-rec exits, systemd restarts it, no segments, REAR
faults on PAGE 0).

> ⚠ **UNVERIFIED: whether the shipped `/etc/video_formats.txt` in the rootfs
> already lists `1640x922`.** Check the card *before* changing anything —
> `v4l2-ctl -d /dev/video0 --list-formats-ext | grep 1640x922`:
>
> - **Present** → leave `/boot/video_formats.txt` absent. Nothing to do.
> - **Absent** → create `/boot/video_formats.txt`. It is an *override* that
>   **replaces the list wholesale**, so it must carry every mode that is still
>   wanted, not just the new one:
>
>   ```
>   mjpeg 1640 922
>   mjpeg 1920 1080
>   mjpeg 1280 720
>   ```
>
>   (`1920x1080` and `1280x720` are kept only so a bench comparison can still
>   shoot them; neither is recorded any more.)
>
> The 2026-08-12 survey *did* create an override on this card carrying
> `mjpeg 1640 1232` — which suggests 1640-wide modes are not in the shipped
> list. **Delete that file if it is still there**, whichever branch above
> applies: `1640x1232` must never be advertised.

**Never advertise `1640x1232`, `2048x1152` or `2560x1440`.** Each hangs the
entire USB gadget — camera *and* serial console — until the Zero is power-cycled,
and on the car a Pi 4 reboot will not do that (both boards share the 12 V
injection). An entry here is a promise to everything that enumerates the device,
including `rootscripts/rear-source`, whose mode ladder shoots every advertised
mode. Note `1640x922@30` is fine and `1640x1232@30` is not — the hang is the
Zero failing to sustain that readout, not anything about the 1640 width.

## 4. `/boot/enable-serial-debug` — USB gadget console

**Keep the file.** It ships, and its presence is what adds the CDC-ACM console
alongside the camera on the same cable. showmewebcam's README suggests deleting
it after setup; this project keeps it, because it is the only way into the
read-only rootfs and the device lives inside a locked car.

```sh
ls -l /dev/serial/by-id/
sudo screen /dev/ttyACM0 115200      # login root / root
```

The console is a function on the same gadget as the camera, so if the camera
wedges the console wedges too. Unplug, wait 3 s, replug — the Zero is stateless.

---

## Checking a card

```sh
v4l2-ctl -d /dev/video0 -C compression_quality      # matches §1
v4l2-ctl -d /dev/video0 --list-formats-ext          # 1640x922 present (the
                                                    # recorded mode),
                                                    # 1640x1232 absent
REAR_BITRATE=8000000 cam/rear-modetest.sh /dev/video0 wide30
                                                    # PC-side; shoots the
                                                    # exact rear-rec chain
```
