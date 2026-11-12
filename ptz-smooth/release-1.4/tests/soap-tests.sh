#!/bin/bash
# soap-tests.sh - SOAP against the PATCHED ARM CGI (with ONVIF Timeout) under
# QEMU, with the smooth ARM bridge (mock-motor build) live. Env from build.sh:
#   SOAP_CGI SOAP_WWW SOAP_PTZTPL SOAP_BRIDGE_ARM SOAP_BASECONF WSSE
set -uo pipefail
QEMU="qemu-arm-static -cpu arm926"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/    /' | head -15; }

USER=ptztest; PASS=ptztestpass

WEB=$(mktemp -d); cp -r "$SOAP_WWW"/* "$WEB"/; cp -r "$SOAP_PTZTPL/ptz_service_files" "$WEB"/
ROOT=$(mktemp -d)
mkdir -p "$ROOT/sys/devices/platform/motor0/motor" "$ROOT/sys/devices/platform/motor1/motor" "$ROOT/dev" "$ROOT/run" "$ROOT/logs"
printf 'current-pos:2048\n' > "$ROOT/sys/devices/platform/motor0/motor/current_pos"
printf 'total-steps:4096\n' > "$ROOT/sys/devices/platform/motor0/motor/total_steps"
printf 'current-pos:1115\n' > "$ROOT/sys/devices/platform/motor1/motor/current_pos"
printf 'total-steps:2230\n' > "$ROOT/sys/devices/platform/motor1/motor/total_steps"
: > "$ROOT/dev/motor0"; : > "$ROOT/dev/motor1"
SOCK="$ROOT/run/ptz.sock"; BLOG="$ROOT/logs/bridge.log"

CONF=$(mktemp); BR="$QEMU $SOAP_BRIDGE_ARM"
grep -v '^ptz=' "$SOAP_BASECONF" | sed 's/^ifs=.*/ifs=lo/' > "$CONF"
cat >> "$CONF" <<EOF
ptz=1
min_step_x=-1.0
max_step_x=1.0
min_step_y=-1.0
max_step_y=1.0
get_position=$BR position
is_moving=$BR is_moving
move_left=$BR left %f
move_right=$BR right %f
move_up=$BR up %f
move_down=$BR down %f
move_stop=$BR stop %s
user=$USER
password=$PASS
EOF

export PTZ_SOCK="$SOCK" PTZ_PIDFILE="$ROOT/run/ptz.pid" PTZ_ROOT="$ROOT" PTZ_LOG="$BLOG" \
       PTZ_TICK_MS=20 PTZ_DEF_TIMEOUT_MS=10000 PTZ_HARD_TIMEOUT_MS=60000
# Redirect the daemon's stdio so it never holds build.sh's tee pipe open.
$QEMU "$SOAP_BRIDGE_ARM" daemon >/dev/null 2>&1 & DPID=$!
trap 'kill "$DPID" 2>/dev/null' EXIT
for i in $(seq 1 60); do $QEMU "$SOAP_BRIDGE_ARM" ping >/dev/null 2>&1 && break; sleep 0.05; done

sec(){ python3 "$WSSE" "$USER" "$PASS"; }
soap(){ # service body [noauth]
    local svc=$1 body=$2 auth=${3:-auth} hdr="" req; [ "$auth" = auth ] && hdr=$(sec); req=$(mktemp)
    cat > "$req" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
 xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
 xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
 xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
 xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"
 xmlns:tt="http://www.onvif.org/ver10/schema">
<s:Header>$hdr</s:Header><s:Body>$body</s:Body></s:Envelope>
EOF
    local len; len=$(wc -c < "$req")
    ( cd "$WEB" && REQUEST_METHOD=POST CONTENT_TYPE="application/soap+xml" CONTENT_LENGTH="$len" PTZ_SOCK="$SOCK" \
        $QEMU "$SOAP_CGI" -c "$CONF" "$svc" < "$req" ); rm -f "$req"
}

echo "=== C. ONVIF SOAP against the patched CGI (ptz=1) ==="
r=$(soap device_service '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>' noauth)
echo "$r" | grep -qi ptz && ok "GetCapabilities advertises PTZ" || no "GetCapabilities PTZ" "$r"
r=$(soap media_service '<trt:GetProfiles/>')
echo "$r" | grep -q PTZConfiguration && ok "GetProfiles includes PTZConfiguration" || no "GetProfiles" "$r"
r=$(soap media_service '<trt:GetStreamUri><trt:ProfileToken>Profile_0</trt:ProfileToken></trt:GetStreamUri>')
echo "$r" | grep -Eq 'rtsp://[^<]*:554/main_ch' && ok "GetStreamUri RTSP preserved" || no "GetStreamUri" "$r"
r=$(soap ptz_service '<tptz:GetNodes/>')
echo "$r" | grep -q PTZNode && ok "GetNodes" || no "GetNodes" "$r"
r=$(soap ptz_service '<tptz:GetStatus><tptz:ProfileToken>Profile_0</tptz:ProfileToken></tptz:GetStatus>')
echo "$r" | grep -q PanTilt && ok "GetStatus PanTilt" || no "GetStatus" "$r"
r=$(soap ptz_service '<tptz:GetStatus><tptz:ProfileToken>Profile_0</tptz:ProfileToken></tptz:GetStatus>' noauth)
echo "$r" | grep -qi Fault && ! echo "$r" | grep -q GetStatusResponse && ok "auth enforced" || no "auth" "$r"

# ContinuousMove drives the bridge
$QEMU "$SOAP_BRIDGE_ARM" stop all >/dev/null 2>&1; : > "$BLOG"
r=$(soap ptz_service '<tptz:ContinuousMove><tptz:ProfileToken>Profile_0</tptz:ProfileToken><tptz:Velocity><tt:PanTilt x="0.8" y="0.0"/></tptz:Velocity></tptz:ContinuousMove>')
echo "$r" | grep -q ContinuousMoveResponse && ok "ContinuousMove accepted" || no "ContinuousMove" "$r"
sleep 0.1
[ "$($QEMU "$SOAP_BRIDGE_ARM" is_moving)" = 1 ] && ok "ContinuousMove started motion" || no "CM motion" "$(cat "$BLOG")"
soap ptz_service '<tptz:Stop><tptz:ProfileToken>Profile_0</tptz:ProfileToken><tptz:PanTilt>true</tptz:PanTilt></tptz:Stop>' >/dev/null
sleep 0.05
[ "$($QEMU "$SOAP_BRIDGE_ARM" is_moving)" = 0 ] && ok "Stop halts motion" || no "Stop" "$(cat "$BLOG")"

# ONVIF Timeout is parsed by the CGI and plumbed to the bridge
: > "$BLOG"
soap ptz_service '<tptz:ContinuousMove><tptz:ProfileToken>Profile_0</tptz:ProfileToken><tptz:Velocity><tt:PanTilt x="0.5" y="0.0"/></tptz:Velocity><tptz:Timeout>PT3S</tptz:Timeout></tptz:ContinuousMove>' >/dev/null
sleep 0.1
grep -q 'timeout=3000ms' "$BLOG" && ok "ONVIF Timeout PT3S -> 3000ms at bridge" || no "timeout plumbing" "$(cat "$BLOG")"
$QEMU "$SOAP_BRIDGE_ARM" stop all >/dev/null 2>&1

# short Timeout actually stops sooner than a long one
: > "$BLOG"
soap ptz_service '<tptz:ContinuousMove><tptz:ProfileToken>Profile_0</tptz:ProfileToken><tptz:Velocity><tt:PanTilt x="0.5" y="0.0"/></tptz:Velocity><tptz:Timeout>PT0.3S</tptz:Timeout></tptz:ContinuousMove>' >/dev/null
sleep 0.12; mv1=$($QEMU "$SOAP_BRIDGE_ARM" is_moving)
sleep 0.4;  mv2=$($QEMU "$SOAP_BRIDGE_ARM" is_moving)
{ [ "$mv1" = 1 ] && [ "$mv2" = 0 ]; } && ok "short Timeout (PT0.3S) auto-stops (~0.3s)" || no "short timeout stop (mv1=$mv1 mv2=$mv2)"

$QEMU "$SOAP_BRIDGE_ARM" shutdown >/dev/null 2>&1
wait "$DPID" 2>/dev/null
echo "=================================================================="
echo "SUMMARY-SOAP: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" = 0 ]
