#!/bin/sh
# firstinstall.sh — DashBerry on-Pi installer (replaces the old sw/install.sh).
# Normally runs ONCE, on the first boot of a card built by cli/dashberry-install,
# via dashberry-firstinstall.service from /opt/dashberry/sw. Can also be run by
# hand as root from this directory on an already-booted stock system.
#
# Installs packages, builds the panel daemon, copies scripts/units/config into
# place and enables the dashberry target. Boot config and fstab are NOT touched
# here — dashberry-install already wrote them into the card (manual installs:
# merge boot/config-snippet.txt and etc/fstab.snippet by hand).
#
# Options come from two places, both written by dashberry-install:
#   - BYPASS_TIME / BYPASS_REAR / DEBUG / RF_JOIN in ./etc/dashberry.conf
#     (the copy installed to /etc below — panel and installer read the same
#     truth). DEBUG=0 is a PRODUCTION card: the OS goes read-only
#     (overlayfs) and every stored Wi-Fi credential is wiped. DEBUG=1 is a
#     DEBUG card: writable OS, Wi-Fi profile and journal kept, and the
#     journal made persistent (/var/log/journal). RF_JOIN=1 (a production
#     card built with --auth) keeps the regdom token so the panel's JOIN
#     WIFI screen has radios it can legally bring up;
#   - FIRSTBOOT_WIFI in ../install-opts (this boot runs over a staged Wi-Fi
#     profile instead of Ethernet).
#
# Whatever the mode, the card ends this script RF-KILLED and boots that way.
# What makes LATER boots RF-KILLED is dashberry-rfkill.service, which
# asserts the block after NetworkManager — after the last thing that can
# speak for the switch. Everything else is depth beneath it: radios_off()
# below pins the two state files boot daemons replay (NetworkManager's
# WirelessEnabled, systemd-rfkill's saved soft state) and proves it, a
# production card masks systemd-rfkill, and 99-dashberry-rfkill.rules
# blocks the switch as it appears. That layering is deliberate — the state
# files only decide a boot while the OS is really read-only, and a card
# whose overlay silently failed to arm proved that is not something to bet
# the RF guarantee on (2026-08-08). The one exception, for the service and
# the udev rule alike, is a debug card given a --wifi profile — an explicit
# request for a card that rejoins the LAN by itself.
#
# Every run appends to an install log on the BOOT partition (see the block
# below) — the card's black box, and the only record of this script that
# outlives it.
#
# dashberry-cli (../cli) is PC-side and is deliberately NOT installed here —
# it never ships on the image.
set -eu

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

# --- the install log ------------------------------------------------------
# The journal cannot be this script's record. On a production card journald
# is volatile (Storage=auto, no /var/log/journal) and this script ENDS BY
# REBOOTING, so a successful install destroys its own log; only a FAILED
# install leaves one behind, in the boot it died in. That asymmetry is not
# academic — it is why the overlay step's output had never once been read
# (2026-08-08), while the apt failure of 2026-08-05 was captured easily.
#
# The boot partition is the one place that survives both: FAT, written
# before the overlay exists, NOT covered by the read-only overlay
# afterwards, and readable by pulling the card into any PC — no ssh, no
# account, no working card required. /data would survive too, but a card
# that fails early may not have reached it.
#
# Appended, never truncated: a card that dies at apt runs this again on the
# next boot, and the sequence of attempts is itself evidence. One rotation
# at 4 MB, because a card that boot-loops must not fill the partition the
# kernel and firmware live on.
#
# WHAT MAY BE IN THIS FILE — it ships on every card, and the boot partition
# is FAT (mode bits do not survive), so treat it as readable by anyone
# holding the card. That is the same threat model the credential wipe
# answers, so the log must never weaken it:
#   NEVER: a Wi-Fi passphrase or SSID, the account name or its hash, the
#   contents of any keyfile, /etc/shadow, userconf.txt, or NM profile.
#   Nothing in this script reads any of them — the PSK is handled PC-side
#   by dashberry-install and at runtime by rf-ctl, neither of which writes
#   here — and every nmcli/rfkill/journalctl call is output-suppressed so a
#   future error string cannot carry one in.
#   ALLOWED, and deliberate: package names and mirror URLs, device paths,
#   unit names, timings, the DS3231 sync, the overlay evidence, and
#   cmdline.txt verbatim (regdom included — a country code names no
#   network, and that file sits in this very directory, so quoting it adds
#   no exposure).
#   KNOWN EDGE: apt error text quotes whatever mirror or proxy the install
#   network injected, so a captive portal can put a local hostname in here.
#   Named rather than hidden; wipe the file if that matters for a card.
#
# The tee re-execs this script once, with DB_INSTALL_LOG=1 marking the
# inner run. The journal and console still receive everything (tee's own
# stdout is this process's stdout) — the log is an addition, not a
# diversion. Two known effects, both accepted: stderr is folded into stdout
# for the inner run (the journal stops distinguishing them), and if the
# boot partition is not writable the tee is skipped silently and the script
# behaves exactly as it did before.
BOOTFW=/boot/firmware
[ -d "$BOOTFW" ] || BOOTFW=/boot
INSTALL_LOG=$BOOTFW/dashberry-install.log
if [ "$(stat -c %s "$INSTALL_LOG" 2>/dev/null || echo 0)" -gt 4194304 ]; then
    mv -f "$INSTALL_LOG" "$INSTALL_LOG.1" 2>/dev/null || true
fi
if [ "${DB_INSTALL_LOG:-0}" != 1 ] && touch "$INSTALL_LOG" 2>/dev/null; then
    DB_INSTALL_LOG=1
    export DB_INSTALL_LOG
    # A pipeline's status is its LAST command's (tee, always 0), so the
    # real one rides in a file — systemd must still see this script fail.
    # `set +e` is needed for that handoff to run at all, and is confined to
    # the subshell the pipeline's left side already is.
    _rc_file=/run/dashberry-firstinstall.rc
    rm -f "$_rc_file"
    {
        echo
        echo "===== firstinstall $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC ====="
        # Card clock, and it is allowed to be wrong: an install that runs at
        # the image build date is exactly the apt-404 fingerprint.
        set +e
        "$0" "$@"
        echo "$?" > "$_rc_file"
    } 2>&1 | tee -a "$INSTALL_LOG"
    if [ -s "$_rc_file" ]; then
        _st=$(cat "$_rc_file")
    else
        _st=1   # no status file: the inner run died before the handoff
    fi
    rm -f "$_rc_file"
    # The script's last act is `systemctl --no-block reboot`, which returns
    # before the log is on the card. Nothing else would flush FAT in time.
    sync
    exit "$_st"
fi

cd "$(dirname "$0")"

FROM_UNIT=0
[ "${1:-}" = "--from-unit" ] && FROM_UNIT=1

BYPASS_TIME=0
BYPASS_REAR=0
DEBUG=0
RF_JOIN=0
FIRSTBOOT_WIFI=0
. ./etc/dashberry.conf
[ -f ../install-opts ] && . ../install-opts

CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt

if [ "$FIRSTBOOT_WIFI" = 1 ]; then
    echo "first-boot Wi-Fi: unblocking and waiting for the network..."
    # The cmdline regdom staged by dashberry-install should already have
    # left wlan unblocked (Trixie is expected to honor
    # cfg80211.ieee80211_regdom headless — known good on bookworm);
    # these are belt-and-braces — rfkill may not exist on the stock
    # image yet.
    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on 2>/dev/null || true
    nm-online -q -t 90 || echo "network not online yet — apt will retry" >&2
fi

# Wait for a real clock BEFORE apt. Field-observed 2026-08-05: first boot
# died on 404s for 18 .debs, apparently at random and apparently keyed to
# the install network, and one reboot always "fixed" it. The cause is the
# clock, not the network. The card boots at the image build date (Jun 18 on
# the card that produced the log), and if firstinstall reaches apt before
# systemd-timesyncd has completed its first NTP exchange, every InRelease
# fails OpenPGP verification with sqv's "Not live until <date>" — the
# signature is dated AFTER the card thinks it is, so it is not valid yet.
# apt then says "The repository is not updated and the previous index files
# will be used" and — this is the part that hurts — exits 0, because those
# are W: not E:. The install downstream resolves against the image's
# months-old seeded indexes and asks the archive for versions that have
# since been superseded and deleted from pool/, which is the 404. Rebooting
# cured it only because timesyncd persists /var/lib/systemd/timesync/clock,
# so boot 2 starts out roughly right; and "which network" was really a race
# against how fast that network resolves and answers NTP.
#
# CLOCK_FLOOR is no help here — it is 2026-01-01 and the bad clock read
# 2026-06-18, well past the floor. A stale-but-plausible image date clears
# every sanity check the card owns, so the gate has to be NTP sync itself.
#
# Not fatal on timeout: NTPSynchronized=no does not prove the clock is
# wrong (a DS3231-fitted card can be correct offline), so a hard failure
# here would break cards that are actually fine. --error-on=any below is
# the real guard — it is what turns a silently-stale index into a failure.
# BYPASS_TIME is deliberately NOT consulted: it means "no DS3231 fitted",
# and such a card needs the network clock here more than any other.
echo "waiting for the clock before apt (NTP)..."
n=0
while [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != yes ]; do
    n=$((n + 1))
    if [ "$n" -ge 90 ]; then      # 90 x 2 s = 3 min
        echo "clock not NTP-synced after 3 min — continuing anyway." >&2
        echo "(if the clock really is wrong, apt-get update below fails" >&2
        echo " loudly on --error-on=any instead of installing 404-bait.)" >&2
        break
    fi
    sleep 2
done

echo "installing packages..."
n=0
# --error-on=any: without it a repo that fails to verify is only a W: and
# apt-get update still exits 0, so this loop would fall straight through to
# an install resolved against stale indexes. That is exactly how the 404s
# above got in. With it, a partial update is a failure and gets retried —
# which also gives a late-syncing clock three more chances to land.
until apt-get update --error-on=any; do
    n=$((n + 1))
    if [ "$n" -ge 3 ]; then
        if [ "$FIRSTBOOT_WIFI" = 1 ]; then
            echo "apt-get update keeps failing — is the staged Wi-Fi profile" >&2
            echo "right (SSID/PSK/--wifi-country, 2.4 GHz in range)? Fix and" >&2
            echo "reboot to retry, or run /opt/dashberry/sw/firstinstall.sh by hand." >&2
        else
            echo "apt-get update keeps failing — is Ethernet connected?" >&2
            echo "(no Wi-Fi is configured on this card; fix the network and reboot" >&2
            echo " to retry, or run /opt/dashberry/sw/firstinstall.sh by hand.)" >&2
        fi
        echo "if the errors say \"Not live until\", the card's clock is behind" >&2
        echo "the archive signatures — NTP never landed; check the network" >&2
        echo "allows outbound NTP (udp/123), then reboot to retry." >&2
        exit 1
    fi
    sleep 15
done
# Full rpicam-apps (not -lite): front-rec needs the libav encoder wrapper
# (--codec libav --libav-format mpegts) so PTS/DTS travel in-band down the
# pipe — the lite build is compiled without libav.
#
# util-linux-extra carries `hwclock`, which since bookworm is NOT in
# util-linux and is absent from the stock Lite image. Field-observed
# 2026-08-04: `hwclock` was simply not on the card, so the `hwclock -w`
# below exited 127 and the else-branch warning fired — the DS3231 was never
# written, whether or not it was fitted — and session-init's RTC re-read
# (`hwclock -s`) was dead code at every boot besides. This apt step is the
# only moment the card is online, so a binary missing here is missing for
# the life of the card. util-linux is named alongside it so the pair reads
# as one stated requirement rather than an assumed base package.
# overlayroot is the read-only OS itself, and it is listed HERE — with the
# network guaranteed up — on purpose. raspi-config (20260522, trixie) no
# longer builds a custom initramfs for `boot=overlay`: enable_overlayfs()
# now runs `is_installed overlayroot || apt-get install -y overlayroot` and
# writes `overlayroot=tmpfs` to the cmdline. That apt-get is the trap. It
# runs deep inside the production branch, and on a --wifi card
# radios_off has already taken the only network down three lines earlier,
# so it dies on DNS — and its failure is swallowed by the `||`, leaving
# raspi-config to write an inert token and exit 0. Field-observed
# 2026-08-08: a JOIN WIFI card that reported "overlay armed" and had been
# running read-WRITE ever since, which is what let a JOIN WIFI session's
# WirelessEnabled=true persist and boot the card RF-ENABLED for life.
# Installing it here makes raspi-config's is_installed short-circuit, so
# the overlay step needs no network at all. Costs ~3.4 MB with its
# cryptsetup dependencies.
apt-get install -y --no-install-recommends \
    rpicam-apps gstreamer1.0-tools gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gpsd gpsd-clients chrony gcc make \
    util-linux util-linux-extra overlayroot

echo "building panel daemon..."
make -C src
make -C src install

# install_files MODE DEST FILE... — install the regular files of a payload
# glob, skipping anything else. A bare `install -m MODE dir/* DEST/` copies
# the files but bails on the first non-file with `install: omitting
# directory '.../__pycache__'` AND a non-zero exit — which under `set -e`
# takes the whole first boot down, half-installed. Dev-side junk in the
# payload (a __pycache__ from running the PC tools over the tree, an editor
# backup dir) must never be able to do that.
install_files() {
    _mode=$1
    _dest=$2
    shift 2
    _n=0
    for _f in "$@"; do
        [ -f "$_f" ] || continue
        install -m "$_mode" "$_f" "$_dest"
        _n=$((_n + 1))
    done
    # An empty glob is not "nothing to do", it is a broken payload — fail
    # loudly rather than booting a card with no scripts or no units.
    [ "$_n" -gt 0 ] || { echo "no files to install into $_dest — broken payload" >&2; exit 1; }
}

echo "installing files..."
install_files 755 /usr/local/bin/ usr/local/bin/*
install -m 644 etc/dashberry.conf /etc/dashberry.conf
install_files 644 /etc/systemd/system/ etc/systemd/system/*
# Both rules files: the device symlinks and the boot-time rfkill block.
# Installing the latter is safe even on a --wifi first boot — udev reloads
# rules on change but does not re-run them against devices that already
# exist, and the trigger further down is subsystem-matched to tty and
# video4linux, so the wlan switch this install may be running over is
# never re-added underneath it. The rule takes effect on the next boot.
install_files 644 /etc/udev/rules.d/ etc/udev/rules.d/*
install -D -m 644 etc/chrony/conf.d/gps-refclock.conf /etc/chrony/conf.d/gps-refclock.conf

echo "configuring gpsd ($GPS_DEV, static, guarded hotplug)..."
# Debian's default gpsd setup adds the device via udev hotplug: udev fires
# gpsdctl@ttyACM0, which races gpsd.socket at boot — if /run/gpsd.sock isn't
# up yet, gpsdctl launches its own gpsd, which then loses the bind on port
# 2947 to the socket unit and dies ("can't bind to IPv4 port gpsd, Address
# already in use"). The device never registers and gpsd runs with no GPS.
# So: pin DEVICES, turn USBAUTO off, and mask gpsdctl@ so the racing path
# can't run at all. Replug (and late enumeration) is instead handled by our
# own gps-readd.service — udev-started via 99-dashberry.rules, and it only
# calls gpsdctl against a gpsd that is already running, so the race can't
# come back. GPS_DEV is the udev symlink /dev/gps0, never the raw ttyACMx
# node: a replug re-enumerates ttyACM0 -> ttyACM1.
# -n: open the device without waiting for a client, so chrony's SHM refclock
# gets fixes even if gps-log is down.
# -b: broken-device-safety (read-only) — gpsd must never reconfigure the
# puck. Without it, one stray UBX byte on the line at open (e.g. an unread
# CFG ACK) makes gpsd identify the puck as binary u-blox and switch it out
# of NMEA — then the .nmea archive silently becomes gpsd pseudo-NMEA and
# raw watchers starve. DashBerry owns the receiver config (gps-rate); gpsd
# just reads.
cat > /etc/default/gpsd <<EOF
# written by DashBerry firstinstall.sh — static device, no USB hotplug
DEVICES="$GPS_DEV"
GPSD_OPTIONS="-n -b"
USBAUTO="false"
EOF
systemctl mask gpsdctl@.service

if [ "$BYPASS_TIME" = "1" ]; then
    # No DS3231: GPS is the only wall-clock source, so the refclock must be
    # trusted (drop noselect) and chrony must be allowed to step the clock at
    # any point — boot-time offset without an RTC can be arbitrarily large.
    echo "bypass-time: trusting the GPS refclock..."
    sed -i 's/ noselect$//' /etc/chrony/conf.d/gps-refclock.conf
    printf 'makestep 1 -1\n' >> /etc/chrony/conf.d/gps-refclock.conf
fi

echo "disabling fake-hwclock..."
# fake-hwclock is stock on Pi OS and is actively harmful on this card. At
# boot it restores the last SAVED timestamp, so an offline card comes up
# reading "real time as of the last save" — behind by the last partial hour
# plus every minute the card has spent powered off since. That value is
# wrong but PLAUSIBLE, and plausible is the one failure this card cannot
# cope with: CLOCK_FLOOR (session-init) and the panel's TIME state both test
# the clock against a FLOOR, not a window, so an error of hours sails past
# both. The card then reports healthy while stamping every session name,
# every directory mtime and every retention decision from a clock that
# nothing ever set. Field-observed 2026-08-04 on a card whose DS3231
# firstinstall never wrote (it was installed with the RTC unfitted): folder
# names hours behind the satellites, and not one check on the card noticed.
#
# Removing it leaves no plausible fallback, which is exactly the point. A
# card with an unset or dead DS3231 now boots at 1970, trips CLOCK_FLOOR,
# and SAYS SO — in the journal from session-init and on PAGE 0 from the
# panel — instead of looking fine for months. Retention is no worse off
# either: install-dated segments already sorted older than real footage,
# precisely as 1970-dated ones do.
#
# Masked rather than merely disabled, for the same reason as gpsdctl@ above:
# a package upgrade or reinstall must not be able to quietly bring it back
# on a debug card. --now first, so its ExecStop (`fake-hwclock save`) runs
# before the file it would write is removed.
systemctl disable --now fake-hwclock.service 2>/dev/null || true
systemctl mask fake-hwclock.service 2>/dev/null || true
rm -f /etc/cron.hourly/fake-hwclock /etc/fake-hwclock.data

echo "fetching accurate time..."
# This is the last moment the card is guaranteed online: a production card
# boots read-only with no network, and the GPS refclock ships noselect — so
# the DS3231 as set HERE is the wall-clock truth for the card's whole life.
# A fresh (or long-unpowered) DS3231 reads an arbitrary time; nothing else
# ever corrects it. chronyd has been running since the apt step on the stock
# Debian pool config (makestep 1 3 → it steps the clock in its first
# updates); wait for that, then burn the result into the RTC.
if chronyc waitsync 12 0.5 >/dev/null 2>&1; then
    if [ "$BYPASS_TIME" = 1 ]; then
        echo "clock synced: $(date -u '+%F %T') UTC (no RTC to write)"
    elif hwclock -w; then
        echo "clock synced: $(date -u '+%F %T') UTC written to the DS3231"
    else
        echo "WARNING: NTP synced but writing the DS3231 failed (hwclock -w)." >&2
        echo "         Is the RTC actually FITTED? This is the only moment" >&2
        echo "         anything ever writes it, and with fake-hwclock gone the" >&2
        echo "         card now has NO wall clock at all: it will boot at 1970" >&2
        echo "         and warn on every session. Check the i2c-rtc overlay /" >&2
        echo "         wiring, then re-run:  hwclock -w && hwclock -r" >&2
    fi
else
    echo "WARNING: no NTP sync after 2 min — system (and RTC) time may be" >&2
    echo "         wrong, and nothing offline ever corrects it. Fix before" >&2
    echo "         deploying:" >&2
    echo "         date -u -s 'YYYY-mm-dd HH:MM:SS' && hwclock -w" >&2
fi

mkdir -p /data/front /data/rear /data/gps

echo "enabling units..."
systemctl daemon-reload
udevadm control --reload
# Reload alone doesn't re-run rules for devices that already enumerated —
# without the trigger, /dev/gps0 (and /dev/rear-cam) would only appear on
# the next reboot, and gpsd's DEVICES= would point at nothing until then.
udevadm trigger --action=add --subsystem-match=tty --subsystem-match=video4linux
udevadm settle
enable_units="dashberry.target session.service \
    gps-rate.service front-rec.service gps-log.service panel.service \
    retention.timer"
if [ "$BYPASS_REAR" = "1" ]; then
    echo "bypass-rear: rear-rec.service stays disabled"
else
    enable_units="$enable_units rear-rec.service"
fi
# The boot-time RF assert goes on every card that is supposed to boot
# RF-KILLED — which is every card except the one build that is meant to
# come up live, a debug card given a --wifi profile. That is byte for byte
# the condition under which the udev rule is removed below, deliberately:
# the two layers must never disagree about which card is allowed radios.
if [ "$DEBUG" = 1 ] && [ "$FIRSTBOOT_WIFI" = 1 ]; then
    echo "debug card with --wifi: dashberry-rfkill.service stays disabled"
else
    enable_units="$enable_units dashberry-rfkill.service"
fi
# shellcheck disable=SC2086 — word splitting is the point
systemctl enable $enable_units

# True while some wlan rfkill switch is clear BOTH ways — byte for byte the
# condition the panel's glyph reads (rf_unblocked() in dashberry-panel.c),
# so this check and the OLED can never disagree about what RF-ENABLED
# means. No wlan switch at all counts as blocked, exactly as it does there.
rf_live() {
    for _s in /sys/class/rfkill/rfkill*; do
        [ -d "$_s" ] || continue
        [ "$(cat "$_s/type" 2>/dev/null)" = wlan ] || continue
        [ "$(cat "$_s/soft" 2>/dev/null)" = 0 ]    || continue
        [ "$(cat "$_s/hard" 2>/dev/null)" = 0 ]    || continue
        return 0
    done
    return 1
}

# Take the radios down and PROVE it — at every layer that can speak again
# at boot. The kernel switch is only the first word of a boot, not the
# last: two daemons rewrite it later in every boot from state files of
# their own, and on a production card those files are about to be frozen
# into the read-only lower layer and replayed identically at every boot
# for the life of the card (the tmpfs upper resets to the frozen copy —
# the files cannot carry a JOIN WIFI session across a boot, but they
# re-assert the install-time state forever):
#
#   1. systemd-rfkill — socket-activated by the wlan switch appearing, its
#      ADD handler RESTORES /var/lib/systemd/rfkill/<dev>:wlan into the
#      kernel, seconds after 99-dashberry-rfkill.rules ran. Its own save
#      of the block below is queued/deferred and races the reboot, so the
#      file is written here by hand instead of trusted to land.
#   2. NetworkManager — loads WirelessEnabled from NetworkManager.state
#      and asserts it onto every wlan killswitch. NM starts last, so its
#      file is the boot's final answer. `nmcli radio wifi off` persists
#      false — but its failure is discarded (`|| true`), and a card that
#      lost that one write booted RF-ENABLED for life with nothing saying
#      so (field-observed 2026-08-04, and again 2026-08-05 on a card the
#      udev rule alone did not save). So the FILE is verified, not the
#      nmcli exit status. A MISSING file is not safe either: NM treats no
#      state file as WirelessEnabled=true.
#
# On a production card whatever is true when this returns is about to be
# frozen into a read-only OS, so every layer is verified rather than hoped
# for. NM applies the kernel block asynchronously, hence the bounded wait.
NM_STATE=/var/lib/NetworkManager/NetworkManager.state
radios_off() {
    nmcli radio wifi off 2>/dev/null || true
    rfkill block wifi 2>/dev/null || true
    _i=0
    while rf_live && [ "$_i" -lt 15 ]; do
        sleep 0.2
        _i=$((_i + 1))
    done
    # Pin the boot-replayed files to match the switch (see above).
    if [ -f "$NM_STATE" ]; then
        sed -i 's/^WirelessEnabled=true$/WirelessEnabled=false/' "$NM_STATE"
        # No line at all also means enabled to NM. The file holds only
        # [main], so appending stays inside it.
        grep -q '^WirelessEnabled=' "$NM_STATE" || \
            printf 'WirelessEnabled=false\n' >> "$NM_STATE"
    else
        printf '[main]\nNetworkingEnabled=true\nWirelessEnabled=false\nWWANEnabled=true\n' \
            > "$NM_STATE"
    fi
    for _f in /var/lib/systemd/rfkill/*:wlan; do
        [ -e "$_f" ] && printf '1\n' > "$_f"
    done
    if rf_live || ! grep -qx 'WirelessEnabled=false' "$NM_STATE"; then
        echo "WARNING: the radios — or a state file a boot daemon replays over" >&2
        echo "         them — are STILL live after the take-down: this card can" >&2
        echo "         boot RF-ENABLED." >&2
        if [ "$DEBUG" = 1 ]; then
            echo "         The OS stays writable: fix and re-run, or block by hand." >&2
        else
            echo "         The read-only OS is about to freeze that: rebuild the card." >&2
        fi
    fi
}

# Everything a later reader needs to decide whether the overlay ACTUALLY
# armed — dumped into the install log, which outlives the reboot and the
# seal. It cannot be decided HERE: `raspi-config nonint do_overlayfs 0`
# only edits files, and whether those files produce a read-only root is not
# known until the next boot. So this records the inputs to that boot rather
# than judging them, and the log settles it afterwards.
#
# The two config.txt paths are the point. Since bookworm the firmware reads
# the BOOT PARTITION's config.txt (/boot/firmware/config.txt); /boot is an
# ordinary directory on the root filesystem, and an `initramfs` line landing
# there is read by nobody. `boot=overlay` on the kernel cmdline is inert
# without an initramfs actually loaded, so a card can arm the overlay,
# report success, and still boot read-write for its whole life. Hence also
# the verbatim dump of this card's own enable_overlayfs(): which file it
# writes is the question, and the answer is different per raspi-config
# version.
#
# Nothing here may abort the install — every probe absorbs its own failure.
overlay_evidence() {
    echo "--- overlay evidence (raspi-config exit $1) ---"
    echo "raspi-config version: $(dpkg-query -W -f='${Version}' raspi-config \
        2>/dev/null || echo unknown)"
    for _f in /boot/config.txt "$BOOTFW/config.txt"; do
        printf 'initramfs line in %s: %s\n' "$_f" \
            "$(grep -i '^[[:space:]]*initramfs' "$_f" 2>/dev/null || echo NONE)"
    done
    # Both naming conventions: initrd.img-<kernel> is what the kernel hooks
    # build into /boot, initramfs8 / initramfs_2712 is what the raspi
    # firmware hook copies onto the boot partition and what auto_initramfs
    # actually loads. The first pass of this dump globbed only the former
    # and reported the latter "absent", which proved nothing.
    for _i in /boot/initrd.img-* "$BOOTFW"/initrd.img-* "$BOOTFW"/initramfs*; do
        if [ -e "$_i" ]; then ls -l "$_i"; else echo "absent: $_i"; fi
    done
    printf 'overlayroot package: %s\n' \
        "$(dpkg-query -W -f='${Status}' overlayroot 2>/dev/null || echo 'not installed')"
    # Verbatim, not grepped for one token: this is the file the firmware
    # reads, it lives on the same partition as this log, and which token
    # means "overlay" has already changed once under us.
    printf 'cmdline: %s\n' "$(cat "$CMDLINE" 2>/dev/null || echo unreadable)"
    # Still the pre-flip mount, always — recorded as the baseline the next
    # boot has to change.
    printf 'root now: %s\n' "$(findmnt -no SOURCE,FSTYPE / 2>/dev/null || echo unknown)"
    echo "--- raspi-config enable_overlayfs() as installed ---"
    sed -n '/^enable_overlayfs()/,/^}/p' /usr/bin/raspi-config 2>/dev/null ||
        echo "(raspi-config not readable)"
    echo "--- end overlay evidence ---"
}

if [ "$DEBUG" = 1 ]; then
    # DEBUG card: keep the Wi-Fi profile (the card rejoins the LAN every
    # boot), keep the journal, and make it persistent — /var/log/journal
    # existing flips journald's Storage=auto to disk from the next boot,
    # so crash-window logs survive a power cut on the writable OS.
    echo "debug card: keeping the journal; enabling persistent journal..."
    mkdir -p /var/log/journal
    if [ "$FIRSTBOOT_WIFI" = 1 ]; then
        # A --wifi profile on a debug card is the explicit request for a
        # card that rejoins the LAN by itself: keep it, keep the regdom,
        # leave the radios live. This is the ONLY build that boots
        # RF-ENABLED, so it is also the only one that must NOT carry the
        # boot-time block — drop the rule (the OS stays writable here, so
        # this survives) and make sure the switch is clear right now.
        # JOIN WIFI is not armed here — the card already knows a network,
        # and the panel's toggle would only fight this profile.
        echo "debug card: keeping the staged Wi-Fi profile (radios stay live)"
        rm -f /etc/udev/rules.d/99-dashberry-rfkill.rules
        udevadm control --reload 2>/dev/null || true
        rfkill unblock wifi 2>/dev/null || true
        nmcli radio wifi on 2>/dev/null || true
    else
        # No network was ever named for this card, so it has nothing to
        # talk to: leave it dark rather than beaconing on the bench.
        echo "debug card: no --wifi profile — leaving the radios blocked"
        radios_off
    fi
else
    # THE OVERLAY IS ARMED FIRST, WHILE THE CARD IS STILL ONLINE. It used
    # to be the last step, after radios_off had taken the network down, and
    # on trixie that ordering is fatal: raspi-config's enable_overlayfs now
    # begins `is_installed overlayroot || apt-get install -y overlayroot`,
    # so the step needs a network — and on a --wifi card there is none left
    # by then. It died on DNS, the `||` swallowed the failure, and
    # raspi-config wrote an inert token and exited 0 (field-observed
    # 2026-08-08, see the apt step). Ordering costs nothing to fix: arming
    # only edits the cmdline and installs a package, and the overlay does
    # not take effect until the next boot — so nothing this branch does
    # afterwards is any less frozen for having armed early. The apt step
    # also installs overlayroot outright, so this is belt AND braces.
    echo "enabling the read-only OS overlay..."
    # 0 = enable in raspi-config's nonint convention. Its exit status is
    # taken separately from the token check below so the log can tell
    # "raspi-config refused" from "raspi-config claimed success and the
    # token is missing" — they were one branch, and the difference is the
    # whole diagnosis.
    if raspi-config nonint do_overlayfs 0; then
        _rc_overlay=0
    else
        _rc_overlay=$?
    fi
    overlay_evidence "$_rc_overlay"
    # raspi-config's exit status is known to lie (0 with the package
    # install failed), so the postcondition is checked here rather than
    # trusted. Two mechanisms are accepted because the image changed one
    # under us without notice and may again: trixie's raspi-config writes
    # `overlayroot=tmpfs` and needs the overlayroot package to implement
    # it; older ones wrote `boot=overlay` and built their own initramfs.
    # Whichever is in play, a token alone is inert — hence the package
    # test, and hence the next-boot VERIFY that no install-time check can
    # stand in for.
    _overlay_ok=0
    if grep -q 'overlayroot=tmpfs' "$CMDLINE" 2>/dev/null; then
        # Two independent tests, because a false negative here would warn on
        # every good card and train the reader to ignore the warning: the
        # dpkg status field, and the binary the package actually ships. The
        # status test matches 'ok installed' rather than the full
        # 'install ok installed' so a held package still counts as present.
        if dpkg-query -W -f='${Status}' overlayroot 2>/dev/null |
                grep -q 'ok installed' ||
                command -v overlayroot-chroot >/dev/null 2>&1; then
            _overlay_ok=1
        else
            echo "WARNING: cmdline says overlayroot=tmpfs but the overlayroot" >&2
            echo "         package is NOT installed — the token is inert and" >&2
            echo "         this card will boot READ-WRITE." >&2
        fi
    elif grep -q 'boot=overlay' "$CMDLINE" 2>/dev/null; then
        _overlay_ok=1
    fi
    if [ "$_rc_overlay" = 0 ] && [ "$_overlay_ok" = 1 ]; then
        echo "overlay armed (to make the OS writable again: raspi-config nonint do_overlayfs 1 + reboot)"
        # Armed is not sealed. Everything above is a precondition; whether
        # the root actually mounts read-only is only true at the next boot,
        # and this is the check that has never been run on any card.
        echo "VERIFY after the reboot: 'findmnt -no FSTYPE /' must say overlay."
    else
        echo "WARNING: could not enable the overlay noninteractively —" >&2
        echo "         this card's OS will stay WRITABLE, which also means a" >&2
        echo "         JOIN WIFI session's credential and radio state survive" >&2
        echo "         reboots. Read the overlay evidence above in" >&2
        echo "         $INSTALL_LOG, then run" >&2
        echo "         'sudo raspi-config' > Performance > Overlay FS by hand." >&2
    fi

    echo "production card: wiping stored Wi-Fi credentials..."
    # Must happen BEFORE the overlay flip: anything left now is frozen into
    # the read-only OS forever. Wiped: the NM profile (holds the plaintext
    # PSK), DHCP leases and the seen-bssids cache, and — on a Wi-Fi install
    # — the journal (NM logs the SSID; the PSK never reaches it).
    # radios_off blocks the switch and pins the frozen-to-be state files
    # (WirelessEnabled=false, systemd-rfkill's wlan state) — THOSE are what
    # make the card come up RF-KILLED on every LATER boot, since the boot
    # daemons replay them over the switch after 99-dashberry-rfkill.rules
    # has run. A JOIN WIFI card's radios only ever come up from the panel
    # and never survive a reboot, clean or not: the session's own state
    # writes all land in the overlay's tmpfs upper and die with the power.
    radios_off
    rm -f /etc/NetworkManager/system-connections/dashberry-firstboot.nmconnection
    rm -f /var/lib/NetworkManager/*.lease
    rm -f /var/lib/NetworkManager/seen-bssids
    # Boot-time rfkill state RESTORE is actively harmful on a frozen-state
    # OS: every save systemd-rfkill makes after this dies in the tmpfs
    # upper, so all its restore can ever do is replay this install's state
    # — or, had radios_off not pinned it, replay RF-ENABLED over the udev
    # rule at every boot (the 2026-08-05 field failure: an install whose
    # frozen state said "unblocked" booted RF-ENABLED despite the rule).
    # Masked, not disabled, same as fake-hwclock and gpsdctl@: nothing may
    # quietly bring it back. Debug cards keep it — the OS is writable
    # there, so its save/restore behaves as designed.
    echo "production card: masking boot-time rfkill state restore..."
    systemctl mask systemd-rfkill.service systemd-rfkill.socket 2>/dev/null || true
    if [ "$RF_JOIN" = 1 ]; then
        # JOIN WIFI card: the credential is gone like on any production
        # card, but the regulatory domain must survive — without it the
        # kernel hard-blocks wlan for the card's whole life and rf-ctl
        # could never bring the radios up, so the feature would be dead on
        # arrival. The regdom is not a credential: it names no network.
        echo "JOIN WIFI armed: keeping the regulatory domain in cmdline.txt"
    else
        sed -i 's/ cfg80211\.ieee80211_regdom=[A-Za-z][A-Za-z]//g' "$CMDLINE"
    fi
    if [ "$FIRSTBOOT_WIFI" = 1 ]; then
        journalctl --rotate --vacuum-time=1s >/dev/null 2>&1 || true
    fi
fi

# self-remove: this must never run twice (and never ships in the runtime)
systemctl disable dashberry-firstinstall.service 2>/dev/null || true
rm -f /etc/systemd/system/dashberry-firstinstall.service \
    /etc/systemd/system/multi-user.target.wants/dashberry-firstinstall.service

echo
echo "firstinstall done."
echo "install log: $INSTALL_LOG (survives the reboot and the overlay; also"
echo "             readable by pulling the card into any PC)"
if [ "$FROM_UNIT" = 1 ]; then
    echo "rebooting into the installed system..."
    systemctl --no-block reboot
else
    echo "reboot to start recording."
fi
