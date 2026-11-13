# common.sh - helpers shared by start.sh, stop.sh and status.sh.
# Sourced with ".", so it needs no execute permission (FAT32-safe).
# POSIX sh / BusyBox ash only.

# BASE must be set by the caller (directory of the package on the SD card).

# Runtime directory on tmpfs. This path is compiled into onvif_simple_server
# (config file, log file) and wsd_simple_server (log file); do not change it
# here without rebuilding.
RUN=/tmp/onvif

BIN_HTTPD=$RUN/bin/httpd
BIN_WSD=$RUN/bin/wsd_simple_server
BIN_CGI=$RUN/bin/onvif_simple_server
WSD_PID_FILE=$RUN/run/wsd_simple_server.pid
LOCK_DIR=/tmp/onvif.lock

SRC_CONF=$BASE/etc/onvif_simple_server.conf
SRC_AUTH=$BASE/etc/onvif_auth.conf
SRC_HTTPD_CONF=$BASE/etc/httpd.conf
RUN_CONF=$RUN/etc/onvif_simple_server.conf

# CGI endpoints that are linked into the web root. Only services that this
# deployment advertises: no ptz_service, media2_service or imaging_service.
ONVIF_SERVICES="device_service media_service deviceio_service events_service"

# Defaults; etc/onvif.env may override them.
WAIT_IP_SECS=60
LOG_IN_RAM=0
WSD_DEBUG=0
HTTPD_VERBOSE=0
MIN_TMP_FREE_KB=2048
QEMU=""
# Carriage-return byte. This camera's BusyBox has no `tr` applet, so we strip CR
# from Windows-edited config files with sed matching this literal byte instead.
CR=$(printf '\r')
if [ -f "$BASE/etc/onvif.env" ]; then
    # Strip CR in case the file was edited on Windows.
    eval "$(sed "s/$CR\$//" "$BASE/etc/onvif.env" | sed -n 's/^\([A-Z_][A-Z0-9_]*\)=\(.*\)$/\1=\2/p')"
fi
# Test hook: build.sh runs the ARM binaries through QEMU with ONVIF_QEMU set.
# It is never set on the camera.
[ -n "${ONVIF_QEMU:-}" ] && QEMU=$ONVIF_QEMU

if [ "$LOG_IN_RAM" = 1 ]; then
    LOGS=$RUN/log
else
    LOGS=$BASE/logs
fi
CONTROL_LOG=$LOGS/onvif-control.log

ts() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }

# have CMD - true if CMD is available. Uses "type" (always built into ash);
# "command -v" depends on an optional BusyBox ash feature.
have() { type "$1" >/dev/null 2>&1; }

# msg TEXT - print to the console and append to the control log.
msg() {
    echo "$*"
    [ -d "$LOGS" ] && echo "$(ts) [$SCRIPT] $*" >> "$CONTROL_LOG" 2>/dev/null
    return 0
}

# conf_get KEY [FILE] - first value of KEY= in an onvif_simple_server style file.
conf_get() {
    sed -n "/^$1=/{s/^$1=//;s/$CR\$//;p;q;}" "${2:-$SRC_CONF}" 2>/dev/null
}

# conf_all KEY [FILE] - all values of KEY=, space separated.
conf_all() {
    _v=""
    for _x in $(sed -n "s/^$1=//p" "${2:-$SRC_CONF}" 2>/dev/null | sed "s/$CR\$//"); do
        _v="$_v $_x"
    done
    echo "${_v# }"
}

# pids_of PATH - PIDs whose command line contains PATH. The last character is
# wrapped in [] so that grep does not match its own command line.
pids_of() {
    _p=$1
    _re="$(echo "$_p" | sed 's/.$//')[$(echo "$_p" | sed 's/.*\(.\)$/\1/')]"
    for _f in $(grep -l "$_re" /proc/[0-9]*/cmdline 2>/dev/null); do
        _pid=${_f#/proc/}
        _pid=${_pid%/cmdline}
        [ "$_pid" = "$$" ] && continue
        echo "$_pid"
    done
}

# iface_ip IFACE - IPv4 address of an interface, empty if none.
iface_ip() {
    _ip=""
    if have ip; then
        _ip=$(ip -4 addr show dev "$1" 2>/dev/null | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | sed -n 1p)
    fi
    if [ -z "$_ip" ] && have ifconfig; then
        _ip=$(ifconfig "$1" 2>/dev/null | sed -n 's/.*inet addr: *\([0-9.]*\).*/\1/p; s/.*inet \([0-9.]*\) .*/\1/p' | sed -n 1p)
    fi
    echo "$_ip"
}

# hexport PORT - port number as in /proc/net/{tcp,udp}.
hexport() { printf '%04X' "$1"; }

# tcp_listening PORT - true if something listens on TCP PORT (IPv4 or IPv6).
tcp_listening() {
    _h=$(hexport "$1")
    grep -q "^ *[0-9]*: [0-9A-F]*:$_h [0-9A-F]*:[0-9A-F]* 0A" /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# udp_bound PORT - true if a UDP socket is bound to PORT.
udp_bound() {
    _h=$(hexport "$1")
    grep -q "^ *[0-9]*: [0-9A-F]*:$_h " /proc/net/udp /proc/net/udp6 2>/dev/null
}

lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        # Stale lock from an interrupted run?
        _lp=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$_lp" ] && [ -d "/proc/$_lp" ]; then
            echo "Another start/stop is running (PID $_lp)." >&2
            exit 1
        fi
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" || exit 1
    fi
    echo $$ > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    trap 'exit 1' INT TERM HUP
}
