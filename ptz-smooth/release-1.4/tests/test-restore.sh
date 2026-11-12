#!/bin/sh
# test-restore.sh - offline tests for the hardened restore.sh.
# Exercises: dry-run, successful staged restore, SHA mismatch (abort, live
# untouched), bad archive structure (abort, live untouched), and the
# health-failure ROLLBACK path (previous installation put back, never missing).
# POSIX sh; uses a sandbox, no real /mnt. Run on the dev host (busybox or bash).
set -u
SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/scripts/restore.sh
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# Build a sandbox: an original (live) install + a recovery archive containing a
# DIFFERENT install, so a rollback is detectable by which marker survives.
setup(){
    SB=$(mktemp -d)
    mkdir -p "$SB/mnt/onvif/bin" "$SB/mnt/onvif/scripts" "$SB/rec"
    echo "LIVE" > "$SB/mnt/onvif/MARKER"            # marks the original install
    : > "$SB/mnt/onvif/start.sh"; : > "$SB/mnt/onvif/stop.sh"
    # staged (archive) install
    AR=$(mktemp -d)
    mkdir -p "$AR/onvif/bin" "$AR/onvif/scripts"
    echo "RESTORED" > "$AR/onvif/MARKER"
    : > "$AR/onvif/start.sh"; : > "$AR/onvif/stop.sh"
    printf 'STABLEBIN-v1.3\n' > "$AR/onvif/bin/onvif_ptz_bridge"
    ( cd "$AR" && tar -cf "$SB/rec/onvif-working.tar" onvif )
    ARCHIVE="$SB/rec/onvif-working.tar"
    ARCH_SHA=$(sha256sum "$ARCHIVE" | awk '{print $1}')
    BIN_SHA=$(sha256sum "$AR/onvif/bin/onvif_ptz_bridge" | awk '{print $1}')
    rm -rf "$AR"
}
run(){ # extra env... ; sets OUT and RC
    OUT=$(env REC="$SB/rec" ARCHIVE="$ARCHIVE" EXPECT_SHA="$ARCH_SHA" \
        TARGET="$SB/mnt/onvif" MNT="$SB/mnt" STABLE_BIN=bin/onvif_ptz_bridge \
        STABLE_BIN_SHA="$BIN_SHA" ASSUME_YES=1 "$@" sh "$SCRIPT" ${CMT:-} 2>&1); RC=$?
}

echo "=== restore.sh offline tests ==="

# 1. dry-run leaves the live install untouched
setup; CMT="" run
[ "$RC" = 0 ] && echo "$OUT" | grep -q "DRY-RUN" && ok "dry-run exits 0 with plan" || no "dry-run"
[ "$(cat "$SB/mnt/onvif/MARKER")" = LIVE ] && ok "dry-run leaves live untouched" || no "dry-run touched live"
rm -rf "$SB"

# 2. successful staged restore (healthy) swaps in the archived install
setup; CMT="--commit" HEALTH_CMD=true START_CMD=true STOP_CMD=true run
[ "$RC" = 0 ] && ok "commit healthy exits 0" || no "commit healthy rc=$RC ($OUT)"
[ "$(cat "$SB/mnt/onvif/MARKER" 2>/dev/null)" = RESTORED ] && ok "live replaced by restored install" || no "restore swap"
ls -d "$SB/mnt/onvif.prev-"* >/dev/null 2>&1 && ok "previous install preserved (prev-*)" || no "prev preserved"
rm -rf "$SB"

# 3. SHA mismatch aborts and leaves live untouched
setup
OUT=$(env REC="$SB/rec" ARCHIVE="$ARCHIVE" EXPECT_SHA=deadbeef TARGET="$SB/mnt/onvif" MNT="$SB/mnt" \
    STABLE_BIN=bin/onvif_ptz_bridge STABLE_BIN_SHA="$BIN_SHA" ASSUME_YES=1 sh "$SCRIPT" --commit 2>&1); RC=$?
[ "$RC" != 0 ] && echo "$OUT" | grep -q "SHA mismatch" && ok "SHA mismatch aborts" || no "SHA mismatch abort"
[ "$(cat "$SB/mnt/onvif/MARKER")" = LIVE ] && ok "SHA mismatch leaves live untouched" || no "SHA mismatch touched live"
rm -rf "$SB"

# 4. bad archive structure (no onvif/) aborts before touching live
setup
BADAR="$SB/rec/bad.tar"; mkdir -p "$SB/junk/notonvif"; ( cd "$SB/junk" && tar -cf "$BADAR" notonvif )
BAD_SHA=$(sha256sum "$BADAR" | awk '{print $1}')
OUT=$(env REC="$SB/rec" ARCHIVE="$BADAR" EXPECT_SHA="$BAD_SHA" TARGET="$SB/mnt/onvif" MNT="$SB/mnt" \
    STABLE_BIN=bin/onvif_ptz_bridge STABLE_BIN_SHA="$BIN_SHA" ASSUME_YES=1 sh "$SCRIPT" --commit 2>&1); RC=$?
[ "$RC" != 0 ] && echo "$OUT" | grep -q "onvif/ top directory" && ok "bad structure aborts" || no "bad structure abort"
[ "$(cat "$SB/mnt/onvif/MARKER")" = LIVE ] && ok "bad structure leaves live untouched" || no "bad structure touched live"
rm -rf "$SB"

# 5. health failure after swap -> ROLLBACK restores the original (never missing)
setup; OUT=$(env REC="$SB/rec" ARCHIVE="$ARCHIVE" EXPECT_SHA="$ARCH_SHA" TARGET="$SB/mnt/onvif" MNT="$SB/mnt" \
    STABLE_BIN=bin/onvif_ptz_bridge STABLE_BIN_SHA="$BIN_SHA" ASSUME_YES=1 \
    START_CMD=true STOP_CMD=true HEALTH_CMD=false sh "$SCRIPT" --commit 2>&1); RC=$?
[ "$RC" != 0 ] && echo "$OUT" | grep -q "rolling back" && ok "health failure triggers rollback" || no "rollback trigger ($OUT)"
[ -d "$SB/mnt/onvif" ] && ok "TARGET exists after rollback (never missing)" || no "TARGET missing after rollback"
[ "$(cat "$SB/mnt/onvif/MARKER" 2>/dev/null)" = LIVE ] && ok "rollback restored ORIGINAL install" || no "rollback wrong content"
ls -d "$SB/mnt/onvif.failed-"* >/dev/null 2>&1 && ok "failed candidate kept for diagnosis" || no "failed candidate kept"
rm -rf "$SB"

echo "=================================================================="
echo "SUMMARY-RESTORE: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" = 0 ]
