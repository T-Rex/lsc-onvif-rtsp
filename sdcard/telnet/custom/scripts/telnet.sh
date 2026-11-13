#!/bin/sh
# telnet.sh - keepalive for the bootstrap Telnet service. Reads hack.conf, then
# keeps a telnetd running on TELNET_PORT. If a shadow file is present on the SD
# (a root password was set at build time), telnetd requires a login (user root
# + that password). If not, it falls back to a passwordless root shell so you
# are never locked out of a factory-reset unit. BusyBox /bin/sh.
: "${SD_DIR:=/tmp/sd}"
[ -f "${SD_DIR}/custom/configs/hack.conf" ] || SD_DIR=/mnt
CFG_FILE="${SD_DIR}/custom/configs/hack.conf"
LOCK="/tmp/telnet.sh.pid"

mkdir -p "${SD_DIR}/logs" 2>/dev/null || true
exec >>"${SD_DIR}/logs/telnet.$(date +%Y%m%d_%H%M%S).log" 2>&1
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

# Defaults, overridable from hack.conf.
TELNET=0
TELNET_PORT=24
[ -f "${CFG_FILE}" ] && . "${CFG_FILE}"

[ "${TELNET}" = "1" ] || { log "TELNET != 1, nothing to do"; exit 0; }

# Single-instance guard.
if [ -f "${LOCK}" ] && kill -0 "$(cat "${LOCK}" 2>/dev/null)" 2>/dev/null; then
    log "telnet.sh already running"; exit 0
fi
echo $$ > "${LOCK}"

start_telnetd() {
    if [ -f "${SD_DIR}/shadow" ]; then
        # Login required: root + the password baked into /shadow.
        telnetd -p "${TELNET_PORT}" && log "telnetd (login) started on ${TELNET_PORT}"
    else
        # No password set: passwordless root shell.
        telnetd -p "${TELNET_PORT}" -l /bin/sh && log "telnetd (passwordless) started on ${TELNET_PORT}"
    fi
}

log "keepalive starting (port ${TELNET_PORT}, shadow present: $( [ -f "${SD_DIR}/shadow" ] && echo yes || echo no ))"
while : ; do
    if ps 2>/dev/null | grep -v grep | grep -q "telnetd -p ${TELNET_PORT}"; then
        sleep 3; continue
    fi
    start_telnetd || log "telnetd failed to start; retrying"
    sleep 2
done
