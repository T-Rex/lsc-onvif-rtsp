#!/bin/sh
# backup.sh - snapshot the current persistent ONVIF + PTZ installation to a
# timestamped archive under /mnt/backups, for later restore with restore.sh.
#
#   sh backup.sh [LABEL]
#
# Produces /mnt/backups/onvif-<YYYYmmdd-HHMMSS>[-LABEL].tar (+ a .sha256 sidecar
# used by restore.sh to verify integrity). Read-only with respect to the live
# install; writes only inside /mnt/backups, which lives at the SD-card root so a
# package reinstall never removes the backups. BusyBox /bin/sh; no gzip/tr/python
# (the archive is an uncompressed .tar, like the rest of the recovery tooling).
#
# Env overrides: TARGET (default /mnt/onvif), BACKUPS (default /mnt/backups).
set -u
TARGET=${TARGET:-/mnt/onvif}
BACKUPS=${BACKUPS:-/mnt/backups}
LABEL=${1:-}

fail(){ echo "ABORT: $*" >&2; exit 1; }

[ -d "$TARGET" ] || fail "install dir not found: $TARGET"
[ -f "$TARGET/start.sh" ] && [ -d "$TARGET/bin" ] || fail "$TARGET is not the ONVIF package"
mkdir -p "$BACKUPS" || fail "cannot create $BACKUPS"

# restore.sh expects the archive to contain a top-level onvif/ directory, so tar
# the package by its basename from its parent. Guard against an odd basename.
parent=$(cd "$(dirname "$TARGET")" && pwd) || fail "cannot resolve $TARGET parent"
base=$(basename "$TARGET")
[ "$base" = onvif ] || echo "NOTE: package dir is '$base' (restore.sh expects an onvif/ top dir)"

ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s 2>/dev/null || echo manual)
name="onvif-$ts"
[ -n "$LABEL" ] && name="$name-$(echo "$LABEL" | sed 's/[^A-Za-z0-9._-]/_/g')"
arc="$BACKUPS/$name.tar"
[ -e "$arc" ] && fail "archive already exists: $arc"

echo "=== backup: $TARGET -> $arc ==="
( cd "$parent" && tar -cf "$arc" "$base" ) || { rm -f "$arc"; fail "tar failed"; }

# integrity sidecar (restore.sh verifies the archive against this)
if sum=$(sha256sum "$arc" 2>/dev/null | awk '{print $1}') && [ -n "$sum" ]; then
    printf '%s  %s\n' "$sum" "$name.tar" > "$arc.sha256"
    echo "sha256: $sum"
else
    echo "WARN: sha256sum unavailable; no integrity sidecar written"
fi

sz=$(ls -l "$arc" 2>/dev/null | awk '{print $5}')
echo "OK: backup created (${sz:-?} bytes)"
echo
echo "Existing backups in $BACKUPS (newest last):"
ls -1 "$BACKUPS"/onvif-*.tar 2>/dev/null | sed 's|^|  |' || echo "  (none)"
echo "Restore with:  sh restore.sh latest --commit   (or: sh restore.sh <name> --commit)"
exit 0
