#!/bin/bash
# run-tests.sh PACKAGE_DIR RESULT_FILE
#
# Integration tests of the deployment package inside the build container.
#
# The ARM binaries are always run through "qemu-arm-static -cpu arm926", so
# an ARMv6+ instruction would raise SIGILL, and nothing can silently run as
# an x86 binary:
#   * start.sh is used unchanged, with the test hook ONVIF_QEMU set. It then
#     launches httpd and wsd_simple_server through QEMU and replaces the CGI
#     symlinks with two-line wrappers "exec qemu-arm-static -cpu arm926
#     /tmp/onvif/bin/onvif_simple_server <service>".
#   * the package copy has every execute bit removed, like files on FAT32,
#     and the scripts are run with "sh".
set -uo pipefail

PKG_SRC=$1
RESULT=$2
HERE=$(cd "$(dirname "$0")" && pwd)
SD=/tmp/sdcard
BASE=$SD/onvif
QEMU_CMD="/usr/bin/qemu-arm-static -cpu arm926"
PORT=8080
T=/tmp/onvif-tests
rm -rf "$SD" "$T" /tmp/onvif /tmp/onvif.lock
mkdir -p "$SD" "$T"

npass=0; nfail=0
exec > >(tee "$RESULT") 2>&1
pass() { echo "PASS  $*"; npass=$((npass + 1)); }
fail() { echo "FAIL  $*"; nfail=$((nfail + 1)); }
check() { # description command...
    local d=$1; shift
    if "$@" > /dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}

echo "Integration tests ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo "qemu: $(qemu-arm-static --version | head -1), CPU model: arm926"
echo

# ---- environment ------------------------------------------------------------
IFACE=$(ip -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
IFACE=${IFACE:-eth0}
IP=$(ip -4 addr show dev "$IFACE" | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -1)
echo "test interface: $IFACE ($IP)  (stands in for wlan0)"
export ONVIF_IFACE=$IFACE
export ONVIF_QEMU=$QEMU_CMD

# The control scripts run under BusyBox sh with a PATH that contains only
# BusyBox applets (sed, grep, tr, ip, setsid, ...), like on the camera.
# Debian's busybox-static is x86 and a different version (see below), so
# this checks POSIX/BusyBox compatibility, not the camera's exact applet set.
BB=$(command -v busybox)
mkdir -p "$T/bb"
for a in $("$BB" --list); do ln -sf "$BB" "$T/bb/$a"; done
cam_sh() { env -i PATH="$T/bb" HOME=/root ONVIF_IFACE="$IFACE" ONVIF_QEMU="$QEMU_CMD" "$BB" sh "$@"; }
CAM_SH_DESC="$("$BB" 2>&1 | head -1) sh, PATH=BusyBox applets only"
echo "control scripts run with: $CAM_SH_DESC"

# Stand-ins for the camera firmware: a process called anyka_ipc and a TCP
# listener on the RTSP port. Both must survive every start/stop below.
cp "$(command -v sleep)" "$T/anyka_ipc"
"$T/anyka_ipc" 3600 &
FAKE_IPC=$!
python3 -I -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 554)); s.listen(5); time.sleep(3600)' &
FAKE_RTSP=$!

cp -r "$PKG_SRC" "$BASE"
find "$BASE" -type f -exec chmod a-x {} +
check "package copy has no execute bits (FAT32 simulation)" \
    test -z "$(find "$BASE" -type f -perm /111)"

# Native execution of the ARM binaries must be impossible, so no test can
# pass by accidentally running something on x86.
cp "$PKG_SRC/bin/onvif_simple_server" "$T/native-probe"; chmod 755 "$T/native-probe"
if "$T/native-probe" -h > "$T/native.out" 2>&1; then
    echo "NOTE  binfmt_misc can run ARM binaries in this container; every test still invokes qemu-arm-static -cpu arm926 explicitly."
else
    pass "ARM binary cannot run natively on the x86 build host ($(head -c 80 "$T/native.out" | tr '\n' ' '))"
fi
check "qemu-arm -cpu arm926: onvif_simple_server -h runs" \
    sh -c "$QEMU_CMD $PKG_SRC/bin/onvif_simple_server -h 2>&1 | grep -q 'conf_file'"
check "qemu-arm -cpu arm926: wsd_simple_server -h runs" \
    sh -c "$QEMU_CMD $PKG_SRC/bin/wsd_simple_server -h 2>&1 | grep -q 'xaddr'"
# (usage texts are not compiled in; a start error message proves it runs)
check "qemu-arm -cpu arm926: httpd runs (reports a missing web root)" \
    sh -c "$QEMU_CMD $PKG_SRC/bin/httpd -f -p 127.0.0.1:18081 -h /nonexistent-webroot 2>&1 | grep -q 'nonexistent-webroot'"

# Negative control: the arm926 CPU model must reject ARMv6 instructions,
# otherwise the QEMU runs would not prove ARMv5 compatibility.
printf 'int main(void){unsigned x=0x12345678u; __asm__ volatile("rev %%0, %%0" : "+r"(x)); return x == 0x78563412u ? 0 : 1;}\n' > "$T/v6.c"
${CROSS_PREFIX}gcc -static -marm -march=armv6 -mfloat-abi=soft -O1 "$T/v6.c" -o "$T/v6-rev"
$QEMU_CMD "$T/v6-rev" > "$T/v6.out" 2>&1; rc_926=$?
qemu-arm-static -cpu arm1136 "$T/v6-rev" > /dev/null 2>&1; rc_1136=$?
check "negative control: ARMv6 'rev' instruction is rejected by -cpu arm926 (exit $rc_926: $(head -c 40 "$T/v6.out" | tr '\n' ' '))" \
    test "$rc_926" -ne 0
check "positive control: the same binary runs on -cpu arm1136 (ARMv6)" test "$rc_1136" -eq 0
check "onvif_simple_server -f prints configuration help" \
    sh -c "$QEMU_CMD $PKG_SRC/bin/onvif_simple_server -f 2>&1 | grep -q 'audio_encoder'"

# ---- helpers ------------------------------------------------------------------
WSSE_NS='xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"'
HEADER=""
# soap SERVICE BODY -> sets CODE, writes $T/resp.xml
soap() {
    local svc=$1 body=$2
    cat > "$T/req.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" $WSSE_NS
  xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
  xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
  xmlns:tev="http://www.onvif.org/ver10/events/wsdl"
  xmlns:tmd="http://www.onvif.org/ver10/deviceIO/wsdl"
  xmlns:tt="http://www.onvif.org/ver10/schema">
  <s:Header>$HEADER</s:Header>
  <s:Body>$body</s:Body>
</s:Envelope>
EOF
    CODE=$(curl -s -m 30 -o "$T/resp.xml" -w '%{http_code}' \
        -H 'Content-Type: application/soap+xml; charset=utf-8' \
        --data-binary @"$T/req.xml" "http://127.0.0.1:$PORT/onvif/$svc")
}
# xp XPATH -> value from the last response (namespace-agnostic XPath)
xp() { xmllint --xpath "$1" "$T/resp.xml" 2>/dev/null; }
ln_() { printf '%s' "$1"; }
wellformed() { xmllint --noout "$T/resp.xml" 2>/dev/null; }
# req NAME SERVICE BODY EXPECTED_HTTP [XPATH EXPECTED_VALUE]...
req() {
    local name=$1 svc=$2 body=$3 want=$4; shift 4
    soap "$svc" "$body"
    cp "$T/resp.xml" "$T/$name.xml"
    local ok=1 why=""
    [ "$CODE" = "$want" ] || { ok=0; why="HTTP $CODE, expected $want"; }
    wellformed || { ok=0; why="$why; response is not well-formed XML"; }
    while [ $# -ge 2 ]; do
        local got
        got=$(xp "$1")
        if [ "$got" != "$2" ]; then ok=0; why="$why; $1 = '$got', expected '$2'"; fi
        shift 2
    done
    if [ $ok = 1 ]; then pass "$name"; else fail "$name ($why)"; fi
}
L() { printf "string(//*[local-name()='%s'])" "$1"; }
C() { printf "count(//*[local-name()='%s'])" "$1"; }

# ---- start ------------------------------------------------------------------
echo
echo "--- start.sh"
if cam_sh "$BASE/start.sh" > "$T/start1.out" 2>&1; then pass "start.sh exits 0"; else fail "start.sh exits 0"; fi
sed 's/^/      /' "$T/start1.out"
H1=$(pgrep -f "/tmp/onvif/bin/httpd" | tr '\n' ' ')
W1=$(pgrep -f "/tmp/onvif/bin/wsd_simple_server" | tr '\n' ' ')
check "httpd process running under qemu-arm" test -n "$H1"
check "wsd_simple_server process running under qemu-arm" test -n "$W1"
check "httpd is executed through qemu-arm-static -cpu arm926" \
    sh -c "pgrep -af /tmp/onvif/bin/httpd | grep -q 'qemu-arm-static -cpu arm926'"
check "TCP $PORT listening" sh -c "ss -ltn | grep -q ':$PORT '"
check "UDP 3702 bound" sh -c "ss -lun | grep -q ':3702 '"
check "runtime config generated at compiled-in path /tmp/onvif/etc/onvif_simple_server.conf" \
    test -s /tmp/onvif/etc/onvif_simple_server.conf
check "runtime config: serial_num=AUTO replaced" \
    sh -c "grep -Eq '^serial_num=LSC-[0-9A-F]{12}$' /tmp/onvif/etc/onvif_simple_server.conf"
check "runtime config: no user= line while authentication is disabled" \
    sh -c "! grep -q '^user=' /tmp/onvif/etc/onvif_simple_server.conf"
check "CGI templates reachable from the web root" \
    test -f /tmp/onvif/www/onvif/device_service_files/GetDeviceInformation.xml
check "WSD templates reachable" test -f /tmp/onvif/wsd/ProbeMatches.xml
check "staged binaries are executable on tmpfs" test -x /tmp/onvif/bin/onvif_simple_server

if cam_sh "$BASE/start.sh" > "$T/start2.out" 2>&1 && grep -q "already running" "$T/start2.out"; then
    pass "second start.sh reports 'already running'"
else
    fail "second start.sh reports 'already running'"
fi
H2=$(pgrep -f "/tmp/onvif/bin/httpd" | tr '\n' ' ')
W2=$(pgrep -f "/tmp/onvif/bin/wsd_simple_server" | tr '\n' ' ')
check "no duplicate processes after second start" test "$H1|$W1" = "$H2|$W2"

SERIAL=$(sed -n 's/^serial_num=//p' /tmp/onvif/etc/onvif_simple_server.conf)
DEV="http://$IP:$PORT/onvif/device_service"
MED="http://$IP:$PORT/onvif/media_service"

# Full CGI trace for the first request proves the CGI reads its compiled-in
# config and log paths.
echo 5 > /tmp/onvif/onvif_simple_server.debug

# ---- device service -----------------------------------------------------------
echo
echo "--- Device service"
req GetSystemDateAndTime device_service '<tds:GetSystemDateAndTime/>' 200 \
    "count(//*[local-name()='UTCDateTime'])" 1
check "CGI log written to /tmp/onvif/log -> logs/onvif_simple_server.log" \
    grep -q "Processing configuration file /tmp/onvif/etc/onvif_simple_server.conf" "$BASE/logs/onvif_simple_server.log"
cp "$BASE/logs/onvif_simple_server.log" "$T/cgi-trace.log"
rm -f /tmp/onvif/onvif_simple_server.debug

req GetDeviceInformation device_service '<tds:GetDeviceInformation/>' 200 \
    "$(L Manufacturer)" "LSC" \
    "$(L Model)" "LSC Smart PTZ 3007325" \
    "$(L FirmwareVersion)" "3.286.81.13" \
    "$(L SerialNumber)" "$SERIAL" \
    "$(L HardwareId)" "AK3918EV330"
req GetCapabilities device_service '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>' 200 \
    "string(//*[local-name()='Device']/*[local-name()='XAddr'])" "$DEV" \
    "string(//*[local-name()='Media']/*[local-name()='XAddr'])" "$MED" \
    "$(C PTZ)" 0 "$(C Imaging)" 0 "$(L IPVersion6)" "false" \
    "$(L WSPullPointSupport)" "false" "$(L WSSubscriptionPolicySupport)" "false" \
    "string(//*[local-name()='RTP_RTSP_TCP'])" "true"
req GetCapabilities_Media device_service '<tds:GetCapabilities><tds:Category>Media</tds:Category></tds:GetCapabilities>' 200 \
    "string(//*[local-name()='Media']/*[local-name()='XAddr'])" "$MED"
req GetServices device_service '<tds:GetServices><tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>' 200 \
    "string(//*[local-name()='Service'][*[local-name()='Namespace']='http://www.onvif.org/ver10/device/wsdl']/*[local-name()='XAddr'])" "$DEV" \
    "string(//*[local-name()='Service'][*[local-name()='Namespace']='http://www.onvif.org/ver10/media/wsdl']/*[local-name()='XAddr'])" "$MED" \
    "count(//*[local-name()='Namespace'][contains(.,'ptz') or contains(.,'ver20/media') or contains(.,'imaging')])" 0
req GetServices_WithCapabilities device_service '<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>' 200 \
    "count(//*[local-name()='Capabilities'][@SnapshotUri='true'])" 0 \
    "count(//*[local-name()='ProfileCapabilities'][@MaximumNumberOfProfiles='1'])" 1
req GetServiceCapabilities device_service '<tds:GetServiceCapabilities/>' 200 \
    "count(//*[local-name()='Network'][@IPVersion6='false'])" 1
req GetScopes device_service '<tds:GetScopes/>' 200 \
    "count(//*[local-name()='ScopeItem'])" 5 \
    "count(//*[local-name()='ScopeItem'][contains(.,'ptz') or contains(.,'Profile/T')])" 0
req GetNetworkInterfaces device_service '<tds:GetNetworkInterfaces/>' 200 \
    "string(//*[local-name()='Manual']/*[local-name()='Address'])" "$IP"
req GetHostname device_service '<tds:GetHostname/>' 200
req GetDNS device_service '<tds:GetDNS/>' 200
req GetNTP device_service '<tds:GetNTP/>' 200
req GetNetworkProtocols device_service '<tds:GetNetworkProtocols/>' 200
req GetDiscoveryMode device_service '<tds:GetDiscoveryMode/>' 200 \
    "$(L DiscoveryMode)" "Discoverable"
req GetUsers device_service '<tds:GetUsers/>' 200
req GetWsdlUrl device_service '<tds:GetWsdlUrl/>' 200
req GetEndpointReference device_service '<tds:GetEndpointReference/>' 200
UUID=$(xp "$(L Address)" | sed 's/^urn:uuid://')
req Unsupported_SetHostname device_service '<tds:SetHostname><tds:Name>x</tds:Name></tds:SetHostname>' 500 \
    "$(C Fault)" 1

# ---- media service ------------------------------------------------------------
echo
echo "--- Media service"
req Media_GetServiceCapabilities media_service '<trt:GetServiceCapabilities/>' 200 \
    "string(//*[local-name()='Capabilities']/@SnapshotUri)" "false" \
    "string(//*[local-name()='ProfileCapabilities']/@MaximumNumberOfProfiles)" "1"
req GetProfiles media_service '<trt:GetProfiles/>' 200 \
    "count(//*[local-name()='Profiles'])" 1 \
    "string(//*[local-name()='Profiles']/@token)" "Profile_0" \
    "string(//*[local-name()='VideoEncoderConfiguration']/*[local-name()='Encoding'])" "H264" \
    "string(//*[local-name()='VideoEncoderConfiguration']//*[local-name()='Width'])" "1920" \
    "string(//*[local-name()='VideoEncoderConfiguration']//*[local-name()='Height'])" "1080" \
    "string(//*[local-name()='AudioEncoderConfiguration']/*[local-name()='Encoding'])" "AAC" \
    "$(C PTZConfiguration)" 0 "$(C AudioDecoderConfiguration)" 0 "$(C AudioOutputConfiguration)" 0
req GetProfile media_service '<trt:GetProfile><trt:ProfileToken>Profile_0</trt:ProfileToken></trt:GetProfile>' 200 \
    "string(//*[local-name()='Profile']/@token)" "Profile_0"
STREAM_BODY='<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup><trt:ProfileToken>Profile_0</trt:ProfileToken></trt:GetStreamUri>'
req GetStreamUri media_service "$STREAM_BODY" 200 \
    "$(L Uri)" "rtsp://$IP:554/main_ch"
req GetStreamUri_UnknownProfile media_service '<trt:GetStreamUri><trt:ProfileToken>Profile_9</trt:ProfileToken></trt:GetStreamUri>' 500 \
    "$(C Fault)" 1
req GetSnapshotUri_NotOffered media_service '<trt:GetSnapshotUri><trt:ProfileToken>Profile_0</trt:ProfileToken></trt:GetSnapshotUri>' 500 \
    "$(C Fault)" 1
req GetVideoSources media_service '<trt:GetVideoSources/>' 200 \
    "string(//*[local-name()='Resolution']/*[local-name()='Width'])" "1920"
req GetVideoSourceConfigurations media_service '<trt:GetVideoSourceConfigurations/>' 200
req GetVideoEncoderConfigurations media_service '<trt:GetVideoEncoderConfigurations/>' 200 \
    "count(//*[local-name()='Configurations'])" 1 \
    "string(//*[local-name()='Encoding'])" "H264"
req GetVideoEncoderConfiguration media_service '<trt:GetVideoEncoderConfiguration><trt:ConfigurationToken>Profile_0_VideoEncoderToken</trt:ConfigurationToken></trt:GetVideoEncoderConfiguration>' 200 \
    "string(//*[local-name()='Configuration']/@token)" "Profile_0_VideoEncoderToken"
req GetVideoEncoderConfigurationOptions media_service '<trt:GetVideoEncoderConfigurationOptions/>' 200
req GetAudioSources media_service '<trt:GetAudioSources/>' 200
req GetAudioEncoderConfigurations media_service '<trt:GetAudioEncoderConfigurations/>' 200 \
    "string(//*[local-name()='Encoding'])" "AAC"
# audio_decoder=NONE: no back channel, the CGI answers with an ONVIF fault.
req GetAudioDecoderConfigurations_NotSupported media_service '<trt:GetAudioDecoderConfigurations/>' 500 \
    "count(//*[local-name()='Value'][contains(.,'AudioDecodingNotSupported')])" 1
req GetGuaranteedNumberOfVideoEncoderInstances media_service '<trt:GetGuaranteedNumberOfVideoEncoderInstances><trt:ConfigurationToken>VideoSourceConfigToken</trt:ConfigurationToken></trt:GetGuaranteedNumberOfVideoEncoderInstances>' 200

# ---- other services -------------------------------------------------------
echo
echo "--- DeviceIO / Events"
req DeviceIO_GetVideoSources deviceio_service '<tmd:GetVideoSources/>' 200
req DeviceIO_GetRelayOutputs_None deviceio_service '<tmd:GetRelayOutputs/>' 200 \
    "$(C RelayOutputs)" 0
req Events_GetServiceCapabilities events_service '<tev:GetServiceCapabilities/>' 200 \
    "string(//*[local-name()='Capabilities']/@WSPullPointSupport)" "false"
req Events_GetEventProperties events_service '<tev:GetEventProperties/>' 200 \
    "count(//*[contains(local-name(),'Motion')])" 0

# ---- HTTP level ---------------------------------------------------------------
echo
echo "--- HTTP"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/onvif/ptz_service" -d '<x/>')
check "ptz_service endpoint does not exist (HTTP $code)" test "$code" = 404
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/onvif/media2_service" -d '<x/>')
check "media2_service endpoint does not exist (HTTP $code)" test "$code" = 404
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/onvif/")
check "directory listing of /onvif/ forbidden (HTTP $code)" test "$code" = 403
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/onvif/device_service_files/GetDeviceInformation.xml")
check "templates are not served as static files (HTTP $code)" test "$code" != 200
curl -s -o "$T/get.html" "http://127.0.0.1:$PORT/onvif/device_service"
check "GET on device_service is rejected by the CGI" grep -q "HTTP method not supported" "$T/get.html"
check "HTTP Content-Type is application/soap+xml" \
    sh -c "curl -s -D - -o /dev/null -H 'Content-Type: application/soap+xml' --data-binary @$T/req.xml http://127.0.0.1:$PORT/onvif/device_service | grep -qi '^Content-type: application/soap+xml'"
# A request from a client that sends 'Expect: 100-continue' (.NET, ODM).
soap device_service '<tds:GetDeviceInformation/>'
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Expect: 100-continue' \
    -H 'Content-Type: application/soap+xml' --data-binary @"$T/req.xml" "http://127.0.0.1:$PORT/onvif/device_service")
check "POST with 'Expect: 100-continue' answered (HTTP $code)" test "$code" = 200
# Five parallel requests (NVRs open several connections).
PAR_PIDS=""
for i in 1 2 3 4 5; do
    curl -s -m 60 -o "$T/par$i.xml" -H 'Content-Type: application/soap+xml' --data-binary @"$T/req.xml" \
        "http://127.0.0.1:$PORT/onvif/device_service" &
    PAR_PIDS="$PAR_PIDS $!"
done
# Wait for these PIDs only: a bare "wait" would also wait for the tee
# process substitution that captures this script's output.
wait $PAR_PIDS
okpar=0
for i in 1 2 3 4 5; do grep -q "<tds:Manufacturer>LSC" "$T/par$i.xml" && okpar=$((okpar + 1)); done
check "5 parallel requests all answered ($okpar/5)" test "$okpar" = 5

# ---- WS-Discovery -------------------------------------------------------------
echo
echo "--- WS-Discovery"
WSD_ARGS=(--xaddr "$DEV" --uuid "$UUID")
if python3 -I "$HERE/wsd_probe.py" probe --target 239.255.255.250 --iface-ip "$IP" "${WSD_ARGS[@]}" > "$T/wsd-mcast.txt" 2>&1; then
    pass "multicast Probe 239.255.255.250:3702 -> valid ProbeMatches"
else
    fail "multicast Probe 239.255.255.250:3702 -> valid ProbeMatches (see below)"
fi
sed 's/^/      /' "$T/wsd-mcast.txt"
if python3 -I "$HERE/wsd_probe.py" probe --target "$IP" "${WSD_ARGS[@]}" > "$T/wsd-ucast.txt" 2>&1; then
    pass "unicast Probe $IP:3702 -> valid ProbeMatches"
else
    fail "unicast Probe $IP:3702 -> valid ProbeMatches"
fi
sed 's/^/      /' "$T/wsd-ucast.txt"
if python3 -I "$HERE/wsd_probe.py" probe --target "$IP" --types "dn:NetworkVideoTransmitter" "${WSD_ARGS[@]}" > "$T/wsd-typed.txt" 2>&1; then
    pass "Probe with Types=dn:NetworkVideoTransmitter answered"
else
    fail "Probe with Types=dn:NetworkVideoTransmitter answered"
fi

# ---- status -----------------------------------------------------------------
echo
echo "--- status.sh"
if cam_sh "$BASE/status.sh" > "$T/status.out" 2>&1; then pass "status.sh exits 0 while running"; else fail "status.sh exits 0 while running"; fi
sed 's/^/      /' "$T/status.out"
check "status.sh sees anyka_ipc and the RTSP port" \
    sh -c "grep -q 'anyka_ipc *running' $T/status.out && grep -q 'TCP 554 *listening' $T/status.out"

# ---- stop, Bye, restart with authentication -----------------------------------
echo
echo "--- stop.sh / authentication / Hello"
python3 -I "$HERE/wsd_probe.py" listen --iface-ip "$IP" --seconds 25 --expect Bye,Hello > "$T/wsd-listen.txt" 2>&1 &
LISTENER=$!
sleep 1
if cam_sh "$BASE/stop.sh" > "$T/stop1.out" 2>&1; then pass "stop.sh exits 0"; else fail "stop.sh exits 0"; fi
sed 's/^/      /' "$T/stop1.out"
check "no httpd left after stop" test -z "$(pgrep -f /tmp/onvif/bin/httpd)"
check "no wsd_simple_server left after stop" test -z "$(pgrep -f /tmp/onvif/bin/wsd_simple_server)"
check "tmpfs runtime directory removed" test ! -e /tmp/onvif/bin
check "TCP $PORT closed after stop" sh -c "! ss -ltn | grep -q ':$PORT '"
if cam_sh "$BASE/status.sh" > /dev/null 2>&1; then fail "status.sh exits 1 when stopped"; else pass "status.sh exits 1 when stopped"; fi

printf 'user=admin\npassword=Test-1234\r\n' > "$BASE/etc/onvif_auth.conf"   # CRLF on purpose
if cam_sh "$BASE/start.sh" > "$T/start3.out" 2>&1; then pass "start.sh with authentication exits 0"; else fail "start.sh with authentication exits 0"; fi
check "runtime config contains the credentials (CR stripped)" \
    sh -c "grep -qx 'password=Test-1234' /tmp/onvif/etc/onvif_simple_server.conf"
check "runtime config is not world-readable" \
    sh -c "[ \"\$(stat -c %a /tmp/onvif/etc/onvif_simple_server.conf)\" = 600 ]"
wait $LISTENER
if grep -q "RESULT OK" "$T/wsd-listen.txt"; then pass "Bye on stop and Hello on start received (multicast)"; else fail "Bye on stop and Hello on start received (multicast)"; fi
sed 's/^/      /' "$T/wsd-listen.txt"

req Auth_GetDeviceInformation_NoToken device_service '<tds:GetDeviceInformation/>' 400 \
    "$(C Fault)" 1
req Auth_GetCapabilities_NoToken device_service '<tds:GetCapabilities/>' 200
req Auth_GetSystemDateAndTime_NoToken device_service '<tds:GetSystemDateAndTime/>' 200
HEADER=$(python3 -I "$HERE/wsse.py" admin Test-1234)
req Auth_GetDeviceInformation_ValidDigest device_service '<tds:GetDeviceInformation/>' 200 \
    "$(L Manufacturer)" "LSC"
req Auth_GetStreamUri_ValidDigest media_service "$STREAM_BODY" 200 \
    "$(L Uri)" "rtsp://$IP:554/main_ch"
HEADER=$(python3 -I "$HERE/wsse.py" admin wrong-password)
req Auth_GetDeviceInformation_WrongPassword device_service '<tds:GetDeviceInformation/>' 400 \
    "$(C Fault)" 1
HEADER=$(python3 -I "$HERE/wsse.py" intruder Test-1234)
req Auth_GetProfiles_WrongUser media_service '<trt:GetProfiles/>' 400 \
    "$(C Fault)" 1
HEADER=""

# ---- IP access control (httpd.conf) -------------------------------------------
cam_sh "$BASE/stop.sh" > /dev/null 2>&1
printf 'user=\npassword=\n' > "$BASE/etc/onvif_auth.conf"
cp "$BASE/etc/httpd.conf" "$T/httpd.conf.orig"
printf 'A:10.255.255.0/24\nD:*\n' > "$BASE/etc/httpd.conf"
cam_sh "$BASE/start.sh" > /dev/null 2>&1
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/soap+xml' --data-binary @"$T/req.xml" "http://127.0.0.1:$PORT/onvif/device_service")
check "httpd.conf ACL denies a client outside the allowed range (HTTP $code)" test "$code" = 403
cam_sh "$BASE/stop.sh" > /dev/null 2>&1
cp "$T/httpd.conf.orig" "$BASE/etc/httpd.conf"

# ---- RAM logging --------------------------------------------------------------
sed -i 's/^LOG_IN_RAM=0/LOG_IN_RAM=1/' "$BASE/etc/onvif.env"
rm -f "$BASE"/logs/*.log
cam_sh "$BASE/start.sh" > /dev/null 2>&1
check "LOG_IN_RAM=1: logs written to /tmp/onvif/log" test -s /tmp/onvif/log/onvif-control.log
check "LOG_IN_RAM=1: no log files on the SD card" test -z "$(ls "$BASE"/logs/*.log 2>/dev/null)"
cam_sh "$BASE/stop.sh" > /dev/null 2>&1
sed -i 's/^LOG_IN_RAM=1/LOG_IN_RAM=0/' "$BASE/etc/onvif.env"

echo
echo "--- firmware stand-ins"
check "anyka_ipc stand-in survived all start/stop/restart cycles" kill -0 "$FAKE_IPC"
check "RTSP port 554 stand-in still listening" sh -c "ss -ltn | grep -q ':554 '"
kill "$FAKE_IPC" "$FAKE_RTSP" 2>/dev/null

echo
echo "Responses of the SOAP tests are stored in the build log directory."
mkdir -p "${LOGDIR:-/output/build-logs}/soap-responses"
cp "$T"/*.xml "$T"/*.txt "$T"/*.out "$T"/*.log "${LOGDIR:-/output/build-logs}/soap-responses/" 2>/dev/null
echo
echo "SUMMARY: $npass passed, $nfail failed"
[ "$nfail" = 0 ]
