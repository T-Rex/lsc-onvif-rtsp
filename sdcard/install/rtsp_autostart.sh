#!/bin/sh
# rtsp_autostart.sh - SD-card boot worker. Installed into /etc/config by
# install-autostart.sh and launched at boot from the sensor-driver hook. Waits
# for the SD opt-in markers and a real LAN Wi-Fi address, restarts anyka_ipc in
# RTSP factory mode (which, via rtsp_factory.ini's [wifi_station], keeps the
# camera on the LAN), then starts ONVIF + PTZ from the SD. BusyBox /bin/sh.
LOG=/tmp/rtsp_autostart.log
echo "RTSP worker started" >> "$LOG"

# One worker per boot: the boot chain can fire the hook more than once, and
# concurrent workers would each restart anyka_ipc. mkdir is atomic.
if ! mkdir /tmp/.rtsp_autostart.lock 2>/dev/null; then
    echo "worker already running this boot; exit" >> "$LOG"; exit 0
fi

# Locate the SD. With the Telnet bootstrap it is reliably at /tmp/sd; on a plain
# boot the firmware mounts it at /mnt. Prefer /tmp/sd. Re-evaluated on each use,
# so a transient /mnt state can never strand us mid-run.
find_sd() {
    for _d in /tmp/sd /mnt; do
        if [ -f "$_d/rtsp_autostart.enabled" ] && [ -s "$_d/rtsp_factory.ini" ]; then
            echo "$_d"; return 0
        fi
    done
    return 1
}

# Wait up to 120s for the card + opt-in marker to appear.
i=0; SD=""
while [ "$i" -lt 120 ]; do
    SD=$(find_sd) && break
    sleep 1; i=$((i + 1))
done
[ -n "$SD" ] || { echo "SD marker/config not found. Exit." >> "$LOG"; exit 0; }

LOG="$SD/rtsp-autostart.log"
echo "=== RTSP boot ===" >> "$LOG"; date >> "$LOG"
echo "Using SD at $SD" >> "$LOG"

# Wait for a real LAN IPv4 on wlan0 - NOT the camera's own factory AP
# (172.14.10.x), which shows up transiently while Wi-Fi is switched to station.
echo "Waiting for LAN Wi-Fi..." >> "$LOG"
i=0; IP=""
while [ "$i" -lt 180 ]; do
    IP=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
    case "$IP" in
        ""|0.0.0.0|172.14.10.*) : ;;   # not ready, or still on the factory AP
        *) break ;;
    esac
    sleep 1; i=$((i + 1))
done
case "$IP" in
    ""|0.0.0.0|172.14.10.*) echo "ERROR: no LAN Wi-Fi (last='$IP')" >> "$LOG"; exit 1 ;;
esac
echo "LAN Wi-Fi up: $IP" >> "$LOG"; ifconfig wlan0 >> "$LOG" 2>&1

# Wait for the factory app, then let it settle. 10s is enough for anyka_ipc to
# finish bringing up the sensor/ISP before we restart it in RTSP mode; raise it
# again if a restarted anyka_ipc ever comes up without video.
i=0
while [ "$i" -lt 90 ]; do pgrep anyka_ipc >/dev/null 2>&1 && break; sleep 1; i=$((i + 1)); done
echo "Waiting 10 seconds for initialization" >> "$LOG"; sleep 10

# Re-locate the SD (mounts can change during Wi-Fi bring-up) and re-check opt-in.
SD=$(find_sd) || { echo "SD vanished before restart; exit" >> "$LOG"; exit 0; }

echo "Installing factory config in tmpfs" >> "$LOG"
cp "$SD/rtsp_factory.ini" /tmp/_ak39_factory.ini || { echo "ERROR: cannot stage factory ini" >> "$LOG"; exit 1; }

echo "Restarting anyka_ipc in RTSP mode" >> "$LOG"
killall -9 anyka_ipc 2>/dev/null
sleep 2
setsid /usr/bin/anyka_ipc </dev/null >> "$LOG" 2>&1 &
echo "RTSP restart requested" >> "$LOG"

# ONVIF (and PTZ via onvif/start.sh) from the SD, after a short settle.
if [ -f "$SD/onvif_autostart.enabled" ] && [ -f "$SD/onvif/start.sh" ]; then
    (
        sleep 6
        SD2=$(find_sd) || SD2="$SD"
        if [ -f "$SD2/onvif_autostart.enabled" ] && [ -f "$SD2/onvif/start.sh" ]; then
            mkdir -p "$SD2/onvif/logs"
            echo "=== ONVIF automatic start ===" >> "$SD2/onvif/logs/onvif-boot.log"
            date >> "$SD2/onvif/logs/onvif-boot.log"
            sh "$SD2/onvif/start.sh" >> "$SD2/onvif/logs/onvif-boot.log" 2>&1
        fi
    ) </dev/null >/tmp/onvif-boot-launcher.log 2>&1 &
fi
exit 0
