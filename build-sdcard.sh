#!/bin/bash
# build-sdcard.sh - produce output/sd_card/ for the LSC Smart Connect PTZ 3007325
# (Anyka AK39EV330, ARM926EJ-S / ARMv5TEJ, soft-float, static). Runs INSIDE the
# onvif-armv5-builder container. Builds the ONVIF server + PTZ-patched CGI and
# the onvif_ptz_bridge 1.4 daemon, then assembles the full SD-card folder (the
# /mnt contents) plus a one-time autostart installer.
#
#   /src     repo (read-only bind mount)
#   /output  results (bind mount) -> output/sd_card
#   /build   scratch (inside build.sh)
set -uo pipefail
SRC=${SRC:-/src}; OUT=${OUT:-/output}
CROSS=${CROSS_PREFIX:-arm-buildroot-linux-musleabi-}; CC="${CROSS}gcc"
FA="-mcpu=arm926ej-s -marm -mfloat-abi=soft -Os -std=gnu11 -Wall -Wextra -ffunction-sections -fdata-sections"
LA="-static -Wl,--gc-sections -lm"
REL="$SRC/ptz-smooth/release-1.4"
SD="$OUT/sd_card"; B="$OUT/sdbuild"
step(){ echo; echo "### $*"; }
die(){ echo "SDCARD BUILD FAILED: $*" >&2; exit 1; }

# This script runs INSIDE the onvif-armv5-builder container (repo bind-mounted at
# /src, cross-toolchain on PATH), not directly on the host. Catch the common
# mistake of running it on Windows/host and print the right command.
if [ ! -f "$SRC/build.sh" ]; then
    echo "ERROR: $SRC/build.sh not found - build-sdcard.sh must run INSIDE the" >&2
    echo "       onvif-armv5-builder container, not on the host." >&2
    echo "From the repo root (PowerShell):" >&2
    echo "  docker compose build" >&2
    echo "  docker run --rm -v \"\${PWD}:/src:ro\" -v \"\${PWD}\\output:/output\" onvif-armv5-builder \`" >&2
    echo "    bash -c \"tr -d '\\r' < /src/build-sdcard.sh > /tmp/b.sh && bash /tmp/b.sh\"" >&2
    exit 1
fi

mkdir -p "$B"

step "1/4 ONVIF server + PTZ CGI (base build + PTZ patch via EXTRA_PATCHES)"
tr -d '\r' < "$SRC/build.sh" > /tmp/onvifbuild.sh
EXTRA_PATCHES="$SRC/patches/ptz-smooth" bash /tmp/onvifbuild.sh || die "ONVIF build"
ONVIF="$OUT/onvif-camera"
[ -d "$ONVIF/bin" ] && [ -f "$ONVIF/start.sh" ] || die "onvif-camera not produced"

step "2/4 onvif_ptz_bridge 1.4 (ARMv5 static)"
BR="$REL/src/bridge.c $REL/src/coords.c $REL/src/log.c $REL/src/ptz-control/motor.c $REL/src/ptz-control/sysfs.c $REL/src/ptz-control/dev_linux.c"
$CC $FA -I"$REL/src" -I"$REL/src/ptz-control" $BR $LA -o "$B/onvif_ptz_bridge" || die "bridge compile"
${CROSS}strip "$B/onvif_ptz_bridge"

step "3/4 assemble sd_card/"
rm -rf "$SD"; mkdir -p "$SD/onvif"
cp -a "$ONVIF/." "$SD/onvif/"
rm -f "$SD/onvif/SHA256SUMS"                         # regenerated at SD level below
# --- PTZ overlay ---
cp "$B/onvif_ptz_bridge" "$SD/onvif/bin/"
# PTZ SOAP templates live alongside the other *_service_files under www/onvif
# (not in a separate top-level ptz/ dir). start.sh does not link them into the
# served web root; enable-ptz.sh links them in only when PTZ is activated.
cp -r "$REL/www/onvif/ptz_service_files" "$SD/onvif/www/onvif/"
mkdir -p "$SD/onvif/scripts" "$SD/onvif/config" "$SD/onvif/logs"
for s in "$REL/scripts/"*.sh; do sed 's/\r$//' "$s" > "$SD/onvif/scripts/$(basename "$s")"; chmod 755 "$SD/onvif/scripts/$(basename "$s")"; done
for c in "$REL/config/"*; do [ -f "$c" ] && sed 's/\r$//' "$c" > "$SD/onvif/config/$(basename "$c")"; done
: > "$SD/onvif/logs/.keep"
# PTZ autostart: insert the block before start.sh's final `exit 0`, set the flag
sed '${/^exit 0$/d}' "$SD/onvif/start.sh" > "$SD/onvif/start.sh.tmp"
sed 's/\r$//' "$SRC/sdcard/overlay/ptz-autostart-block.sh" >> "$SD/onvif/start.sh.tmp"
printf 'exit 0\n' >> "$SD/onvif/start.sh.tmp"
mv "$SD/onvif/start.sh.tmp" "$SD/onvif/start.sh"; chmod 755 "$SD/onvif/start.sh"
: > "$SD/onvif/ptz_autostart.enabled"
# --- SD root: opt-in flags, RTSP factory config, one-time installer ---
: > "$SD/onvif_autostart.enabled"
: > "$SD/rtsp_autostart.enabled"
sed 's/\r$//' "$SRC/sdcard/rtsp_factory.ini" > "$SD/rtsp_factory.ini"
# Bake Wi-Fi station creds into the RTSP factory config so that when the boot
# worker restarts anyka_ipc in factory mode it stays on YOUR LAN (STA). Without
# this, factory mode falls back to the camera's own AP (172.14.10.x) and the
# ONVIF server loses the LAN address. Written to output/ only (git-ignored).
if [ "${WIFI_MODE:-}" = sta ] && [ -n "${WIFI_SSID:-}" ]; then
    {
        echo ""
        echo "[wifi_station]"
        echo "ssid=${WIFI_SSID}"
        echo "passphrase=${WIFI_PASS:-}"
        if [ -n "${WIFI_IP:-}" ]; then
            echo "ip=${WIFI_IP}"
            echo "netmask=${WIFI_NETMASK:-255.255.255.0}"
            echo "gateway=${WIFI_GW:-}"
        fi
    } >> "$SD/rtsp_factory.ini"
    echo "sd_card: rtsp_factory.ini [wifi_station] set (anyka_ipc joins '${WIFI_SSID}' in RTSP mode)"
fi
mkdir -p "$SD/install"
sed 's/\r$//' "$SRC/sdcard/install/install-autostart.sh" > "$SD/install/install-autostart.sh"; chmod 755 "$SD/install/install-autostart.sh"
sed 's/\r$//' "$SRC/sdcard/install/rtsp_autostart.sh" > "$SD/install/rtsp_autostart.sh"; chmod 755 "$SD/install/rtsp_autostart.sh"
[ -f "$SRC/sdcard/README.md" ] && sed 's/\r$//' "$SRC/sdcard/README.md" > "$SD/README.md"

# Optional ONVIF credentials (WS-UsernameToken), baked into the card's
# onvif_auth.conf. These are SEPARATE from the Telnet root password, and from
# RTSP: the factory anyka_ipc RTSP server has no authentication (its RTSP parser
# has no Authorization field; the :554/main_ch stream is open by design), so
# there is no RTSP login/password to set here. Written to output/ only.
AUTHF="$SD/onvif/etc/onvif_auth.conf"
if [ -n "${ONVIF_USER:-}" ] && [ -f "$AUTHF" ]; then
    sed -e '/^user=/d' -e '/^password=/d' "$AUTHF" > "$AUTHF.tmp"
    { echo "user=${ONVIF_USER}"; echo "password=${ONVIF_PASS:-}"; } >> "$AUTHF.tmp"
    mv -f "$AUTHF.tmp" "$AUTHF"
    echo "sd_card: ONVIF auth ENABLED (WS-UsernameToken, user '${ONVIF_USER}')"
else
    echo "sd_card: ONVIF auth left disabled (set ONVIF_USER/ONVIF_PASS to enable)"
fi

step "3b/4 assemble sd_card_telnet/ (factory-reset Telnet bootstrap)"
# A tiny, compile-free card whose ONLY job is to open a root Telnet shell on a
# factory-reset camera (which ships with Telnet off), so you can then run
# install-autostart.sh. It writes no flash. Credit: guino/LSCOutdoor1080P.
# Delegated to build-telnet-sd.sh (single source of truth); it honours the same
# TELNET_ROOT_PASSWORD and the WIFI_* env vars. prepare-telnet-sd.ps1 wraps it.
STL="$OUT/sd_card_telnet"
if [ -f "$SRC/build-telnet-sd.sh" ]; then
    tr -d '\r' < "$SRC/build-telnet-sd.sh" > /tmp/telnetbuild.sh
    SRC="$SRC" OUT="$OUT" sh /tmp/telnetbuild.sh || echo "WARN: telnet card build failed"
else
    echo "WARN: $SRC/build-telnet-sd.sh missing -> telnet card skipped"
fi

step "4/4 ABI verify + checksums"
rc=0
for b in onvif_ptz_bridge httpd onvif_simple_server wsd_simple_server; do
    f="$SD/onvif/bin/$b"; [ -f "$f" ] || die "missing binary $b"
    file "$f" | grep -q "ELF 32-bit.*ARM" || { echo "WARN: $b not ARM ELF"; rc=1; }
    ${CROSS}readelf -d "$f" 2>/dev/null | grep -q "NEEDED" && { echo "WARN: $b is dynamically linked"; rc=1; }
done
tag=$(${CROSS}readelf -A "$B/onvif_ptz_bridge" | sed -n 's/.*Tag_CPU_arch: //p' | head -1)
flt=$(${CROSS}readelf -h "$B/onvif_ptz_bridge" | grep -qi hard-float && echo HARD || echo soft)
echo "bridge: Tag_CPU_arch=$tag float=$flt  ($(sha256sum "$SD/onvif/bin/onvif_ptz_bridge" | cut -d' ' -f1))"
case "$tag" in *5TE*|v5T*) : ;; *) echo "WARN: unexpected arch tag $tag"; rc=1;; esac
[ "$flt" = soft ] || { echo "ERROR: hard-float!"; rc=1; }
( cd "$SD" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )

if [ -d "$STL" ]; then
    ( cd "$STL" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
fi

echo; echo "=== sd_card tree ==="; ( cd "$OUT" && find sd_card -maxdepth 2 | LC_ALL=C sort )
[ -d "$STL" ] && { echo; echo "=== sd_card_telnet tree ==="; ( cd "$OUT" && find sd_card_telnet | LC_ALL=C sort ); }
echo; echo "sd_card ready at output/sd_card; telnet bootstrap at output/sd_card_telnet (rc=$rc)"
exit $rc
