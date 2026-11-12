#!/bin/sh
# disable-ptz.sh - stop the bridge daemon, remove the ptz_service endpoint, set
# the live config back to ptz=0. Leaves RTSP/ONVIF/auth intact. The patched CGI
# stays staged (inert while ptz=0); use restore.sh to restore a saved install.
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/scripts/common-ptz.sh"

echo "=== disabling smooth ONVIF PTZ ==="
if bridge_alive; then
    "$BRIDGE_RUN" shutdown >/dev/null 2>&1
    n=0; while bridge_alive && [ "$n" -lt 20 ]; do sleep 0.1 2>/dev/null || sleep 1; n=$((n+1)); done
fi
if [ -f "$PTZ_PID" ]; then p=$(cat "$PTZ_PID" 2>/dev/null); [ -n "$p" ] && [ -d "/proc/$p" ] && kill "$p" 2>/dev/null; rm -f "$PTZ_PID"; fi
rm -f "$PTZ_SOCK"
echo "bridge daemon stopped"

rm -f "$WEB/ptz_service" "$WEB/ptz_service_files"
echo "ptz_service endpoint removed"

if [ -f "$RUN_CONF" ]; then
    tmp="$RUN_CONF.new"
    sed "/^$(sed_lit "$PTZ_BEGIN")$/,/^$(sed_lit "$PTZ_END")$/d; /^ptz=/d" "$RUN_CONF" > "$tmp"
    echo "ptz=0" >> "$tmp"; mv -f "$tmp" "$RUN_CONF"
fi
echo "PTZ disabled (ptz=0). ONVIF Device/Media/RTSP unaffected."
exit 0
