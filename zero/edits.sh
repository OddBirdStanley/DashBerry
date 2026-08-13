#!/usr/bin/env bash
# edits.sh — turn a stock showmewebcam checkout into the DashBerry Zero.
#
# Called by build.sh with the checkout directory as $1. Every change is
# ANCHORED: it finds an exact string in upstream, fails loudly if that string
# is not there, and only then rewrites it. Nothing here is a .patch file,
# deliberately — a patch that fails to apply says "hunk #2 failed", while this
# says which upstream assumption moved and what it was for.
#
# The anchors come from a source review dated 2026-08-13
# (INVESTIGATE-REAR-ENCODE.md §2). They are checked at BUILD time, not at
# review time: if upstream has moved since, this stops rather than producing a
# card that looks right and streams the wrong thing.
set -euo pipefail

SMW=${1:?usage: edits.sh <showmewebcam-checkout>}
HERE=$(cd "$(dirname "$0")" && pwd)

say()  { printf '  %s\n' "$*"; }
die()  { printf 'edits.sh: %s\n' "$*" >&2; exit 1; }

# anchor <file> <fixed-string> <what-it-is-for>
anchor() {
    [ -f "$1" ] || die "expected file missing: $1
    ($3)
    Upstream layout has changed. Re-read the file and update edits.sh."
    grep -qF -- "$2" "$1" || die "anchor not found in $1:
      \"$2\"
    ($3)
    Upstream has moved. Do NOT loosen this check — read the file, work out
    what replaced it, and update edits.sh so the next build is still honest."
}

# ---------------------------------------------------------------------------
# 1. KERNEL — repin off 5.10.11.
#
# showmewebcam pins raspberrypi/linux @ 6af8ae32 = Linux 5.10.11, and in that
# tree drivers/usb/gadget/function/uvc_configfs.c has:
#
#     static const char * const uvcg_format_names[] = { "uncompressed", "mjpeg", };
#
# No framebased, no H264, no guidFormat: there is no configfs directory the
# gadget could advertise H.264 in, so the whole design is blocked on that one
# array. Frame-based format support was accepted upstream in Sept 2024
# (commit 7b5a5895) and reaches the RPi tree in rpi-6.13.y.
#
# We take rpi-6.16.y, which needs NO kernel patch and still carries
# drivers/staging/vc04_services/bcm2835-camera — the legacy MMAL driver this
# image depends on for the sensor AND for the encoder controls
# (video_bitrate, h264_i_period, compression_quality, auto_exposure_bias).
# Fallback if an ARMv6 Zero W will not build or boot on it: rpi-6.12.y (the
# protected long-term branch) plus a single backport of 7b5a5895.
# ---------------------------------------------------------------------------
KERNEL_BRANCH=${KERNEL_BRANCH:-rpi-6.16.y}

repin_kernel() {
    local cfg
    say "kernel → $KERNEL_BRANCH"
    mapfile -t cfg < <(grep -rl 'BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION' "$SMW" \
                       --include='*_defconfig' --include='*.config' 2>/dev/null || true)
    [ "${#cfg[@]}" -gt 0 ] || die "no defconfig carrying BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION.
    Upstream may have switched to a released-tarball kernel. Read the
    buildroot config before changing anything."
    for f in "${cfg[@]}"; do
        sed -i "s|^BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION=.*|BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION=\"$KERNEL_BRANCH\"|" "$f"
        say "  repinned $(basename "$f")"
    done

    # showmewebcam's own kernel patches are written against 5.10 and will not
    # apply. Removing them is EXPECTED, not a workaround — but it is also the
    # single most likely reason a first build on this branch misbehaves, so it
    # is announced rather than done quietly.
    if [ -d "$SMW/patches/linux-custom" ] && [ -n "$(ls -A "$SMW/patches/linux-custom" 2>/dev/null)" ]; then
        say "  dropping patches/linux-custom (written against 5.10, will not apply):"
        ls "$SMW/patches/linux-custom" | sed 's/^/    /'
        rm -rf "$SMW/patches/linux-custom"
    fi
}

# ---------------------------------------------------------------------------
# 2. uvc-gadget — teach it the H.264 fourcc.
#
# peterbay's uvc-gadget picks the V4L2 pixel format from THE FIRST CHARACTER
# of the configfs format instance name: 'm' → V4L2_PIX_FMT_MJPEG, 'u' →
# V4L2_PIX_FMT_YUYV, and nothing else. That is the entire format-selection
# logic, which is why this change is small — but it is also why an unpatched
# daemon silently streams the wrong thing rather than failing.
# ---------------------------------------------------------------------------
patch_uvc_gadget() {
    local src
    src=$(grep -rl 'V4L2_PIX_FMT_MJPEG' "$SMW" --include='*.c' 2>/dev/null \
          | grep -i 'configfs\|uvc' | head -n 1 || true)
    [ -n "$src" ] || die "cannot find uvc-gadget's format-selection source in $SMW.
    It is normally fetched as a buildroot package rather than vendored — run
    build.sh with PREFETCH=1 first so the source tree exists, or point
    UVC_GADGET_SRC at it."
    anchor "$src" "V4L2_PIX_FMT_MJPEG" "uvc-gadget's fourcc selection"
    say "uvc-gadget → +h264 ($(basename "$src"))"

    if grep -q 'V4L2_PIX_FMT_H264' "$src"; then
        say "  already carries an H264 branch — left alone"
        return
    fi
    # Insert the 'h' case beside the existing 'm'. The case is on the first
    # character of the configfs instance name, so a format directory called
    # framebased.h/ selects H.264.
    python3 - "$src" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(r"case\s+'m'\s*:", s)
if not m:
    sys.exit("edits.sh: no \"case 'm':\" in %s — uvc-gadget's fourcc switch has "
             "changed shape. Read it and update edits.sh." % p)
ins = ("case 'h':\t\t/* DashBerry: framebased.h -> H.264 from the Zero's\n"
       "\t\t\t * hardware encoder. The Pi 4 cannot software-encode\n"
       "\t\t\t * any usable mode at 30 fps; see\n"
       "\t\t\t * INVESTIGATE-REAR-ENCODE.md. */\n"
       "\t\tformat = V4L2_PIX_FMT_H264;\n"
       "\t\tbreak;\n\t")
s = s[:m.start()] + ins + s[m.start():]
open(p, 'w').write(s)
PY
}

# ---------------------------------------------------------------------------
# 3. multi-gadget.sh — accept the h264 keyword in video_formats.txt.
#
# Upstream parses that file with
#   grep -E "^(mjpeg|uncompressed)[[:space:]]+..."
# so an h264 line is silently DROPPED — the gadget comes up advertising
# nothing new and the failure looks like a caps mismatch on the Pi 4.
# ---------------------------------------------------------------------------
patch_multi_gadget() {
    local f="$SMW/package/piwebcam/multi-gadget.sh"
    anchor "$f" "mjpeg|uncompressed" "multi-gadget.sh's video_formats.txt parser"
    say "multi-gadget.sh → +h264 keyword"
    sed -i 's/mjpeg|uncompressed/mjpeg|uncompressed|h264/g' "$f"

    # A format directory's TYPE decides the descriptor: uncompressed/ and
    # mjpeg/ exist on every kernel, framebased/ only from rpi-6.13.y on, and
    # it is what carries a guidFormat (H.264 by default). The instance name
    # must start with 'h' for the daemon patched above to pick the fourcc.
    if ! grep -q 'framebased' "$f"; then
        anchor "$f" "mjpeg" "the format-directory name multi-gadget.sh creates"
        say "  NOTE: multi-gadget.sh needs a framebased/ branch for h264 lines."
        say "        It is scripted below, but READ THE RESULT — this is the"
        say "        one edit here that is a guess at upstream's shape."
        cat >> "$f" <<'SH'

# --- DashBerry ---------------------------------------------------------
# h264 lines in video_formats.txt become framebased/ format instances. The
# UVC gadget's framebased format defaults to the H.264 GUID, so nothing more
# has to be said; the instance name starting with 'h' is what tells
# uvc-gadget to ask the capture device for V4L2_PIX_FMT_H264.
# Kernel >= 6.13 only: on anything older this directory cannot be created,
# and the build should have failed at the kernel repin long before here.
dashberry_h264_format() {          # $1 = width, $2 = height, $3 = index
    local d="$FUNC/streaming/framebased/h$3"
    mkdir -p "$d/${1}x${2}p" || {
        echo "multi-gadget: no framebased/ support in this kernel — the" >&2
        echo "  DashBerry image needs >= rpi-6.13.y. Refusing to advertise" >&2
        echo "  MJPEG in its place: the Pi 4 expects H.264." >&2
        return 1
    }
    echo "$1" > "$d/${1}x${2}p/wWidth"
    echo "$2" > "$d/${1}x${2}p/wHeight"
    echo 333333 > "$d/${1}x${2}p/dwDefaultFrameInterval"
    echo 333333 > "$d/${1}x${2}p/dwFrameInterval"
}
SH
    fi
}

# ---------------------------------------------------------------------------
# 4. camera.txt — stop shipping a live 25 Mbps setting.
#
# showmewebcam's camera.txt carries video_bitrate=25000000. On an MJPEG card
# that line is INERT — it is V4L2_CID_MPEG_VIDEO_BITRATE, an H.264 control on
# a gadget that never encoded H.264, and it is the origin of the retracted
# "~25 Mbps MJPEG floor" claim. THE MOMENT THIS IMAGE ENCODES H.264 IT BECOMES
# LIVE, and it would quietly make the rear a 25 Mbps camera: ~11 GB/h, which
# on its own halves the drive history a 256 GB card holds.
#
# It does not get a corrected value here. It LEAVES, because bitrate is the
# Pi 4's to own (dashberry.conf REAR_BITRATE, pushed by rear-ctl) and nothing
# per-installation may live on this card.
# ---------------------------------------------------------------------------
patch_camera_txt() {
    local f
    f=$(find "$SMW" -name camera.txt -not -path '*/.git/*' | head -n 1 || true)
    [ -n "$f" ] || { say "camera.txt not in the tree (generated at boot?) — skipped"; return; }
    if grep -q '^video_bitrate' "$f"; then
        say "camera.txt → dropping the shipped video_bitrate (rear-ctl owns it)"
        sed -i 's/^video_bitrate=.*/# video_bitrate: REMOVED by DashBerry — the Pi 4 pushes it (rear-ctl).\n# Left here it would be a live 25 Mbps setting the moment this card encodes./' "$f"
    fi
}

# ---------------------------------------------------------------------------
# 5. Our own files.
# ---------------------------------------------------------------------------
install_overlay() {
    local dest
    dest=$(grep -rhoP '(?<=^BR2_ROOTFS_OVERLAY=").*(?=")' "$SMW"/*_defconfig "$SMW"/configs/*_defconfig 2>/dev/null | head -n 1 || true)
    dest=${dest:-board/raspberrypi/rootfs_overlay}
    dest="$SMW/${dest#\$(BR2_EXTERNAL_*_PATH)/}"
    say "overlay → ${dest#"$SMW"/}"
    mkdir -p "$dest"
    cp -a "$HERE/overlay/." "$dest/"
    chmod 755 "$dest/usr/bin/rear-ctld" "$dest/etc/init.d/S95rear-ctld"
    printf '%s\n' "${DASHBERRY_ZERO_VERSION:-dev}" > "$dest/etc/dashberry-zero-version"

    # gpu_mem=256 on a 512 MB Zero W — one of the three deviations this card
    # already carried before H.264 (with advertised resolutions and USB
    # peripheral mode), now tracked instead of hand-edited.
    local cfg="$dest/boot/config.txt"
    mkdir -p "$(dirname "$cfg")"
    grep -q '^gpu_mem=256' "$cfg" 2>/dev/null || echo 'gpu_mem=256' >> "$cfg"
}

echo "edits.sh: patching $SMW"
repin_kernel
patch_uvc_gadget
patch_multi_gadget
patch_camera_txt
install_overlay
echo "edits.sh: done"
