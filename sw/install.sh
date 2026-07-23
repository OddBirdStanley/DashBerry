#!/bin/sh
# install.sh — run ON THE PI, from this directory, as root.
# Builds the panel daemon, copies scripts/units/config into place and enables
# the dashberry target. Boot config (config.txt/cmdline.txt) and fstab are NOT
# touched — merge boot/config-snippet.txt and etc/fstab.snippet by hand (both
# are commented). dashberry-cli (../cli) is PC-side and is deliberately NOT
# installed here — it never ships on the image (PLAN §3c).
set -eu

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")"

echo "installing packages..."
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

mkdir -p /data/front /data/rear /data/gps /data/rf

echo "enabling units..."
systemctl daemon-reload
udevadm control --reload
systemctl enable dashberry.target rf-state.service session.service \
    gps-rate.service front-rec.service rear-rec.service gps-log.service \
    panel.service retention.timer

echo "removing rev-4 leftovers (if this is an upgrade)..."
systemctl disable dashcam.target rf-init.service rf-switch.service 2>/dev/null || true
rm -f /usr/local/bin/panel /usr/local/bin/rf-switch /usr/local/bin/rf-apply \
    /usr/local/bin/nmea2csv /etc/dashcam.conf \
    /etc/systemd/system/dashcam.target /etc/systemd/system/rf-init.service \
    /etc/systemd/system/rf-switch.service /etc/udev/rules.d/99-dashcam.rules

echo
echo "done. Remaining manual steps:"
echo "  1. merge boot/config-snippet.txt into /boot/firmware/config.txt (+cmdline notes)"
echo "  2. append etc/fstab.snippet to /etc/fstab (adjust partition)"
echo "  3. work the VERIFY table in README.md (bench checks)"
echo "  4. reboot; radios should come up BLOCKED (rfkill list) - fresh card = no state file"
