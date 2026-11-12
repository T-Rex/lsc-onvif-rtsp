# common-ptz.sh - shared values for the smooth PTZ upgrade scripts.
# Sourced (".") by the others. POSIX sh / BusyBox ash. BASE = ONVIF package dir.
RUN=/tmp/onvif
WEB=$RUN/www/onvif
BIN_CGI=$RUN/bin/onvif_simple_server
RUN_CONF=$RUN/etc/onvif_simple_server.conf

CGI_SD=$BASE/bin/onvif_simple_server
BRIDGE_SD=$BASE/bin/onvif_ptz_bridge
BRIDGE_RUN=$RUN/bin/onvif_ptz_bridge
PTZ_TPL_SD=$BASE/www/onvif/ptz_service_files
PTZ_SOCK=$RUN/run/ptz.sock
PTZ_PID=$RUN/run/ptz.pid
PTZ_LOG=$BASE/logs/onvif_ptz_bridge.log

PTZ_BEGIN='#--- onvif-ptz-smooth begin (managed, do not edit) ---'
PTZ_END='#--- onvif-ptz-smooth end ---'

say(){ echo "$*"; }
have(){ type "$1" >/dev/null 2>&1; }
bridge_alive(){ [ -x "$BRIDGE_RUN" ] && "$BRIDGE_RUN" ping >/dev/null 2>&1; }

# PTZ config block. The CGI appends the (validated) ONVIF Timeout in ms to each
# move command, so the bridge receives e.g. "right 0.50 5000".
emit_ptz_block(){
    cat <<EOF
$PTZ_BEGIN
ptz=1
min_step_x=-1.0
max_step_x=1.0
min_step_y=-1.0
max_step_y=1.0
get_position=$BRIDGE_RUN position
is_moving=$BRIDGE_RUN is_moving
move_left=$BRIDGE_RUN left %f
move_right=$BRIDGE_RUN right %f
move_up=$BRIDGE_RUN up %f
move_down=$BRIDGE_RUN down %f
move_stop=$BRIDGE_RUN stop %s
$PTZ_END
EOF
}

# Escape a literal string for use as a sed address (basic regex).
sed_lit(){ printf '%s' "$1" | sed 's/[][\\/.*^$]/\\&/g'; }
