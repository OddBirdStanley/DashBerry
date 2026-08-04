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
# `nmcli radio wifi off` persists WirelessEnabled=false. The one exception
# is a debug card that was given a --wifi profile — an explicit request for
# a card that rejoins the LAN by itself.
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

echo "installing packages..."
n=0
until apt-get update; do
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
        exit 1
    fi
    sleep 15
done
# Full rpicam-apps (not -lite): front-rec needs the libav encoder wrapper
# (--codec libav --libav-format mpegts) so PTS/DTS travel in-band down the
# pipe — the lite build is compiled without libav.
apt-get install -y --no-install-recommends \
    rpicam-apps gstreamer1.0-tools gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gpsd gpsd-clients chrony gcc make

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
install -m 644 etc/udev/rules.d/99-dashberry.rules /etc/udev/rules.d/
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
        # RF-ENABLED. JOIN WIFI is not armed here — the card already knows
        # a network, and the panel's toggle would only fight this profile.
        echo "debug card: keeping the staged Wi-Fi profile (radios stay live)"
    else
        # No network was ever named for this card, so it has nothing to
        # talk to: leave it dark rather than beaconing on the bench.
        echo "debug card: no --wifi profile — leaving the radios blocked"
        nmcli radio wifi off 2>/dev/null || true
    fi
else
    echo "production card: wiping stored Wi-Fi credentials..."
    # Must happen BEFORE the overlay flip: anything left now is frozen into
    # the read-only OS forever. Wiped: the NM profile (holds the plaintext
    # PSK), DHCP leases and the seen-bssids cache, and — on a Wi-Fi install
    # — the journal (NM logs the SSID; the PSK never reaches it). nmcli
    # radio wifi off additionally persists WirelessEnabled=false into
    # NetworkManager.state, so the card comes up RF-KILLED on this and
    # every later boot — including a JOIN WIFI card, whose radios only ever
    # come up from the panel and never survive the reboot.
    nmcli radio wifi off 2>/dev/null || true
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
