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
# h264_i_period, compression_quality, auto_exposure_bias).
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

    mkdir -p "$OVERLAY/etc/systemd/system/basic.target.wants"
    ln -sf ../rear-ctld.service "$OVERLAY/etc/systemd/system/basic.target.wants/rear-ctld.service"
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
# (a) dr_mode=peripheral. Upstream appends a BARE `dtoverlay=dwc2`, which
#     leaves the controller in OTG mode, where the port's role is decided by
#     the ID pin in the cable. A micro-USB converter or right-angle adapter
#     that grounds ID — and the BOM has two of those in the rear cable run —
#     tells the Zero to be a HOST, and it then never enumerates as a camera at
#     all. The Zero is only ever a peripheral in this design, so saying so is
#     both correct and deterministic: the role stops depending on which
#     adapter is in the run.
# (b) gpu_mem=256 on a 512 MB Zero W. The hardware encoder needs it, and it
#     needs it MORE now than when this was an MJPEG card.
# ---------------------------------------------------------------------------
patch_post_image() {
    local f="$SMW/board/post-image.sh"
    anchor "$f" "--configure-picam)" "the boot config.txt assembly"
    anchor "$f" "dtoverlay=dwc2" "the picam boot-config block"

    if grep -q 'dr_mode=peripheral' "$f"; then
        say "post-image.sh already forces peripheral mode — left alone"
    else
        say "post-image.sh → dtoverlay=dwc2,dr_mode=peripheral"
        # The existing guard greps ^dtoverlay=dwc2, which still matches the
        # longer line, so this stays idempotent across rebuilds.
        python3 - "$f" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"
dtoverlay=dwc2
__EOF__'''
new = '''			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"
# DashBerry: dr_mode=peripheral, not the overlay's default of otg. In OTG the
# port's role is decided by the ID pin, so a micro-USB converter or
# right-angle adapter that grounds ID makes the Zero try to be a HOST and it
# never enumerates as a camera. This board is only ever a peripheral.
dtoverlay=dwc2,dr_mode=peripheral
__EOF__'''
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

echo "edits.sh: patching ${SMW}"
patch_download_sites
patch_busybox
patch_kernel_config
repin_kernel
patch_uvc_gadget
patch_multi_gadget
patch_camera_txt
install_overlay
patch_post_image
echo "edits.sh: done"
