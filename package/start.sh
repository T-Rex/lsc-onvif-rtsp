#!/bin/sh
# start.sh - start the ONVIF service (BusyBox httpd + onvif_simple_server CGI)
# and WS-Discovery (wsd_simple_server) from the SD card.
#
#   sh /mnt/onvif/start.sh
#
# Safe to run more than once: services that are already running are left
# alone. Nothing outside /tmp/onvif and the package's logs/ directory is
# written. anyka_ipc, Wi-Fi and RTSP are not touched.

SCRIPT=start
BASE=$(cd "$(dirname "$0")" && pwd)
. "$BASE/lib/common.sh"

lock
mkdir -p "$LOGS" 2>/dev/null

msg "=== ONVIF start ($(ts)) from $BASE"

for f in "$BASE/bin/httpd" "$BASE/bin/onvif_simple_server" "$BASE/bin/wsd_simple_server" \
         "$SRC_CONF" "$SRC_HTTPD_CONF" "$BASE/www/onvif/wsd/ProbeMatches.xml" \
         "$BASE/www/onvif/device_service_files/GetDeviceInformation.xml"; do
    [ -f "$f" ] || { msg "ERROR: missing $f - incomplete copy of the package?"; exit 1; }
done

# ---- settings from the ONVIF configuration file ---------------------------
IFACE=${ONVIF_IFACE:-$(conf_get ifs)}
IFACE=${IFACE:-wlan0}
PORT=${ONVIF_PORT:-$(conf_get port)}
PORT=${PORT:-8080}
MODEL=$(conf_get model)
MANUFACTURER=$(conf_get manufacturer)
SCOPES=$(conf_all scope)

case "$PORT" in *[!0-9]*|'') msg "ERROR: invalid port '$PORT' in $SRC_CONF"; exit 1 ;; esac

# ---- already running? ------------------------------------------------------
HTTPD_PIDS=$(pids_of "$BIN_HTTPD")
WSD_PIDS=$(pids_of "$BIN_WSD")
if [ -n "$HTTPD_PIDS" ] && [ -n "$WSD_PIDS" ]; then
    msg "ONVIF is already running (httpd PID $HTTPD_PIDS, wsd PID $WSD_PIDS). Nothing to do."
    msg "Use 'sh $BASE/stop.sh' first to restart."
    exit 0
fi

if [ -z "$HTTPD_PIDS" ] && tcp_listening "$PORT"; then
    msg "ERROR: TCP port $PORT is already in use by another program. Not starting."
    exit 1
fi

# ---- wait for an IPv4 address on the interface ------------------------------
if [ ! -d "/sys/class/net/$IFACE" ]; then
    msg "ERROR: network interface $IFACE does not exist (set ifs= in $SRC_CONF)."
    exit 1
fi
IP=$(iface_ip "$IFACE")
n=0
while [ -z "$IP" ] && [ "$n" -lt "$WAIT_IP_SECS" ]; do
    [ "$n" -eq 0 ] && msg "Waiting up to ${WAIT_IP_SECS}s for an IPv4 address on $IFACE..."
    sleep 1
    n=$((n + 1))
    IP=$(iface_ip "$IFACE")
done
if [ -z "$IP" ]; then
    msg "ERROR: no IPv4 address on $IFACE."
    exit 1
fi
msg "Interface $IFACE has address $IP"

# ---- stage the runtime directory on tmpfs ----------------------------------
# FAT32 keeps neither execute bits nor symlinks, so the binaries are copied
# to tmpfs and made executable there; the web root is built from symlinks.
if have df; then
    FREE_KB=$(df -k /tmp 2>/dev/null | sed -n '2,$p' | tr -s ' ' | sed -n '$p' | cut -d' ' -f4)
    case "$FREE_KB" in
        ''|*[!0-9]*) ;;
        *) if [ "$FREE_KB" -lt "$MIN_TMP_FREE_KB" ]; then
               msg "ERROR: only ${FREE_KB} KB free on /tmp, need ${MIN_TMP_FREE_KB} KB."
               exit 1
           fi ;;
    esac
fi

mkdir -p "$RUN/bin" "$RUN/etc" "$RUN/run" "$RUN/www/onvif" || { msg "ERROR: cannot create $RUN"; exit 1; }

# Log directory: a symlink to the SD card (default) or a RAM directory.
if [ "$LOG_IN_RAM" = 1 ]; then
    [ -L "$RUN/log" ] && rm -f "$RUN/log"
    mkdir -p "$RUN/log"
else
    [ -d "$RUN/log" ] && [ ! -L "$RUN/log" ] && rm -rf "$RUN/log"
    ln -sfn "$BASE/logs" "$RUN/log"
fi

install_bin() { # src dst - copy via a temporary name so a running copy is never truncated
    cp "$1" "$2.new" && chmod 755 "$2.new" && mv -f "$2.new" "$2"
}
for b in httpd onvif_simple_server wsd_simple_server; do
    install_bin "$BASE/bin/$b" "$RUN/bin/$b" || { msg "ERROR: cannot copy $b to $RUN/bin"; exit 1; }
done

# Runtime configuration: the SD card file with CR removed, serial number
# derived if set to AUTO, and the optional credentials appended.
MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null | tr 'a-f' 'A-F')
SERIAL=$(conf_get serial_num)
if [ "$SERIAL" = AUTO ] || [ -z "$SERIAL" ]; then
    # Stable per-device identifier that does not expose the MAC address.
    if have sha256sum; then
        H=$(printf 'lsc-onvif-%s' "$MAC" | sha256sum)
    elif have md5sum; then
        H=$(printf 'lsc-onvif-%s' "$MAC" | md5sum)
    else
        H=$(printf 'lsc-onvif-%s' "$MAC" | cksum | tr -d ' ')
    fi
    SERIAL="LSC-$(echo "$H" | tr 'a-f' 'A-F' | sed 's/^\([0-9A-F]\{12\}\).*/\1/')"
fi

AUTH_USER=$(conf_get user "$SRC_AUTH")
AUTH_PASS=$(conf_get password "$SRC_AUTH")

umask 077
{
    tr -d '\r' < "$SRC_CONF" | sed \
        -e '/^user=/d' -e '/^password=/d' \
        -e "s|^serial_num=.*|serial_num=$SERIAL|" \
        -e "s|^ifs=.*|ifs=$IFACE|" \
        -e "s|^port=.*|port=$PORT|"
    if [ -n "$AUTH_USER" ]; then
        echo ""
        echo "#Credentials from $SRC_AUTH"
        echo "user=$AUTH_USER"
        echo "password=$AUTH_PASS"
    fi
} > "$RUN_CONF.new" && mv -f "$RUN_CONF.new" "$RUN_CONF"
tr -d '\r' < "$SRC_HTTPD_CONF" > "$RUN/etc/httpd.conf"
umask 022
if [ -n "$AUTH_USER" ]; then
    [ -n "$AUTH_PASS" ] || msg "WARNING: user '$AUTH_USER' has an empty password."
    msg "ONVIF authentication: ENABLED (WS-UsernameToken, user '$AUTH_USER')"
else
    msg "ONVIF authentication: disabled (set user/password in $SRC_AUTH to enable)"
fi
msg "Serial number: $SERIAL"

# Web root: /onvif/<service> -> CGI binary, templates read from the SD card.
W=$RUN/www/onvif
for s in $ONVIF_SERVICES; do
    rm -f "$W/$s"
    if [ -n "$QEMU" ]; then
        # Test hook only (see common.sh): run the ARM CGI through QEMU.
        printf '#!/bin/sh\nexec %s %s %s\n' "$QEMU" "$BIN_CGI" "$s" > "$W/$s"
        chmod 755 "$W/$s"
    else
        ln -s "$BIN_CGI" "$W/$s"
    fi
done
for d in device_service_files media_service_files deviceio_service_files \
         events_service_files generic_files; do
    ln -sfn "$BASE/www/onvif/$d" "$W/$d"
done
# Helper scripts run by the CGI through /bin/sh -c need the execute bit.
mkdir -p "$W/scripts"
for f in "$BASE"/www/onvif/scripts/*.sh; do
    [ -f "$f" ] || continue
    tr -d '\r' < "$f" > "$W/scripts/$(basename "$f")"
    chmod 755 "$W/scripts/$(basename "$f")"
done
# WS-Discovery templates: staged outside the served web root ($RUN/www) so they
# are never reachable over HTTP. Source lives under the SD card's www/onvif/wsd.
ln -sfn "$BASE/www/onvif/wsd" "$RUN/wsd"

# ---- start httpd -----------------------------------------------------------
HTTPD_OPTS=""
[ "$HTTPD_VERBOSE" = 1 ] && HTTPD_OPTS="-v"
SETSID=""
have setsid && SETSID=setsid

if [ -z "$HTTPD_PIDS" ]; then
    # -f: no self-daemonising, so stdout/stderr go to the log. setsid gives
    # httpd its own session; SIGHUP is ignored as well, so closing the Telnet
    # session cannot stop it even where setsid is missing.
    ( trap '' HUP
      exec $SETSID $QEMU "$BIN_HTTPD" -f -p "$PORT" -h "$RUN/www" -c "$RUN/etc/httpd.conf" $HTTPD_OPTS \
          >> "$LOGS/httpd.log" 2>&1 < /dev/null ) &
else
    msg "httpd already running (PID $HTTPD_PIDS)"
fi

# ---- start WS-Discovery ----------------------------------------------------
if [ -z "$WSD_PIDS" ]; then
    rm -f "$WSD_PID_FILE"     # a stale PID file makes wsd_simple_server refuse to start
    # wsd_simple_server daemonises itself and writes its PID file.
    $QEMU "$BIN_WSD" -i "$IFACE" -x "http://%s:$PORT/onvif/device_service" \
        -m "$MODEL" -n "$MANUFACTURER" -s "$SCOPES" \
        -p "$WSD_PID_FILE" -t "$RUN/wsd" -d "$WSD_DEBUG" \
        >> "$LOGS/wsd_simple_server.stderr.log" 2>&1 < /dev/null
else
    msg "wsd_simple_server already running (PID $WSD_PIDS)"
fi

# ---- check -----------------------------------------------------------------
ok=1
n=0
while [ "$n" -lt 15 ]; do
    HTTPD_PIDS=$(pids_of "$BIN_HTTPD")
    WSD_PIDS=$(pids_of "$BIN_WSD")
    tcp_listening "$PORT" && [ -n "$HTTPD_PIDS" ] && udp_bound 3702 && [ -n "$WSD_PIDS" ] && break
    sleep 1
    n=$((n + 1))
done
if [ -n "$HTTPD_PIDS" ] && tcp_listening "$PORT"; then
    msg "httpd running, PID $HTTPD_PIDS, TCP port $PORT"
else
    msg "ERROR: httpd did not start; see $LOGS/httpd.log"
    ok=0
fi
if [ -n "$WSD_PIDS" ] && udp_bound 3702; then
    msg "wsd_simple_server running, PID $WSD_PIDS, UDP port 3702"
elif [ -n "$WSD_PIDS" ]; then
    msg "WARNING: wsd_simple_server running (PID $WSD_PIDS) but UDP 3702 is not bound yet"
else
    msg "ERROR: wsd_simple_server did not start; see $LOGS/wsd_simple_server.log"
    ok=0
fi

msg "ONVIF device service: http://$IP:$PORT/onvif/device_service"
msg "RTSP stream (unchanged): $(conf_get url | sed "s|%s|$IP|")"
[ "$ok" = 1 ] || exit 1
exit 0
