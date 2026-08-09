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

# run_installer LOOPDEV -> stdout is the whole session, return is the exit code.
#
# The installer demands a real terminal (`[ -t 0 ] || die`) before it will
# accept the typed device-path confirmation, and it is right to: that check is
# the last thing standing between a typo and a wiped card. A plain
# `printf ... | installer` therefore does NOT test this tool, it dies at the
# gate — which is exactly what happened, and worse, it died SILENTLY as far as
# CASE 1 was concerned: with the installer never running, "p3 start unchanged"
# and "footage byte-identical" were trivially true. The whole case was green
# for the reason it should have been red.
#
# So allocate a pty with script(1) instead of weakening the installer. The
# confirmation is piped into script, which relays it to the child through the
# pty, so `[ -t 0 ]` is true and `read` still gets the answer. -e propagates
# the child's exit status; %q survives paths with spaces.
# Returns the INSTALLER's exit code, not tr's — the cleanup is done off a
# temp file rather than in the pipeline, or `$?` would always be 0.
run_installer() {
    local dev=$1 cmd rc
    cmd=$(printf '%q --root-size keep %q %q' "$INSTALLER" "$IMG" "$dev")
    printf '%s\n' "$dev" | script -qec "$cmd" /dev/null > "$WORK/raw.log" 2>&1
    rc=$?
    tr -d '\r' < "$WORK/raw.log"
    return "$rc"
}

# Any run that dies at the terminal gate is a HARNESS fault, not a result.
# Never let it be scored.
assert_ran() {   # assert_ran LOGFILE LABEL
    grep -q "must be run on a visual terminal" "$1" && \
        die "$2: the installer never ran — no pty (is script(1) present?)"
    # An EMPTY transcript is never a result either. It meant the log itself
    # could not be written (the workspace was full), and the run was then
    # scored against a card whose state nobody could explain.
    [ -s "$1" ] || die "$2: the installer produced no output at all — workspace full, or script(1) failed"
    return 0
}

# --- bookkeeping helpers (needed by the self-test too) ----------------------
# register_loop writes to a FILE and not a shell array, because make_card is
# called as $( ) — a SUBSHELL — and an array append inside one is discarded
# the instant it returns. That is why every run leaked its loop devices, each
# pinning a backing file it had already unlinked, until the workspace filled
# and sfdisk started reporting "fsync device failed: Input/output error".
register_loop() { printf '%s\n' "$1" >> "$LOOPFILE"; }

# Release a fixture the moment its case is done, rather than holding all five
# to the end. Peak disk is then one card (~4 GiB once an image is flashed
# into it), not the sum of them.
release_card() {   # release_card LOOPDEV BACKING_FILE
    [ -n "${1:-}" ] && losetup -d "$1" 2>/dev/null
    [ -n "${2:-}" ] && rm -f "$2"
    return 0
}

# make_card and synth_image die inside a subshell, which only kills the
# subshell — the caller carried on with an empty variable and then ran
# `mkfs.ext4 ... p3` on the literal string "p3". Every fixture is claimed
# through this, so a failure stops the run.
claim() {          # claim VARNAME COMMAND...
    local _var=$1; shift
    local _dev; _dev=$("$@") || { echo "FIXTURE ERROR: $* failed" >&2; exit 1; }
    [ -b "$_dev" ] || { echo "FIXTURE ERROR: $* gave no block device ('$_dev')" >&2; exit 1; }
    printf -v "$_var" '%s' "$_dev"
}


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

    # --- the pty runner ----------------------------------------------------
    # The bug this guards: the harness fed the confirmation down a PIPE, so
    # the installer's `[ -t 0 ]` gate killed every run before it did anything,
    # and CASE 1's "nothing changed" assertions all passed on a card the
    # installer had never touched. Checkable with no root at all, using a
    # stand-in that behaves like the gate.
    echo "== self-test: pty runner =="
    if command -v script >/dev/null 2>&1; then
        WORK="$t"
        INSTALLER="$t/fake-installer"; IMG="$t/fake.img"; : > "$IMG"
        # Stands in for the installer's gate only: same [ -t 0 ] refusal, same
        # prompt-then-read. Echoes what it read so the assertion can check the
        # confirmation actually arrived, and exits 3 to prove the code carries
        # back through script(1).
        cat > "$INSTALLER" <<'FAKE'
#!/bin/sh
[ -t 0 ] || { echo "Fatal Error: This script must be run on a visual terminal"; exit 1; }
dev=$4
printf 'Type the device path (%s) to continue: ' "$dev"
read -r answer
[ "$answer" = "$dev" ] || { echo "Aborted (got '$answer' want '$dev')"; exit 1; }
echo "confirmed=$answer"
exit 3
FAKE
        chmod +x "$INSTALLER"
        out=$(run_installer /dev/fake-loop9); rc=$?
        ck "installer sees a terminal"    yes \
           "$(printf '%s' "$out" | grep -q "visual terminal" && echo no || echo yes)"
        ck "confirmation reaches read(1)" yes \
           "$(printf '%s' "$out" | grep -q "confirmed=/dev/fake-loop9" && echo yes || echo no)"
        ck "child exit code propagates"   3 "$rc"
        printf '%s\n' "$out" > "$t/gate.log"
        ck "assert_ran passes a real run" yes \
           "$(assert_ran "$t/gate.log" self-test >/dev/null 2>&1 && echo yes || echo no)"
        # And it must FAIL loudly on a gated run, rather than scoring it.
        echo "Fatal Error: This script must be run on a visual terminal" > "$t/gated.log"
        ck "assert_ran rejects a gated run" yes \
           "$( ( assert_ran "$t/gated.log" self-test ) >/dev/null 2>&1 && echo no || echo yes)"
    else
        fail=$((fail+1)); echo "  FAIL script(1) missing — the pty runner cannot work"
    fi

    # --- OS sizing across an image layout shift, and the /data-first order --
    # The bug: a card built by an image with p1 at sector 8192, reflashed with
    # Trixie which puts p1 at 16384, leaves the OS 4 MiB under 8 GiB — and the
    # floor rejected it outright, after the flash had already erased the old
    # table. All arithmetic, all checkable here.
    echo "== self-test: OS sizing and /data-first ordering =="
    fstart() { sfdisk -d "$1" 2>/dev/null | awk -v n="$2" '$1==n{for(i=3;i<=NF;i++) if($i=="start="){v=$(i+1);sub(/,$/,"",v);print v;exit}}'; }
    fend()   { sfdisk -d "$1" 2>/dev/null | awk -v n="$2" '$1==n{for(i=3;i<=NF;i++){if($i=="start="){s=$(i+1);sub(/,$/,"",s)};if($i=="size="){z=$(i+1);sub(/,$/,"",z)}};print s+z;exit}'; }

    old_p2=$((8192 + P1_SIZE)); new_p2=$((16384 + P1_SIZE))
    read -r _ card_p3 card_p3z <<<"$(geom 20480 8192)"
    derived=$((card_p3 - new_p2))
    target=$((8 * 1024 * 1024 * 1024)); slack=$((64 * 1024 * 1024))
    ck "image shifts p2 by 4 MiB"     8192 "$((new_p2 - old_p2))"
    ck "derived OS size (MiB)"        8188 "$((derived * 512 / 1024 / 1024))"
    ck "shifted card is ACCEPTED"     yes \
       "$([ $((derived * 512)) -ge $((target - slack)) ] && echo yes || echo no)"
    read -r _ small_p3 _ <<<"$(geom 20480 4096)"
    small=$((small_p3 - new_p2))
    ck "genuine 4 GiB card REFUSED"   yes \
       "$([ $((small * 512)) -lt $((target - slack)) ] && echo yes || echo no)"

    o="$t/order.img"; truncate -s 20G "$o"
    printf 'label: dos\n%s1 : start=16384, size=%s, type=c\n%s2 : start=%s, size=4751360, type=83\n' \
        "$o" "$P1_SIZE" "$o" "$new_p2" > "$t/o.in"
    sfdisk -q "$o" < "$t/o.in" >/dev/null 2>&1
    echo "$card_p3,$card_p3z,L" | sfdisk -q --wipe-partitions never -a "$o" >/dev/null 2>&1
    ck "/data entry restorable post-flash" "$card_p3" "$(fstart "$o" "${o}3")"
    echo ", $derived" | sfdisk -q -N 2 "$o" >/dev/null 2>&1
    ck "OS then grows to abut /data"       "$card_p3" "$(fend "$o" "${o}2")"
    if echo ", $((derived + 2048))" | sfdisk -q -N 2 "$o" >/dev/null 2>&1; then over=no; else over=yes; fi
    ck "oversized OS refused by sfdisk"    yes "$over"
    ck "/data survived the refusal"        "$card_p3" "$(fstart "$o" "${o}3")"

    # --- loop-device bookkeeping across a subshell -------------------------
    # make_card hands its device back through $( ), so anything it records in
    # a shell VARIABLE is discarded when that subshell exits. The harness kept
    # its loop devices in an array, so cleanup detached none of them: every
    # run leaked, each leak pinned an unlinked backing file, and the workspace
    # filled until sfdisk began failing with "fsync device failed:
    # Input/output error". This pins both halves — the loss and the fix.
    echo "== self-test: loop bookkeeping and fixture claiming =="
    LOOPFILE="$t/loops"; : > "$LOOPFILE"
    arr=()
    probe() { arr+=("/dev/fake$1"); register_loop "/dev/fake$1"; echo "/dev/fake$1"; }
    got=$(probe 7)
    ck "subshell returns the device"       /dev/fake7 "$got"
    ck "array append LOST in subshell"     0 "${#arr[@]}"
    ck "file record SURVIVES subshell"     1 "$(grep -c . "$LOOPFILE")"
    # claim() must abort the run when a fixture cannot be built, rather than
    # letting die()'s subshell-only exit leave an empty variable behind — the
    # path that ended in `mkfs.ext4` being handed the literal string "p3".
    if ( claim _X false ) >/dev/null 2>&1; then claimed=no; else claimed=yes; fi
    ck "claim aborts on a failed fixture"  yes "$claimed"
    if ( claim _X echo "not-a-device" ) >/dev/null 2>&1; then claimed=no; else claimed=yes; fi
    ck "claim rejects a non-device"        yes "$claimed"
    echo; echo "passed $pass, failed $fail"; [ "$fail" -eq 0 ]; exit $?
fi

# --- full run: needs root ---------------------------------------------------
[ "$(id -u)" = 0 ] || { echo "run as root (losetup/mount), or --self-test" >&2; exit 1; }
# script(1) is not optional garnish: it is how the installer gets the terminal
# it insists on. Without it every run dies at the confirmation gate.
for t in losetup sfdisk partprobe blkid mkfs.ext4 mkfs.vfat e2fsck udevadm script awk; do
    command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
INSTALLER="$HERE/dashberry-install"
[ -x "$INSTALLER" ] || die "not found: $INSTALLER"
USER_IMG=${1:-}

WORK=$(mktemp -d "${HARNESS_WORK:-${TMPDIR:-/tmp}}/keepdata.XXXXXX")

# Loop devices leaked by EARLIER runs of this harness (the subshell bug below)
# still pin backing files that were unlinked long ago, so the space they hold
# is invisible to du and never comes back on its own. Say so, with the command
# that clears exactly those and nothing else — "(deleted)" is the kernel's own
# marker for a backing file with no remaining name.
leaked=$(losetup -l 2>/dev/null | grep -c '(deleted)' || true)
if [ "${leaked:-0}" -gt 0 ]; then
    echo "NOTE: $leaked leaked loop device(s) from earlier runs are still holding deleted files."
    echo "      Reclaim that space with:"
    echo "          sudo losetup -l | awk '/\\(deleted\\)/ {print \$1}' | xargs -r sudo losetup -d"
    echo
fi

# Each flashed card costs roughly the image's uncompressed size plus the
# metadata resize2fs writes, and fixtures are released as they finish, so the
# peak is about one card. Refuse up front rather than failing mid-flash with
# "fsync device failed: Input/output error", which is what ENOSPC looks like
# through sfdisk and is not a phrase anyone should have to decode.
avail_mib=$(df -Pm "$WORK" | awk 'NR==2 {print $4}')
NEED_MIB=8192
if [ "${avail_mib:-0}" -lt "$NEED_MIB" ]; then
    die "only ${avail_mib} MiB free on $(df -Pm "$WORK" | awk 'NR==2 {print $6}') — need ~${NEED_MIB} MiB.
       Point the harness somewhere roomier:  sudo HARNESS_WORK=/var/tmp $0 $*"
fi
echo "workspace: $WORK (${avail_mib} MiB free)"

# Loop devices are recorded in a FILE, not a shell array. make_card runs
# inside $( ) to hand back the device path, and a command substitution is a
# SUBSHELL — so `LOOPS+=(...)` inside it evaporated the moment the function
# returned, and cleanup detached nothing. Every run leaked its loop devices;
# each one pinned the backing file it had already unlinked, so the space was
# never reclaimed either. That is what eventually produced
# "sfdisk: fsync device failed: Input/output error" (ENOSPC by another name)
# and an installer transcript that could not be written at all. A file
# survives the subshell.
LOOPFILE="$WORK/loops"; : > "$LOOPFILE"
cleanup() {
    if [ -f "$LOOPFILE" ]; then
        while read -r l; do
            [ -n "$l" ] && losetup -d "$l" 2>/dev/null
        done < "$LOOPFILE"
    fi
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
    register_loop "$lo"
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
    register_loop "$lo"
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
diskid()  { sfdisk -d "$1" 2>/dev/null | awk '$1 == "label-id:" { print $2; exit }'; }

IMG=${USER_IMG:-$(synth_image)}
echo "image: $IMG"
[ -n "$USER_IMG" ] || echo "(synthetic stand-in: the installer WILL fail in OS customisation; assertions still hold)"

# ==========================================================================
echo
echo "== CASE 1: normal card, footage must survive =="
claim CARD make_card "$WORK/card.img" 8192 3
validate_card "$CARD" dashberry-data
plant_footage "$CARD"
before_start=$(p3start "$CARD")
before_uuid=$(blkid -p -o value -s UUID "${CARD}p3")
before_diskid=$(diskid "$CARD")
[ -n "$before_start" ] && [ -n "$before_uuid" ] || die "could not read the fixture's p3 start/UUID"
echo "  fixture: p3 at sector $before_start, fs UUID $before_uuid, MBR id $before_diskid"

case1_fail_before=$fail
run_installer "$CARD" > "$WORK/out.log" 2>&1
echo "  installer exit $? (non-zero expected with the stand-in)"
assert_ran "$WORK/out.log" "CASE 1"
# The installer's own words, always. Without this the harness reports a wall
# of red and throws away the one line that says why — which is exactly what
# happened when it died at a check nobody could see.
if grep -q "Fatal Error" "$WORK/out.log"; then
    echo "  installer said: $(grep -m1 "Fatal Error" "$WORK/out.log")"
fi

# POSITIVE evidence that the installer did the work. Without these, every
# assertion below is also satisfied by an installer that never started —
# which is precisely how this case passed while doing nothing.
ck "reached the wipe (past the confirmation)" yes \
   "$(grep -q "Wiping the old partition" "$WORK/out.log" && echo yes || echo no)"
ck "spared p3 from the wipe"                  yes \
   "$(grep -q "keeping ${CARD}p3" "$WORK/out.log" && echo yes || echo no)"
ck "re-adopted /data (did not mkfs it)"       yes \
   "$(grep -q "Re-adopting the existing /data" "$WORK/out.log" && echo yes || echo no)"

partprobe "$CARD" 2>/dev/null; udevadm settle
# The MBR disk id comes from the flashed image, so a changed id is proof the
# flash really landed — and it is the same mechanism that makes PARTUUID
# change, which the installer documents as expected.
ck "MBR disk id changed (flash landed)" changed \
   "$([ "$(diskid "$CARD")" != "$before_diskid" ] && echo changed || echo "same:$before_diskid")"
# THE invariant, and it holds whether the installer succeeded or bailed: once
# the flash has erased the old table, /data must never be left without an
# entry pointing at it. `keep` cannot recover from that by itself — it learns
# the start sector by reading the old table — so a card in that state has
# footage that is physically present, addressable only by hand, and invisible
# to a retry. An OS-size check used to fail inside exactly that window.
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

# Anything failed in CASE 1? Then the installer's transcript is the evidence,
# not the assertion list. Print enough of it to diagnose without a re-run.
if [ "$fail" -gt "$case1_fail_before" ]; then
    echo
    echo "  ---- installer transcript (last 30 lines) ----"
    tail -30 "$WORK/out.log" | sed 's/^/  | /'
    echo "  ---- partition table now ----"
    sfdisk -d "$CARD" 2>&1 | sed 's/^/  | /'
    echo "  ---------------------------------------------"
fi

# ==========================================================================
echo
# CASE 1 is finished with: give its ~4 GiB back before building the next one.
release_card "$CARD" "$WORK/card.img"

echo "== CASE 2..5: refusals =="
# Same pty runner as CASE 1: the /data-overlap refusal happens AFTER the
# confirmation, so a pipe-fed run never reaches it and the case fails for the
# wrong reason. The label/count/GPT refusals come before the gate and would
# pass either way — which is what made the discrepancy so easy to misread.
neg() {   # neg LABEL LOOPDEV EXPECTED_SUBSTRING
    run_installer "$2" > "$WORK/neg.log" 2>&1
    assert_ran "$WORK/neg.log" "$1"
    if grep -qi -- "$3" "$WORK/neg.log"; then
        pass=$((pass+1)); printf '  ok   %-42s refused\n' "$1"
    else
        fail=$((fail+1)); printf '  FAIL %-42s no "%s" in:\n%s\n' "$1" "$3" "$(tail -3 "$WORK/neg.log")"
    fi
}

claim lo2 make_card "$WORK/two.img" 8192 2
neg "two-partition card" "$lo2" "expected 3"
release_card "$lo2" "$WORK/two.img"

claim lo3 make_card "$WORK/badl.img" 8192 3
mkfs.ext4 -q -F -L someone-elses "${lo3}p3" || die "relabel fixture"
neg "third partition with a foreign label" "$lo3" "labelled 'someone-elses'"
release_card "$lo3" "$WORK/badl.img"

# GPT fixture: sfdisk -X gpt is enough; no dependency on sgdisk being present.
truncate -s 20G "$WORK/gpt.img"
lo4=$(losetup --show -f -P "$WORK/gpt.img") || die "losetup gpt"
register_loop "$lo4"
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
release_card "$lo4" "$WORK/gpt.img"

# /data deliberately at ~1 GiB so the 2 GiB stand-in lands on top of it.
claim lo5 make_card "$WORK/over.img" 512 3
validate_card "$lo5" dashberry-data
plant_footage "$lo5"
neg "image would overwrite /data" "$lo5" "overwrote /data"
release_card "$lo5" "$WORK/over.img"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
