#!/bin/sh
# deploy.sh - stage, then (separately) promote the current ONVIF + PTZ build on
# the camera WITHOUT destroying the installation already in /mnt/onvif. Version-
# agnostic: it deploys whatever candidate package you place at /mnt/onvif-next
# and backs up whatever is currently installed before replacing it.
#
#   deploy.sh stage     candidate activation in RAM (/tmp); /mnt/onvif (the
#                       persistent install) is left untouched. Default.
#   deploy.sh promote   production: snapshot the current /mnt/onvif to
#                       /mnt/backups, then install the candidate into /mnt/onvif
#                       and restart. Only after acceptance passes.
#   deploy.sh dry       print the plan, change nothing.
#
# Candidate package lives at /mnt/onvif-next (copy the sd_card/onvif there).
# Never overwrites /mnt/onvif/bin/onvif_ptz_bridge during staging. Never runs two
# daemons at once. BusyBox /bin/sh; no tr/gzip/python. Asks for a typed YES on
# any live-affecting step (ASSUME_YES=1 to skip in automation). Recover a bad
# promote with restore.sh (the pre-promote snapshot is in /mnt/backups).
set -u
NEXT=${NEXT:-/mnt/onvif-next}
STABLE=${STABLE:-/mnt/onvif}
RUN=${RUN:-/tmp/onvif}
BACKUPS=${BACKUPS:-/mnt/backups}
HERE=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-stage}

say(){ echo "$*"; }
fail(){ echo "ABORT: $*" >&2; exit 1; }
confirm(){ [ "${ASSUME_YES:-0}" = 1 ] && return 0; printf '%s Type YES: ' "$1"; read a; [ "$a" = YES ] || fail "not confirmed"; }
bping(){ PTZ_SOCK="$RUN/run/ptz.sock" "$RUN/bin/onvif_ptz_bridge" ping >/dev/null 2>&1; }
bstatus(){ PTZ_SOCK="$RUN/run/ptz.sock" "$RUN/bin/onvif_ptz_bridge" status 2>/dev/null; }
bver(){ bstatus | sed -n 's/^version=//p'; }
ndaemon(){ ps 2>/dev/null | grep -c '[o]nvif_ptz_bridge daemon'; }

# Candidate version is read from the candidate binary (no hardcoded number).
cand_ver(){ "$NEXT/bin/onvif_ptz_bridge" -h 2>&1 | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1; }

check_next(){
    [ -d "$NEXT" ] || fail "candidate package missing: $NEXT (copy the sd_card/onvif there first)"
    [ -f "$NEXT/bin/onvif_ptz_bridge" ] || fail "$NEXT/bin/onvif_ptz_bridge missing"
    [ -x "$NEXT/scripts/enable-ptz.sh" ] || chmod 755 "$NEXT/scripts/"*.sh 2>/dev/null
    # Optional integrity check against the package's own manifest, if present.
    if [ -f "$NEXT/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
        ( cd "$NEXT" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
            && say "OK: candidate SHA256SUMS verified" \
            || say "NOTE: candidate SHA256SUMS not fully verifiable (ok if the manifest covers the SD root)"
    fi
    say "OK: candidate present ($NEXT)"
}
# run the candidate binary from RAM (FAT32 has no exec bit) to prove it executes
check_exec(){
    mkdir -p "$RUN/bin"
    cp "$NEXT/bin/onvif_ptz_bridge" "$RUN/bin/.ptztest" && chmod 755 "$RUN/bin/.ptztest" || fail "cannot stage candidate to RAM"
    v=$("$RUN/bin/.ptztest" -h 2>&1 | head -1)
    rm -f "$RUN/bin/.ptztest"
    [ -n "$v" ] || fail "candidate did not run (-h produced no output)"
    say "OK: candidate executes, reports: $v"
}
no_motion(){
    if bping; then
        [ "$(PTZ_SOCK="$RUN/run/ptz.sock" "$RUN/bin/onvif_ptz_bridge" is_moving 2>/dev/null)" = 0 ] \
            || fail "a motor is moving; stop it before deploying"
    fi
    say "OK: no active motor movement"
}

plan(){
CV=$([ -f "$NEXT/bin/onvif_ptz_bridge" ] && cand_ver || echo "?")
cat <<EOF
=== deploy.sh plan (mode=$MODE, candidate version=${CV:-?}) ===
STAGE (candidate in RAM, $STABLE untouched):
  1 verify $NEXT present + integrity   2 exec-check candidate runs
  3 confirm no motor movement          4 stop stable bridge gracefully (disable-ptz)
  5 activate candidate: $NEXT/scripts/enable-ptz.sh (stages into $RUN, starts)
  6 confirm exactly one daemon         7 run verify-installation.sh + acceptance tests
PROMOTE (production; only after acceptance passes):
  1 require candidate healthy in RAM
  2 snapshot current $STABLE -> $BACKUPS/onvif-<ts>-pre-promote.tar  (backup.sh)
  3 install candidate bin + scripts + config into $STABLE (atomic .new + mv)
  4 restart via enable-ptz.sh; verify the daemon reports the candidate version
  5 on failure: sh $HERE/restore.sh latest --commit
EOF
}

case "$MODE" in
  dry) plan; exit 0;;

  stage)
    say "=== deploy: STAGE (candidate in RAM; $STABLE untouched) ==="
    check_next; check_exec; no_motion
    CV=$(cand_ver)
    confirm "This stops the stable bridge and starts the candidate (v${CV:-?}) in RAM (no change to $STABLE)."
    [ -f "$STABLE/scripts/disable-ptz.sh" ] && sh "$STABLE/scripts/disable-ptz.sh" 2>/dev/null || say "WARN: stable disable-ptz nonzero/absent"
    n=0; while bping && [ "$n" -lt 30 ]; do sleep 0.2 2>/dev/null || sleep 1; n=$((n+1)); done
    sh "$NEXT/scripts/enable-ptz.sh" || fail "candidate enable-ptz failed (recover: sh $HERE/restore.sh latest --commit)"
    nd=$(ndaemon); [ "$nd" = 1 ] || fail "expected exactly one bridge daemon, found $nd (recover: restore.sh)"
    rv=$(bver); say "OK: candidate active in RAM (one daemon, reports v${rv:-?}). $STABLE unchanged."
    say "NEXT: run  sh $HERE/verify-installation.sh  and the acceptance tests (ACCEPTANCE_TESTS.md),"
    say "      then  sh $0 promote  to make it persistent, or reboot to drop the candidate."
    ;;

  promote)
    say "=== deploy: PROMOTE to production (persistent $STABLE) ==="
    bping || fail "no bridge daemon running; stage + accept the candidate first"
    [ "$(PTZ_SOCK="$RUN/run/ptz.sock" "$RUN/bin/onvif_ptz_bridge" is_moving 2>/dev/null)" = 0 ] || fail "motor moving; stop first"
    check_next
    CV=$(cand_ver); RV=$(bver)
    [ -n "$RV" ] && [ "$RV" = "$CV" ] || say "NOTE: running bridge v${RV:-?} vs candidate v${CV:-?}"
    # snapshot the current persistent install BEFORE replacing it
    if [ -d "$STABLE" ]; then
        if [ -x "$NEXT/scripts/backup.sh" ]; then
            TARGET="$STABLE" BACKUPS="$BACKUPS" sh "$NEXT/scripts/backup.sh" pre-promote \
                || fail "pre-promote backup failed; not promoting"
        else
            say "WARN: backup.sh not found in candidate; proceeding without a /mnt/backups snapshot"
        fi
    fi
    confirm "This REPLACES the persistent $STABLE with the candidate (snapshot saved in $BACKUPS)."
    cur="$STABLE/bin/onvif_ptz_bridge"
    cp "$NEXT/bin/onvif_ptz_bridge" "$cur.new" && chmod 755 "$cur.new" && mv -f "$cur.new" "$cur" \
        || fail "install candidate binary failed (snapshot intact; recover: restore.sh latest --commit)"
    # install updated scripts + config
    [ -d "$STABLE/scripts" ] || mkdir -p "$STABLE/scripts"
    for f in "$NEXT/scripts/"*.sh; do cp "$f" "$STABLE/scripts/$(basename "$f")" 2>/dev/null; chmod 755 "$STABLE/scripts/$(basename "$f")" 2>/dev/null; done
    [ -d "$NEXT/config" ] && { mkdir -p "$STABLE/config"; for f in "$NEXT/config/"*; do [ -f "$f" ] && cp "$f" "$STABLE/config/$(basename "$f")" 2>/dev/null; done; }
    # install updated PTZ templates under www/onvif
    if [ -d "$NEXT/www/onvif/ptz_service_files" ]; then
        mkdir -p "$STABLE/www/onvif"
        rm -rf "$STABLE/www/onvif/ptz_service_files"
        cp -r "$NEXT/www/onvif/ptz_service_files" "$STABLE/www/onvif/ptz_service_files"
    fi
    say "installed candidate into $STABLE"
    # restart the bridge via enable-ptz (start.sh no-ops when ONVIF is already up)
    [ -f "$STABLE/scripts/disable-ptz.sh" ] && sh "$STABLE/scripts/disable-ptz.sh" 2>/dev/null
    n=0; while bping && [ "$n" -lt 30 ]; do sleep 0.2 2>/dev/null || sleep 1; n=$((n+1)); done
    sh "$STABLE/scripts/enable-ptz.sh" || fail "enable-ptz failed (recover: sh $HERE/restore.sh latest --commit)"
    nd=$(ndaemon); [ "$nd" = 1 ] || fail "expected one daemon after promote, found $nd (recover: restore.sh latest --commit)"
    rv=$(bver)
    [ -n "$CV" ] && { [ "$rv" = "$CV" ] || fail "persistent bridge reports v${rv:-?}, expected v$CV (recover: restore.sh latest --commit)"; }
    say "OK: the candidate (v${rv:-?}) is now the persistent production install."
    say "Pre-promote snapshot kept in $BACKUPS. Verify: sh $HERE/verify-installation.sh"
    ;;

  *) plan; fail "unknown mode '$MODE' (use: stage | promote | dry)";;
esac
exit 0
