#!/bin/sh
# wifi.sh - optional Wi-Fi reconfiguration for the Telnet bootstrap card.
#
# The bootstrap hook (_ht_ap_mode.conf) makes the stock firmware bring wlan0 up
# as an access point. That is fine for a quick local Telnet, but usually you
# want the camera on your LAN instead. This script reads custom/configs/wifi.conf
# and, for MODE=sta, tears the AP down and joins an existing network so the
# camera lands on your LAN with Telnet reachable at its DHCP/static address.
#
# Switching the Realtek rtl8188 driver from AP to STA is firmware-specific, so
# this tries several methods AND writes a full firmware probe to the SD logs.
# If the join fails, that log tells us exactly what the firmware offers so the
# next build can target it precisely. Writes no flash. BusyBox /bin/sh (ash).
: "${SD_DIR:=/tmp/sd}"
[ -d "${SD_DIR}/custom" ] || SD_DIR=/mnt
CFG="${SD_DIR}/custom/configs/wifi.conf"

mkdir -p "${SD_DIR}/logs" 2>/dev/null || true
LOG="${SD_DIR}/logs/wifi.$(date +%Y%m%d_%H%M%S).log"
exec >>"$LOG" 2>&1
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

# Defaults (overridden by wifi.conf)
MODE=ap
SSID=""
PASS=""
SECURITY=wpa2        # wpa2 | open
IP=""                # empty => DHCP
NETMASK=255.255.255.0
GW=""
SETTLE=8             # seconds to let the firmware finish its own bringup first
[ -f "$CFG" ] && . "$CFG"

log "wifi.sh start: MODE=$MODE SSID='$SSID' security=$SECURITY ip='${IP:-dhcp}'"

# Single-instance guard. The firmware can run the boot hook more than once, and
# two concurrent wifi.sh would reload the Wi-Fi driver and start rival
# wpa_supplicants at the same time, tearing the link down. Only the first wins.
LOCK=/tmp/wifi.sh.lock
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
    log "wifi.sh already running (pid $(cat "$LOCK")); exiting"
    exit 0
fi
echo $$ > "$LOCK"

# ---------------------------------------------------------------------------
# Firmware probe - so we learn the box even without an interactive shell.
# ---------------------------------------------------------------------------
probe() {
    echo "================ FIRMWARE PROBE ================"
    echo "--- uname ---";            uname -a 2>&1
    echo "--- tools ---"
    for b in wpa_supplicant wpa_cli udhcpc udhcpd hostapd iwconfig iw ifconfig route; do
        printf '%s: ' "$b"; command -v "$b" 2>/dev/null || echo MISSING
    done
    echo "--- wifi scripts ---"
    ls -la /usr/sbin/wifi_driver_rtl8188.sh /usr/sbin/ethernet.sh \
           /usr/sbin/station_connect.sh /usr/sbin/wifi_*.sh 2>&1
    echo "--- /etc/config ---";       ls -la /etc/config 2>&1
    echo "--- hostapd.conf ---";      cat /etc/config/hostapd.conf 2>&1
    echo "--- udhcpd.conf ---";       cat /etc/config/udhcpd.conf 2>&1
    echo "--- udhcpc default.script ---"; ls -la /usr/share/udhcpc/default.script 2>&1
    echo "--- wifi_driver_rtl8188.sh ---"; cat /usr/sbin/wifi_driver_rtl8188.sh 2>&1
    echo "--- station_connect.sh ---"; cat /usr/sbin/station_connect.sh 2>&1
    echo "--- grep wifi_station ---";  grep -rl wifi_station /usr /etc 2>/dev/null
    echo "--- ifconfig (pre) ---";     ifconfig 2>&1
    echo "--- iwconfig (pre) ---";     iwconfig 2>&1
    echo "================================================"
}
probe

ip_of() { ifconfig "$1" 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p'; }

wait_for_ip() {
    i=0
    while [ "$i" -lt "${1:-20}" ]; do
        a=$(ip_of wlan0)
        if [ -n "$a" ] && [ "$a" != "0.0.0.0" ]; then
            log "STA: wlan0 has IP $a"
            echo "$a" > "${SD_DIR}/logs/wifi_ip.txt" 2>/dev/null || true
            return 0
        fi
        sleep 2; i=$((i + 1))
    done
    log "STA: no IP after $(( ${1:-20} * 2 ))s"
    return 1
}

start_dhcp() {
    killall udhcpc 2>/dev/null || true
    if [ -x /usr/share/udhcpc/default.script ]; then
        udhcpc -i wlan0 -s /usr/share/udhcpc/default.script -b >/dev/null 2>&1 &
    else
        udhcpc -i wlan0 -b >/dev/null 2>&1 &
    fi
    log "STA: udhcpc launched"
}

join_sta() {
    # 1) Let the firmware settle, then stop the AP-side services.
    sleep "$SETTLE"
    log "STA: stopping AP services (udhcpd/hostapd)"
    killall udhcpd 2>/dev/null || true
    killall hostapd 2>/dev/null || true

    # 2) Ask the firmware's own driver script to re-init in station mode. This
    #    is the cleanest way to flip the rtl8188 out of AP mode when present.
    if [ -x /usr/sbin/wifi_driver_rtl8188.sh ]; then
        log "STA: /usr/sbin/wifi_driver_rtl8188.sh sta"
        /usr/sbin/wifi_driver_rtl8188.sh sta >/dev/null 2>&1 &
        sleep 4
    fi
    ifconfig wlan0 up 2>/dev/null || true

    # 3) Associate. Prefer wpa_supplicant; fall back to the firmware helper.
    if command -v wpa_supplicant >/dev/null 2>&1; then
        WP=/tmp/wpa_bootstrap.conf
        if [ "$SECURITY" = open ]; then
            printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\nnetwork={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$SSID" > "$WP"
        else
            printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\nnetwork={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$SSID" "$PASS" > "$WP"
        fi
        mkdir -p /var/run/wpa_supplicant 2>/dev/null || true
        killall wpa_supplicant 2>/dev/null || true; sleep 1
        if wpa_supplicant -B -i wlan0 -D nl80211 -c "$WP" 2>&1; then
            log "STA: wpa_supplicant up (nl80211)"
        elif wpa_supplicant -B -i wlan0 -D wext -c "$WP" 2>&1; then
            log "STA: wpa_supplicant up (wext)"
        else
            log "STA: wpa_supplicant FAILED on both drivers"
        fi
    elif [ -x /usr/sbin/station_connect.sh ]; then
        sec=3; [ "$SECURITY" = open ] && sec=1
        log "STA: /usr/sbin/station_connect.sh $sec '$SSID' ****"
        /usr/sbin/station_connect.sh "$sec" "$SSID" "$PASS" 2>&1 || true
    else
        log "STA: NO wpa_supplicant and NO station_connect.sh -> cannot associate."
        log "STA: see the FIRMWARE PROBE above; send this log back to refine the build."
        return 1
    fi

    # 3b) Wait for real association. "wpa_supplicant up" only means the daemon
    # started; association + the 4-way handshake can still fail (wrong password,
    # weak signal). wpa_cli talks to our ctrl socket.
    j=0; st=
    while [ "$j" -lt 15 ]; do
        st=$(wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')
        [ "$st" = COMPLETED ] && break
        sleep 2; j=$((j + 1))
    done
    if [ "$st" = COMPLETED ]; then
        log "STA: associated (wpa_state=COMPLETED)"
    else
        log "STA: WARNING not associated (wpa_state=${st:-unknown}) - check SSID/password/signal"
    fi

    # 4) Address: static if given, else DHCP.
    if [ -n "$IP" ]; then
        ifconfig wlan0 "$IP" netmask "$NETMASK" up 2>/dev/null || true
        [ -n "$GW" ] && route add default gw "$GW" 2>/dev/null || true
        log "STA: static IP $IP"
    else
        start_dhcp
        wait_for_ip 25 || true
    fi

    echo "--- ifconfig (post) ---"; ifconfig wlan0 2>&1
    echo "--- iwconfig (post) ---"; iwconfig wlan0 2>&1
    echo "--- route (post) ---";    route -n 2>&1

    # Monitor ~40s: catches the firmware/anyka_ipc reasserting Wi-Fi (e.g.
    # flipping wlan0 back to the 172.14.10.1 AP) after we switch to STA.
    k=0
    while [ "$k" -lt 8 ]; do
        sleep 5
        a=$(ip_of wlan0)
        st=$(wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')
        ap=$(iwconfig wlan0 2>/dev/null | sed -n 's/.*Access Point: *//p')
        log "monitor +$(( (k + 1) * 5 ))s: ip='${a:-none}' wpa_state='${st:-?}' ap='${ap}'"
        k=$((k + 1))
    done
    log "STA: monitor done"
}

apply_custom_ap() {
    # Best-effort custom AP SSID/password. The stock firmware brings the AP up
    # itself, so this only takes effect if the firmware reads hostapd.conf after
    # our hook runs; otherwise the factory SSID stays. Firmware-dependent.
    SRC_HOSTAPD="${SD_DIR}/custom/configs/hostapd.conf"
    [ -n "$SSID" ] && [ -f "$SRC_HOSTAPD" ] || { log "AP: using factory SSID"; return 0; }
    if [ -f /etc/config/hostapd.conf ] && mount --bind "$SRC_HOSTAPD" /etc/config/hostapd.conf 2>/dev/null; then
        log "AP: bound custom hostapd.conf (SSID='$SSID') - best effort"
    else
        log "AP: could not override hostapd.conf; factory SSID stays"
    fi
}

case "$MODE" in
    sta) join_sta || true ;;
    ap)  apply_custom_ap ;;
    *)   log "wifi.sh: unknown MODE='$MODE' (use ap|sta); leaving wifi as-is" ;;
esac

log "wifi.sh done"
