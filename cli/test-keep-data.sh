#!/bin/bash
# test-keep-data.sh — end-to-end harness for `dashberry-install --root-size keep`.
#
# WHY THIS EXISTS. `--root-size keep` re-adopts the /data partition already on
# a card instead of reformatting it, which means the one thing it must never
# do is lose footage. That is not a property you want to first exercise on a
# card with a drive on it, so this builds a FAKE card in a sparse file, runs
# the real installer against it through a loop device, and asserts the
# footage came back byte for byte.
#
#   sudo ./cli/test-keep-data.sh [/path/to/raspios-lite.img[.xz]]
#
# With no image argument it synthesises a minimal 2-partition stand-in (vfat +
# ext4). That exercises everything this feature touches — the layout read, the
# spared wipe, the post-flash superblock check, the OS sizing and the
# re-adopt — and then the installer fails later, in OS customisation, because
# the stand-in is not really Raspberry Pi OS. That failure is EXPECTED and the
# assertions below still hold; pass a real image for a genuine full run.
#
# Needs root (losetup, mkfs, mount). Touches nothing outside its temp dir and
# the loop devices it creates.
set -u

[ "$(id -u)" = 0 ] || { echo "run as root (losetup/mount)" >&2; exit 1; }
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
INSTALLER="$HERE/dashberry-install"
[ -x "$INSTALLER" ] || { echo "not found: $INSTALLER" >&2; exit 1; }
USER_IMG=${1:-}

WORK=$(mktemp -d); LOOPS=()
cleanup() {
    for l in "${LOOPS[@]:-}"; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %-42s = %s\n' "$1" "$3"
       else fail=$((fail+1)); printf '  FAIL %-42s expected %s, got %s\n' "$1" "$2" "$3"; fi; }

# --- build a fake DashBerry card -------------------------------------------
# 20 GiB sparse: 512 MiB boot | 8 GiB OS | rest /data, msdos, matching what
# dashberry-install itself produces.
make_card() {                       # $1=path  $2=data_start_MiB (8704 = normal)
    truncate -s 20G "$1"
    local lo; lo=$(losetup --show -f -P "$1"); LOOPS+=("$lo")
    sfdisk -q "$lo" >/dev/null 2>&1 <<EOF
label: dos
${lo}p1 : start=8192, size=1048576, type=c
${lo}p2 : start=1056768, size=$(( ($2 - 512) * 2048 )), type=83
${lo}p3 : start=$(( $2 * 2048 )), size=$(( (20480 - $2) * 2048 )), type=83
EOF
    partprobe "$lo"; udevadm settle
    mkfs.vfat -F 32 "${lo}p1" >/dev/null 2>&1
    mkfs.ext4 -q -F "${lo}p2"
    mkfs.ext4 -q -F -L dashberry-data "${lo}p3"
    echo "$lo"
}

plant_footage() {                   # $1=loopdev -> writes markers into p3
    local m; m=$(mktemp -d)
    mount "${1}p3" "$m"
    mkdir -p "$m/front/2026-08-09T12-00-00" "$m/rear/2026-08-09T12-00-00" "$m/gps"
    head -c 3000000 /dev/urandom > "$m/front/2026-08-09T12-00-00/00000.ts"
    head -c 1500000 /dev/urandom > "$m/rear/2026-08-09T12-00-00/00000.ts"
    echo "marker" > "$m/gps/2026-08-09T12-00-00.nmea"
    ( cd "$m" && find . -type f -exec sha256sum {} \; | sort ) > "$WORK/before.sha"
    umount "$m"; rmdir "$m"
}

synth_image() {                     # minimal 2-partition stand-in
    local img="$WORK/synth.img"
    truncate -s 3G "$img"
    local lo; lo=$(losetup --show -f -P "$img"); LOOPS+=("$lo")
    sfdisk -q "$lo" >/dev/null 2>&1 <<EOF
label: dos
${lo}p1 : start=8192, size=1048576, type=c
${lo}p2 : start=1056768, size=5242880, type=83
EOF
    partprobe "$lo"; udevadm settle
    mkfs.vfat -F 32 "${lo}p1" >/dev/null 2>&1
    mkfs.ext4 -q -F "${lo}p2"
    losetup -d "$lo"
    echo "$img"
}

run_installer() {                   # $1=loopdev $2=image ; feeds confirmation
    printf '%s\n' "$1" | "$INSTALLER" --root-size keep "$2" "$1" \
        > "$WORK/out.log" 2>&1
    echo $?
}

IMG=${USER_IMG:-$(synth_image)}
echo "image: $IMG"

# ==========================================================================
echo
echo "== CASE 1: normal card, footage must survive =="
CARD=$(make_card "$WORK/card.img" 8704)
plant_footage "$CARD"
p3start() { sfdisk -d "$1" | awk '$1 ~ /p3$/ {for(i=3;i<=NF;i++) if($i=="start="){v=$(i+1);sub(/,$/,"",v);print v;exit}}'; }
before_start=$(p3start "$CARD")
before_uuid=$(blkid -p -o value -s UUID "${CARD}p3")
rc=$(run_installer "$CARD" "$IMG")
echo "  installer exit $rc (non-zero is expected with a synthetic image)"
grep -q "keeping ${CARD}p3" "$WORK/out.log" && echo "  (wipe was skipped for p3)"

partprobe "$CARD" 2>/dev/null; udevadm settle
after_start=$(p3start "$CARD")
after_uuid=$(blkid -p -o value -s UUID "${CARD}p3" 2>/dev/null || echo MISSING)
ck "p3 start sector unchanged" "$before_start" "$after_start"
ck "p3 filesystem UUID unchanged" "$before_uuid" "$after_uuid"

e2fsck -fn "${CARD}p3" >/dev/null 2>&1; ck "e2fsck clean on preserved /data" 0 "$?"
m=$(mktemp -d); mount "${CARD}p3" "$m"
( cd "$m" && find . -type f -exec sha256sum {} \; | sort ) > "$WORK/after.sha"
umount "$m"; rmdir "$m"
if diff -q "$WORK/before.sha" "$WORK/after.sha" >/dev/null; then
    ck "every footage file byte-identical" same same
else
    ck "every footage file byte-identical" same differs
    diff "$WORK/before.sha" "$WORK/after.sha" | head
fi
p2end=$(sfdisk -d "$CARD" | awk '$1 ~ /p2$/ {for(i=3;i<=NF;i++){if($i=="start="){s=$(i+1);sub(/,$/,"",s)}; if($i=="size="){z=$(i+1);sub(/,$/,"",z)}}; print s+z; exit}')
ck "OS partition abuts /data exactly" "$after_start" "$p2end"

# ==========================================================================
echo
echo "== CASE 2..5: refusals (device must be left alone) =="
neg() {   # $1=label  $2=loopdev  $3=expected substring
    local out; out=$(printf '%s\n' "$2" | "$INSTALLER" --root-size keep "$IMG" "$2" 2>&1)
    if printf '%s' "$out" | grep -qi -- "$3"; then
        pass=$((pass+1)); printf '  ok   %-42s refused\n' "$1"
    else
        fail=$((fail+1)); printf '  FAIL %-42s no "%s" in output:\n%s\n' "$1" "$3" "$(printf '%s' "$out" | tail -3)"
    fi
}

TWO=$(mktemp -u "$WORK/two.XXXX.img"); truncate -s 20G "$TWO"
lo2=$(losetup --show -f -P "$TWO"); LOOPS+=("$lo2")
sfdisk -q "$lo2" >/dev/null 2>&1 <<EOF
label: dos
${lo2}p1 : start=8192, size=1048576, type=c
${lo2}p2 : start=1056768, size=16777216, type=83
EOF
partprobe "$lo2"; udevadm settle
neg "two-partition card" "$lo2" "expected 3"

BADL=$(mktemp -u "$WORK/badl.XXXX.img")
lo3=$(make_card "$BADL" 8704)
mkfs.ext4 -q -F -L someone-elses "${lo3}p3"
neg "third partition with a foreign label" "$lo3" "labelled"

GPTC=$(mktemp -u "$WORK/gpt.XXXX.img"); truncate -s 20G "$GPTC"
lo4=$(losetup --show -f -P "$GPTC"); LOOPS+=("$lo4")
sgdisk -n 1:8192:+512M -n 2:0:+8G -n 3:0:0 "$lo4" >/dev/null 2>&1 \
  || sfdisk -q -X gpt "$lo4" >/dev/null 2>&1 <<EOF
start=8192, size=1048576
start=1056768, size=16777216
start=17833984, size=24000000
EOF
partprobe "$lo4"; udevadm settle
mkfs.ext4 -q -F -L dashberry-data "${lo4}p3" 2>/dev/null
neg "GPT-labelled card" "$lo4" "partition table"

OVER=$(mktemp -u "$WORK/over.XXXX.img")
lo5=$(make_card "$OVER" 1024)       # /data starts at 1 GiB — the image will hit it
plant_footage "$lo5"
neg "image would overwrite /data" "$lo5" "overwrote /data"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
