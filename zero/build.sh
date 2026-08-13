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
# THE PART THAT IS NOT SETTLED
# The kernel repin (5.10.11 → rpi-6.16.y) is the risk in this build, and it is
# unproven at the time of writing: showmewebcam's buildroot pin predates 6.x
# host-tool requirements, so buildroot itself may need bumping, and an ARMv6
# Zero W has never been built or booted on that branch here. If it fights
# back, KERNEL_BRANCH=rpi-6.12.y plus a backport of 7b5a5895 is the documented
# fallback (see zero/README.md).
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

VERSION=${DASHBERRY_ZERO_VERSION:-$(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null || echo dev)}
export DASHBERRY_ZERO_VERSION=$VERSION

die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

BOARD=${BOARD:-raspberrypi0w}       # the Zero W. raspberrypi0 / raspberrypi4 also exist

# Buildroot's own dependency list is longer than this; these are just the ones
# whose absence would fail late and confusingly.
for t in git xz make gcc g++ bc rsync cpio unzip bzip2 perl; do
    command -v "$t" >/dev/null || die "missing tool: $t (buildroot needs a full build environment)"
done

step "sources"
if [ -d "$SMW_DIR/.git" ]; then
    echo "  reusing $SMW_DIR"
    # A rebuild must not stack our edits on top of the last run's edits: every
    # change edits.sh makes is idempotent by intent, but "by intent" is not a
    # guarantee worth a silently wrong card. `output` is buildroot's build
    # tree — kept, because rebuilding it from scratch costs an hour.
    git -C "$SMW_DIR" reset --hard >/dev/null
    git -C "$SMW_DIR" clean -fdx -e output >/dev/null
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
if command -v cmake >/dev/null; then
    CMAKE_MAJOR=$(cmake --version | sed -n '1s/.*version \([0-9]*\).*/\1/p')
    if [ "${CMAKE_MAJOR:-0}" -ge 4 ]; then
        export CMAKE_POLICY_VERSION_MINIMUM=3.5
        echo "  cmake $CMAKE_MAJOR.x: exporting CMAKE_POLICY_VERSION_MINIMUM=3.5"
        echo "  (buildroot 2021.02.8's lzo 2.10 predates cmake 4's policy floor)"
    fi
fi

step "image ($BOARD)"
[ -x "$SMW_DIR/build-showmewebcam.sh" ] || die "no build-showmewebcam.sh in $SMW_DIR — upstream's entry point moved"
[ -f "$SMW_DIR/buildroot/Makefile" ] || die "the buildroot submodule is empty — run:
  git -C $SMW_DIR submodule update --init --recursive"
( cd "$SMW_DIR" && BUILDROOT_DIR=buildroot ./build-showmewebcam.sh "$BOARD" )

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
kernel         ${KERNEL_BRANCH:-rpi-6.16.y} @ $(cat "$SMW_DIR/.dashberry-kernel-sha" 2>/dev/null || echo '?')
image          $(basename "$DEST").xz
sha256         $(sha256sum "$DEST.xz" | cut -d' ' -f1)
EOF

echo
echo "built $DEST.xz"
echo "flash it with:  sudo cli/dashberry-zero --flash /dev/sdX --image $DEST.xz"
echo "then check it:  sudo cli/dashberry-zero --check"
