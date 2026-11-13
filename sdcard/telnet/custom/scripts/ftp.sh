#!/bin/sh
# ftp.sh - optional root FTP (BusyBox ftpd via tcpsvd) for the bootstrap card.
# Handy for pushing files to the camera without re-writing the SD. Reads
# FTP / FTP_PORT from hack.conf; keepalive respawns ftpd if it dies. Serves / as
# root (no login, like the camera's factory FTP). Off by default (FTP=0).
# Credit: approach from guino/LSCOutdoor1080P via lsc-tuya-toolkit. BusyBox /bin/sh.
: "${SD_DIR:=/tmp/sd}"
[ -f "${SD_DIR}/custom/configs/hack.conf" ] || SD_DIR=/mnt
CFG_FILE="${SD_DIR}/custom/configs/hack.conf"
LOCK=/tmp/ftp.sh.pid

mkdir -p "${SD_DIR}/logs" 2>/dev/null || true
exec >>"${SD_DIR}/logs/ftp.$(date +%Y%m%d_%H%M%S).log" 2>&1
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

# Defaults, overridable from hack.conf.
FTP=0
FTP_PORT=21
[ -f "${CFG_FILE}" ] && . "${CFG_FILE}"

[ "${FTP}" = "1" ] || { log "FTP != 1, nothing to do"; exit 0; }

# Single-instance guard.
if [ -f "${LOCK}" ] && kill -0 "$(cat "${LOCK}" 2>/dev/null)" 2>/dev/null; then
    log "ftp.sh already running"; exit 0
fi
echo $$ > "${LOCK}"

command -v tcpsvd >/dev/null 2>&1 || { log "tcpsvd missing; cannot serve FTP"; exit 0; }
command -v ftpd  >/dev/null 2>&1 || { log "ftpd missing; cannot serve FTP"; exit 0; }

log "keepalive starting (port ${FTP_PORT})"
while : ; do
    if ps 2>/dev/null | grep -v grep | grep -q "tcpsvd 0 ${FTP_PORT}"; then
        sleep 3; continue
    fi
    tcpsvd 0 "${FTP_PORT}" ftpd -w / -t 1800 >/dev/null 2>&1 &
    log "ftpd started on ${FTP_PORT}"
    sleep 2
done
