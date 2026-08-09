#!/bin/bash
# test-keep-data.sh — end-to-end harness for `dashberry-install --root-size keep`.
#
# WHY THIS EXISTS. `--root-size keep` re-adopts the /data partition already on
# a card instead of reformatting it, which means the one thing it must never
# do is lose footage. That is not a property to first exercise on a card with
# a drive on it, so this builds a FAKE card in a sparse file, runs the real
# installer against it through a loop device, and asserts the footage came
# back byte for byte.
#
#   sudo ./cli/test-keep-data.sh [/path/to/raspios-lite.img[.xz]]
#   ./cli/test-keep-data.sh --self-test        # geometry only, no root needed
#
# With no image argument it synthesises a minimal 2-partition stand-in (vfat +
# ext4). That exercises everything this feature touches — the layout read, the
# spared wipe, the post-flash superblock check, the OS sizing and the
# re-adopt — and then the installer fails later, in OS customisation, because
# the stand-in is not really Raspberry Pi OS. That failure is EXPECTED and the
# assertions below still hold; pass a real image for a genuine full run.
#
# --self-test needs no root and no loop devices: it builds the same partition
# tables in plain files and checks sfdisk accepts them. It exists because the
# first version of this harness had TWO fixture bugs that a hidden `2>&1`
# swallowed — p3 laid down 8192 sectors inside p2 (p1 starts at 4 MiB, so p2
# ends at 516 MiB + root, not at root), and a 3 GiB stand-in whose p2 ran 8192
# sectors past the end of the file. Neither wrote a partition table at all,
# and the run still reported "ok" for a comparison of "" against "". Fixture
# arithmetic is now derived rather than written out, checked here, and every
# fixture is validated before a single assertion is allowed to run.
set -u

# --- partition geometry, derived so the pieces cannot drift apart -----------
# One 512 MiB boot at 4 MiB, then the OS, then /data taking the rest bar a
# 1 MiB tail. Every start is the previous partition's end: nothing is written
# as an absolute offset, which is exactly how the original bug got in.
SECT_PER_MIB=2048
P1_START=8192                                  # 4 MiB
P1_SIZE=$((512 * SECT_PER_MIB))                # 512 MiB boot
P2_START=$((P1_START + P1_SIZE))               # 1056768
geom() {            # geom TOTAL_MIB ROOT_MIB -> "p2size p3start p3size"
    local total=$(($1 * SECT_PER_MIB)) root=$(($2 * SECT_PER_MIB))
    local p3s=$((P2_START + root))
    local p3z=$((total - p3s - SECT_PER_MIB))  # 1 MiB slack at the end
    printf '%s %s %s\n' "$root" "$p3s" "$p3z"
}

pass=0; fail=0
ck()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %-42s = %s\n' "$1" "$3"
        else fail=$((fail+1)); printf '  FAIL %-42s expected %s, got %s\n' "$1" "$2" "$3"; fi; }
die() { echo "FIXTURE ERROR: $*" >&2; exit 1; }

# --- self-test: no root, no loop devices -----------------------------------
if [ "${1:-}" = --self-test ]; then
    echo "== self-test: fixture geometry (plain files, no root) =="
    t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
    check_layout() {   # check_layout LABEL TOTAL_MIB ROOT_MIB NPARTS
        local lbl=$1 total=$2 root=$3 nparts=$4 f="$t/$1.img" p2z p3s p3z out rc
        read -r p2z p3s p3z <<<"$(geom "$total" "$root")"
        truncate -s "${total}M" "$f"
        {
            echo "label: dos"
            echo "${f}1 : start=$P1_START, size=$P1_SIZE, type=c"
            echo "${f}2 : start=$P2_START, size=$p2z, type=83"
            [ "$nparts" = 3 ] && echo "${f}3 : start=$p3s, size=$p3z, type=83"
        } > "$t/script"
        out=$(sfdisk -q "$f" < "$t/script" 2>&1); rc=$?
        if [ "$rc" -eq 0 ]; then
            ck "$lbl accepted by sfdisk" 0 0
        else
            fail=$((fail+1))
            printf '  FAIL %-42s sfdisk rc=%s: %s\n' "$lbl" "$rc" \
                "$(printf '%s' "$out" | grep -iE 'no free|no space|overlap|error|Failed' | head -1)"
        fi
        # p3 must begin exactly where p2 ends — the invariant that broke.
        if [ "$nparts" = 3 ]; then
            ck "$lbl p3 abuts p2" "$((P2_START + p2z))" "$p3s"
            ck "$lbl p3 ends inside the file" yes \
               "$([ $((p3s + p3z)) -le $((total * SECT_PER_MIB)) ] && echo yes || echo no)"
        fi
        return 0
    }
    check_layout normal-card   20480 8192 3
    check_layout overlap-card  20480  512 3
    check_layout two-part-card 20480 8192 2

    # The 2 GiB stand-in image is sized from the FILE, not from a constant —
    # the second fixture bug was a p2 that ran 8192 sectors past the end.
    synth_total=$((2048 * SECT_PER_MIB))
    synth_p2z=$((synth_total - P2_START - SECT_PER_MIB))
    ck "stand-in p2 ends inside its file" yes \
       "$([ $((P2_START + synth_p2z)) -le "$synth_total" ] && echo yes || echo no)"
    # And it must straddle the two /data placements: clear of 8 GiB, over 512 MiB.
    read -r _ normal_p3s _ <<<"$(geom 20480 8192)"
    read -r _ over_p3s   _ <<<"$(geom 20480 512)"
    ck "stand-in clears a normal /data"  yes "$([ "$synth_total" -lt "$normal_p3s" ] && echo yes || echo no)"
    ck "stand-in reaches an early /data" yes "$([ "$synth_total" -gt "$over_p3s"   ] && echo yes || echo no)"
    echo; echo "passed $pass, failed $fail"; [ "$fail" -eq 0 ]; exit $?
fi

# --- full run: needs root ---------------------------------------------------
[ "$(id -u)" = 0 ] || { echo "run as root (losetup/mount), or --self-test" >&2; exit 1; }
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
INSTALLER="$HERE/dashberry-install"
[ -x "$INSTALLER" ] || die "not found: $INSTALLER"
USER_IMG=${1:-}

WORK=$(mktemp -d); LOOPS=()
cleanup() {
    for l in "${LOOPS[@]:-}"; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

# make_card PATH ROOT_MIB [NPARTS] -> echoes loop device. Dies on any failure:
# a fixture that half-built is worse than no fixture, because every assertion
# after it becomes a comparison of one empty string against another.
make_card() {
    local path=$1 root_mib=$2 nparts=${3:-3} p2z p3s p3z lo out
    read -r p2z p3s p3z <<<"$(geom 20480 "$root_mib")"
    truncate -s 20G "$path" || die "truncate $path"
    lo=$(losetup --show -f -P "$path") || die "losetup $path"
    LOOPS+=("$lo")
    {
        echo "label: dos"
        echo "${lo}p1 : start=$P1_START, size=$P1_SIZE, type=c"
        echo "${lo}p2 : start=$P2_START, size=$p2z, type=83"
        [ "$nparts" = 3 ] && echo "${lo}p3 : start=$p3s, size=$p3z, type=83"
    } > "$WORK/sfdisk.in"
    out=$(sfdisk -q "$lo" < "$WORK/sfdisk.in" 2>&1) || \
        die "sfdisk on $lo: $out"$'\n'"script was:"$'\n'"$(cat "$WORK/sfdisk.in")"
    partprobe "$lo"; udevadm settle
    [ -b "${lo}p1" ] && [ -b "${lo}p2" ] || die "partition nodes missing on $lo"
    mkfs.vfat -F 32 "${lo}p1" >/dev/null 2>&1 || die "mkfs.vfat ${lo}p1"
    mkfs.ext4 -q -F "${lo}p2" || die "mkfs.ext4 ${lo}p2"
    if [ "$nparts" = 3 ]; then
        [ -b "${lo}p3" ] || die "partition node ${lo}p3 missing"
        mkfs.ext4 -q -F -L dashberry-data "${lo}p3" || die "mkfs.ext4 ${lo}p3"
    fi
    echo "$lo"
}

# Refuse to run assertions against a fixture that is not what we asked for.
validate_card() {   # validate_card LOOP EXPECT_LABEL
    local lo=$1 want=$2 n t l
    n=$(sfdisk -d "$lo" 2>/dev/null | grep -c '^/dev/') || n=0
    [ "$n" = 3 ] || die "fixture $lo has $n partitions, expected 3"
    t=$(blkid -p -o value -s TYPE "${lo}p3" 2>/dev/null || true)
    l=$(blkid -p -o value -s LABEL "${lo}p3" 2>/dev/null || true)
    [ "$t" = ext4 ] || die "fixture ${lo}p3 is '$t', expected ext4"
    [ "$l" = "$want" ] || die "fixture ${lo}p3 labelled '$l', expected '$want'"
}

plant_footage() {                   # $1=loopdev -> writes markers into p3
    local m; m=$(mktemp -d)
    mount "${1}p3" "$m" || die "cannot mount ${1}p3 to plant footage"
    mkdir -p "$m/front/2026-08-09T12-00-00" "$m/rear/2026-08-09T12-00-00" "$m/gps"
    head -c 3000000 /dev/urandom > "$m/front/2026-08-09T12-00-00/00000.ts"
    head -c 1500000 /dev/urandom > "$m/rear/2026-08-09T12-00-00/00000.ts"
    echo "marker" > "$m/gps/2026-08-09T12-00-00.nmea"
    sync
    ( cd "$m" && find . -type f -exec sha256sum {} \; | sort ) > "$WORK/before.sha"
    [ -s "$WORK/before.sha" ] || die "planted no footage"
    umount "$m"; rmdir "$m"
}

# 2 GiB stand-in: small enough to leave a /data at 8.5 GiB untouched, big
# enough to reach one deliberately placed at ~1 GiB (the overlap case), and
# its p2 is sized from the FILE so it cannot run off the end.
synth_image() {
    local img="$WORK/synth.img" lo p2z out
    p2z=$((2048 * SECT_PER_MIB - P2_START - SECT_PER_MIB))
    truncate -s 2G "$img" || die "truncate stand-in"
    lo=$(losetup --show -f -P "$img") || die "losetup stand-in"
    out=$(sfdisk -q "$lo" 2>&1 <<EOF
label: dos
${lo}p1 : start=$P1_START, size=$P1_SIZE, type=c
${lo}p2 : start=$P2_START, size=$p2z, type=83
EOF
    ) || { losetup -d "$lo"; die "sfdisk on stand-in: $out"; }
    partprobe "$lo"; udevadm settle
    mkfs.vfat -F 32 "${lo}p1" >/dev/null 2>&1 || { losetup -d "$lo"; die "mkfs.vfat stand-in"; }
    mkfs.ext4 -q -F "${lo}p2" || { losetup -d "$lo"; die "mkfs.ext4 stand-in"; }
    losetup -d "$lo"
    echo "$img"
}

p3start() { sfdisk -d "$1" 2>/dev/null | awk '$1 ~ /p3$/ {for(i=3;i<=NF;i++) if($i=="start="){v=$(i+1);sub(/,$/,"",v);print v;exit}}'; }

IMG=${USER_IMG:-$(synth_image)}
echo "image: $IMG"
[ -n "$USER_IMG" ] || echo "(synthetic stand-in: the installer WILL fail in OS customisation; assertions still hold)"

# ==========================================================================
echo
echo "== CASE 1: normal card, footage must survive =="
CARD=$(make_card "$WORK/card.img" 8192 3)
validate_card "$CARD" dashberry-data
plant_footage "$CARD"
before_start=$(p3start "$CARD")
before_uuid=$(blkid -p -o value -s UUID "${CARD}p3")
[ -n "$before_start" ] && [ -n "$before_uuid" ] || die "could not read the fixture's p3 start/UUID"
echo "  fixture: p3 at sector $before_start, fs UUID $before_uuid"

printf '%s\n' "$CARD" | "$INSTALLER" --root-size keep "$IMG" "$CARD" > "$WORK/out.log" 2>&1
echo "  installer exit $? (non-zero expected with the stand-in)"
grep -q "keeping ${CARD}p3" "$WORK/out.log" && echo "  wipe was skipped for p3"
grep -q "Re-adopting the existing /data" "$WORK/out.log" && echo "  /data was re-adopted, not formatted"

partprobe "$CARD" 2>/dev/null; udevadm settle
ck "p3 start sector unchanged"    "$before_start" "$(p3start "$CARD")"
ck "p3 filesystem UUID unchanged" "$before_uuid"  "$(blkid -p -o value -s UUID "${CARD}p3" 2>/dev/null || echo MISSING)"

e2fsck -fn "${CARD}p3" >/dev/null 2>&1; ck "e2fsck clean on preserved /data" 0 "$?"
m=$(mktemp -d)
if mount "${CARD}p3" "$m" 2>/dev/null; then
    ( cd "$m" && find . -type f -exec sha256sum {} \; | sort ) > "$WORK/after.sha"
    umount "$m"
    if diff -q "$WORK/before.sha" "$WORK/after.sha" >/dev/null; then
        ck "every footage file byte-identical" same same
    else
        ck "every footage file byte-identical" same differs
        diff "$WORK/before.sha" "$WORK/after.sha" | head
    fi
else
    ck "every footage file byte-identical" same "unmountable"
fi
rmdir "$m" 2>/dev/null || true
p2end=$(sfdisk -d "$CARD" | awk '$1 ~ /p2$/ {for(i=3;i<=NF;i++){if($i=="start="){s=$(i+1);sub(/,$/,"",s)}; if($i=="size="){z=$(i+1);sub(/,$/,"",z)}}; print s+z; exit}')
ck "OS partition abuts /data exactly" "$(p3start "$CARD")" "$p2end"

# ==========================================================================
echo
echo "== CASE 2..5: refusals =="
neg() {   # neg LABEL LOOPDEV EXPECTED_SUBSTRING
    local out; out=$(printf '%s\n' "$2" | "$INSTALLER" --root-size keep "$IMG" "$2" 2>&1)
    if printf '%s' "$out" | grep -qi -- "$3"; then
        pass=$((pass+1)); printf '  ok   %-42s refused\n' "$1"
    else
        fail=$((fail+1)); printf '  FAIL %-42s no "%s" in:\n%s\n' "$1" "$3" "$(printf '%s' "$out" | tail -3)"
    fi
}

lo2=$(make_card "$WORK/two.img" 8192 2)
neg "two-partition card" "$lo2" "expected 3"

lo3=$(make_card "$WORK/badl.img" 8192 3)
mkfs.ext4 -q -F -L someone-elses "${lo3}p3" || die "relabel fixture"
neg "third partition with a foreign label" "$lo3" "labelled 'someone-elses'"

# GPT fixture: sfdisk -X gpt is enough; no dependency on sgdisk being present.
truncate -s 20G "$WORK/gpt.img"
lo4=$(losetup --show -f -P "$WORK/gpt.img") || die "losetup gpt"
LOOPS+=("$lo4")
read -r g2z g3s g3z <<<"$(geom 20480 8192)"
sfdisk -q -X gpt "$lo4" >/dev/null 2>&1 <<EOF
start=$P1_START, size=$P1_SIZE
start=$P2_START, size=$g2z
start=$g3s, size=$g3z
EOF
partprobe "$lo4"; udevadm settle
[ "$(sfdisk -d "$lo4" 2>/dev/null | awk '$1=="label:"{print $2}')" = gpt ] || die "gpt fixture is not gpt"
mkfs.ext4 -q -F -L dashberry-data "${lo4}p3" 2>/dev/null || true
neg "GPT-labelled card" "$lo4" "has a 'gpt' partition table"

# /data deliberately at ~1 GiB so the 2 GiB stand-in lands on top of it.
lo5=$(make_card "$WORK/over.img" 512 3)
validate_card "$lo5" dashberry-data
plant_footage "$lo5"
neg "image would overwrite /data" "$lo5" "overwrote /data"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
