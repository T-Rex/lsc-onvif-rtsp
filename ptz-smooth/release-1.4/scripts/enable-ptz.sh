#!/bin/sh
# enable-ptz.sh - activate smooth ONVIF PTZ on the running camera. Stages the
# patched CGI and smooth bridge into /tmp, adds the ptz_service endpoint, starts
# the bridge daemon, and sets ptz=1 in the live config. RAM-only: a reboot
# returns to ptz=0 until re-run. No motor moves here. Reverse with disable-ptz.sh.
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/scripts/common-ptz.sh"

[ -d "$WEB" ] || { echo "ERROR: ONVIF not running ($WEB missing). Run start.sh first."; exit 1; }
[ -f "$BRIDGE_SD" ] || { echo "ERROR: $BRIDGE_SD missing. Run install.sh."; exit 1; }
[ -d "$PTZ_TPL_SD" ] || { echo "ERROR: $PTZ_TPL_SD missing. Run install.sh."; exit 1; }

echo "=== enabling smooth ONVIF PTZ ==="
mkdir -p "$RUN/bin" "$RUN/run"
# ensure the bridge log directory exists (a fresh staged package has no logs/)
mkdir -p "$(dirname "$PTZ_LOG")" 2>/dev/null || true

# stage patched CGI + smooth bridge into tmpfs
stage(){ cp "$1" "$2.new" && chmod 755 "$2.new" && mv -f "$2.new" "$2"; }
[ -f "$CGI_SD" ] && { stage "$CGI_SD" "$BIN_CGI" && echo "staged patched CGI"; }
stage "$BRIDGE_SD" "$BRIDGE_RUN" || { echo "ERROR: cannot stage bridge"; exit 1; }

# add ptz_service endpoint + templates to the live web root
ln -sfn "$PTZ_TPL_SD" "$WEB/ptz_service_files"
rm -f "$WEB/ptz_service"
if [ -n "${ONVIF_QEMU:-}" ]; then
    printf '#!/bin/sh\nexec %s %s ptz_service\n' "$ONVIF_QEMU" "$BIN_CGI" > "$WEB/ptz_service"; chmod 755 "$WEB/ptz_service"
else
    ln -s "$BIN_CGI" "$WEB/ptz_service"
fi

# Speed profile config (1.4). Default (absent) => compat profile == 1.3: the
# bridge issues NO SET_SPEED. onvif_ptz.env may set PTZ_SPEED_PROFILE and the
# per-axis step/limit. onvif_ptz_speed.env is still honoured for back-compat.
for envf in onvif_ptz.env onvif_ptz_speed.env; do
    if [ -f "$BASE/config/$envf" ]; then
        # shellcheck disable=SC1090
        . "$BASE/config/$envf"
    fi
done
export PTZ_SPEED_PROFILE PTZ_PAN_SPEED_STEP PTZ_TILT_SPEED_STEP \
       PTZ_PAN_SPEED_MAX PTZ_TILT_SPEED_MAX PTZ_HW_SPEED_ENABLED \
       PTZ_TICK_MS PTZ_MAX_PER_TICK PTZ_MARGIN PTZ_DEF_TIMEOUT_MS PTZ_HARD_TIMEOUT_MS 2>/dev/null
echo "speed profile: ${PTZ_SPEED_PROFILE:-compat} (pan_step=${PTZ_PAN_SPEED_STEP:-600} tilt_step=${PTZ_TILT_SPEED_STEP:-600})"

# start the smooth bridge daemon (idempotent, no motion)
if bridge_alive; then echo "bridge daemon already running"; else
    SETSID=""; have setsid && SETSID=setsid
    ( trap '' HUP; exec $SETSID "$BRIDGE_RUN" daemon >> "$PTZ_LOG" 2>&1 < /dev/null ) &
    n=0; while [ "$n" -lt 20 ]; do bridge_alive && break; sleep 0.1 2>/dev/null || sleep 1; n=$((n+1)); done
    bridge_alive && echo "bridge daemon started" || { echo "ERROR: daemon did not start (see $PTZ_LOG)"; exit 1; }
fi

# enable PTZ in the live config (strip any prior block + ptz= line, append block)
if [ -f "$RUN_CONF" ]; then
    tmp="$RUN_CONF.new"
    sed "/^$(sed_lit "$PTZ_BEGIN")$/,/^$(sed_lit "$PTZ_END")$/d; /^ptz=/d" "$RUN_CONF" > "$tmp"
    emit_ptz_block >> "$tmp"; mv -f "$tmp" "$RUN_CONF"
else echo "ERROR: $RUN_CONF missing"; exit 1; fi

echo "Smooth PTZ enabled. Endpoint: /onvif/ptz_service"
echo "ONVIF ContinuousMove now moves smoothly until Stop or the ONVIF Timeout"
echo "(default ${PTZ_DEF_TIMEOUT_MS:-10000}ms, bridge-clamped). Motors move only on client request."
exit 0
