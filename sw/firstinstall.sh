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
#   - BYPASS_TIME / BYPASS_REAR in ./etc/dashberry.conf (the copy installed
#     to /etc below — panel and installer read the same truth);
#   - READONLY in ../install-opts (enable the overlayfs at the end);
#   - FIRSTBOOT_WIFI in ../install-opts (this boot runs over a staged Wi-Fi
#     profile instead of Ethernet; every trace of it is wiped below, before
#     the overlay can freeze it into the read-only OS).
#
# dashberry-cli (../cli) is PC-side and is deliberately NOT installed here —
# it never ships on the image (PLAN §3c).
set -eu

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")"

FROM_UNIT=0
[ "${1:-}" = "--from-unit" ] && FROM_UNIT=1

BYPASS_TIME=0
BYPASS_REAR=0
READONLY=0
FIRSTBOOT_WIFI=0
. ./etc/dashberry.conf
[ -f ../install-opts ] && . ../install-opts

CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt

if [ "$FIRSTBOOT_WIFI" = 1 ]; then
    echo "first-boot Wi-Fi: unblocking and waiting for the network..."
    # rf-state.service is not enabled yet (that happens below), so nothing
    # re-blocks the radio this boot. The cmdline regdom staged by
    # dashberry-install should already have left wlan unblocked (VERIFY on
    # bench: Bookworm honors cfg80211.ieee80211_regdom headless); these are
    # belt-and-braces — rfkill may not exist on the stock image yet.
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
            echo "(Wi-Fi is rfkill-blocked by design; fix the network and reboot" >&2
            echo " to retry, or run /opt/dashberry/sw/firstinstall.sh by hand.)" >&2
        fi
        exit 1
    fi
    sleep 15
done
apt-get install -y --no-install-recommends \
    rpicam-apps-lite gstreamer1.0-tools gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gpsd gpsd-clients rfkill chrony gcc make

echo "building panel daemon..."
make -C src
make -C src install

echo "installing files..."
install -m 755 usr/local/bin/* /usr/local/bin/
install -m 644 etc/dashberry.conf /etc/dashberry.conf
install -m 644 etc/systemd/system/* /etc/systemd/system/
install -m 644 etc/udev/rules.d/99-dashberry.rules /etc/udev/rules.d/
install -D -m 644 etc/chrony/conf.d/gps-refclock.conf /etc/chrony/conf.d/gps-refclock.conf

if [ "$BYPASS_TIME" = "1" ]; then
    # No DS3231: GPS is the only wall-clock source, so the refclock must be
    # trusted (drop noselect) and chrony must be allowed to step the clock at
    # any point — boot-time offset without an RTC can be arbitrarily large.
    echo "bypass-time: trusting the GPS refclock..."
    sed -i 's/ noselect$//' /etc/chrony/conf.d/gps-refclock.conf
    printf 'makestep 1 -1\n' >> /etc/chrony/conf.d/gps-refclock.conf
fi

mkdir -p /data/front /data/rear /data/gps /data/rf

echo "enabling units..."
systemctl daemon-reload
udevadm control --reload
enable_units="dashberry.target rf-state.service session.service \
    gps-rate.service front-rec.service gps-log.service panel.service \
    retention.timer"
if [ "$BYPASS_REAR" = "1" ]; then
    echo "bypass-rear: rear-rec.service stays disabled"
else
    enable_units="$enable_units rear-rec.service"
fi
# shellcheck disable=SC2086 — word splitting is the point
systemctl enable $enable_units

if [ "$FIRSTBOOT_WIFI" = 1 ]; then
    echo "wiping first-boot Wi-Fi traces..."
    # Must happen BEFORE the overlay flip: anything left now is frozen into
    # the read-only OS forever. Wiped: the NM profile (holds the plaintext
    # PSK), DHCP leases and the seen-bssids cache, the cmdline regdom token,
    # and the journal (NM logs the SSID). nmcli radio wifi off additionally
    # persists WirelessEnabled=false into NetworkManager.state. From the
    # next boot rf-state fails closed as on any fresh card (/data/rf empty).
    nmcli radio wifi off 2>/dev/null || true
    rm -f /etc/NetworkManager/system-connections/dashberry-firstboot.nmconnection
    rm -f /var/lib/NetworkManager/*.lease
    rm -f /var/lib/NetworkManager/seen-bssids
    sed -i 's/ cfg80211\.ieee80211_regdom=[A-Za-z][A-Za-z]//g' "$CMDLINE"
    journalctl --rotate --vacuum-time=1s >/dev/null 2>&1 || true
fi

if [ "$READONLY" = "1" ]; then
    echo "enabling the read-only OS overlay..."
    # VERIFY (bench): nonint do_overlayfs works headless — 0 = enable in
    # raspi-config's convention; takes effect at the next boot.
    if raspi-config nonint do_overlayfs 0 && grep -q boot=overlay "$CMDLINE"; then
        echo "overlay armed (bench iteration: raspi-config nonint do_overlayfs 1 + reboot)"
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
    echo "reboot to start recording; then work the VERIFY table in README.md."
fi
