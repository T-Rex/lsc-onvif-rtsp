#!/bin/sh
# verify-installation.sh - read-only health + identity check of the running PTZ
# bridge and the ONVIF/RTSP/WSD services (KERNEL-RESEARCH-UPDATE-09 §19).
# No motor movement. BusyBox /bin/sh; no tr/gzip/python. Exit 0 iff all pass.
#
# Env: BRIDGE (bridge binary, default /tmp/onvif/bin/onvif_ptz_bridge),
#      WANT_VERSION (default 1.4.0), WANT_SHA (optional expected bridge SHA),
#      PTZ_SOCK (default /tmp/onvif/run/ptz.sock).
set -u
BRIDGE=${BRIDGE:-/tmp/onvif/bin/onvif_ptz_bridge}
WANT_VERSION=${WANT_VERSION:-1.4.0}
WANT_SHA=${WANT_SHA:-}
export PTZ_SOCK=${PTZ_SOCK:-/tmp/onvif/run/ptz.sock}
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

echo "=== verify-installation (read-only) ==="

# bridge daemon alive + version
if [ -x "$BRIDGE" ] && "$BRIDGE" ping >/dev/null 2>&1; then ok "bridge daemon responds to ping"
else no "bridge daemon not responding ($BRIDGE)"; fi
ST=$("$BRIDGE" status 2>/dev/null)
echo "$ST" | grep -q "version=$WANT_VERSION" && ok "bridge version $WANT_VERSION" || no "bridge version (want $WANT_VERSION)"
echo "$ST" | grep -q "^active_speed_profile=" && ok "status exposes speed profile" || no "status speed profile"

# exactly one bridge daemon process
NB=$(ps 2>/dev/null | grep -c '[o]nvif_ptz_bridge daemon')
[ "${NB:-0}" = 1 ] && ok "exactly one bridge daemon ($NB)" || no "bridge daemon count=$NB (want 1)"

# optional binary identity
if [ -n "$WANT_SHA" ]; then
    HV=$(sha256sum "$BRIDGE" 2>/dev/null | awk '{print $1}')
    [ "$HV" = "$WANT_SHA" ] && ok "bridge SHA matches intended build" || no "bridge SHA $HV != $WANT_SHA"
fi

# speed_step 600/600 (baseline restored; read-only sysfs)
for m in 0 1; do
    sp=$(ls /sys/devices/platform/motor$m/motor/speed_step /sys/devices/*/motor$m/motor/speed_step /sys/*/motor$m/motor/speed_step 2>/dev/null | head -1)
    cur=""; [ -n "$sp" ] && cur=$(cat "$sp" 2>/dev/null)
    case "$cur" in *600*) ok "motor$m speed_step=600";; *) no "motor$m speed_step='${cur:-?}' (want 600)";; esac
done

# positions readable and in range
for m in 0 1; do
    pp=$(ls /sys/devices/platform/motor$m/motor/current_pos /sys/devices/*/motor$m/motor/current_pos /sys/*/motor$m/motor/current_pos 2>/dev/null | head -1)
    v=""; [ -n "$pp" ] && v=$(cat "$pp" 2>/dev/null | sed -n 's/.*:\([0-9]*\).*/\1/p')
    case "$v" in ''|*[!0-9]*) no "motor$m position unreadable";; *) ok "motor$m position=$v";; esac
done

# no motor currently moving
[ "$("$BRIDGE" is_moving 2>/dev/null)" = 0 ] && ok "no motor movement" || no "a motor reports moving"

# services + ports
for p in anyka_ipc onvif_simple_server httpd onvif_ptz_bridge wsd_simple_server; do
    ps 2>/dev/null | grep -q "[${p%${p#?}}]${p#?}" && ok "process up: $p" || echo "NOTE: $p not seen (ok if not applicable)"
done
for port in 554 8080; do
    netstat -lnt 2>/dev/null | grep -q ":$port " && ok "listening on $port" || no "port $port not listening"
done
echo "WS-Discovery (UDP 3702): check from the LAN with an ONVIF client (not shown by netstat -lnt)."

echo "=================================================================="
echo "SUMMARY-VERIFY: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" = 0 ]
