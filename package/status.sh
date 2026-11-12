#!/bin/sh
# status.sh - show the state of the ONVIF services.
#
#   sh /mnt/onvif/status.sh
#
# Exit status 0 when httpd and wsd_simple_server are both running.

SCRIPT=status
BASE=$(cd "$(dirname "$0")" && pwd)
. "$BASE/lib/common.sh"

IFACE=${ONVIF_IFACE:-$(conf_get ifs)}
IFACE=${IFACE:-wlan0}
PORT=${ONVIF_PORT:-$(conf_get port)}
PORT=${PORT:-8080}
IP=$(iface_ip "$IFACE")

rss() { sed -n 's/^VmRSS:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null; }

show() { # name path
    _pids=$(pids_of "$2")
    if [ -n "$_pids" ]; then
        for _p in $_pids; do
            printf '  %-20s running  PID %-6s RSS %s\n' "$1" "$_p" "$(rss "$_p")"
        done
        return 0
    fi
    printf '  %-20s STOPPED\n' "$1"
    return 1
}

rc=0
echo "ONVIF package: $BASE"
[ -f "$BASE/VERSION" ] && sed -n 's/^onvif_simple_server_commit=/  onvif_simple_server commit: /p' "$BASE/VERSION"
echo "Interface $IFACE: ${IP:-no IPv4 address}"
echo ""
echo "Processes:"
show httpd "$BIN_HTTPD" || rc=1
show wsd_simple_server "$BIN_WSD" || rc=1
if [ -n "$(pids_of anyka_ipc)" ]; then
    echo "  anyka_ipc            running (camera firmware, provides RTSP)"
else
    echo "  anyka_ipc            not found"
fi
echo ""
echo "Sockets:"
if tcp_listening "$PORT"; then echo "  TCP $PORT   listening (ONVIF HTTP)"; else echo "  TCP $PORT   NOT listening"; rc=1; fi
if udp_bound 3702; then echo "  UDP 3702   bound (WS-Discovery)"; else echo "  UDP 3702   NOT bound"; rc=1; fi
if tcp_listening 554; then echo "  TCP 554    listening (RTSP, anyka_ipc)"; else echo "  TCP 554    not listening"; fi
echo ""
if [ -n "$IP" ]; then
    echo "Device service: http://$IP:$PORT/onvif/device_service"
    echo "RTSP stream:    $(conf_get url | sed "s|%s|$IP|")"
fi
if [ -f "$RUN_CONF" ]; then
    if grep -q '^user=' "$RUN_CONF" 2>/dev/null; then
        echo "Authentication: enabled (WS-UsernameToken)"
    else
        echo "Authentication: disabled"
    fi
fi
echo ""
if have df; then
    echo "tmpfs /tmp:"
    df -k /tmp 2>/dev/null | sed 's/^/  /'
    [ -d "$RUN" ] && echo "  /tmp/onvif uses $(du -sk "$RUN" 2>/dev/null | cut -f1) KB"
    echo ""
fi
for l in onvif-control.log httpd.log wsd_simple_server.log onvif_simple_server.log; do
    if [ -s "$LOGS/$l" ]; then
        echo "--- last lines of $LOGS/$l"
        tail -n 5 "$LOGS/$l" 2>/dev/null
    fi
done
exit $rc
