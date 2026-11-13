#!/bin/sh
# install-autostart.sh - ONE-TIME autostart bootstrap for a clean camera.
#
# The camera runs its sensor driver from /etc/config (JFFS2 flash) at boot. This
# installs the RTSP+ONVIF boot worker there and hooks it into that sensor driver,
# so from then on every boot brings up RTSP (factory mode) + ONVIF + PTZ straight
# from the SD card. Idempotent; backs up the stock files; writes flash only on the
# first run. Run once over Telnet after copying the SD-card contents to /mnt:
#
#   sh /mnt/install/install-autostart.sh
#
# BusyBox /bin/sh. Writes JFFS2 (/etc/config) - the only step that does. The ONVIF
# package itself lives entirely on the SD; this only arranges for it to autostart.
# To undo: restore /etc/config/sensor_driver.sh.rtsp-original and remove
# /etc/config/rtsp_autostart.sh (see the end of this script).
set -u
CFG=/etc/config
HERE=$(cd "$(dirname "$0")" && pwd)
# The card may be mounted at /mnt (normal boot) or /tmp/sd (Telnet bootstrap).
# Derive it from where this script actually lives so the final notes are right.
SD=$(cd "$HERE/.." && pwd)

[ -d "$CFG" ] || { echo "ERROR: $CFG not present (is JFFS2 mounted?)"; exit 1; }
[ -f "$HERE/rtsp_autostart.sh" ] || { echo "ERROR: $HERE/rtsp_autostart.sh missing"; exit 1; }

echo "=== installing SD autostart into $CFG ==="

# 1. install the boot worker
cp "$HERE/rtsp_autostart.sh" "$CFG/rtsp_autostart.sh" && chmod 755 "$CFG/rtsp_autostart.sh" \
    || { echo "ERROR: cannot write $CFG/rtsp_autostart.sh"; exit 1; }
echo "installed $CFG/rtsp_autostart.sh"

# 2. hook it into the sensor driver that the factory runs at boot
if [ ! -f "$CFG/sensor_driver.sh" ]; then
    echo "NOTE: $CFG/sensor_driver.sh not found."
    echo "      On this firmware the boot sensor driver should live in $CFG."
    echo "      Copy your camera's stock sensor_driver.sh into $CFG first, then re-run,"
    echo "      or hook rtsp_autostart.sh into whatever script your firmware runs at boot."
    exit 1
fi
# Always end up with exactly ONE fresh hook, no matter how many times this ran
# before: if any previous hook is present, restore the pristine stock file first
# (or strip the block as a fallback), then append the current hook once.
if grep -q "RTSP_SD_AUTOSTART" "$CFG/sensor_driver.sh"; then
    if [ -f "$CFG/sensor_driver.sh.rtsp-original" ]; then
        cp "$CFG/sensor_driver.sh.rtsp-original" "$CFG/sensor_driver.sh"
        echo "removed previous hook (restored stock sensor_driver.sh)"
    else
        sed '/# RTSP_SD_AUTOSTART/,/^fi$/d' "$CFG/sensor_driver.sh" > "$CFG/sensor_driver.sh.tmp" \
            && mv -f "$CFG/sensor_driver.sh.tmp" "$CFG/sensor_driver.sh"
        cp "$CFG/sensor_driver.sh" "$CFG/sensor_driver.sh.rtsp-original"
        echo "stripped previous hook(s) (no backup existed; saved current as stock)"
    fi
else
    cp "$CFG/sensor_driver.sh" "$CFG/sensor_driver.sh.rtsp-original"
fi
cat >> "$CFG/sensor_driver.sh" <<'HOOK'

# RTSP_SD_AUTOSTART_V1
if [ -f /etc/config/rtsp_autostart.sh ]; then
    sh /etc/config/rtsp_autostart.sh </dev/null >/tmp/rtsp_auto_boot.log 2>&1 &
fi
HOOK
echo "hooked rtsp_autostart.sh into $CFG/sensor_driver.sh (single fresh hook; stock saved as .rtsp-original)"

echo "=== done. Verify the SD has: onvif/, onvif_autostart.enabled, rtsp_autostart.enabled, rtsp_factory.ini"
echo "    then REBOOT. After ~90-120s: RTSP 554, ONVIF 8080, WS-Discovery 3702, PTZ bridge."
echo
echo "To UNINSTALL: cp $CFG/sensor_driver.sh.rtsp-original $CFG/sensor_driver.sh ; rm $CFG/rtsp_autostart.sh ; reboot"
exit 0
