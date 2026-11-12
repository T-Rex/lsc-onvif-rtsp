#!/bin/sh
# rtsp_autostart.sh - SD-card boot worker. Installed into /etc/config by
# install-autostart.sh and launched at boot from the sensor-driver hook. Waits
# for the SD opt-in markers, Wi-Fi and the factory app, restarts anyka_ipc in
# RTSP factory mode, then (if opted in) starts ONVIF from the SD. BusyBox /bin/sh.
SD=/mnt
LOG=/tmp/rtsp_autostart.log
echo "RTSP worker started" >> "$LOG"

# Wait for SD card and opt-in marker
i=0
while [ "$i" -lt 120 ]; do
    if [ -f "$SD/rtsp_autostart.enabled" ] && [ -s "$SD/rtsp_factory.ini" ]; then
        break
    fi
    sleep 1; i=$((i + 1))
done
[ "$i" -ge 120 ] && { echo "SD marker/config not found. Exit." >> "$LOG"; exit 0; }

LOG="$SD/rtsp-autostart.log"
echo "=== RTSP boot ===" >> "$LOG"; date >> "$LOG"

# Wait until Wi-Fi has an IPv4 address
echo "Waiting for Wi-Fi..." >> "$LOG"
i=0
while [ "$i" -lt 180 ]; do
    ifconfig wlan0 2>/dev/null | grep -Eq 'inet addr:|inet ' && break
    sleep 2; i=$((i + 2))
done
[ "$i" -ge 180 ] && { echo "ERROR: Wi-Fi timeout" >> "$LOG"; exit 1; }
echo "Wi-Fi address found" >> "$LOG"; ifconfig wlan0 >> "$LOG" 2>&1

# Wait for normal application startup
i=0
while [ "$i" -lt 90 ]; do
    pgrep anyka_ipc >/dev/null 2>&1 && break
    sleep 2; i=$((i + 2))
done
[ "$i" -ge 90 ] && { echo "ERROR: anyka_ipc startup timeout" >> "$LOG"; exit 1; }

# Allow normal initialization to finish
echo "Waiting 20 seconds for initialization" >> "$LOG"; sleep 20

ifconfig wlan0 2>/dev/null | grep -Eq 'inet addr:|inet ' || { echo "ERROR: Wi-Fi lost before switching" >> "$LOG"; exit 1; }
[ -f "$SD/rtsp_autostart.enabled" ] || { echo "Autostart disabled" >> "$LOG"; exit 0; }

echo "Installing factory config in tmpfs" >> "$LOG"
cp "$SD/rtsp_factory.ini" /tmp/_ak39_factory.ini || exit 1

echo "Restarting anyka_ipc in RTSP mode" >> "$LOG"
killall -9 anyka_ipc
sleep 3
setsid /usr/bin/anyka_ipc </dev/null >> "$LOG" 2>&1 &
echo "RTSP restart requested" >> "$LOG"

# ONVIF_SD_AUTOSTART_V1 - start ONVIF (and PTZ via onvif/start.sh) from the SD.
if [ -f /mnt/onvif_autostart.enabled ] && [ -f /mnt/onvif/start.sh ]; then
    (
        sleep 12
        if [ -f /mnt/onvif_autostart.enabled ] && [ -f /mnt/onvif/start.sh ]; then
            mkdir -p /mnt/onvif/logs
            echo "=== ONVIF automatic start ===" >> /mnt/onvif/logs/onvif-boot.log
            date >> /mnt/onvif/logs/onvif-boot.log
            sh /mnt/onvif/start.sh >> /mnt/onvif/logs/onvif-boot.log 2>&1
        fi
    ) </dev/null >/tmp/onvif-boot-launcher.log 2>&1 &
fi
exit 0
