#!/usr/bin/env bash
# build.sh — build the DashBerry Zero image.
#
# Produces zero/out/dashberry-zero-<version>.img.xz: a showmewebcam card that
# streams H.264 over UVC and answers a control protocol on a second CDC-ACM
# function, so the Pi 4 can stop encoding and start owning the settings.
#
# WHY THE ZERO IS BUILT BY THIS TREE NOW
# --------------------------------------
# It used to be hand-modified and documented in ZERO_SETUP.md, which existed
# because a reflash silently reverted the rear camera and the only symptom was
# a worse picture. The card is now a build artifact: one command, a version
# string the Pi 4 checks over the cable, and no per-installation state on it
# at all. Every setting a human chooses still lives on the Pi 4
# (dashberry-install → /etc/dashberry.conf → rear-ctl), which is what makes a
# reflash safe.
#
# WHAT IT DOES
#   1. clones showmewebcam at a pinned ref (or reuses $SMW_DIR)
#   2. runs edits.sh, which repins the kernel, teaches the gadget H.264 and
#      lays our overlay down — every change anchored to an upstream string and
#      hard-failing if that string moved
#   3. runs upstream's own build-showmewebcam.sh, which merges configs/config
#      with the board config, merges the kernel config, and drives buildroot
#   4. compresses, and writes a manifest beside the image
#
# It is a BUILDROOT build: it fetches a toolchain and every package source,
# and the first run takes hours and several GB. Nothing about that is ours to
# speed up, but `work/` is kept between runs so a second build is incremental.
#
# Run `CHECK_HOST_ONLY=1 zero/build.sh` first: it audits this machine's
# toolchain against what buildroot 2021.02 expects and stops, which is seconds
# rather than the hour it would otherwise take to find out.
#
# THE KERNEL PIN, AND ITS FALLBACKS
# rpi-6.18.y, for two f_uvc fixes that rpi-6.16.y will never get because they
# landed after it went end-of-life (see zero/edits.sh section 1). VERIFIED
# 2026-08-15: it builds for raspberrypi0w and the card streams — image
# dashberry-zero-7729166, 690 frames at 1640x922@30 with 0 decoder errors.
# showmewebcam's buildroot pin needed no bump after all.
#
# If a future move fights back: KERNEL_BRANCH=rpi-6.16.y boots, but SET
# /boot/uvc-interval BACK TO 1 IF YOU TAKE IT. The default is 3, and 6.16 is
# missing 010dc57cb516/56135c0c60b0, so its f_uvc reads bInterval linearly
# where dwc2 reads it as an exponent — every interval above 1 over-commits the
# endpoint. KERNEL_BRANCH=rpi-6.12.y plus a backport of 7b5a5895 is the
# fallback below that, and predates the whole request rework, so the interval
# is unconstrained there (see zero/README.md).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out}
WORK=${WORK:-$HERE/work}

SMW_REPO=${SMW_REPO:-https://github.com/showmewebcam/showmewebcam.git}
SMW_DIR=${SMW_DIR:-$WORK/showmewebcam}

# SMW_REF empty = whatever the remote calls its default branch. Not hardcoded:
# upstream's is `master`, and guessing `main` cost a build. Set it to pin —
# `v1.91` is the newest tag at the time of writing, and pinning to a tag or a
# sha is what makes a card reproducible. Do that the moment a build succeeds.
SMW_REF=${SMW_REF:-}

resolve_ref() {                     # → the ref to check out
    [ -n "$SMW_REF" ] && { printf '%s\n' "$SMW_REF"; return; }
    local head
    head=$(git -C "$SMW_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || true
    if [ -z "$head" ]; then
        # A clone made with --depth, or an older git, may not have set it.
        git -C "$SMW_DIR" remote set-head origin -a >/dev/null 2>&1 || true
        head=$(git -C "$SMW_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || true
    fi
    [ -n "$head" ] || die "cannot work out $SMW_REPO's default branch — pass SMW_REF=<branch|tag|sha>"
    printf '%s\n' "${head#origin/}"
}

# <release>-<sha>: the release names what the card claims to be, the sha
# names the exact tree that built it. This string becomes
# /etc/dashberry-zero-version on the image, so it reaches everything that
# reads that file: rear-ctld's VERSION reply, boot-report, the manifest.
RELEASE=$(cat "$HERE/../VERSION" 2>/dev/null || echo 0.0)
VERSION=${DASHBERRY_ZERO_VERSION:-$RELEASE-$(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null || echo dev)}
export DASHBERRY_ZERO_VERSION=$VERSION

die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

BOARD=${BOARD:-raspberrypi0w}       # the Zero W. raspberrypi0 / raspberrypi4 also exist
# Buildroot's own dependency list is longer than this; these are just the ones
# whose absence would fail late and confusingly.
for t in git xz make gcc g++ bc rsync cpio unzip bzip2 perl; do
    command -v "$t" >/dev/null || die "missing tool: $t (buildroot needs a full build environment)"
done

# =========================== HOST TOOLCHAIN AUDIT ===========================
# Everything from here to the build step exists because this tree is built by
# other people on machines we have never seen. showmewebcam pins buildroot
# 2021.02.8 and its 2021 package versions; the host compiler is whatever the
# user has. Every build failure so far has come from that gap, so the rules
# here are: probe, never assume; say what was decided and why; and offer the
# one option that removes the variable entirely.

probe_cflag() {                     # $1 = flag → 0 if the C compiler takes it
    printf 'int main(void){return 0;}\n' > "$PROBE_C" 2>/dev/null || return 1
    "${CC:-gcc}" "$1" -c -o /dev/null "$PROBE_C" >/dev/null 2>&1
}

version_of() {                      # $1 = tool → its version, or "absent"
    command -v "$1" >/dev/null || { echo absent; return; }
    case $1 in
        gcc|g++) "$1" -dumpfullversion 2>/dev/null || "$1" -dumpversion ;;
        cmake)   cmake --version | sed -n '1s/.*version //p' ;;
        make)    make --version | sed -n '1s/^GNU Make //p' ;;
        perl)    perl -e 'print $^V' 2>/dev/null | sed 's/^v//' ;;
        python3) python3 --version 2>&1 | sed 's/^Python //' ;;
        *)       echo present ;;
    esac
}

major_of() { version_of "$1" | cut -d. -f1; }

host_audit() {
    GCC_MAJOR=$(major_of gcc)
    CMAKE_MAJOR=$(major_of cmake)
    RISKY=0

    echo "  gcc      $(version_of gcc)"
    echo "  g++      $(version_of g++)"
    echo "  cmake    $(version_of cmake)"
    echo "  make     $(version_of make)"
    echo "  perl     $(version_of perl)"
    echo "  python3  $(version_of python3)"

    # Known-hostile combinations, each one a failure this tree actually hit.
    case ${GCC_MAJOR:-0} in
        ''|*[!0-9]*) ;;
        *) if [ "$GCC_MAJOR" -ge 14 ]; then
               RISKY=1
               echo "  ! gcc $GCC_MAJOR turns implicit-declaration, incompatible-pointer-types"
               echo "    and int-conversion into ERRORS, and (from 15) defaults to C23."
               echo "    2021 sources trip all of these; flags below compensate."
           fi ;;
    esac
    case ${CMAKE_MAJOR:-0} in
        ''|*[!0-9]*) ;;
        *) if [ "$CMAKE_MAJOR" -ge 4 ]; then
               RISKY=1
               echo "  ! cmake $CMAKE_MAJOR dropped compatibility with pre-3.5 policy"
               echo "    minimums, which buildroot 2021.02's lzo 2.10 declares."
           fi ;;
    esac
    if [ "${GCC_MAJOR:-0}" -ge 16 ] 2>/dev/null; then
        echo "  ! gcc $GCC_MAJOR is NEWER than anything this has been run against."
        echo "    Workarounds here were written for 14 and 15. If the build fails"
        echo "    on a diagnostic that is not in the list below, that is why."
    fi
    return $RISKY
}

# --- the flags, probed rather than assumed ---------------------------------
# gcc 14 and 15 turned four long-standing warnings into errors, and code from
# 2019-2021 trips all of them:
#
#   implicit-function-declaration   an error since gcc 14, in EVERY -std mode
#   incompatible-pointer-types      an error since gcc 14
#   int-conversion                  an error since gcc 14
#   `void f()` means `void f(void)`  gcc 15 defaults to -std=gnu23
#
# Both halves are needed and both were measured: squashfs-tools 4.4 will not
# compile without the dialect flag, and fakeroot 1.25.3's CONFIGURE fails
# without the -Wno-error ones — its probe for setgroups()'s argument type calls
# puts() without <stdio.h>, so under gcc 15 it fails for an unrelated reason,
# configure writes `#define SETGROUPS_SIZE_TYPE unknown`, and the build dies
# much later on a type that does not exist. Any autoconf probe of that shape is
# silently wrong on a new host, which is why these are global.
#
# The last two are a different case: they are not gcc changing its defaults but
# a PACKAGE promoting warnings itself. systemd 247's meson.build carries its own
# list — '-Werror=format=2' among them — and gcc 15's sharper format analysis
# then flags src/core/job.c:990, a debug log line where it can prove a %s
# argument may be null. systemd is from 2020 and gcc's analysis is from 2025, so
# the code was never wrong against the compiler it was written for.
#
# That these help at all depends on meson placing environment CFLAGS AFTER a
# project's own arguments, so ours override. Verified rather than assumed:
# host-systemd fails without them and builds clean with them.
# -Wno-error=format-truncation is PREEMPTIVE — same warning family, same
# promotion, and busybox already emits truncation warnings — but nothing has
# actually failed on it yet.
#
# EVERY FLAG IS PROBED. -std=gnu17 needs gcc >= 8, and a user on an older
# distro (or on clang) must not have their build broken BY the workaround. A
# flag the compiler rejects is dropped and reported, not passed and hoped for.
select_host_cflags() {
    local candidate keep=""
    for candidate in -std=gnu17 \
                     -Wno-error=implicit-function-declaration \
                     -Wno-error=incompatible-pointer-types \
                     -Wno-error=int-conversion \
                     -Wno-error=format-overflow \
                     -Wno-error=format-truncation; do
        if probe_cflag "$candidate"; then
            keep="$keep $candidate"
        else
            echo "  - $candidate rejected by this compiler, dropped"
        fi
    done
    printf '%s' "$keep"
}

step "host toolchain"
PROBE_C=$(mktemp --suffix=.c) || die "cannot create a temp file"
trap 'rm -f "$PROBE_C"' EXIT

host_audit || HOST_IS_RISKY=1
: "${HOST_IS_RISKY:=0}"

if [ "$HOST_IS_RISKY" = 1 ]; then
    echo
    echo "  This host needs compatibility workarounds. They are applied below and"
    echo "  each one was verified against the package that needed it — but they"
    echo "  are compensation, not immunity. A host whose gcc and cmake predate"
    echo "  the changes above (Debian bookworm's gcc 12 / cmake 3.25, say) needs"
    echo "  none of them and is the surer footing if a build fights back."
fi

HOST_CFLAGS_EXTRA=$(select_host_cflags)
export HOST_CFLAGS="-O2$HOST_CFLAGS_EXTRA"
echo "  HOST_CFLAGS=$HOST_CFLAGS"
# buildroot's package/Makefile.in declares HOST_CFLAGS with `?=`, so the
# environment wins and its own `+= $(HOST_CPPFLAGS)` still appends the include
# path. pkg-cmake.mk passes it through as -DCMAKE_C_FLAGS, so cmake host
# packages are covered too (checked, not assumed).
#
# The cost of setting this globally: buildroot does HOST_CXXFLAGS +=
# HOST_CFLAGS, so C++ host packages see a C-only dialect flag and warn once per
# compile. Noise, not breakage — g++ warns and exits 0.

# CMake >= 4.0 removed compatibility with projects declaring a policy minimum
# below 3.5. lzo 2.10 (host-lzo, pulled in by host-squashfs for the squashfs
# rootfs) is one such project, and buildroot 2021.02 has no newer lzo to offer.
# CMAKE_POLICY_VERSION_MINIMUM is CMake's own documented escape hatch, honoured
# as an environment variable since 3.31.
if [ "${CMAKE_MAJOR:-0}" -ge 4 ] 2>/dev/null; then
    export CMAKE_POLICY_VERSION_MINIMUM=3.5
    echo "  CMAKE_POLICY_VERSION_MINIMUM=3.5"
fi

[ "${CHECK_HOST_ONLY:-0}" = 1 ] && { echo; echo "host check only — stopping here."; exit 0; }

step "sources"
if [ -d "$SMW_DIR/.git" ]; then
    echo "  reusing $SMW_DIR"
    # A rebuild must not stack our edits on top of the last run's edits: every
    # change edits.sh makes is idempotent by intent, but "by intent" is not a
    # guarantee worth a silently wrong card. `output` is buildroot's build
    # tree — kept, because rebuilding it from scratch costs an hour.
    git -C "$SMW_DIR" reset --hard >/dev/null
    git -C "$SMW_DIR" clean -fdx -e output >/dev/null
    # The buildroot submodule is patched too (host-squashfs' dialect flag), and
    # `reset --hard` above does not reach into it. Tracked files only - no
    # clean - so buildroot's dl/ tarball cache survives between builds.
    git -C "$SMW_DIR" submodule foreach --quiet --recursive 'git reset --hard >/dev/null' || true
else
    mkdir -p "$WORK"
    git clone --recurse-submodules "$SMW_REPO" "$SMW_DIR"
fi
REF=$(resolve_ref)
[ -n "$SMW_REF" ] || echo "  no SMW_REF set — using the remote default ($REF)"
git -C "$SMW_DIR" checkout -q "$REF" 2>/dev/null \
    || die "no such ref in $SMW_REPO: $REF
  Branches and tags it does have:
$(git -C "$SMW_DIR" branch -r --format='    %(refname:short)'; git -C "$SMW_DIR" tag | tail -n 5 | sed 's/^/    /')"
echo "  showmewebcam @ $REF = $(git -C "$SMW_DIR" rev-parse --short HEAD)"

step "DashBerry edits"
"$HERE/edits.sh" "$SMW_DIR"

# --- 2021-era buildroot on a 2026 host --------------------------------------
# showmewebcam pins buildroot 2021.02.8. Its package versions are frozen there,
# but the HOST tools are whatever this laptop has, and the two have drifted
# five years apart. Each mismatch gets a narrow, named workaround here rather
# than a blanket "disable the check", so that when the durable fix lands — a
# buildroot bump to a recent LTS — it is obvious what can be deleted.
#
# CMake >= 4.0 removed compatibility with projects declaring a policy minimum
# below 3.5. lzo 2.10 (host-lzo, pulled in by host-squashfs for the squashfs
# rootfs) is one such project, and buildroot 2021.02 has no newer lzo to offer.
# CMAKE_POLICY_VERSION_MINIMUM is CMake's own documented escape hatch for
# exactly this, honoured as an environment variable since 3.31 — it makes the
# old declaration read as 3.5 without touching any package source.
step "image ($BOARD)"
[ -x "$SMW_DIR/build-showmewebcam.sh" ] || die "no build-showmewebcam.sh in $SMW_DIR — upstream's entry point moved"
[ -f "$SMW_DIR/buildroot/Makefile" ] || die "the buildroot submodule is empty — run:
  git -C $SMW_DIR submodule update --init --recursive"
# Buildroot decides a package is done by a STAMP FILE, not by whether its
# sources changed. `git clean -e output` deliberately keeps output/ so rebuilds
# are incremental — which also keeps piwebcam's .stamp_target_installed, so
# every edit edits.sh makes to package/piwebcam/ AFTER the first successful
# build is silently ignored. That is not theoretical: a UDC wait loop added to
# multi-gadget.sh sat in the source through two builds and never reached the
# card, and the resulting card looked like a fresh bug each time.
#
# So: force-invalidate every package whose files we patch. Cheap — piwebcam is
# a few hundred KB and builds in seconds.
if [ -f "$SMW_DIR/output/$BOARD/.config" ]; then
    step "invalidate patched packages"
    # rpi-firmware owns images/rpi-firmware/config.txt, and post-image.sh
    # APPENDS to that file guarded by "if not already present". The file
    # survives in output/ across builds, so after the first build every
    # dtoverlay line is frozen: changing dr_mode in edits.sh had no effect on
    # the card for several rounds, and the card was tested against a config
    # nobody had written that week.
    for pkg in piwebcam rpi-firmware; do
        echo "  $pkg-dirclean (its sources are patched by edits.sh)"
        make -C "$SMW_DIR/output/$BOARD" "$pkg-dirclean" >/dev/null 2>&1 \
            || die "could not dirclean $pkg — a stale build of it would ship silently"
    done

    # The kernel is the same trap and a far more expensive one. Buildroot
    # applies BR2_LINUX_KERNEL_PATCH at EXTRACT time, so a patch added to an
    # already-extracted tree is simply never applied — and the card boots a
    # kernel that looks right and is not.
    #
    # But a linux-dirclean is a full rebuild, so it is done only when the patch
    # set has actually changed, keyed on a hash of the directory.
    KPATCH_DIR="$HERE/patches/linux-custom"
    KPATCH_STAMP="$SMW_DIR/.dashberry-kernel-patch-hash"
    if [ -d "$KPATCH_DIR" ]; then
        KPATCH_HASH=$(cat "$KPATCH_DIR"/*.patch 2>/dev/null | sha256sum | cut -d' ' -f1)
        if [ "$KPATCH_HASH" != "$(cat "$KPATCH_STAMP" 2>/dev/null || true)" ]; then
            echo "  linux-dirclean (kernel patch set changed — this is a full rebuild)"
            make -C "$SMW_DIR/output/$BOARD" linux-dirclean >/dev/null 2>&1 \
                || die "could not dirclean linux — the kernel patch would not be applied"
            printf '%s\n' "$KPATCH_HASH" > "$KPATCH_STAMP"
        else
            echo "  linux: kernel patch set unchanged, keeping the built tree"
        fi
    fi
fi

( cd "$SMW_DIR" && BUILDROOT_DIR=buildroot ./build-showmewebcam.sh "$BOARD" )

# --- gate: did the kernel keep the options that make the card work? --------
# This exists because of a card that flashed fine and was completely dead. The
# 5.10-era config fragment asked for CONFIG_MMC_BCM2835_SDHOST; that symbol was
# renamed to CONFIG_MMC_BCM2835 somewhere between 5.10 and 6.16, and
# olddefconfig DROPS a symbol it does not recognise without a word. The kernel
# built, booted, could not mount its root filesystem, and panicked before USB
# init — so the card enumerated nothing at all and looked bricked.
#
# Nothing about that failure pointed at the kernel config, and it cost a full
# build to find. A renamed symbol must fail the BUILD, not the board.
verify_kernel_config() {
    local cfg="$SMW_DIR/output/$BOARD/build/linux-custom/.config" missing="" sym
    [ -f "$cfg" ] || { echo "  (no kernel .config to check — skipped)"; return 0; }

    # symbol:what breaks without it. =y or =m both count.
    for sym in \
        "CONFIG_ARCH_BCM2835:the SoC itself" \
        "CONFIG_MMC_BCM2835:the SD card (brcm,bcm2835-sdhost) — no rootfs, no boot" \
        "CONFIG_SQUASHFS:the rootfs format" \
        "CONFIG_SQUASHFS_LZ4:the rootfs is squashfs4+lz4; without this it cannot be read" \
        "CONFIG_USB_DWC2:the USB controller — no gadget at all" \
        "CONFIG_NOP_USB_XCEIV:the usb-nop-xceiv PHY the DT points at — without it dwc2 runs with no PHY and never drives the port" \
        "CONFIG_USB_CONFIGFS:the gadget is built from configfs" \
        "CONFIG_USB_CONFIGFS_F_UVC:the camera function" \
        "CONFIG_USB_CONFIGFS_ACM:the console and the control port" \
        "CONFIG_VIDEO_BCM2835:bcm2835-v4l2, the sensor driver" \
        "CONFIG_BCM2835_VCHIQ:VideoCore messaging, which the camera rides on" \
        "CONFIG_SERIAL_AMBA_PL011_CONSOLE:the serial console — the only way to debug a card that will not enumerate" \
    ; do
        grep -q "^${sym%%:*}=[ym]" "$cfg" || missing="$missing
    ${sym%%:*}  — ${sym#*:}"
    done

    # The inverse check: options whose PRESENCE breaks the card. A precomposed
    # gadget driver built in will grab the UDC the instant dwc2 registers it,
    # and our configfs gadget — which can only bind once userspace writes to
    # UDC — loses every time. That is exactly how a card came back enumerating
    # as a bare serial port with no camera.
    local hostile="" h
    for h in USB_ZERO USB_AUDIO USB_ETH USB_G_NCM USB_GADGETFS USB_FUNCTIONFS \
             USB_MASS_STORAGE USB_G_SERIAL USB_G_PRINTER USB_CDC_COMPOSITE \
             USB_G_ACM_MS USB_G_MULTI USB_G_HID USB_G_DBGP USB_G_WEBCAM; do
        grep -q "^CONFIG_${h}=y" "$cfg" && hostile="$hostile
    CONFIG_${h}=y"
    done
    [ -z "$hostile" ] || die "the kernel has precomposed gadget drivers BUILT IN:$hostile

  Each of these auto-binds the first UDC that appears. This card builds its
  gadget from configfs, which binds only when userspace writes to UDC — so a
  built-in g_* driver wins the race and the card enumerates as whatever that
  driver is, with no camera. Turn them off in patch_kernel_config.
  Refusing to package this image."

    [ -z "$missing" ] || die "the kernel was built WITHOUT options this card needs:$missing

  A card built like this may flash cleanly and then do nothing at all.
  The usual cause is a symbol RENAMED since 5.10: olddefconfig drops what it
  does not recognise, silently. Find what it became —
      grep -rn 'config <NAME>' $SMW_DIR/output/$BOARD/build/linux-custom/**/Kconfig
  — and add the rename to patch_kernel_config in zero/edits.sh.
  Refusing to package this image."
    echo "  kernel config gate: all boot- and function-critical options present"
}
verify_kernel_config

# --- gate: did our patched files actually reach the rootfs? ----------------
# The stamp problem above is invisible by design: the build succeeds, the image
# is valid, and only the board shows the difference. This compares what we
# patched against what was installed, so a stale package fails the build.
verify_patched_files() {
    local t="$SMW_DIR/output/$BOARD/target" stale="" src dst
    for pair in \
        "package/piwebcam/multi-gadget.sh:/opt/uvc-webcam/multi-gadget.sh" \
        "package/piwebcam/start-webcam.sh:/opt/uvc-webcam/start-webcam.sh" \
    ; do
        src="$SMW_DIR/${pair%%:*}"; dst="$t${pair#*:}"
        [ -f "$src" ] && [ -f "$dst" ] || continue
        cmp -s "$src" "$dst" || stale="$stale
    ${pair#*:}  differs from ${pair%%:*}"
    done
    [ -z "$stale" ] || die "files we patched did NOT reach the built rootfs:$stale

  Buildroot considered the package already installed and skipped it. The image
  would look fine and behave like the unpatched one. Add the package to the
  dirclean list above.
  Refusing to package this image."
    echo "  patched-file gate: what we patched is what shipped"
}
verify_patched_files

# --- gate: did our kernel patches actually get applied? --------------------
# Same failure as a stale package, but worse to find: the kernel is extracted
# once and reused, so an unapplied patch is invisible. The card boots, the
# camera enumerates, and only STREAMING is broken — a whole bench session to
# discover, which is exactly how it was discovered.
verify_kernel_patched() {
    local src="$SMW_DIR/output/$BOARD/build/linux-custom/drivers/usb/gadget/function/uvc_video.c"
    [ -f "$src" ] || { echo "  (no kernel source tree to check — skipped)"; return 0; }
    grep -q 'case -ENODATA:' "$src" || die "the built kernel does NOT carry our uvc_video.c patch.
    wanted: 'case -ENODATA:' in drivers/usb/gadget/function/uvc_video.c

  Buildroot applies BR2_LINUX_KERNEL_PATCH when it EXTRACTS the kernel, so a
  patch added to an already-extracted tree is never applied. The card would
  boot, enumerate, and stream nothing: f_uvc cancels the video queue on the
  first missed isochronous slot and dwc2 reports those as -ENODATA.
  Run: make -C $SMW_DIR/output/$BOARD linux-dirclean
  Refusing to package this image."
    echo "  kernel-patch gate: uvc_video.c carries the -ENODATA case"
}
verify_kernel_patched

# --- gate: is the boot config the one we asked for? ------------------------
# Same failure as the stale package, one directory over: post-image.sh only
# appends what is not already in config.txt, and that file outlives the build
# that wrote it. This checks the USB role actually shipped, because getting it
# wrong costs a card that never enumerates and looks like a driver bug.
verify_boot_config() {
    local cfg="$SMW_DIR/output/$BOARD/images/rpi-firmware/config.txt" want
    [ -f "$cfg" ] || { echo "  (no config.txt to check — skipped)"; return 0; }
    case ${ZERO_DR_MODE:-otg} in
        otg) want="dtoverlay=dwc2" ;;
        *)   want="dtoverlay=dwc2,dr_mode=${ZERO_DR_MODE}" ;;
    esac
    grep -qx "$want" "$cfg" || die "the built config.txt does not carry the USB role we asked for.
    wanted: $want
    found : $(grep -E '^dtoverlay=dwc2' "$cfg" || echo '(no dtoverlay=dwc2 line at all)')

  post-image.sh appends that line only when it is absent, and
  images/rpi-firmware/config.txt persists across builds — so a stale one is
  never corrected. rpi-firmware should have been dircleaned above.
  Refusing to package this image."
    echo "  boot config gate: $want"
}
verify_boot_config

IMG="$SMW_DIR/output/$BOARD/images/sdcard.img"
[ -f "$IMG" ] || die "the build produced no $IMG — read the log above"

step "package"
mkdir -p "$OUT"
DEST="$OUT/dashberry-zero-$VERSION.img"
cp "$IMG" "$DEST"
xz -T0 -f "$DEST"
cat > "$OUT/dashberry-zero-$VERSION.manifest" <<EOF
version        $VERSION
built          $(date -u +%Y-%m-%dT%H:%M:%SZ)
showmewebcam   $REF = $(git -C "$SMW_DIR" rev-parse HEAD)
board          $BOARD
kernel         ${KERNEL_BRANCH:-rpi-6.18.y} @ $(cat "$SMW_DIR/.dashberry-kernel-sha" 2>/dev/null || echo '?')
host gcc       $(version_of gcc)
host cmake     $(version_of cmake)
host cflags    $HOST_CFLAGS
image          $(basename "$DEST").xz
sha256         $(sha256sum "$DEST.xz" | cut -d' ' -f1)
EOF

echo
echo "built $DEST.xz"
echo "flash it with:  sudo cli/dashberry-zero --flash /dev/sdX --image $DEST.xz"
echo "then check it:  sudo cli/dashberry-zero --check"
