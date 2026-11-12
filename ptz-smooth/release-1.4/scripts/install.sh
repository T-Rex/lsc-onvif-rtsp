#!/bin/sh
# install.sh - overlay the smooth-PTZ build onto an ONVIF package already on the
# SD card. Snapshots the current install to /mnt/backups first (via backup.sh),
# then installs the new binaries, PTZ templates and management scripts. Preserves
# onvif_auth.conf. Does NOT enable PTZ and does NOT move a motor. Does not touch
# start.sh, Wi-Fi, RTSP, anyka_ipc or flash.
#
#   sh install.sh [TARGET_ONVIF_DIR]        (default /mnt/onvif)
#
# Note: a package built with build-sdcard.sh already contains the PTZ overlay, so
# install.sh is only needed to upgrade an older on-card install in place. Recover
# with restore.sh (picks a snapshot from /mnt/backups).
set -u
UP=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:-/mnt/onvif}
BACKUPS=${BACKUPS:-/mnt/backups}
[ -f "$TARGET/start.sh" ] && [ -d "$TARGET/bin" ] || { echo "ERROR: $TARGET is not the ONVIF package"; exit 1; }

echo "=== installing smooth PTZ upgrade into $TARGET ==="

# Snapshot the current install to /mnt/backups before changing anything.
if [ -x "$UP/scripts/backup.sh" ]; then
    TARGET="$TARGET" BACKUPS="$BACKUPS" sh "$UP/scripts/backup.sh" pre-install \
        || { echo "ERROR: pre-install backup failed; not installing"; exit 1; }
else
    echo "WARN: backup.sh not found; proceeding without a /mnt/backups snapshot"
fi

mkdir -p "$TARGET/bin" "$TARGET/www/onvif" "$TARGET/scripts" "$TARGET/config" "$TARGET/logs"

# install new binaries (patched CGI with ONVIF Timeout + smooth bridge)
[ -f "$UP/bin/onvif_simple_server" ] && cp "$UP/bin/onvif_simple_server" "$TARGET/bin/onvif_simple_server" && echo "installed patched CGI"
cp "$UP/bin/onvif_ptz_bridge" "$TARGET/bin/onvif_ptz_bridge" && echo "installed smooth bridge"

rm -rf "$TARGET/www/onvif/ptz_service_files"
cp -r "$UP/www/onvif/ptz_service_files" "$TARGET/www/onvif/ptz_service_files"
echo "installed ptz_service templates (www/onvif/ptz_service_files)"

for s in common-ptz.sh enable-ptz.sh disable-ptz.sh ptz-status.sh \
         deploy.sh backup.sh restore.sh verify-installation.sh; do
    [ -f "$UP/scripts/$s" ] && cp "$UP/scripts/$s" "$TARGET/scripts/$s"
done
echo "installed management scripts"

# optional speed-profile config examples (do not overwrite a live .env)
for c in "$UP/config/"*.example; do
    [ -f "$c" ] && cp "$c" "$TARGET/config/$(basename "$c")"
done

echo
echo "Done. PTZ is installed but NOT active (no motor moves)."
echo "Next:"
echo "  1. restart ONVIF (loads patched CGI): sh $TARGET/stop.sh && sh $TARGET/start.sh"
echo "  2. read-only checks:                  sh $TARGET/scripts/verify-installation.sh"
echo "  3. activate smooth PTZ:               sh $TARGET/scripts/enable-ptz.sh"
echo "Recover a previous install:             sh $TARGET/scripts/restore.sh list"
exit 0
