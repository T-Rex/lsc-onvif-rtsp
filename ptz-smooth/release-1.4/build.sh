#!/bin/bash
# build.sh - build onvif_ptz_bridge 1.4.0 for the Anyka AK39EV330 (ARMv5TEJ,
# ARM926EJ-S, soft-float, static musl) as ONE unified binary (compat default +
# runtime hardware-speed profile). Cross-compile, verify ABI, run host unit +
# daemon tests, assemble the release-1.4 package and the release archive.
#
# Runs INSIDE the onvif-armv5-builder image. Expects the repo bind-mounted so
# this dir is .../ptz-smooth/release-1.4. No hardware involved.
set -uo pipefail
HERE=${HERE:-$(cd "$(dirname "$0")" && pwd)}    # .../ptz-smooth/release-1.4
REPO=$(cd "$HERE/../.." && pwd)                 # repo root
OUT="$HERE/output"; WORK=/tmp/b14
CROSS=${CROSS_PREFIX:-arm-buildroot-linux-musleabi-}; CC_ARM="${CROSS}gcc"
FA="-mcpu=arm926ej-s -marm -mfloat-abi=soft -Os -std=gnu11 -Wall -Wextra -ffunction-sections -fdata-sections"
LA="-static -Wl,--gc-sections -lm"
FH="-O1 -g -std=gnu11 -Wall -Wextra -fsanitize=undefined -fno-sanitize-recover=all"
PC="$HERE/src/ptz-control"; PI="-I$HERE/src -I$PC"
# reuse the patched CGI + templates from the repo
# The PTZ SOAP templates ship with this release (committed). The patched CGI/www
# come from the ONVIF build output when present (else the SOAP test is skipped);
# the authoritative full build is the repo's top-level build-sdcard.sh.
SMOOTH_CGI=${SMOOTH_CGI:-$REPO/output/onvif-camera/bin/onvif_simple_server}
SMOOTH_WWW=${SMOOTH_WWW:-$REPO/output/onvif-camera/www/onvif}
PTZ_TPL=${PTZ_TPL:-$HERE/www/onvif/ptz_service_files}

rc=0; mkdir -p "$WORK" "$OUT" "$OUT/unstripped" "$OUT/build-logs"
rm -rf "$OUT/onvif-ptz-bridge-1.4.0" "$OUT"/*.tar "$OUT"/*.tar.gz 2>/dev/null
step(){ echo; echo "### $*"; }
die(){ echo "BUILD FAILED: $*" >&2; exit 1; }

BR_SRCS="$HERE/src/bridge.c $HERE/src/coords.c $HERE/src/log.c $PC/motor.c $PC/sysfs.c"

step "Cross-compiling onvif_ptz_bridge 1.4.0 (ARMv5, static musl)"
$CC_ARM $FA $PI $BR_SRCS "$PC/dev_linux.c" $LA -o "$WORK/bridge" \
    2> "$OUT/build-logs/bridge-arm.log" || { cat "$OUT/build-logs/bridge-arm.log"; die "ARM compile"; }
cat "$OUT/build-logs/bridge-arm.log"; BW=$(grep -c warning: "$OUT/build-logs/bridge-arm.log" || true)
cp "$WORK/bridge" "$OUT/unstripped/onvif_ptz_bridge"; ${CROSS}strip "$WORK/bridge"

step "Cross-compiling ARM mock bridge (SOAP under QEMU)"
$CC_ARM $FA $PI $BR_SRCS "$HERE/tests/mock_motor.c" $LA -o "$WORK/bridge_mock_arm" \
    2> "$OUT/build-logs/bridge-arm-mock.log" || { cat "$OUT/build-logs/bridge-arm-mock.log"; die "mock ARM"; }

step "Host test binaries (UBSan)"
gcc $FH $PI "$HERE/tests/test_coords.c" "$HERE/src/coords.c" -lm -o "$WORK/test_coords" 2> "$OUT/build-logs/host-coords.log" || { cat "$OUT/build-logs/host-coords.log"; die "test_coords"; }
gcc $FH "$HERE/tests/test_duration.c" -o "$WORK/test_duration" 2> "$OUT/build-logs/host-dur.log" || { cat "$OUT/build-logs/host-dur.log"; die "test_duration"; }
gcc $FH $PI $BR_SRCS "$HERE/tests/mock_motor.c" -lm -o "$WORK/bridge_host" 2> "$OUT/build-logs/host-bridge.log" || { cat "$OUT/build-logs/host-bridge.log"; die "host bridge"; }

step "ABI verification"
{
  echo "== file =="; file "$OUT/unstripped/onvif_ptz_bridge"
  echo "== readelf -h =="; ${CROSS}readelf -h "$OUT/unstripped/onvif_ptz_bridge"
  echo "== readelf -A (arch attrs) =="; ${CROSS}readelf -A "$OUT/unstripped/onvif_ptz_bridge"
  echo "== readelf -d (dynamic; expect none, static) =="; ${CROSS}readelf -d "$OUT/unstripped/onvif_ptz_bridge" 2>&1 | head
} > "$OUT/binary-checks.txt" 2>&1
TAG=$(${CROSS}readelf -A "$OUT/unstripped/onvif_ptz_bridge" | sed -n 's/.*Tag_CPU_arch: //p' | head -1)
FLG=$(${CROSS}readelf -h "$OUT/unstripped/onvif_ptz_bridge" | sed -n 's/^ *Flags: *//p')
MACH=$(${CROSS}readelf -h "$OUT/unstripped/onvif_ptz_bridge" | sed -n 's/^ *Machine: *//p')
STAT=$(file "$OUT/unstripped/onvif_ptz_bridge" | grep -qi "statically linked" && echo yes || echo no)
HARD=$(echo "$FLG" | grep -qi "hard-float" && echo HARD || echo soft)
echo "arch=$TAG machine=$MACH static=$STAT float=$HARD flags=[$FLG]" | tee -a "$OUT/binary-checks.txt"
case "$TAG" in v5TE|v5T|5TE|5TEJ|v5TEJ) : ;; *) echo "WARN: unexpected CPU arch tag '$TAG' (want ARMv5TE)"; rc=1;; esac
[ "$STAT" = yes ] || { echo "WARN: binary is not statically linked"; rc=1; }
[ "$HARD" = soft ] || { echo "ERROR: hard-float flags present (must be soft-float for ARM926EJ-S)"; rc=1; }

step "Unit + daemon tests (mock motor; profiles exercised via env)"
bash "$HERE/tests/run-tests.sh" "$WORK/test_coords" "$WORK/test_duration" "$WORK/bridge_host" "$WORK/bridge_host" 2>&1 | tee "$OUT/test-results.txt"
[ "${PIPESTATUS[0]}" = 0 ] || rc=1

step "ONVIF SOAP tests (patched CGI under QEMU, mock bridge)"
if [ -x "$SMOOTH_CGI" ] && [ -d "$SMOOTH_WWW" ] && [ -f "$HERE/tests/soap-tests.sh" ]; then
    SOAP_CGI="$SMOOTH_CGI" SOAP_WWW="$SMOOTH_WWW" SOAP_PTZTPL="$REPO/ptz-bridge/templates" \
    SOAP_BRIDGE_ARM="$WORK/bridge_mock_arm" SOAP_BASECONF="$REPO/package/etc/onvif_simple_server.conf" \
    WSSE="$REPO/tests/wsse.py" bash "$HERE/tests/soap-tests.sh" 2>&1 | tee "$OUT/soap-results.txt"
    [ "${PIPESTATUS[0]}" = 0 ] || rc=1
else
    echo "SKIP: patched CGI / SOAP harness not found (offline SOAP test skipped)" | tee "$OUT/soap-results.txt"
fi

step "Assembling release package onvif-ptz-bridge-1.4.0"
P="$OUT/onvif-ptz-bridge-1.4.0"
mkdir -p "$P/bin" "$P/scripts" "$P/config" "$P/docs" "$P/www/onvif" "$P/logs"
: > "$P/logs/.keep"
cp "$WORK/bridge" "$P/bin/onvif_ptz_bridge"
[ -x "$SMOOTH_CGI" ] && cp "$SMOOTH_CGI" "$P/bin/onvif_simple_server"
[ -d "$PTZ_TPL" ] && cp -r "$PTZ_TPL" "$P/www/onvif/ptz_service_files"
for s in "$HERE"/scripts/*.sh; do [ -f "$s" ] && sed 's/\r$//' "$s" > "$P/scripts/$(basename "$s")"; done
for d in "$HERE"/docs/*.md; do [ -f "$d" ] && sed 's/\r$//' "$d" > "$P/docs/$(basename "$d")"; done
for c in "$HERE"/config/*; do [ -f "$c" ] && sed 's/\r$//' "$c" > "$P/config/$(basename "$c")"; done
[ -f "$HERE/README.md" ] && sed 's/\r$//' "$HERE/README.md" > "$P/README.md"
echo "onvif_ptz_bridge 1.4.0 - unified (compat default + runtime hardware-speed profile)" > "$P/FLAVOUR.txt"

step "Checksums + release archive (uncompressed .tar; camera has no gzip)"
( cd "$OUT" && tar --sort=name --mtime="@0" --owner=0 --group=0 --numeric-owner -cf onvif-ptz-bridge-1.4.0-armv5.tar onvif-ptz-bridge-1.4.0 )
( cd "$OUT" && sha256sum onvif-ptz-bridge-1.4.0-armv5.tar onvif-ptz-bridge-1.4.0/bin/* > SHA256SUMS )
cp "$OUT/SHA256SUMS" "$P/SHA256SUMS"

step "Build report"
{
    echo "# onvif_ptz_bridge 1.4.0 build report"
    echo; echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) inside Docker. No hardware involved."
    echo
    echo "| Step | Result |"; echo "| --- | --- |"
    echo "| ARM compile | PASS ($BW warnings) |"
    echo "| ABI (arch/static/float) | $TAG / static=$STAT / $HARD |"
    echo "| Unit + daemon tests | $(grep '^SUMMARY-SMOOTH:' "$OUT/test-results.txt" | sed 's/SUMMARY-SMOOTH: //') |"
    echo "| SOAP tests | $(grep '^SUMMARY-SOAP:' "$OUT/soap-results.txt" 2>/dev/null | sed 's/SUMMARY-SOAP: //' || echo skipped) |"
    echo; echo '```'; file "$P/bin/onvif_ptz_bridge"; echo '```'
    echo "bridge 1.4.0: $(stat -c %s "$P/bin/onvif_ptz_bridge") B, SHA-256 $(sha256sum "$P/bin/onvif_ptz_bridge"|cut -d' ' -f1)"
    echo "Tag_CPU_arch: $TAG   Flags: $FLG"
    echo "Single binary: speed-ioctl present once, gated by runtime profile (default compat == 1.3)."
} > "$OUT/build-report.md"
cp "$OUT/build-report.md" "$P/build-report.md"
sha256sum "$P/bin/onvif_ptz_bridge"
step "Done (rc=$rc)"; exit $rc
