#!/bin/bash
# build.sh - runs INSIDE the Docker build container.
#
# Fetches and verifies all sources, cross-compiles onvif_simple_server,
# wsd_simple_server and a BusyBox httpd for the ARM926EJ-S camera, assembles
# the onvif-camera deployment package, verifies the binaries and tests them
# under QEMU. Everything is written to /output (bind-mounted from Windows).
#
#   /src     project directory (read-only bind mount)
#   /output  results (bind mount)
#   /build   scratch space inside the container

set -euo pipefail

SRC=/src
OUT=/output
WORK=/build
DL=$WORK/dl
SYSROOT=$WORK/sysroot
PKG_NAME=onvif-camera
PKG=$OUT/$PKG_NAME
LOGDIR=$OUT/build-logs

# ---- pinned inputs ---------------------------------------------------------
ONVIF_REPO=${ONVIF_REPO:-https://github.com/roleoroleo/onvif_simple_server.git}
ONVIF_COMMIT=${ONVIF_COMMIT:-7b3941af76a57277ba975efaf2366cb8c6fa1936}

BUSYBOX_VER=1.36.1
BUSYBOX_URL=https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2
BUSYBOX_SHA256=b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314

ZLIB_VER=1.3.1
ZLIB_URL=https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23

JSONC_TAG=json-c-0.18-20240915
JSONC_URL=https://github.com/json-c/json-c/archive/refs/tags/$JSONC_TAG.tar.gz
JSONC_SHA256=3112c1f25d39eca661fe3fc663431e130cc6e2f900c081738317fba49d29e298

MBEDTLS_VER=3.6.4
MBEDTLS_URL=https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VER/mbedtls-$MBEDTLS_VER.tar.bz2
MBEDTLS_SHA256=ec35b18a6c593cf98c3e30db8b98ff93e8940a8c4e690e66b41dfc011d678110

# ---- target ------------------------------------------------------------------
CROSS=${CROSS_PREFIX:-arm-buildroot-linux-musleabi-}
CC=${CROSS}gcc
TARGET_CFLAGS="-mcpu=arm926ej-s -marm -mfloat-abi=soft -Os"

# Runtime directory on the camera's tmpfs. These paths are compiled into the
# binaries (see patches/onvif_simple_server/0001-*.patch); start.sh creates it.
RUNDIR=/tmp/onvif

JOBS=$(nproc)

say() { printf '\n==== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Normalise text copied from a Windows checkout (CRLF -> LF).
lf_copy() { tr -d '\r' < "$1" > "$2"; }

fetch() { # url sha256 -> prints local path
    local url=$1 sum=$2 f
    f=$DL/$(basename "$url")
    if [ ! -f "$f" ]; then
        curl -fsSL --retry 3 -o "$f.part" "$url"
        mv "$f.part" "$f"
    fi
    echo "$sum  $f" | sha256sum -c --quiet - >&2 || die "checksum mismatch: $url"
    echo "$f"
}

rm -rf "$WORK" "$PKG" "$OUT/$PKG_NAME.tar.gz" "$OUT/SHA256SUMS" "$LOGDIR" "$OUT/unstripped"
mkdir -p "$WORK" "$DL" "$SYSROOT" "$OUT" "$LOGDIR"

{
    echo "build_date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "toolchain=$(cat /opt/toolchain/TOOLCHAIN_NAME)"
    echo "gcc=$($CC -dumpversion)"
    echo "target_cflags=\"$TARGET_CFLAGS\""
} > "$WORK/buildinfo.env"

# ---------------------------------------------------------------------------
say "Fetching sources"
cd "$WORK"
git clone --quiet "$ONVIF_REPO" onvif_simple_server
git -C onvif_simple_server checkout --quiet "$ONVIF_COMMIT"
ONVIF_HEAD=$(git -C onvif_simple_server rev-parse HEAD)
ONVIF_DATE=$(git -C onvif_simple_server log -1 --format=%ci)
ONVIF_SUBJ=$(git -C onvif_simple_server log -1 --format=%s)
# Reproducible builds: BusyBox embeds a build timestamp; pin it (and the
# archive timestamps) to the upstream commit time.
export SOURCE_DATE_EPOCH=$(git -C onvif_simple_server log -1 --format=%ct)
echo "onvif_simple_server: $ONVIF_HEAD ($ONVIF_DATE) $ONVIF_SUBJ"

tar -xjf "$(fetch "$BUSYBOX_URL" "$BUSYBOX_SHA256")"
tar -xzf "$(fetch "$ZLIB_URL" "$ZLIB_SHA256")"
tar -xzf "$(fetch "$JSONC_URL" "$JSONC_SHA256")"
tar -xjf "$(fetch "$MBEDTLS_URL" "$MBEDTLS_SHA256")"

# run_step NAME FUNCTION - run FUNCTION with "set -e" in a subshell, output to
# build-logs/NAME.log; abort the build with the log tail on failure.
# (set -e is ignored inside "cmd || ..." lists, hence the explicit $?.)
run_step() {
    local rc
    set +e
    ( set -e; "$2" ) > "$LOGDIR/$1.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        tail -40 "$LOGDIR/$1.log"
        die "$1 failed (exit $rc), see build-logs/$1.log"
    fi
}

# ---------------------------------------------------------------------------
build_zlib() {
    cd "$WORK/zlib-$ZLIB_VER"
    CHOST=arm-linux CC=$CC AR=${CROSS}ar RANLIB=${CROSS}ranlib CFLAGS="$TARGET_CFLAGS" \
        ./configure --static --prefix="$SYSROOT"
    make -j"$JOBS" libz.a
    make install
}
say "Building zlib $ZLIB_VER (static)"
run_step zlib build_zlib

build_jsonc() {
    mkdir -p "$WORK/json-c-build"
    cd "$WORK/json-c-build"
    cmake "../json-c-$JSONC_TAG" \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$(command -v ${CROSS}ar)" \
        -DCMAKE_C_FLAGS="$TARGET_CFLAGS" -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_INSTALL_PREFIX="$SYSROOT" -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_TESTING=OFF \
        -DBUILD_APPS=OFF -DDISABLE_WERROR=ON
    make -j"$JOBS"
    make install
}
say "Building json-c ($JSONC_TAG, static)"
run_step json-c build_jsonc

build_mbedtls() {
    # The upstream minimal config (extras/mbedtls_config.h) enables only what
    # the WS-UsernameToken digest check needs: SHA-1 and Base64.
    cp "$WORK/onvif_simple_server/extras/mbedtls_config.h" "$WORK/mbedtls_config.h"
    cd "$WORK/mbedtls-$MBEDTLS_VER"
    # Use the generated sources shipped in the release tarball instead of
    # regenerating them with Python/Jinja: GEN_FILES= disables most rules, and
    # the driver wrapper rule (timestamp based, not guarded) is satisfied by
    # touching its outputs.
    touch library/psa_crypto_driver_wrappers.h library/psa_crypto_driver_wrappers_no_static.c
    make -C library -j"$JOBS" libmbedcrypto.a GEN_FILES= \
        CC="$CC" AR=${CROSS}ar \
        CFLAGS="$TARGET_CFLAGS -DMBEDTLS_CONFIG_FILE='\"$WORK/mbedtls_config.h\"'"
    mkdir -p "$SYSROOT/lib" "$SYSROOT/include"
    cp library/libmbedcrypto.a "$SYSROOT/lib/"
    cp -r include/mbedtls include/psa "$SYSROOT/include/"
    cp "$WORK/mbedtls_config.h" "$SYSROOT/include/mbedtls/mbedtls_config.h"
}
say "Building mbedtls $MBEDTLS_VER libmbedcrypto (SHA-1 + Base64 only)"
run_step mbedtls build_mbedtls

# ---------------------------------------------------------------------------
say "Patching and building onvif_simple_server + wsd_simple_server"
cd "$WORK/onvif_simple_server"
for p in "$SRC"/patches/onvif_simple_server/*.patch; do
    echo "applying $(basename "$p")"
    tr -d '\r' < "$p" | patch -p1 --no-backup-if-mismatch
done
# Optional extra patches (e.g. the ptz-smooth ONVIF Timeout patch) supplied out
# of tree, so add-on projects can rebuild the CGI without modifying patches/.
if [ -n "${EXTRA_PATCHES:-}" ] && [ -d "$EXTRA_PATCHES/onvif_simple_server" ]; then
    for p in "$EXTRA_PATCHES"/onvif_simple_server/*.patch; do
        [ -f "$p" ] || continue
        echo "applying extra $(basename "$p")"
        tr -d '\r' < "$p" | patch -p1 --no-backup-if-mismatch
    done
fi

PATH_DEFS="-DDEFAULT_CONF_FILE='\"$RUNDIR/etc/onvif_simple_server.conf\"'"
PATH_DEFS="$PATH_DEFS -DDEFAULT_JSON_CONF_FILE='\"$RUNDIR/etc/onvif_simple_server.json\"'"
PATH_DEFS="$PATH_DEFS -DDEFAULT_LOG_FILE='\"$RUNDIR/log/onvif_simple_server.log\"'"
PATH_DEFS="$PATH_DEFS -DDEBUG_FILE='\"$RUNDIR/onvif_simple_server.debug\"'"
WSD_DEFS="-DDEFAULT_LOG_FILE='\"$RUNDIR/log/wsd_simple_server.log\"'"
WSD_DEFS="$WSD_DEFS -DDEFAULT_TEMPLATE_DIR='\"$RUNDIR/wsd\"'"
COMMON="-DHAVE_MBEDTLS -ffunction-sections -fdata-sections -I$SYSROOT/include $TARGET_CFLAGS"

build_onvif() {
    cd "$WORK/onvif_simple_server"
    # The CGI and the WSD daemon share object files (utils.o, log.o, ...),
    # but need different -D path defaults, so build them in separate passes.
    make -j"$JOBS" CC="$CC" STRIP=true HAVE_MBEDTLS=1 \
        INCLUDE="$COMMON $PATH_DEFS" \
        LIBS_O="-static -Wl,--gc-sections -L$SYSROOT/lib -lmbedcrypto -lz -ljson-c -lpthread -lrt" \
        onvif_simple_server
    mv onvif_simple_server "$WORK/onvif_simple_server.bin"
    make clean
    make -j"$JOBS" CC="$CC" STRIP=true HAVE_MBEDTLS=1 \
        INCLUDE="$COMMON $WSD_DEFS" \
        LIBS_W="-static -Wl,--gc-sections" \
        wsd_simple_server
    mv wsd_simple_server "$WORK/wsd_simple_server.bin"
}
run_step onvif_simple_server build_onvif
grep -c "warning:" "$LOGDIR/onvif_simple_server.log" > "$WORK/onvif_warnings.txt" || true

say "Running upstream unit tests (make test, native host compiler)"
make clean > /dev/null
if make test > "$LOGDIR/upstream-unit-tests.log" 2>&1; then
    UNIT_TESTS="PASS"
else
    UNIT_TESTS="FAIL"
fi
tail -3 "$LOGDIR/upstream-unit-tests.log"
echo "upstream unit tests: $UNIT_TESTS"

# ---------------------------------------------------------------------------
build_busybox() {
    cd "$WORK/busybox-$BUSYBOX_VER"
    tr -d '\r' < "$SRC/patches/busybox/0001-httpd-onvif-cgi.patch" | patch -p1 --no-backup-if-mismatch
    make allnoconfig
    # Apply our fragment on top of allnoconfig, then let kconfig resolve it.
    { tr -d '\r' < "$SRC/config/busybox-httpd.fragment"
      echo "CONFIG_CROSS_COMPILER_PREFIX=\"$CROSS\""
      echo "CONFIG_EXTRA_CFLAGS=\"$TARGET_CFLAGS\""
    } | while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        key=${line%%=*}
        sed -i "/^$key=/d; /^# $key is not set/d" .config
        echo "$line" >> .config
    done
    # "yes" dies of SIGPIPE when oldconfig is done; ignore that, keep make's status.
    ( set +o pipefail; yes "" | make oldconfig )
    make -j"$JOBS"
    # Make sure every option we asked for survived kconfig.
    tr -d '\r' < "$SRC/config/busybox-httpd.fragment" | grep -E '^CONFIG_' | while IFS= read -r line; do
        grep -qx "$line" .config || { echo "BusyBox option not applied: $line"; exit 1; }
    done
    cp .config "$WORK/busybox.config"
    cp busybox_unstripped "$WORK/httpd.bin"
}
say "Building BusyBox $BUSYBOX_VER httpd (static, CGI, ONVIF patch)"
run_step busybox build_busybox
grep -E '^CONFIG_(HTTPD|FEATURE_HTTPD|STATIC|FEATURE_IPV6)' "$WORK/busybox.config" || true

# ---------------------------------------------------------------------------
say "Assembling $PKG_NAME"
ONVIF=$WORK/onvif_simple_server
mkdir -p "$PKG"/{bin,etc,www/onvif/wsd,logs,lib}
# Unstripped copies (with symbols) are kept for the instruction-set check
# and for debugging; the package gets stripped binaries.
mkdir -p "$OUT/unstripped"
for b in onvif_simple_server wsd_simple_server httpd; do
    install -m 755 "$WORK/$b.bin" "$OUT/unstripped/$b"
    ${CROSS}strip -o "$PKG/bin/$b" "$WORK/$b.bin"
    chmod 755 "$PKG/bin/$b"
done

# CGI templates must sit next to the CGI: the CGI opens them relative to its
# working directory, and httpd chdir()s into the script's directory.
for d in device_service_files media_service_files deviceio_service_files \
         events_service_files generic_files; do
    cp -r "$ONVIF/$d" "$PKG/www/onvif/"
done
cp -r "$ONVIF/scripts" "$PKG/www/onvif/"
# WS-Discovery templates live under the ONVIF web-root tree (www/onvif/wsd) but
# are NOT linked into the served web root by start.sh, so they are not HTTP-
# reachable; wsd_simple_server reads them from the SD card via its -t option.
cp "$ONVIF"/wsd_files/*.xml "$PKG/www/onvif/wsd/"

for f in start.sh stop.sh status.sh README.md lib/common.sh \
         etc/onvif_simple_server.conf etc/onvif_auth.conf etc/httpd.conf etc/onvif.env; do
    lf_copy "$SRC/package/$f" "$PKG/$f"
done
chmod 755 "$PKG"/*.sh
find "$PKG/www/onvif/scripts" -name '*.sh' -exec sed -i 's/\r$//' {} + -exec chmod 755 {} +
echo "Logs of httpd, wsd_simple_server, the CGI and the control scripts go here." > "$PKG/logs/README.txt"

. "$WORK/buildinfo.env"
cat > "$PKG/VERSION" <<EOF
package=$PKG_NAME
built=$build_date_utc
onvif_simple_server_commit=$ONVIF_HEAD
busybox=$BUSYBOX_VER (httpd applet only, onvif CGI patch)
mbedtls=$MBEDTLS_VER
json-c=$JSONC_TAG
zlib=$ZLIB_VER
toolchain=$toolchain (gcc $gcc, musl 1.2.5)
target=ARM926EJ-S ARMv5TEJ, EABI5, soft-float, static
EOF

# The deployment guide also ships inside the package.
lf_copy "$SRC/docs/deployment-guide.md" "$PKG/deployment-guide.md"

# ---------------------------------------------------------------------------
say "Verifying binaries"
bash "$SRC/tests/check-binaries.sh" "$PKG/bin" "$OUT/unstripped" "$OUT/binary-checks.txt"

say "Testing under QEMU (qemu-arm -cpu arm926)"
TEST_RESULT=PASS
bash "$SRC/tests/run-tests.sh" "$PKG" "$OUT/test-results.txt" || TEST_RESULT=FAIL

# ---------------------------------------------------------------------------
say "Packaging"
cd "$OUT"
lf_copy "$SRC/docs/deployment-guide.md" "$OUT/deployment-guide.md"
# Per-file checksums inside the package (check on the camera: sha256sum -c).
( cd "$PKG" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner     -cf - "$PKG_NAME" | gzip -9n > "$PKG_NAME.tar.gz"
sha256sum "$PKG_NAME.tar.gz" "$PKG_NAME"/bin/* > SHA256SUMS

ONVIF_HEAD=$ONVIF_HEAD ONVIF_DATE=$ONVIF_DATE ONVIF_SUBJ=$ONVIF_SUBJ \
UNIT_TESTS=$UNIT_TESTS TEST_RESULT=$TEST_RESULT \
BUSYBOX_VER=$BUSYBOX_VER MBEDTLS_VER=$MBEDTLS_VER JSONC_TAG=$JSONC_TAG ZLIB_VER=$ZLIB_VER \
WORK=$WORK OUT=$OUT PKG=$PKG LOGDIR=$LOGDIR \
    bash "$SRC/tests/make-report.sh" > "$OUT/build-report.md"

say "Done"
ls -la "$OUT"
echo "tests: $TEST_RESULT   upstream unit tests: $UNIT_TESTS"
[ "$TEST_RESULT" = PASS ] || exit 1
