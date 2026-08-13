# ZERO_SETUP.md — rear camera card

The rear camera is a **Pi Zero W + IMX219 wide clone running
[showmewebcam](https://github.com/showmewebcam/showmewebcam)**, appearing to the
Pi 4 as an MJPEG UVC webcam.

That card is **not built by this tree** — `dashberry-install` never touches it.
This file is the complete list of changes to make to a **fresh showmewebcam
image**, so the card can be reproduced after a reflash. Without it a reflash
silently reverts the rear camera, and the only symptom is a worse picture.

The rear records **1280x720@30** as of 2026-08-13, reverted from the 1920x1080@30
that PLAN.md **rev 8.1** had selected on 2026-08-12. That survey's findings still
stand — 1080p is the sharper mode on the centre of the frame, and 720p is the
weakest mode the gadget offers — so the reasoning is worth reading before
changing this back; what changed is the decision, not the evidence. Recording-side
settings and the full trade are in `sw/etc/dashberry.conf`.

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

**Leave this file absent.** It is an *override* that does not ship; when it is
missing the gadget uses `/etc/video_formats.txt` in the read-only rootfs, whose
list already contains the `1280x720` mode this project records. An override
**replaces the list wholesale**, so creating one can only remove modes.

> ⚠ If a `video_formats.txt` exists on `/boot`, **delete it.** One was created
> during the 2026-08-12 bench survey and carried `mjpeg 1640 1232`.

**Never advertise `1640x1232`, `2048x1152` or `2560x1440`.** Each hangs the
entire USB gadget — camera *and* serial console — until the Zero is power-cycled,
and on the car a Pi 4 reboot will not do that (both boards share the 12 V
injection). An entry here is a promise to everything that enumerates the device,
including `rootscripts/rear-source`, whose mode ladder shoots every advertised
mode.

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
v4l2-ctl -d /dev/video0 --list-formats-ext          # 1280x720 present,
                                                    # 1640x1232 absent
cam/rear-modetest.sh /dev/video0 720p30             # PC-side; shoots the
                                                    # exact rear-rec chain
```
