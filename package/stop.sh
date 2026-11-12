#!/bin/sh
# stop.sh - stop ONVIF httpd and WS-Discovery and free the tmpfs runtime dir.
#
#   sh /mnt/onvif/stop.sh
#
# Only processes started from /tmp/onvif/bin are signalled. anyka_ipc and
# therefore RTSP keep running.

SCRIPT=stop
BASE=$(cd "$(dirname "$0")" && pwd)
. "$BASE/lib/common.sh"

lock
msg "=== ONVIF stop ($(ts))"

stop_prog() { # name path
    _pids=$(pids_of "$2")
    if [ -z "$_pids" ]; then
        msg "$1 is not running"
        return 0
    fi
    msg "Stopping $1 (PID $_pids)"
    # wsd_simple_server sends a WS-Discovery Bye on SIGTERM.
    kill $_pids 2>/dev/null
    _n=0
    while [ "$_n" -lt 10 ]; do
        [ -z "$(pids_of "$2")" ] && return 0
        sleep 1
        _n=$((_n + 1))
    done
    _pids=$(pids_of "$2")
    if [ -n "$_pids" ]; then
        msg "$1 did not exit, sending SIGKILL to $_pids"
        kill -9 $_pids 2>/dev/null
        sleep 1
    fi
}

stop_prog wsd_simple_server "$BIN_WSD"
stop_prog httpd "$BIN_HTTPD"

if [ -n "$(pids_of "$BIN_HTTPD")$(pids_of "$BIN_WSD")" ]; then
    msg "ERROR: some ONVIF processes are still running; runtime files kept."
    exit 1
fi

# Free tmpfs. Logs survive: they are on the SD card, or kept in $RUN/log
# when LOG_IN_RAM=1.
rm -rf "$RUN/bin" "$RUN/www" "$RUN/etc" "$RUN/run" "$RUN/wsd" "$RUN/onvif_simple_server.debug"
[ -L "$RUN/log" ] && rm -f "$RUN/log"
rmdir "$RUN" 2>/dev/null
msg "ONVIF stopped."
exit 0
