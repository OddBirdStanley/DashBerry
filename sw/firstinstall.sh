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
# Whatever the mode, the card ends this script RF-KILLED and boots that way:
# 99-dashberry-rfkill.rules blocks the wlan switch as it appears on every
# boot, and radios_off() below takes the radios down here and proves it.
# The one exception is a debug card that was given a --wifi profile — an
# explicit request for a card that rejoins the LAN by itself — where the
# rule is removed again.
#
# dashberry-cli (../cli) is PC-side and is deliberately NOT installed here —
# it never ships on the image.
set -eu

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
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
apt-get install -y --no-install-recommends \
    rpicam-apps gstreamer1.0-tools gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gpsd gpsd-clients chrony gcc make \
    util-linux util-linux-extra

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
enable_units="dashberry.target session.service tail-repair.service \
    gps-rate.service front-rec.service gps-log.service panel.service \
    retention.timer"
if [ "$BYPASS_REAR" = "1" ]; then
    echo "bypass-rear: rear-rec.service stays disabled"
else
    enable_units="$enable_units rear-rec.service"
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

# Take the radios down and PROVE it. Both halves, exactly like rf-ctl's
# `down`: nmcli persists WirelessEnabled=false (NetworkManager's own boot
# preference) and rfkill blocks the switch in the kernel now. Neither is
# what makes later boots safe — 99-dashberry-rfkill.rules is — but this is
# the state the card carries into its very first reboot, and on a
# production card whatever is true when this returns is about to be frozen
# into a read-only OS. So it is verified rather than hoped for: the old
# `nmcli radio wifi off 2>/dev/null || true` discarded its own failure, and
# a card that lost that one write booted RF-ENABLED for life with nothing
# saying so. NM applies the block asynchronously, hence the bounded wait.
radios_off() {
    nmcli radio wifi off 2>/dev/null || true
    rfkill block wifi 2>/dev/null || true
    _i=0
    while rf_live && [ "$_i" -lt 15 ]; do
        sleep 0.2
        _i=$((_i + 1))
    done
    if rf_live; then
        echo "WARNING: the radios are STILL unblocked after 'nmcli radio wifi off'" >&2
        echo "         and 'rfkill block wifi' — this card boots RF-ENABLED." >&2
        if [ "$DEBUG" = 1 ]; then
            echo "         The OS stays writable: fix and re-run, or block by hand." >&2
        else
            echo "         The read-only OS is about to freeze that: rebuild the card." >&2
        fi
    fi
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
    echo "production card: wiping stored Wi-Fi credentials..."
    # Must happen BEFORE the overlay flip: anything left now is frozen into
    # the read-only OS forever. Wiped: the NM profile (holds the plaintext
    # PSK), DHCP leases and the seen-bssids cache, and — on a Wi-Fi install
    # — the journal (NM logs the SSID; the PSK never reaches it).
    # radios_off persists WirelessEnabled=false into NetworkManager.state
    # on top of blocking the switch; 99-dashberry-rfkill.rules is what
    # makes the card come up RF-KILLED on every LATER boot — including a
    # JOIN WIFI card, whose radios only ever come up from the panel and
    # never survive a reboot, clean or not.
    radios_off
    rm -f /etc/NetworkManager/system-connections/dashberry-firstboot.nmconnection
    rm -f /var/lib/NetworkManager/*.lease
    rm -f /var/lib/NetworkManager/seen-bssids
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

    echo "enabling the read-only OS overlay..."
    # nonint do_overlayfs works headless — 0 = enable in raspi-config's
    # convention; takes effect at the next boot.
    if raspi-config nonint do_overlayfs 0 && grep -q boot=overlay "$CMDLINE"; then
        echo "overlay armed (to make the OS writable again: raspi-config nonint do_overlayfs 1 + reboot)"
    else
        echo "WARNING: could not enable the overlay noninteractively;" >&2
        echo "         run 'sudo raspi-config' > Performance > Overlay FS by hand." >&2
    fi
fi

# self-remove: this must never run twice (and never ships in the runtime)
systemctl disable dashberry-firstinstall.service 2>/dev/null || true
rm -f /etc/systemd/system/dashberry-firstinstall.service \
    /etc/systemd/system/multi-user.target.wants/dashberry-firstinstall.service

echo
echo "firstinstall done."
if [ "$FROM_UNIT" = 1 ]; then
    echo "rebooting into the installed system..."
    systemctl --no-block reboot
else
    echo "reboot to start recording."
fi
