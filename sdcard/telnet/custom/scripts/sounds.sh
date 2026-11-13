#!/bin/sh
# sounds.sh - silence the loud factory-mode boot voice/beep prompts.
#
# On this firmware the _ht_ap_mode.conf bootstrap puts the camera through its
# factory path, which plays "enter factory mode" / speaker-test voice prompts and
# runs a PTZ self-test with a beep. /usr is read-only SquashFS, so we cannot
# delete those files - instead we bind-mount a tiny silent clip over them for
# this boot only (reverts on reboot without the card). Controlled by hack.conf:
#   MUTE_FACTORY_PROMPT=1  mute just the factory prompts (default)
#   MUTE_ALL_SOUNDS=1      mute every /usr/share/*.mp3
#
# Must run BEFORE anyka_ipc starts (hack.sh launches it first). BusyBox /bin/sh.
# Credit: approach + silent.mp3 from guino/LSCOutdoor1080P via the lsc-tuya-toolkit.
: "${SD_DIR:=/tmp/sd}"
[ -d "${SD_DIR}/custom" ] || SD_DIR=/mnt
CUSTOM_DIR="${SD_DIR}/custom"
CFG_FILE="${CUSTOM_DIR}/configs/hack.conf"
SILENT_FILE="${CUSTOM_DIR}/audio/silent.mp3"

mkdir -p "${SD_DIR}/logs" 2>/dev/null || true
exec >>"${SD_DIR}/logs/sounds.$(date +%Y%m%d_%H%M%S).log" 2>&1
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }

# Defaults (factory prompt is very loud) - overridable from hack.conf.
MUTE_FACTORY_PROMPT=1
MUTE_ALL_SOUNDS=0
[ -f "${CFG_FILE}" ] && . "${CFG_FILE}"

if [ ! -f "${SILENT_FILE}" ]; then
    log "no silent.mp3 at ${SILENT_FILE}; nothing to mute"
    exit 0
fi

mute_one() {
    [ -f "$1" ] || return 0
    if mount --bind "${SILENT_FILE}" "$1" 2>/dev/null; then
        log "muted $1"
    fi
}

if [ "${MUTE_ALL_SOUNDS}" = "1" ]; then
    log "muting ALL /usr/share/*.mp3"
    for f in /usr/share/*.mp3; do mute_one "$f"; done
elif [ "${MUTE_FACTORY_PROMPT}" = "1" ]; then
    log "muting factory prompt clips"
    mute_one /usr/share/hutong_sound2.mp3
    mute_one /usr/share/8k16_cn_factory_enter_factory_mode.mp3
    mute_one /usr/share/8k16_cn_factory_speaker_test_voice.mp3
else
    log "muting disabled (MUTE_FACTORY_PROMPT=0, MUTE_ALL_SOUNDS=0)"
fi
log "sounds.sh done"
