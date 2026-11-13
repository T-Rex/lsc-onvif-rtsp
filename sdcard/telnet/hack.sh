#!/bin/sh
# hack.sh - Telnet bootstrap for a factory-reset LSC Smart Connect PTZ 3007325
# (Anyka AK3918EV330). Run from the SD by the /mnt/hostapd boot hook. It brings
# up a Telnet root shell so you can run the one-time ONVIF autostart installer
# (sh /mnt/install/install-autostart.sh) on a camera that ships with Telnet off.
#
# Runs entirely from RAM + SD. It writes NO flash: the root password (if any) is
# applied by bind-mounting our shadow over the live one for this boot only, so a
# reboot WITHOUT this card leaves the camera exactly as the factory left it.
#
# Credit: boot-chain discovery by guino/LSCOutdoor1080P; adapted from the
# lsc-tuya-toolkit. BusyBox /bin/sh (ash); no bashisms, no tr/gzip.
SD_DIR="/tmp/sd"
SCRIPTS_DIR="${SD_DIR}/custom/scripts"
CONFIG_DIR="${SD_DIR}/custom/configs"
CFG_FILE="${CONFIG_DIR}/hack.conf"

mkdir -p "${SD_DIR}" 2>/dev/null || true
# The SD may already be mounted at /mnt; mount a second view at /tmp/sd so our
# paths are stable regardless of how the firmware mounted it.
mount /dev/mmcblk0p1 "${SD_DIR}" 2>/dev/null \
    || mount /dev/mmcblk0 "${SD_DIR}" 2>/dev/null || true
[ -f "${CFG_FILE}" ] || { SD_DIR="/mnt"; SCRIPTS_DIR="${SD_DIR}/custom/scripts"; CONFIG_DIR="${SD_DIR}/custom/configs"; CFG_FILE="${CONFIG_DIR}/hack.conf"; }

mkdir -p "${SD_DIR}/logs" 2>/dev/null || true
LOG_FILE="${SD_DIR}/logs/telnet-bootstrap.$(date +%Y%m%d_%H%M%S).log"
exec >>"${LOG_FILE}" 2>&1
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

log "telnet bootstrap starting (SD_DIR=${SD_DIR})"

# The firmware can run this boot hook more than once per boot (the Wi-Fi driver
# re-invokes /tmp/hostapd). mkdir is atomic, so only the first instance proceeds;
# a second concurrent/duplicate invocation exits here instead of launching a
# second telnet.sh/wifi.sh (which would fight over the Wi-Fi driver).
if ! mkdir /tmp/.telnet_bootstrap.lock 2>/dev/null; then
    log "bootstrap already ran this boot; exiting"
    exit 0
fi

# Silence the loud factory-mode voice/beep prompts ASAP - before anyka_ipc runs
# its startup/PTZ self-test. Synchronous so the bind-mounts are in place first.
if [ -f "${SCRIPTS_DIR}/sounds.sh" ]; then
    SD_DIR="${SD_DIR}" /bin/sh "${SCRIPTS_DIR}/sounds.sh" >/dev/null 2>&1
    log "ran sounds.sh (factory-prompt mute)"
fi

# NOTE: we do NOT mirror the card to /mnt. On this firmware the AP/bootstrap path
# remounts /mnt as tmpfs later in boot, so any bind we make here does not stick
# (and a transient "/mnt has the card" state used to strand the autostart worker).
# The card lives at /tmp/sd; install-autostart.sh and rtsp_autostart.sh use it
# directly, and the worker auto-detects /tmp/sd (or /mnt on a plain boot).

# Apply the chosen root password, if a shadow file was generated onto the card.
# Bind-mount it over whatever the camera's login consults. Non-persistent.
if [ -f "${SD_DIR}/shadow" ]; then
    for dst in /etc/shadow /etc/config/shadow; do
        [ -e "$dst" ] || touch "$dst" 2>/dev/null || continue
        if mount --bind "${SD_DIR}/shadow" "$dst" 2>/dev/null; then
            log "installed root password via ${dst} (this boot only)"
        fi
    done
else
    log "no /shadow on card -> Telnet will be passwordless (login shell /bin/sh)"
fi

# Launch the Telnet keepalive. Backgrounded; it re-spawns telnetd if it dies.
if [ -f "${SCRIPTS_DIR}/telnet.sh" ]; then
    SD_DIR="${SD_DIR}" /bin/sh "${SCRIPTS_DIR}/telnet.sh" >/dev/null 2>&1 &
    log "launched telnet.sh"
else
    log "ERROR: ${SCRIPTS_DIR}/telnet.sh missing"
fi

# Optional Wi-Fi reconfiguration (join your LAN in STA mode, or set a custom AP).
# Backgrounded: it settles, probes the firmware, and switches wlan0 per wifi.conf.
if [ -f "${SCRIPTS_DIR}/wifi.sh" ]; then
    SD_DIR="${SD_DIR}" /bin/sh "${SCRIPTS_DIR}/wifi.sh" >/dev/null 2>&1 &
    log "launched wifi.sh"
fi

# Optional root FTP keepalive (enabled via FTP=1 in hack.conf). Backgrounded.
if [ -f "${SCRIPTS_DIR}/ftp.sh" ]; then
    SD_DIR="${SD_DIR}" /bin/sh "${SCRIPTS_DIR}/ftp.sh" >/dev/null 2>&1 &
    log "launched ftp.sh"
fi

log "telnet bootstrap done"
