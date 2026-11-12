#!/bin/sh
# restore.sh - restore a previously saved ONVIF + PTZ installation from a
# timestamped backup under /mnt/backups, SAFELY (staged + health-checked +
# auto-rollback). Version-agnostic: it restores whatever a backup contains, so
# it works for the current release and any older snapshot you kept.
#
# Key safety property: the archive is extracted into a STAGING directory on the
# same filesystem and fully validated BEFORE the live /mnt/onvif is touched.
# Activation is an atomic-ish rename; if the restarted services are unhealthy the
# previous installation is put back. /mnt/onvif is therefore never left missing.
#
#   sh restore.sh                     # list available backups + usage (no change)
#   sh restore.sh list                # same as above
#   sh restore.sh latest              # dry-run plan for the newest backup
#   sh restore.sh latest --commit     # restore the newest backup (asks for YES)
#   sh restore.sh <name> --commit     # restore a specific backup (name or path)
#
# Backups are created by backup.sh (and automatically by deploy.sh promote).
# Each archive is verified against its <archive>.sha256 sidecar when present.
#
# BusyBox ash / POSIX sh. No gzip, no tr (archives are uncompressed .tar).
# Non-destructive: the replaced installation is kept as /mnt/onvif.prev-<ts>.
#
# Advanced / test overrides (used by tests/test-restore.sh offline): set ARCHIVE
# to bypass the /mnt/backups chooser, plus EXPECT_SHA, TARGET, MNT, STABLE_BIN,
# STABLE_BIN_SHA, STOP_CMD, START_CMD, HEALTH_CMD, ASSUME_YES=1.
set -u

BACKUPS=${BACKUPS:-/mnt/backups}
TARGET=${TARGET:-/mnt/onvif}
MNT=${MNT:-/mnt}
STABLE_BIN=${STABLE_BIN:-bin/onvif_ptz_bridge}      # path INSIDE the extracted onvif/
STAGE="$MNT/.onvif-stage.$$"
PREV="$TARGET.prev-$(date +%s 2>/dev/null || echo old)"

fail(){ echo "ABORT: $*" >&2; exit 1; }
cleanup_stage(){ [ -d "$STAGE" ] && rm -rf "$STAGE" 2>/dev/null; }

# ---- parse args: a selector and/or --commit, in any order ------------------
COMMIT=0; sel=""
for a in "$@"; do
    case "$a" in
        --commit) COMMIT=1 ;;
        *) [ -z "$sel" ] && sel="$a" ;;
    esac
done

list_backups(){ ls -1 "$BACKUPS"/onvif-*.tar 2>/dev/null | LC_ALL=C sort; }

# ---- choose the archive ----------------------------------------------------
# ARCHIVE preset in the environment (advanced/test) bypasses the chooser.
if [ -z "${ARCHIVE:-}" ]; then
    case "${sel:-list}" in
        list|"")
            echo "=== restore.sh: available backups in $BACKUPS ==="
            n=0
            for f in $(list_backups); do
                n=$((n+1))
                sz=$(ls -l "$f" 2>/dev/null | awk '{print $5}')
                echo "  $(basename "$f")   (${sz:-?} bytes)$( [ -f "$f.sha256" ] && echo '  [sha256 ok-to-verify]')"
            done
            [ "$n" = 0 ] && echo "  (none - create one with: sh backup.sh)"
            echo
            echo "Restore:  sh restore.sh latest --commit        # newest"
            echo "          sh restore.sh <name> --commit        # a specific backup above"
            echo "Omit --commit for a dry-run plan that changes nothing."
            exit 0
            ;;
        latest)
            ARCHIVE=$(list_backups | tail -1)
            [ -n "$ARCHIVE" ] || fail "no backups in $BACKUPS (create one with backup.sh)"
            ;;
        *)
            if   [ -f "$sel" ];              then ARCHIVE="$sel"
            elif [ -f "$BACKUPS/$sel" ];     then ARCHIVE="$BACKUPS/$sel"
            elif [ -f "$BACKUPS/$sel.tar" ]; then ARCHIVE="$BACKUPS/$sel.tar"
            else fail "backup not found: $sel  (list them with: sh restore.sh list)"; fi
            ;;
    esac
fi

# Expected archive SHA: env override, else the sidecar written by backup.sh.
if [ -z "${EXPECT_SHA:-}" ] && [ -f "$ARCHIVE.sha256" ]; then
    EXPECT_SHA=$(awk '{print $1; exit}' "$ARCHIVE.sha256" 2>/dev/null)
fi

echo "=== restore.sh (archive=$ARCHIVE commit=$COMMIT) ==="

# 1. archive present + SHA (if known) + readable structure
[ -f "$ARCHIVE" ] || fail "archive not found: $ARCHIVE"
if [ -n "${EXPECT_SHA:-}" ]; then
    have_sha=$(sha256sum "$ARCHIVE" 2>/dev/null | awk '{print $1}')
    [ "$have_sha" = "$EXPECT_SHA" ] || fail "archive SHA mismatch: got ${have_sha:-none} expected $EXPECT_SHA"
    echo "OK: archive verified ($ARCHIVE, sha $have_sha)"
else
    echo "WARN: no expected SHA for $ARCHIVE (no sidecar); skipping integrity check"
fi
tar -tf "$ARCHIVE" >/dev/null 2>&1 || fail "archive not readable (tar -tf failed)"
tar -tf "$ARCHIVE" 2>/dev/null | grep -q '^onvif/' || fail "archive does not contain an onvif/ top directory"

# 2. free space on the target filesystem (need room for a second copy)
free_kb=$(df -k "$MNT" 2>/dev/null | awk 'END{print $4}')
case "$free_kb" in ''|*[!0-9]*) echo "WARN: cannot read free space on $MNT";;
  *) [ "$free_kb" -gt 20000 ] || fail "low free space on $MNT (${free_kb}KB < 20000)";; esac
echo "OK: $MNT free ${free_kb:-?} KB"

if [ "$COMMIT" != 1 ]; then
    echo "Plan (safe staged restore):"
    echo "  1) extract archive -> $STAGE (same filesystem, live install untouched)"
    echo "  2) validate staged files + exec bits${STABLE_BIN_SHA:+ + stable binary SHA}"
    echo "  3) stop services gracefully (disable-ptz + stop.sh; anyka_ipc/RTSP left alone)"
    echo "  4) mv $TARGET -> $PREV ; mv $STAGE/onvif -> $TARGET   (atomic-ish swap)"
    echo "  5) start services ; validate health"
    echo "  6) on failure: put $PREV back as $TARGET (never left missing)"
    echo "DRY-RUN only. Re-run with --commit to execute (asks for a typed YES)."
    exit 0
fi

if [ "${ASSUME_YES:-0}" != 1 ]; then
    printf 'Type YES to restore (stops ONVIF/PTZ, replaces %s): ' "$TARGET"
    read ans
    [ "$ans" = YES ] || fail "not confirmed"
fi

trap cleanup_stage EXIT INT TERM

# 3. extract into staging FIRST (live install untouched); fail cleanly
cleanup_stage
mkdir -p "$STAGE" || fail "cannot create staging dir $STAGE"
tar -xf "$ARCHIVE" -C "$STAGE" || fail "extract into staging failed (live $TARGET untouched)"
[ -d "$STAGE/onvif" ] || fail "staging has no onvif/ after extract (live $TARGET untouched)"

# 4. validate staged content: required files, exec bits, optional stable-bin SHA
for f in start.sh stop.sh; do
    [ -e "$STAGE/onvif/$f" ] || fail "staged install missing required file: $f (live $TARGET untouched)"
done
if [ -n "${STABLE_BIN_SHA:-}" ]; then
    sbin="$STAGE/onvif/$STABLE_BIN"
    [ -e "$sbin" ] || fail "staged install missing $STABLE_BIN (live $TARGET untouched)"
    sb_sha=$(sha256sum "$sbin" 2>/dev/null | awk '{print $1}')
    [ "$sb_sha" = "$STABLE_BIN_SHA" ] || fail "staged stable binary SHA mismatch: got ${sb_sha:-none} expected $STABLE_BIN_SHA (live $TARGET untouched)"
    echo "OK: staged stable binary verified (sha $sb_sha)"
fi
# FAT32 drops exec bits; make scripts/bins runnable in the staged copy
chmod 755 "$STAGE/onvif/start.sh" "$STAGE/onvif/stop.sh" 2>/dev/null
[ -d "$STAGE/onvif/scripts" ] && chmod 755 "$STAGE/onvif/scripts/"*.sh 2>/dev/null
[ -d "$STAGE/onvif/bin" ] && chmod 755 "$STAGE/onvif/bin/"* 2>/dev/null
echo "OK: staged install validated"

# 5. stop services gracefully (no kill -9)
echo "stopping services gracefully..."
if [ -n "${STOP_CMD:-}" ]; then
    sh -c "$STOP_CMD" || echo "WARN: STOP_CMD returned nonzero"
else
    [ -f "$TARGET/scripts/disable-ptz.sh" ] && sh "$TARGET/scripts/disable-ptz.sh" 2>/dev/null || echo "WARN: disable-ptz nonzero/absent"
    [ -f "$TARGET/stop.sh" ] && sh "$TARGET/stop.sh" 2>/dev/null || echo "WARN: stop.sh nonzero/absent"
fi

# 6. atomic-ish swap: move current aside, move staged into place
if [ -e "$TARGET" ]; then
    mv "$TARGET" "$PREV" || fail "cannot move $TARGET aside (still present; nothing lost)"
fi
if ! mv "$STAGE/onvif" "$TARGET"; then
    echo "ERROR: activating staged install failed; restoring previous installation" >&2
    [ -e "$PREV" ] && mv "$PREV" "$TARGET"
    fail "activation move failed (previous installation restored)"
fi
echo "activated staged install as $TARGET (previous kept at $PREV)"

# 7. start services + validate health; roll back on failure
echo "starting services..."
start_rc=0
if [ -n "${START_CMD:-}" ]; then
    sh -c "$START_CMD" || start_rc=$?
else
    [ -f "$TARGET/start.sh" ] && { sh "$TARGET/start.sh" || start_rc=$?; } || start_rc=1
fi

health_rc=0
if [ -n "${HEALTH_CMD:-}" ]; then
    sh -c "$HEALTH_CMD" || health_rc=$?
else
    # default health: a bridge responds OR the stable bin exists + ports look up
    sp=$(ls /sys/devices/platform/motor0/motor/speed_step /sys/devices/*/motor0/motor/speed_step /sys/*/motor0/motor/speed_step 2>/dev/null | head -1)
    [ -n "$sp" ] && grep -q '600' "$sp" 2>/dev/null || health_rc=1
fi

if [ "$start_rc" != 0 ] || [ "$health_rc" != 0 ]; then
    echo "ERROR: post-restore services unhealthy (start_rc=$start_rc health_rc=$health_rc); rolling back" >&2
    if [ -n "${STOP_CMD:-}" ]; then sh -c "$STOP_CMD" 2>/dev/null; else [ -f "$TARGET/stop.sh" ] && sh "$TARGET/stop.sh" 2>/dev/null; fi
    mv "$TARGET" "$TARGET.failed-$(date +%s 2>/dev/null || echo x)" 2>/dev/null
    [ -e "$PREV" ] && mv "$PREV" "$TARGET" || fail "rollback could not restore $TARGET from $PREV"
    if [ -n "${START_CMD:-}" ]; then sh -c "$START_CMD" 2>/dev/null; else [ -f "$TARGET/start.sh" ] && sh "$TARGET/start.sh" 2>/dev/null; fi
    fail "restore failed health check; previous installation put back and restarted"
fi

cleanup_stage
echo "=== restore OK. Verify: RTSP/ONVIF/WSD up, one bridge, speed_step 600/600, Stop, boundaries. ==="
echo "Previous installation kept at: $PREV (remove manually once satisfied)."
exit 0
