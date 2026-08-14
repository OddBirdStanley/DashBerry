#!/usr/bin/env bash
# edits.sh — turn a stock showmewebcam checkout into the DashBerry Zero.
#
# Called by build.sh with the checkout directory as $1. Every change is
# ANCHORED: it finds an exact string in upstream, fails loudly if that string
# is not there, and only then rewrites it. A failed anchor names the upstream
# assumption that moved and what it was for, instead of "hunk #2 failed".
#
# The exception is the one change that IS a patch file: uvc-gadget is fetched
# by buildroot from a pinned git SHA rather than vendored in this checkout, so
# there is no source here to edit. Buildroot applies package/<pkg>/*.patch to
# the fetched source, which is the correct idiom, and the patch was generated
# against that exact SHA rather than written by hand.
set -euo pipefail

SMW=${1:?usage: edits.sh <showmewebcam-checkout>}
HERE=$(cd "$(dirname "$0")" && pwd)

CFG="$SMW/configs/config"                  # merged into every board defconfig
PIWEBCAM="$SMW/package/piwebcam"
OVERLAY="$SMW/rootfs"                      # BR2_ROOTFS_OVERLAY, applied after
                                           # packages install, so our files win

say() { printf '  %s\n' "$*"; }
die() { printf '\nedits.sh: %s\n\n' "$*" >&2; exit 1; }

# anchor <file> <fixed-string> <what-it-is-for>
anchor() {
    [ -f "$1" ] || die "expected file missing: ${1#"$SMW"/}
    ($3)
  Upstream layout has changed. Read the tree and update edits.sh."
    grep -qF -- "$2" "$1" || die "anchor not found in ${1#"$SMW"/}:
    \"$2\"
    ($3)
  Upstream has moved. Do NOT loosen this check — read the file, work out what
  replaced it, and update edits.sh so the next build is still honest."
}

# ---------------------------------------------------------------------------
# 1. KERNEL — repin off 5.10.11.
#
# showmewebcam fetches raspberrypi/linux as a GitHub TARBALL at
# 6af8ae321a801a4e20183454c65eb0d23069d8ac = Linux 5.10.11, and in that tree
# drivers/usb/gadget/function/uvc_configfs.c has:
#
#     static const char * const uvcg_format_names[] = { "uncompressed", "mjpeg", };
#
# No framebased, no H264, no guidFormat: there is no configfs directory the
# gadget could advertise H.264 in, so the whole design is blocked on that one
# array. Frame-based format support was accepted upstream in Sept 2024
# (commit 7b5a5895) and reaches the RPi tree at rpi-6.13.y.
#
# We take rpi-6.16.y, which needs NO kernel patch and still carries
# drivers/staging/vc04_services/bcm2835-camera — the legacy MMAL driver this
# image depends on for the sensor AND for the encoder controls (video_bitrate,
# h264_i_frame_period, compression_quality, auto_exposure_bias).
#
# The branch is resolved to a SHA here, not left as a branch name: buildroot's
# $(call github,...) will happily fetch a moving branch, and a card you cannot
# rebuild byte for byte is not a card you can debug.
#
# UNVERIFIED, and this is the risk in the whole image: no ARMv6 Zero W has
# been built or booted on 6.16 here, board/linux-base.config was written for
# 5.10, and showmewebcam's buildroot submodule predates 6.x host tooling.
# Fallback: KERNEL_BRANCH=rpi-6.12.y (RPi's protected branch) plus a backport
# of 7b5a5895.
# ---------------------------------------------------------------------------
KERNEL_BRANCH=${KERNEL_BRANCH:-rpi-6.16.y}

repin_kernel() {
    anchor "$CFG" "BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION" "the kernel pin"
    local old sha
    old=$(sed -n 's/.*linux,\([0-9a-f]\{40\}\)).*/\1/p' "$CFG" | head -n 1)
    [ -n "$old" ] || die "cannot read the current kernel SHA out of configs/config.
  Upstream may have switched away from \$(call github,raspberrypi,linux,SHA)."

    sha=${KERNEL_SHA:-}
    if [ -z "$sha" ]; then
        say "resolving raspberrypi/linux $KERNEL_BRANCH"
        sha=$(git ls-remote https://github.com/raspberrypi/linux.git "refs/heads/$KERNEL_BRANCH" | cut -f1)
        [ -n "$sha" ] || die "no such branch in raspberrypi/linux: $KERNEL_BRANCH
  Pass KERNEL_SHA=<sha> to pin one directly."
    fi
    say "kernel → $KERNEL_BRANCH @ ${sha:0:12} (was ${old:0:12}, Linux 5.10.11)"
    sed -i "s/$old/$sha/g" "$CFG"
    echo "$sha" > "$SMW/.dashberry-kernel-sha"

    # Kernel headers were pinned to 5.10 to match. AS_KERNEL follows whatever
    # kernel is being built, which is the only answer that stays correct
    # across a repin — and it sidesteps an old buildroot not knowing 6.16 as a
    # headers version at all.
    if grep -q '^BR2_KERNEL_HEADERS_5_10=y' "$CFG"; then
        say "  kernel headers → AS_KERNEL (were pinned to 5.10)"
        sed -i 's/^BR2_KERNEL_HEADERS_5_10=y/BR2_KERNEL_HEADERS_AS_KERNEL=y/' "$CFG"
    fi

    # showmewebcam's kernel patch is written against 5.10 and will not apply.
    # It is also OBSOLETE on this branch, which is the only reason dropping it
    # is safe: patches/linux-custom/0001-linux-enable-more-video-controls.patch
    # exists to widen two descriptor bitfields that f_uvc.c hardcoded —
    # camera-terminal bmControls {2,0,0} -> {10,0,0} and processing-unit
    # bmControls {1,0} -> {219,4}. Those are what make the seven UVC controls
    # (brightness, contrast, saturation, sharpness, ...) visible to the host at
    # all. Since ~5.15 both are WRITABLE CONFIGFS ATTRIBUTES —
    #   control/terminal/camera/default/bmControls
    #   control/processing/default/bmControls
    # (verified in rpi-6.16.y's uvc_configfs.c: uvcg_default_camera_bm_controls
    # _store / uvcg_default_processing_bm_controls_store, newline-separated
    # bytes) — so multi-gadget.sh sets the identical values from userspace and
    # the host-visible control surface is unchanged. DashBerry itself does not
    # need those controls (rear-ctl uses the control port and reaches every
    # v4l2 control, not the seven the gadget forwards), but the bench
    # rootscripts drive them from the Pi 4 and would otherwise break silently.
    if grep -q '^BR2_LINUX_KERNEL_PATCH=' "$CFG"; then
        say "  dropping BR2_LINUX_KERNEL_PATCH — obsolete on >= 5.15, replaced"
        say "    by configfs bmControls writes in multi-gadget.sh:"
        ls "$SMW/patches/linux-custom" 2>/dev/null | sed 's/^/      /' || true
        sed -i '/^BR2_LINUX_KERNEL_PATCH=/d' "$CFG"
    fi
}

# ---------------------------------------------------------------------------
# 2. uvc-gadget — teach it the H.264 fourcc, via a buildroot patch.
#
# piwebcam.mk fetches peterbay/uvc-gadget at a pinned SHA, so there is nothing
# in this checkout to sed. Buildroot applies package/<pkg>/*.patch to the
# fetched source; the patch in zero/patches/ was generated against that same
# SHA, so if the pin moves, the patch fails to apply and the build stops —
# which is what should happen.
# ---------------------------------------------------------------------------
PINNED_UVC_SHA=e9a733fe5c4a7fcb48e963e8d994bc33d24d814e

patch_uvc_gadget() {
    anchor "$PIWEBCAM/piwebcam.mk" "PIWEBCAM_SITE = https://github.com/peterbay/uvc-gadget.git" \
        "the uvc-gadget source pin"
    local pinned
    pinned=$(sed -n 's/^PIWEBCAM_VERSION = \(.*\)/\1/p' "$PIWEBCAM/piwebcam.mk")
    if [ "$pinned" != "$PINNED_UVC_SHA" ]; then
        die "uvc-gadget's pin moved: piwebcam.mk now wants
    $pinned
  but zero/patches/0001-*.patch was generated against
    $PINNED_UVC_SHA
  Regenerate the patch against the new SHA before building. It adds one
  branch to configfs_video_format() ('h' -> V4L2_PIX_FMT_H264) and widens a
  diagnostic filter; both are three-line changes, but a patch that applies
  with fuzz to a moved file is exactly how a card ends up streaming the
  wrong thing."
    fi
    say "uvc-gadget → +h264 (patch into package/piwebcam/)"
    cp "$HERE"/patches/*.patch "$PIWEBCAM/"
}

# ---------------------------------------------------------------------------
# 3. multi-gadget.sh — advertise H.264, and add the control port.
#
# Four changes, and only the first is the obvious one:
#   a) the video_formats.txt parser greps ^(mjpeg|uncompressed), so an h264
#      line is silently DROPPED — the gadget comes up advertising nothing new
#      and the failure surfaces on the Pi 4 as a caps mismatch.
#   b) config_frame() writes dwMaxVideoFrameBufferSize, which the framebased
#      format does not carry — the mkdir would succeed and the write would
#      fail, leaving a half-built format.
#   c) the streaming header hardcodes symlinks to mjpeg/m and uncompressed/u.
#      Without a framebased/h link the format exists in configfs and is never
#      advertised to the host.
#   d) acm.usb0 is the login console (post-build.sh puts a getty on ttyGS0).
#      The control port needs a SECOND ACM function, and it must be linked
#      LAST so its interface number is stable for the Pi 4's udev rule.
#   e) the descriptor bitfields that showmewebcam's dropped kernel patch used
#      to hardcode are set here instead, from configfs. Same values, no patch.
# ---------------------------------------------------------------------------
patch_multi_gadget() {
    local f="$PIWEBCAM/multi-gadget.sh"
    anchor "$f" 'grep -E "^(mjpeg|uncompressed)' "the video_formats.txt parser"
    anchor "$f" 'ln -s functions/uvc.usb0/streaming/mjpeg/m' "the streaming header links"
    anchor "$f" 'mkdir -p functions/acm.usb0' "the serial console function"
    anchor "$f" 'mkdir -p functions/uvc.usb0/control/header/h' "the control header setup"
    anchor "$f" 'FRAMEDIR="functions/uvc.usb0/streaming/$FORMAT/$NAME/${HEIGHT}p"' \
        "the frame-directory layout"
    say "multi-gadget.sh → h264 + control port"

    python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

# (a) the parser
s = s.replace('grep -E "^(mjpeg|uncompressed)', 'grep -E "^(mjpeg|uncompressed|h264)')

# The format directory type is not the keyword: h264 lives under framebased/,
# which is where the kernel's guidFormat (H.264 by default) lives. The
# INSTANCE name still has to start with 'h' — that first character is how
# uvc-gadget picks V4L2_PIX_FMT_H264.
s = s.replace(
    '''    VIDEO_FORMAT=$(echo "$line" | awk '{print $1}')
    HDR_DESC=$(echo "$VIDEO_FORMAT" | cut -c 1)''',
    '''    VIDEO_FORMAT=$(echo "$line" | awk '{print $1}')
    HDR_DESC=$(echo "$VIDEO_FORMAT" | cut -c 1)
    # DashBerry: h264 lines are frame-based UVC descriptors. The configfs
    # directory is framebased/, the instance name stays "h" (uvc-gadget reads
    # that first character to choose the fourcc), and the keyword itself is
    # only what appears in video_formats.txt.
    if [ "$VIDEO_FORMAT" = "h264" ] ; then
      VIDEO_FORMAT=framebased
    fi''')

# (b) frame attributes that the framebased format does not have
s = s.replace(
    '''  echo $((WIDTH * HEIGHT * 2))     > "$FRAMEDIR"/dwMaxVideoFrameBufferSize''',
    '''  # dwMaxVideoFrameBufferSize exists on uncompressed/mjpeg frames; the
  # frame-based format has no such attribute, and writing it is not fatal.
  if [ -e "$FRAMEDIR"/dwMaxVideoFrameBufferSize ] ; then
    echo $((WIDTH * HEIGHT * 2))   > "$FRAMEDIR"/dwMaxVideoFrameBufferSize
  fi''')

# ...and a mkdir that fails means the kernel has no framebased support at all,
# which must stop the gadget rather than quietly advertise less.
s = s.replace(
    '''  FRAMEDIR="functions/uvc.usb0/streaming/$FORMAT/$NAME/${HEIGHT}p"

  mkdir -p "$FRAMEDIR"''',
    '''  FRAMEDIR="functions/uvc.usb0/streaming/$FORMAT/$NAME/${HEIGHT}p"

  if ! mkdir -p "$FRAMEDIR" 2>/dev/null ; then
    echo "Cannot create $FRAMEDIR"
    if [ "$FORMAT" = "framebased" ] ; then
      echo "  This kernel has no frame-based UVC format (needs >= rpi-6.13.y)."
      echo "  Refusing to fall back to MJPEG: the host expects H.264."
    fi
    return 1
  fi''')

# (e) the control-descriptor bitfields. These used to come from
# patches/linux-custom/0001-linux-enable-more-video-controls.patch, which
# hardcoded them in f_uvc.c; since ~5.15 they are configfs attributes, so the
# patch is obsolete and this is the same change made from userspace. Without
# them the host sees ONE control instead of seven, and nothing says why.
s = s.replace(
    '''  mkdir -p functions/uvc.usb0/control/header/h''',
    '''  mkdir -p functions/uvc.usb0/control/header/h

  # DashBerry: widen the advertised control bitfields. Values are exactly
  # those showmewebcam's kernel patch used to compile in (camera terminal
  # 10,0,0 and processing unit 219,4); they became writable configfs
  # attributes in ~5.15, which is why that patch is gone. Newline-separated,
  # matching the kernel's own show() format. Best effort: an older kernel
  # without these attributes still gives a working camera, just the narrower
  # UVC control set — and DashBerry drives controls over the control port,
  # not through UVC.
  CAM_CTRL=functions/uvc.usb0/control/terminal/camera/default/bmControls
  PU_CTRL=functions/uvc.usb0/control/processing/default/bmControls
  if [ -w "$CAM_CTRL" ] && [ -w "$PU_CTRL" ] ; then
    printf '10\\n0\\n0\\n' > "$CAM_CTRL"
    printf '219\\n4\\n'      > "$PU_CTRL"
  else
    echo "Warning: bmControls not writable — host will see the narrow UVC control set"
  fi''')

# (g) THE SUPERSPEED CLASS LINKS. This is what stopped the camera binding.
#
# 6.16's uvc_function_bind() builds descriptors for ALL FOUR speeds
# unconditionally - FULL, HIGH, SUPER and SUPER_PLUS. uvc_copy_descriptors()
# for SUPER needs uvc->desc.ss_control and ss_streaming, which come from the
# configfs symlinks control/class/ss and streaming/class/ss. Upstream
# multi-gadget.sh only ever creates fs and hs, so on this kernel the SUPER copy
# returns ERR_PTR(-ENODEV) and the whole composite bind fails:
#
#     configfs-gadget.piwebcam gadget.0: uvc: uvc_function_bind()
#     udc 20980000.usb: failed to start piwebcam: -19
#
# and NOTHING else is logged, because that return is the one error path in
# uvc_copy_descriptors() with no message attached.
#
# It worked on 5.10 because f_uvc.c copied the SS descriptors only
# `if (gadget_is_superspeed(c->cdev->gadget))`, and dwc2 on a Zero is
# high-speed, so the missing links were never read. The links cost nothing on
# a high-speed device: they are descriptors the host will never ask for.
s = s.replace(
    """  ln -s functions/uvc.usb0/control/header/h         functions/uvc.usb0/control/class/fs""",
    """  ln -s functions/uvc.usb0/control/header/h         functions/uvc.usb0/control/class/fs
  # DashBerry: 6.16 builds SuperSpeed descriptors even for a high-speed
  # gadget, and returns a silent -ENODEV if these are missing. See edits.sh.
  ln -s functions/uvc.usb0/streaming/header/h       functions/uvc.usb0/streaming/class/ss
  ln -s functions/uvc.usb0/control/header/h         functions/uvc.usb0/control/class/ss""")

# (c) the streaming header links: only link what exists, and include
# framebased/h so the host is actually told about it.
s = s.replace(
    '''  ln -s functions/uvc.usb0/streaming/mjpeg/m        functions/uvc.usb0/streaming/header/h
  ln -s functions/uvc.usb0/streaming/uncompressed/u functions/uvc.usb0/streaming/header/h''',
    '''  for FMTDIR in framebased/h mjpeg/m uncompressed/u ; do
    if [ -d "functions/uvc.usb0/streaming/$FMTDIR" ] ; then
      ln -s "functions/uvc.usb0/streaming/$FMTDIR" functions/uvc.usb0/streaming/header/h
    fi
  done''')

# (f) WAIT FOR A UDC. Upstream does `ls /sys/class/udc > UDC` the instant the
# functions are built, and on 6.16 that is a race it loses: dwc2 finishes
# registering the gadget controller AFTER this script has run. The first
# working card produced a fully-built gadget with `bound UDC: ''` and an empty
# /sys/class/udc, and the dwc2 line proving the controller had come up
# ("EPs: 8, dedicated fifos, 4080 entries in SPRAM" — dwc2_hsotg_hw_cfg, on
# the peripheral path) appeared at the very END of the kernel log, well after
# this script exited.
#
# Building the gadget stack into the kernel makes it probe long before
# userspace and should close the race on its own. This loop is the belt to
# that braces: it costs nothing when the UDC is already there, and it turns
# "silently no USB at all" into a message that says which half failed.
s = s.replace(
    '''ls /sys/class/udc > UDC''',
    '''# DashBerry: wait for the USB controller to register a UDC before binding.
# See the note in edits.sh: upstream assumes it already exists, and on 6.16
# dwc2 can finish after this script does.
UDC_TRIES=0
while [ -z "$(ls /sys/class/udc 2>/dev/null)" ] ; do
  UDC_TRIES=$((UDC_TRIES + 1))
  if [ "$UDC_TRIES" -ge 15 ] ; then
    echo "No UDC after ${UDC_TRIES}s: the USB controller never registered."
    echo "  Nothing will enumerate - not the camera, not the console."
    echo "  Check 'dmesg | grep dwc2' and /sys/kernel/debug/devices_deferred."
    exit 1
  fi
  echo "Waiting for a UDC to appear (${UDC_TRIES}s)..."
  sleep 1
done

# DashBerry: bind, and DEGRADE RATHER THAN DIE.
#
# A composite gadget binds all or nothing: one function the controller cannot
# satisfy takes the whole device down, so the card enumerates NOTHING - no
# camera and no console - and the only way to ask why is the console that just
# vanished. That happened here with "failed to start piwebcam: -19" (-ENODEV),
# and each guess at which function was at fault cost a full image build.
#
# So each configuration is tried in turn, most complete first, and whichever
# binds is kept. The fallbacks are ordered by what they cost:
#   1. everything
#   2. no control port  - the Pi 4 cannot push settings, but the camera works
#                         and the console is up. dwc2 has 8 endpoints and the
#                         second ACM wants 3 of them, so this is the first
#                         thing worth suspecting.
#   3. console only     - no camera, but a way in to debug it live
# The log says which one won, which is the diagnosis.
bind_gadget() {
  ls /sys/class/udc > UDC 2>/tmp/udc-bind.err
  if [ -n "$(cat UDC 2>/dev/null)" ] ; then
    echo "Gadget bound to $(cat UDC)  [$1]"
    # DashBerry: BINDING IS NOT ATTACHING. In dr_mode=peripheral - which the
    # car needs, because its converter grounds ID and an OTG port would become
    # a HOST - dwc2 runs no OTG session state machine, so
    # usb_udc_vbus_handler() never reports VBUS, udc->vbus stays false, and
    # usb_udc_connect_control() DISCONNECTS instead of connecting. The result
    # is a gadget that binds, registers its video node, and is never on the
    # bus: the host sees nothing at all, not even a failed enumeration.
    #
    # soft_connect calls usb_gadget_connect_locked() directly, and that path
    # checks only ->pullup, ->started and ->allow_connect - never vbus - all of
    # which hold once the bind above succeeded.
    for sc in /sys/class/udc/*/soft_connect ; do
      [ -e "$sc" ] || continue
      if echo connect > "$sc" 2>/dev/null ; then
        echo "Pull-up asserted via $sc"
      else
        echo "WARNING: could not assert pull-up via $sc"
        echo "  The gadget is bound but may never appear on the bus."
      fi
    done
    return 0
  fi
  echo "Bind FAILED [$1]: $(cat /tmp/udc-bind.err 2>/dev/null)"
  echo "  (dmesg will name the function that refused and its errno)"
  echo "" > UDC 2>/dev/null || true
  return 1
}

# DashBerry: /boot/no-camera - a deliberate escape hatch, toggled by editing
# the FAT boot partition on any PC, no rebuild.
#
# f_uvc sets bind_deactivated, so the UVC function keeps the WHOLE gadget
# deactivated until a userspace app subscribes to UVC_EVENT_SETUP on the
# gadget's video node. uvc-gadget does that - and when uvc-gadget fails, as it
# does with "configfs settings for uvc gadget not found", the card enumerates
# NOTHING: no camera, no console, no control port. The one channel that could
# explain the failure is removed by the failure.
#
# With this file present the camera function is left out entirely, so the
# gadget has nothing that deactivates it and the console comes up. That is a
# card you can log into and run uvc-gadget on by hand.
if [ -f /boot/no-camera ] ; then
  echo "/boot/no-camera present: binding WITHOUT the camera."
  echo "  This is the debugging shape - console and control port only."
  echo "  NOTE uvc-webcam will exit immediately in this mode: with the UVC"
  echo "  function left out of the config there is no /dev/video1 for it to"
  echo "  open. That is expected, not a new fault - but it means the daemon"
  echo "  cannot be debugged from this console. Read /boot/boot-report.txt off"
  echo "  the card instead; it carries the daemon's full log."
  echo "  Delete /boot/no-camera to go back to a camera card."
  rm -f configs/c.1/uvc.usb0
  bind_gadget "console + control port, camera deliberately omitted"
elif ! bind_gadget "camera + console + control port" ; then
  echo "Retrying without the control port (acm.usb1)..."
  rm -f configs/c.1/acm.usb1
  if ! bind_gadget "camera + console, NO control port" ; then
    echo "Retrying with the console only..."
    rm -f configs/c.1/uvc.usb0
    if ! bind_gadget "console only, NO camera" ; then
      echo "Nothing binds at all. The controller has a UDC but refuses every"
      echo "  configuration - see dmesg for the function and errno."
      exit 1
    fi
  fi
fi''')

# (d) the control port. Linked after acm.usb0 so the interface numbering is
# uvc(0,1) acm.usb0(2,3) acm.usb1(4,5) — the Pi 4's udev rule matches on 04.
s = s.replace(
    '''config_usb_serial () {
  mkdir -p functions/acm.usb0
  ln -s functions/acm.usb0 configs/c.1/acm.usb0
}''',
    '''config_usb_serial () {
  mkdir -p functions/acm.usb0
  ln -s functions/acm.usb0 configs/c.1/acm.usb0
}

# DashBerry control port: a SECOND CDC-ACM function, where the Pi 4 pushes the
# camera settings it owns (flips, bitrate, I-period, profile, exposure bias)
# and reads them back. Kept separate from acm.usb0, which is the login console
# a getty sits on — a control protocol must not fight a shell for a port.
# Linked LAST on purpose: interface numbering is what the Pi 4's udev rule
# uses to tell the two apart.
config_usb_control () {
  mkdir -p functions/acm.usb1
  ln -s functions/acm.usb1 configs/c.1/acm.usb1
}''')

s = s.replace(
    '''if [ "$CONFIGURE_USB_SERIAL" = true ] ; then
  echo "Configuring USB gadget serial interface"
  config_usb_serial
fi''',
    '''if [ "$CONFIGURE_USB_SERIAL" = true ] ; then
  echo "Configuring USB gadget serial interface"
  config_usb_serial
fi

echo "Configuring USB gadget control interface"
config_usb_control''')

open(p, 'w').write(s)
PY

    grep -q 'config_usb_control' "$f" || die "multi-gadget.sh edits did not take — read it."
}

# ---------------------------------------------------------------------------
# 4. camera.txt — stop shipping a live 25 Mbps setting.
#
# start-webcam.sh feeds every key in /boot/camera.txt to v4l2-ctl before the
# gadget streams. On an MJPEG card video_bitrate=25000000 was INERT — it is
# V4L2_CID_MPEG_VIDEO_BITRATE, an H.264 control on a gadget that never encoded
# H.264, and it is the origin of the retracted "~25 Mbps MJPEG floor" claim.
# THE MOMENT THIS IMAGE ENCODES H.264 IT BECOMES LIVE, and would quietly make
# the rear a 25 Mbps camera (~11 GB/h).
#
# It does not get a corrected value here. It LEAVES, because bitrate is the
# Pi 4's to own (dashberry.conf REAR_BITRATE, pushed by rear-ctl) and nothing
# per-installation may live on this card.
#
# auto_exposure_bias=12 stays: it is the shipped default and the Pi 4 pushes
# the same value, so an un-pushed card still looks like the one it replaced.
# ---------------------------------------------------------------------------
patch_camera_txt() {
    local f="$PIWEBCAM/camera.txt"
    anchor "$f" "video_bitrate=25000000" "the shipped camera settings"
    say "camera.txt → dropping video_bitrate (rear-ctl owns it)"
    python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("video_bitrate=25000000\n",
    "# video_bitrate: REMOVED by DashBerry. It was inert while this gadget\n"
    "# streamed MJPEG; it is a LIVE 25 Mbps setting now that it encodes H.264,\n"
    "# and bitrate belongs to the Pi 4 (dashberry.conf REAR_BITRATE, pushed by\n"
    "# rear-ctl on every start of rear-rec).\n")
open(p, 'w').write(s)
PY
}

# ---------------------------------------------------------------------------
# 5. Our own files, into BR2_ROOTFS_OVERLAY.
#
# The overlay is applied after every package installs, so rootfs/etc/
# video_formats.txt wins over the one package/piwebcam/ installs.
# The image is systemd (BR2_INIT_SYSTEMD=y), so rear-ctld gets a unit and a
# basic.target.wants symlink — the same shape piwebcam.mk uses for its own.
# ---------------------------------------------------------------------------
install_overlay() {
    anchor "$CFG" 'BR2_ROOTFS_OVERLAY="$(BR2_EXTERNAL_PICAM_PATH)/rootfs"' \
        "the rootfs overlay location"
    say "overlay → rootfs/"
    mkdir -p "$OVERLAY"
    cp -a "$HERE/overlay/." "$OVERLAY/"
    chmod 755 "$OVERLAY/usr/bin/rear-ctld"
    printf '%s\n' "${DASHBERRY_ZERO_VERSION:-dev}" > "$OVERLAY/etc/dashberry-zero-version"

    chmod 755 "$OVERLAY/usr/bin/boot-report"
    chmod 755 "$OVERLAY/usr/bin/uvc-trace"
    mkdir -p "$OVERLAY/etc/systemd/system/basic.target.wants"
    ln -sf ../rear-ctld.service   "$OVERLAY/etc/systemd/system/basic.target.wants/rear-ctld.service"
    ln -sf ../boot-report.service "$OVERLAY/etc/systemd/system/basic.target.wants/boot-report.service"
    ln -sf ../uvc-trace.service   "$OVERLAY/etc/systemd/system/basic.target.wants/uvc-trace.service"

    # A shell that is NOT on the gadget.
    #
    # Every way into this card runs down the USB cable: the console is ttyGS0,
    # the control port is ttyGS1, the video is the same gadget again. So the
    # one failure we most need to observe — the gadget wedging — is the one
    # that takes away the means of observing it. Measured on 2026-08-14: a
    # failed capture left ttyACM0 hung, and with it went any chance of reading
    # the log that would say why.
    #
    # The UART is independent of dwc2 and of libcomposite. The kernel already
    # talks to it (console=ttyAMA0,115200 in cmdline.txt) and disable-bt has
    # already moved the PL011 onto GPIO 14/15, so the pins are live on any
    # card built here — there was simply no getty to log into. This adds one.
    #
    # Wiring: USB-TTL GND to pin 6, its RX to pin 8 (Zero TXD), its TX to
    # pin 10 (Zero RXD), 115200 8N1. Nothing is connected in normal service.
    mkdir -p "$OVERLAY/etc/systemd/system/getty.target.wants"
    ln -sf /usr/lib/systemd/system/serial-getty@.service \
        "$OVERLAY/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"
}

# ---------------------------------------------------------------------------
# 6. /boot/config.txt — the two deviations that live there.
#
# This card carried THREE deviations from the official image before H.264 ever
# came up: advertised resolutions (video_formats.txt, handled in the overlay),
# USB PERIPHERAL MODE, and memory allocation. Both of the latter land in
# config.txt, and neither can go in the rootfs overlay: /boot is a separate FAT
# partition built by genimage from ${BINARIES_DIR}/rpi-firmware/config.txt, and
# fstab mounts it over anything the overlay put at /boot. post-image.sh's
# --configure-picam block is where that file is assembled, so both append
# there, in the same shape as the enable_uart/boot_delay lines beside them.
#
# (a) dr_mode. Upstream appends a BARE `dtoverlay=dwc2`, leaving the
#     controller in OTG, where the port's role comes from the ID pin. We set
#     dr_mode=peripheral to stop that depending on the cable — a converter
#     that grounds ID makes an OTG port try to be a HOST, and it then never
#     appears as a camera.
#
#     THAT WAS REVERTED. On 6.16 the cure was worse than the disease: the
#     gadget bound and never pulled up. In forced-peripheral mode dwc2 does
#     not run the OTG session state machine, so usb_udc_vbus_handler() never
#     reports VBUS present, udc->vbus stays false, and
#     usb_udc_connect_control() disconnects instead of connecting. From
#     inside the card everything looked right — "bound driver
#     configfs-gadget.piwebcam", /dev/video1 present — and the host saw
#     nothing at all, not even a failed enumeration attempt.
#
#     OTG IS THE DEFAULT because it is the only mode OBSERVED to attach here.
#     A stock 5.10 card's log shows dwc2 doing full dual-role init - "DWC OTG
#     Controller", "new USB bus registered", "hub 1-0:1.0" - and only then
#     "new device is high-speed / new address 4", the gadget reporting that a
#     host enumerated it.
#
#     THAT IS NOT EVIDENCE THAT PERIPHERAL MODE IS BROKEN, and an earlier
#     version of this comment claimed it was. Diffed against 5.10.11: the
#     pullup's op_state gate, udc_start's dwc2_lowlevel_hw_enable() call for
#     PERIPHERAL, and the op_state assignment are all identical; dwc2 never
#     calls usb_udc_vbus_handler() in either version; udc->vbus is initialised
#     true in both. There is no 5.10->6.16 change here to blame.
#
#     What is true: every peripheral test before the PHY fix ran with no PHY,
#     where no mode could attach, and exactly ONE test has had PHY+peripheral.
#     OTG+PHY - what stock proves works - has not been tried. Use otg because
#     it is the known-good shape, not because peripheral is condemned.
#
#     THE CAR STILL NEEDS ID TO FLOAT. In OTG the role comes from the ID pin,
#     so a converter that grounds it makes the Zero a HOST and the camera
#     disappears. That has to be fixed in the CABLE, not the driver: the Zero
#     is the device, so a plain USB-A-to-micro-B cable is correct and leaves ID
#     floating. Only an OTG-style adapter (micro-B male to A female) grounds
#     it, and masking pin 4 defeats one that does. Fighting it in software
#     means dr_mode=peripheral, which does not work on this kernel.
#
#     The pull-up is asserted explicitly instead. multi-gadget.sh writes
#     "connect" to /sys/class/udc/<udc>/soft_connect after binding, which calls
#     usb_gadget_connect_locked() directly — and that path checks only
#     ->pullup, ->started and ->allow_connect, never udc->vbus. So the gadget
#     attaches without depending on a session interrupt that forced-peripheral
#     dwc2 never delivers.
#
#     ZERO_DR_MODE=otg selects stock's behaviour, for a bench cable that leaves
#     ID floating.
# (b) gpu_mem=256 on a 512 MB Zero W. The hardware encoder needs it, and it
#     needs it MORE now than when this was an MJPEG card.
# ---------------------------------------------------------------------------
patch_post_image() {
    local f="$SMW/board/post-image.sh"
    anchor "$f" "--configure-picam)" "the boot config.txt assembly"
    anchor "$f" "dtoverlay=dwc2" "the picam boot-config block"

    ZERO_DR_MODE=${ZERO_DR_MODE:-otg}
    case $ZERO_DR_MODE in
        otg) DR_SUFFIX= ;;
        *)   DR_SUFFIX=",dr_mode=$ZERO_DR_MODE" ;;
    esac
    if grep -q 'DashBerry: USB role' "$f"; then
        say "post-image.sh already sets the USB role — left alone"
    else
        say "post-image.sh → dtoverlay=dwc2${DR_SUFFIX} (role: $ZERO_DR_MODE)"
        # The existing guard greps ^dtoverlay=dwc2, which still matches the
        # longer line, so this stays idempotent across rebuilds.
        DR_SUFFIX="$DR_SUFFIX" python3 - "$f" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"
dtoverlay=dwc2
__EOF__'''
new = '''			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"
# DashBerry: USB role. OTG (no dr_mode) is what stock uses and what is proven
# to enumerate here. dr_mode=peripheral was tried, to stop the role depending
# on whether the cable grounds ID, and on 6.16 it bound but never pulled up:
# forced-peripheral dwc2 runs no OTG session machine, so udc->vbus stays false
# and the UDC core disconnects instead of connecting. See zero/edits.sh.
dtoverlay=dwc2DR_SUFFIX_HERE
__EOF__'''
import os
new = new.replace("DR_SUFFIX_HERE", os.environ.get("DR_SUFFIX", ""))
assert old in s, "post-image.sh's dwc2 append has changed shape"
s = s.replace(old, new, 1)
open(p, 'w').write(s)
PY2
    fi

    if grep -q 'disable-wifi' "$f"; then
        say "post-image.sh already disables the radios — left alone"
    else
        say "post-image.sh → dtoverlay=disable-wifi, dtoverlay=disable-bt"
        python3 - "$f" <<'PY3'
import sys
p = sys.argv[1]
s = open(p).read()
old = """		# Configure uart on 40-pin header"""
new = """		# DashBerry: RADIO SILENCE. Disable the BCM43438 in the device
		# tree, so the SDIO link to the Wi-Fi side and the UART to the
		# Bluetooth side are never brought up. This is the second of
		# three layers — the drivers are also built out of the kernel
		# (board/linux-base.config) and no brcm firmware ships — and it
		# is the one that keeps the hardware itself dark.
		# Both .dtbo files ship with rpi-firmware; verified present at
		# the pinned revision.
		# NOTE disable-bt also frees the PL011 (ttyAMA0) for the 40-pin
		# header, which is where BR2_TARGET_GENERIC_GETTY_PORT points.
		# The console this project actually uses is the USB one
		# (ttyGS0), so that is a bonus rather than a change of plan.
		if ! grep -qE '^dtoverlay=disable-wifi' "${BINARIES_DIR}/rpi-firmware/config.txt"; then

			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"
dtoverlay=disable-wifi
dtoverlay=disable-bt
__EOF__
		fi

		# Configure uart on 40-pin header"""
assert old in s, "post-image.sh's picam block has changed shape"
s = s.replace(old, new, 1)
open(p, 'w').write(s)
PY3
    fi

    if grep -q 'gpu_mem=256' "$f"; then
        say "post-image.sh already sets gpu_mem — left alone"
        return
    fi
    say "post-image.sh → gpu_mem=256"
    python3 - "$f" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''		# Configure uart on 40-pin header'''
new = '''		# DashBerry: the H.264 encoder and the ISP need the GPU split
		# raised on a 512 MB Zero W. Not gpu_mem_512= — the stock
		# config.txt has no such line for a sed to land on, and this
		# block appends rather than substitutes for exactly that reason.
		if ! grep -qE '^gpu_mem=' "${BINARIES_DIR}/rpi-firmware/config.txt"; then

			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"
gpu_mem=256
__EOF__
		fi

		# ...and gpu_mem alone is NOT enough. The stock config.txt sets
		# gpu_mem_256/512/1024, and the firmware treats those as
		# OVERRIDES of the generic gpu_mem on a board with that much
		# RAM. A Zero W has 512 MB, so gpu_mem_512=100 would win and
		# the line above would be inert — the same trap as camera.txt's
		# video_bitrate. Raise the one that actually applies.
		sed -e '/^gpu_mem_512=/s,=.*,=256,' -i "${BINARIES_DIR}/rpi-firmware/config.txt"

		# Configure uart on 40-pin header'''
assert old in s, "post-image.sh's picam block has changed shape"
s = s.replace(old, new, 1)
open(p, 'w').write(s)
PY2
}

# ---------------------------------------------------------------------------
# 7. Download sites — a 2021 buildroot points at tarballs that have moved.
#
# buildroot 2021.02.8 pins package versions from five years ago and fetches
# each from its upstream's own site. Plenty of those upstreams keep only the
# CURRENT release: libzlib wants zlib-1.2.11.tar.xz from http://www.zlib.net,
# which does not serve it any more — the fetch does not 404, it hangs, and
# `wget -t 3` hangs three times before buildroot even tries its backup site.
#
# BR2_PRIMARY_SITE makes buildroot try a mirror FIRST. sources.buildroot.net
# is buildroot's own archive and carries every tarball it has ever referenced,
# so this fixes zlib and pre-empts every other vanished-tarball case in the
# same build rather than one at a time.
#
# This is not a trust shortcut: every package carries a .hash file (libzlib's
# pins sha256 4ff94144…) and buildroot verifies the tarball against it no
# matter where it came from. The mirror changes WHERE the bytes come from, not
# whether they are checked.
#
# BR2_PRIMARY_SITE_ONLY is deliberately NOT set: if the mirror is ever down,
# falling through to upstream is better than failing.
# ---------------------------------------------------------------------------
patch_download_sites() {
    if grep -q '^BR2_PRIMARY_SITE=' "$CFG"; then
        say "download mirror already set — left alone"
    else
        say "downloads → sources.buildroot.net first (upstreams have moved on)"
        printf '%s\n' 'BR2_PRIMARY_SITE="https://sources.buildroot.net"' >> "$CFG"
    fi
    # And so a site that is genuinely dead fails in seconds instead of
    # stalling the build: the default is `wget --passive-ftp -nd -t 3` with no
    # timeout at all, which is how a single moved tarball costs an afternoon.
    if ! grep -q '^BR2_WGET=' "$CFG"; then
        say "  wget → 15 s connect/read timeout"
        printf '%s\n' 'BR2_WGET="wget --passive-ftp -nd -t 3 -T 15"' >> "$CFG"
    fi
}

# ---------------------------------------------------------------------------
# 9. busybox — the first casualty of the kernel repin.
#
# busybox 1.33.2's `tc` applet reads TCA_CBQ_*, struct tc_cbq_lssopt and
# friends out of <linux/pkt_sched.h>. Linux removed the CBQ queueing
# discipline and deleted those uapi definitions with it, so against the
# rpi-6.16.y headers this image now builds on, networking/tc.c does not
# compile at all.
#
# There is nothing to repair: the kernel does not implement CBQ any more, so
# the applet would have nothing to configure even if it built. It is disabled
# via a config fragment, which is buildroot's own hook for this
# (BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES, empty upstream) and leaves
# buildroot's busybox.config untouched. Upstream busybox disables tc by
# default in later releases for the same reason.
#
# Expect more of this shape as the target build proceeds: this is target
# source written against 5.10 uapi meeting 6.16 uapi, which is a different
# problem from the host-tooling drift build.sh works around.
# ---------------------------------------------------------------------------
patch_busybox() {
    local frag="board/dashberry-busybox.fragment"
    say "busybox → disabling the tc applet (CBQ is gone from the kernel uapi)"
    cp "$HERE/busybox.fragment" "$SMW/$frag"
    if grep -q '^BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES=' "$CFG"; then
        say "  a busybox fragment is already configured — appending ours"
        sed -i "s|^BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES=\"\(.*\)\"|BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES=\"\1 \$(BR2_EXTERNAL_PICAM_PATH)/$frag\"|" "$CFG"
    else
        printf '%s\n' "BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES=\"\$(BR2_EXTERNAL_PICAM_PATH)/$frag\"" >> "$CFG"
    fi
}

# ---------------------------------------------------------------------------
# 10. RADIO SILENCE — the Zero must be RF-killed, like the Pi 4 beside it.
#
# The Pi Zero W has a BCM43438: 2.4 GHz Wi-Fi and Bluetooth on one die. This
# board sits in a locked car recording continuously and has exactly one
# interface it is meant to speak on — the USB gadget. Every radio on it is
# attack surface and battery draw for no function, and the Pi 4 half of this
# project already boots RF-KILLED as a rule.
#
# Three independent layers, because "fail closed" means no single mistake
# turns a radio back on:
#
#   1. the DRIVERS are not built (here). No brcmfmac, no cfg80211/mac80211, no
#      Bluetooth stack — the code to drive the radio does not exist in the
#      kernel, so nothing can load it, and no userspace toggle can undo it.
#   2. the HARDWARE is disabled in the device tree (patch_post_image), so the
#      SDIO link to the Wi-Fi side and the UART to the BT side are never
#      brought up at all.
#   3. no FIRMWARE ships. There is no /lib/firmware/brcm in this rootfs, so
#      even a driver that appeared could not bring the part out of reset.
#
# Layer 1 is the one that cannot be argued with, and it is why this is a
# kernel-config change rather than an rfkill service: showmewebcam has no
# rfkill binary, and a runtime kill is a thing that can fail to run.
# ---------------------------------------------------------------------------
patch_kernel_config() {
    local f="$SMW/board/linux-base.config"
    anchor "$f" "CONFIG_BRCMFMAC" "the kernel's Wi-Fi driver selection"
    if grep -q "DashBerry: radio silence" "$f"; then
        say "kernel config already RF-silenced — left alone"
        return
    fi
    # RENAMED SYMBOLS. olddefconfig silently drops a CONFIG_ it does not
    # recognise, so a symbol renamed between 5.10 and 6.16 does not warn — it
    # just vanishes and takes its driver with it. One of these is fatal:
    #
    #   MMC_BCM2835_SDHOST -> MMC_BCM2835
    #     The bcm2835-sdhost driver. The Zero W's device tree drives its SD
    #     card from a `brcm,bcm2835-sdhost` node, so without this the kernel
    #     boots, cannot mount /dev/mmcblk0p2, and panics BEFORE USB comes up.
    #     From outside the card is simply dead: no camera, no console, no
    #     enumeration at all. (MMC_BCM2835_MMC, which the fragment also sets,
    #     is the OTHER controller — the Arasan/SDIO one — and does not serve
    #     the SD card here.)
    #
    # build.sh gates on the resulting config, so a future rename fails the
    # build instead of producing another dead card.
    say "kernel → renaming symbols that moved since 5.10"
    sed -i 's/^CONFIG_MMC_BCM2835_SDHOST=/CONFIG_MMC_BCM2835=/' "$f"

    # THE GADGET STACK IS BUILT IN, NOT MODULAR.
    #
    # showmewebcam ships CONFIG_USB_DWC2=m, CONFIG_USB_GADGET=m and
    # CONFIG_USB_CONFIGFS=m, and relies on `modules-load=dwc2,libcomposite` on
    # the kernel command line to bring them up. On 6.16 that leaves the USB
    # controller probing LATE, after the deferred-probe pass has settled, and
    # the first card built here bound no UDC at all: dwc2 attached to
    # 20980000.usb, logged its two dummy-regulator warnings, and then went
    # silent. Several early returns in dwc2_driver_probe() exit without
    # printing anything — a deferred probe most of all — so silence is
    # consistent with a probe that never completed.
    #
    # Building it in removes module ordering from the question entirely, and
    # is what this board should have been doing anyway: its whole purpose is
    # to be a USB gadget. It also settles a complaint already visible in the
    # log — "Unknown kernel command line parameters modules-load=dwc2,
    # libcomposite, will be passed to user space".
    #
    # This does NOT prove the ordering was the fault. If the next card still
    # binds no UDC, the boot report now carries what does prove it: which
    # driver owns the USB node, the deferred-probe list, and a forced re-probe.
    # NO PRECOMPOSED GADGET DRIVERS. This board builds its gadget from
    # configfs and nothing else, and every legacy "g_*" driver in the kernel
    # auto-binds the FIRST UDC that appears — which is a race configfs cannot
    # win, because configfs binds only when userspace writes to UDC.
    #
    # showmewebcam's fragment has always carried CONFIG_USB_G_SERIAL=y and
    # CONFIG_USB_CDC_COMPOSITE=y. With CONFIG_USB_GADGET=m kconfig could only
    # honour them as =m, so they sat harmless and unloaded. Building the
    # gadget core in (above) let those =y requests take effect, and g_serial
    # took the controller the moment dwc2 registered it:
    #
    #   dwc2 20980000.usb: EPs: 8, dedicated fifos, 4080 entries in SPRAM
    #   g_serial gadget.0: g_serial ready
    #   dwc2 20980000.usb: bound driver g_serial
    #
    # The card then enumerated as a bare serial gadget: one ttyACM, no camera,
    # and `bound UDC: ''` on our own configfs gadget. Turning them off is not
    # a workaround for that change — they should never have been reachable on
    # a configfs-only device.
    # THE USB PHY. The device tree's USB node carries
    #   phys = <&usbphy>;   with  usbphy { compatible = "usb-nop-xceiv"; }
    # and CONFIG_NOP_USB_XCEIV was never in showmewebcam's fragment - it did
    # not need to be, because nothing consumed that phandle on 5.10.
    #
    # On 6.16 dwc2_lowlevel_hw_init() looks the PHY up, and with no driver
    # registered for usb-nop-xceiv the lookup returns -EPROBE_DEFER. dwc2's
    # probe is then retried until the deferred-probe timeout gives up, which is
    # the unexplained ~9 second gap between "Module 'dwc2' is built in" and the
    # first dwc2 message. It finally proceeds with no PHY at all - so every
    # software layer succeeds and the port is never physically driven:
    #
    #   Gadget bound to 20980000.usb  [camera + console + control port]
    #   Pull-up asserted via /sys/class/udc/20980000.usb/soft_connect
    #   20980000.usb state: not attached
    #
    # and nothing whatsoever on the host - not a failed enumeration, no
    # descriptor error, no port event. That is what an un-powered PHY looks
    # like, and it is why chasing dr_mode was wrong: peripheral and otg both
    # fail identically because neither ever reaches the wire.
    #
    # raspberrypi/linux's own bcmrpi_defconfig sets CONFIG_NOP_USB_XCEIV=y.
    # This is not a workaround; it is the driver the device tree asks for.
    # dwc2's own tracing. -DDEBUG turns its dev_dbg() calls into real output,
    # including dwc2_hsotg_pullup()'s "is_on: %d op_state: %d" and
    # dwc2_hsotg_core_connect()'s "called" - i.e. exactly whether the pull-up
    # reached the hardware and what state the core thought it was in. Every
    # round so far has had to INFER that from silence.
    #
    # It is verbose and belongs off once the port enumerates; the cost while
    # bringing up is a longer log, and the log is the only instrument here.
    #
    # OFF BY DEFAULT SINCE 2026-08-14, AND NOT MERELY FOR TIDINESS. The port
    # enumerates now, so it has done its job — but the option it drags in with
    # it is CONFIG_USB_DWC2_DEBUG_PERIODIC, which defaults to y and means
    # "log PERIODIC transfers too". Periodic is ISOCHRONOUS, and isochronous is
    # how UVC moves video: a high-speed gadget is handed a packet every
    # microframe, 8000 a second, whether or not there is a full frame's worth
    # to put in it. Each one turns into several dev_dbg() lines, into the
    # journal, on a 1 GHz single-core ARM11.
    #
    # That is a printk storm the moment streaming starts, and it fits what was
    # measured: enumeration is a few hundred control transfers and survives,
    # while every capture attempt wedges the whole gadget — the console with
    # it, because a CPU buried in printk is not servicing ep0 either. It also
    # explains the result that killed the bandwidth theory. 1280x720 failed
    # exactly like 1640x922, and it would: the PACKET RATE is 8000/s for both,
    # only the payload differs.
    #
    # ZERO_DWC2_DEBUG=1 puts it back for the next bring-up problem.
    say "kernel → USB_DWC2_DEBUG ${ZERO_DWC2_DEBUG:+ON (ZERO_DWC2_DEBUG=1)}${ZERO_DWC2_DEBUG:-off — it logs every isochronous packet}"
    sed -i -E '/^(# )?CONFIG_USB_DWC2_(DEBUG|VERBOSE|DEBUG_PERIODIC)( is not set|=.*)$/d' "$f"
    if [ "${ZERO_DWC2_DEBUG:-0}" = 1 ]; then
        printf 'CONFIG_USB_DWC2_DEBUG=y\n' >> "$f"
    else
        printf '# CONFIG_USB_DWC2_DEBUG is not set\n' >> "$f"
    fi

    say "kernel → +NOP_USB_XCEIV (the DT's usb-nop-xceiv phy, never built)"
    sed -i -E '/^(# )?CONFIG_(NOP_USB_XCEIV|USB_PHY|GENERIC_PHY)( is not set|=.*)$/d' "$f"
    cat >> "$f" <<'EOP'

# DashBerry: the USB PHY the device tree points at. bcm2708-rpi-zero-w.dtb has
# phys = <&usbphy> on the USB node, and usbphy is compatible = "usb-nop-xceiv".
# Without this driver dwc2's phy lookup returns -EPROBE_DEFER until the
# deferred-probe timeout, then runs with no PHY: the gadget binds, the pull-up
# "succeeds", and the port is never driven. RPi's own bcmrpi_defconfig has it.
CONFIG_GENERIC_PHY=y
CONFIG_USB_PHY=y
CONFIG_NOP_USB_XCEIV=y
EOP

    say "kernel → removing precomposed g_* gadget drivers (they steal the UDC)"
    sed -i -E '/^CONFIG_USB_(ZERO|AUDIO|ETH|G_NCM|GADGETFS|FUNCTIONFS|MASS_STORAGE|G_SERIAL|G_PRINTER|CDC_COMPOSITE|G_ACM_MS|G_MULTI|G_HID|G_DBGP|G_WEBCAM|G_UVC)=/d' "$f"
    cat >> "$f" <<'EOG'

# DashBerry: no precomposed gadget drivers. The gadget is built from configfs,
# and any g_* driver would auto-bind the first UDC to appear, beating us to it.
# CONFIG_USB_ZERO is not set
# CONFIG_USB_AUDIO is not set
# CONFIG_USB_ETH is not set
# CONFIG_USB_G_NCM is not set
# CONFIG_USB_GADGETFS is not set
# CONFIG_USB_FUNCTIONFS is not set
# CONFIG_USB_MASS_STORAGE is not set
# CONFIG_USB_G_SERIAL is not set
# CONFIG_USB_G_PRINTER is not set
# CONFIG_USB_CDC_COMPOSITE is not set
# CONFIG_USB_G_ACM_MS is not set
# CONFIG_USB_G_MULTI is not set
# CONFIG_USB_G_HID is not set
# CONFIG_USB_G_DBGP is not set
# CONFIG_USB_G_WEBCAM is not set
EOG

    say "kernel → USB gadget stack built in (was modular + modules-load)"
    sed -i -E 's/^CONFIG_USB_(DWC2|GADGET|CONFIGFS|LIBCOMPOSITE)=m$/CONFIG_USB_\1=y/' "$f"
    for k in CONFIG_USB_DWC2 CONFIG_USB_GADGET CONFIG_USB_CONFIGFS CONFIG_USB_LIBCOMPOSITE; do
        grep -q "^$k=y" "$f" || printf '%s=y\n' "$k" >> "$f"
    done

    say "kernel → Wi-Fi and Bluetooth built out entirely"
    # The existing =m lines have to go, not just be followed by a disable:
    # merge_config takes the LAST value, but leaving both is unreadable.
    sed -i -E '/^CONFIG_(BRCMFMAC|BRCMUTIL|BT|BT_[A-Z0-9_]*|CFG80211|MAC80211|WLAN|RFKILL)(=| )/d' "$f"
    cat >> "$f" <<'EOK'

# DashBerry: radio silence. The BCM43438's Wi-Fi and Bluetooth are built out
# of the kernel entirely — this board records in a locked car and speaks only
# over its USB gadget, so both radios are pure attack surface. Disabling the
# drivers is the layer that cannot be undone at runtime; the device tree
# (dtoverlay=disable-wifi / disable-bt in config.txt) and the absence of any
# brcm firmware in the rootfs are the other two.
# CONFIG_WLAN is not set
# CONFIG_CFG80211 is not set
# CONFIG_MAC80211 is not set
# CONFIG_BRCMFMAC is not set
# CONFIG_BT is not set
EOK
}

# ---------------------------------------------------------------------------
# 11. DEVICE TREE PATH — ARM DTS files moved in Linux 6.5.
#
# arch/arm/boot/dts/ was flat until 6.5, when every board's DTS was filed under
# a vendor subdirectory: bcm2708-rpi-zero-w.dts now lives in
# arch/arm/boot/dts/broadcom/. buildroot builds the DTB by asking make for
# "$(BR2_LINUX_KERNEL_INTREE_DTS_NAME).dtb", so with the unqualified name the
# kernel has no such target:
#
#   make[3]: *** No rule to make target 'arch/arm/boot/dts/bcm2708-rpi-zero-w.dtb'
#
# The name gains a broadcom/ prefix. buildroot installs the result with
# $(notdir), so the file still lands in BINARIES_DIR as
# bcm2708-rpi-zero-w.dtb, which is the name genimage-raspberrypi0w.cfg asks
# for — nothing downstream has to change.
#
# Applied to every board config, since all the bcm27xx boards moved together.
# ---------------------------------------------------------------------------
dts_needs_vendor_prefix() {         # 0 = yes, on this kernel branch
    local v maj min
    case $KERNEL_BRANCH in
    rpi-[0-9]*.[0-9]*.y)
        v=${KERNEL_BRANCH#rpi-}; v=${v%.y}
        maj=${v%%.*}; min=${v#*.}
        [ "$maj" -gt 6 ] && return 0
        [ "$maj" -eq 6 ] && [ "$min" -ge 5 ] && return 0
        return 1 ;;
    *)
        say "  (cannot read a version out of '$KERNEL_BRANCH' — assuming >= 6.5)"
        return 0 ;;
    esac
}

patch_dts_name() {
    dts_needs_vendor_prefix || {
        say "device tree paths left flat (${KERNEL_BRANCH} predates the 6.5 move)"
        return
    }
    local f found=0
    for f in "$SMW"/configs/*; do
        case $f in *_defconfig) continue ;; esac      # generated at build time
        grep -q '^BR2_LINUX_KERNEL_INTREE_DTS_NAME=' "$f" 2>/dev/null || continue
        found=1
        if grep -q 'INTREE_DTS_NAME="broadcom/' "$f"; then
            say "device tree already vendor-qualified in $(basename "$f")"
            continue
        fi
        say "device tree → broadcom/ prefix in $(basename "$f")"
        sed -i 's|^BR2_LINUX_KERNEL_INTREE_DTS_NAME="\([^/"]*\)"|BR2_LINUX_KERNEL_INTREE_DTS_NAME="broadcom/\1"|' "$f"
    done
    [ "$found" = 1 ] || die "no board config sets BR2_LINUX_KERNEL_INTREE_DTS_NAME.
  Upstream's configs/ layout has changed; the device tree name has to be
  vendor-qualified for kernels >= 6.5 and edits.sh could not find where."
}

# ---------------------------------------------------------------------------
# 12. DIAGNOSABLE WITHOUT A UART ADAPTER.
#
# Every debug channel this board has is a function of the USB gadget: the
# console is a CDC-ACM, the control port is a second one, the camera is a
# third. When the gadget fails to bind they all disappear at once — which is
# precisely the failure you most need to see inside. That leaves a UART
# adapter on the 40-pin header, or physical access with HDMI.
#
# Two cheaper channels, both built in here:
#
#   `quiet` LEAVES the kernel command line. The kernel already has
#   CONFIG_FB_SIMPLE and CONFIG_FRAMEBUFFER_CONSOLE, and cmdline already
#   carries console=tty1, so a mini-HDMI cable shows the boot — including a
#   panic — with no adapter to buy. `quiet` was blanking exactly that.
#
#   /boot/boot-report.txt, written on every boot by boot-report.service:
#   gadget state (crucially whether the UDC bound), camera nodes, service
#   status, and the tail of the kernel log. /boot is FAT, so ANY PC can read
#   it with just the SD card. Gated by /boot/enable-boot-report in the same
#   spirit as enable-serial-debug, because writing there means remounting it
#   read-write and a dashcam is power-cut without warning.
# ---------------------------------------------------------------------------
patch_boot_debug() {
    local f="$SMW/board/post-image.sh"
    anchor "$f" "Add default enable-serial-debug file" "the boot-file assembly"
    if grep -q 'enable-boot-report' "$f"; then
        say "boot diagnostics already wired — left alone"
    else
        say "cmdline → dropping 'quiet' (HDMI console is a debug channel)"
        say "boot → shipping the enable-boot-report marker"
        python3 - "$f" <<'PY4'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\t\t# Add default enable-serial-debug file"
new = (
 "\t\t# DashBerry: DROP `quiet`. Every debug channel on this board is\n"
 "\t\t# a function of the USB gadget, so when the gadget fails to bind\n"
 "\t\t# there is nothing left to ask. HDMI still works in that case\n"
 "\t\t# (CONFIG_FB_SIMPLE + FRAMEBUFFER_CONSOLE are on and cmdline\n"
 "\t\t# already carries console=tty1) and `quiet` was blanking it. A\n"
 "\t\t# boot that fails before the gadget exists is when its messages\n"
 "\t\t# matter most.\n"
 "\t\tsed -e 's/ quiet//g' -i \"${BINARIES_DIR}/rpi-firmware/cmdline.txt\"\n"
 "\n"
 "\t\t# DashBerry: marker for the boot report, same spirit as\n"
 "\t\t# enable-serial-debug below. See usr/bin/boot-report.\n"
 "\t\tcat << __EOF__ >> \"${BINARIES_DIR}/enable-boot-report\"\n"
 "# Present = the Zero writes /boot/boot-report.txt every boot: gadget state,\n"
 "# camera nodes, service status, tail of the kernel log. It exists so a card\n"
 "# that boots but does not ENUMERATE can be diagnosed with only an SD card\n"
 "# reader - when the gadget fails, console, control port and camera go too.\n"
 "#\n"
 "# DELETE THIS FILE for a card going into the car: the report remounts /boot\n"
 "# read-write, and a dashcam loses power without warning.\n"
 "__EOF__\n"
 "\n"
 "\t\t# Add default enable-serial-debug file")
assert old in s, "post-image.sh's boot-file block has changed shape"
s = s.replace(old, new, 1)
open(p, 'w').write(s)
PY4
    fi

    # genimage lists the boot partition's files explicitly, so a new file that
    # is not named there is simply never copied onto the card.
    local g
    for g in "$SMW"/board/genimage-*.cfg; do
        grep -q 'enable-serial-debug' "$g" || continue
        grep -q 'enable-boot-report' "$g" && continue
        say "genimage → +enable-boot-report ($(basename "$g"))"
        sed -i 's|"enable-serial-debug",|"enable-serial-debug",\n      "enable-boot-report",|' "$g"
    done
}

# ---------------------------------------------------------------------------
# 13. RPI FIRMWARE — optional, and the prime suspect when the kernel dies
# before it says anything.
#
# buildroot 2021.02 pins raspberrypi/firmware at d016a6eb, dated 2020-12-18.
# That start.elf is now being asked to load a 2026 kernel and a 6.16 device
# tree. The firmware/kernel interface is mostly stable, but Raspberry Pi ship
# the two together and do not support mixing eras this far apart — and the
# failure mode when it goes wrong is exactly the one seen here: the firmware
# reads the card, jumps to the kernel, and nothing further happens. No error
# code on the LED (so the firmware did not fail to FIND anything), no console,
# no USB.
#
# NOT the default, for two reasons:
#   - it is a hypothesis until the kernel is confirmed at fault, and the
#     tarball is a large download;
#   - newer firmware is where the LEGACY CAMERA STACK was progressively
#     retired, and bcm2835-v4l2 (this whole image's camera path) depends on
#     start_x.elf and the MMAL firmware behind it. Fixing boot this way could
#     cost the camera. If it does, the answer is to find the newest firmware
#     that still carries working legacy-camera support, not to abandon it.
#
#   RPI_FIRMWARE_REF=1.20260521 zero/build.sh
#
# Hashes: buildroot verifies the tarball, and we cannot know the hash of a
# revision we have not downloaded. `none` is buildroot's OWN documented value
# for "explicitly no hash" (support/download/check-hash), so this uses that
# rather than deleting the line, which would be a hard error. Pass
# RPI_FIRMWARE_SHA256=... to pin one properly once known.
# ---------------------------------------------------------------------------
patch_firmware() {
    [ -n "${RPI_FIRMWARE_REF:-}" ] || return 0
    local mk="$SMW/buildroot/package/rpi-firmware/rpi-firmware.mk"
    local hf="$SMW/buildroot/package/rpi-firmware/rpi-firmware.hash"
    anchor "$mk" "RPI_FIRMWARE_VERSION = " "the firmware pin"
    local old
    old=$(sed -n 's/^RPI_FIRMWARE_VERSION = \(.*\)/\1/p' "$mk")
    [ "$old" = "$RPI_FIRMWARE_REF" ] && { say "firmware already at $old"; return 0; }

    say "firmware → $RPI_FIRMWARE_REF (was $old, dated 2020-12-18)"
    sed -i "s|^RPI_FIRMWARE_VERSION = .*|RPI_FIRMWARE_VERSION = $RPI_FIRMWARE_REF|" "$mk"

    sed -i "/rpi-firmware-${old}\.tar\.gz/d" "$hf"
    if [ -n "${RPI_FIRMWARE_SHA256:-}" ]; then
        say "  hash pinned from RPI_FIRMWARE_SHA256"
        printf 'sha256  %s  rpi-firmware-%s.tar.gz\n' \
            "$RPI_FIRMWARE_SHA256" "$RPI_FIRMWARE_REF" >> "$hf"
    else
        say "  no hash known for this revision — recording buildroot's explicit 'none'"
        say "  (pass RPI_FIRMWARE_SHA256=... to verify it properly)"
        printf 'none  rpi-firmware-%s.tar.gz\n' "$RPI_FIRMWARE_REF" >> "$hf"
    fi

    # The buildroot submodule is patched here, so build.sh's submodule reset
    # is what keeps this from stacking across runs.
}

echo "edits.sh: patching ${SMW}"
patch_download_sites
patch_firmware
patch_busybox
patch_kernel_config
repin_kernel
patch_dts_name
patch_uvc_gadget
patch_multi_gadget
patch_camera_txt
install_overlay
patch_post_image
patch_boot_debug
echo "edits.sh: done"
