#!/bin/sh
# ptz-status.sh - show the live smooth-PTZ state (read-only).
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/scripts/common-ptz.sh"
echo "=== smooth ONVIF PTZ status ==="

if [ -f "$RUN_CONF" ] && grep -q '^ptz=1' "$RUN_CONF"; then echo "config:   ptz=1 (ENABLED)"; else echo "config:   ptz=0 (disabled)"; fi
[ -e "$WEB/ptz_service" ] && echo "endpoint: /onvif/ptz_service present" || echo "endpoint: absent"
if bridge_alive; then echo "daemon:   UP"; "$BRIDGE_RUN" status 2>&1 | sed 's/^/          /'; else echo "daemon:   down"; fi

echo "processes:"
for p in anyka_ipc onvif_simple_server httpd onvif_ptz_bridge; do
    pids=""
    for f in $(grep -l "$p" /proc/[0-9]*/cmdline 2>/dev/null); do pid=${f#/proc/}; pid=${pid%/cmdline}; pids="$pids $pid"; done
    [ -n "$pids" ] && echo "          $p:$pids" || echo "          $p: (not running)"
done

echo "recent bridge log:"
[ -f "$PTZ_LOG" ] && tail -n 8 "$PTZ_LOG" 2>/dev/null | sed 's/^/          /' || echo "          (no log yet)"
exit 0
