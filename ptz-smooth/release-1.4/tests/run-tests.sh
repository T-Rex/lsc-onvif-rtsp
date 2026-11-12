#!/bin/bash
# run-tests.sh UNIT_BIN DUR_BIN BRIDGE_BIN
# Unit tests + smooth-daemon integration using a host build of the bridge
# linked against the simulating mock motor. No real hardware.
set -uo pipefail
UNIT=$1; DUR=$2; BRIDGE=$3; EXP_BRIDGE=${4:-}   # $4 = experimental (hw-speed) host bridge, optional

# Track daemon PIDs and kill them on exit. Daemons must not inherit this
# script's stdout (it is piped to tee in build.sh); an open writer would keep
# tee from seeing EOF and hang the build.
ALLPIDS=""
cleanup(){ for p in $ALLPIDS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

mock_tree(){ # pan_pos tilt_pos
    local r; r=$(mktemp -d)
    mkdir -p "$r/sys/devices/platform/motor0/motor" "$r/sys/devices/platform/motor1/motor" "$r/dev" "$r/run" "$r/tmp" "$r/logs"
    printf 'current-pos:%d\n' "${1:-2048}" > "$r/sys/devices/platform/motor0/motor/current_pos"
    printf 'total-steps:4096\n' > "$r/sys/devices/platform/motor0/motor/total_steps"
    printf 'current-pos:%d\n' "${2:-1115}" > "$r/sys/devices/platform/motor1/motor/current_pos"
    printf 'total-steps:2230\n' > "$r/sys/devices/platform/motor1/motor/total_steps"
    : > "$r/dev/motor0"; : > "$r/dev/motor1"
    echo "$r"
}
start_daemon(){ # root  -> sets SOCK; starts $BRIDGE daemon
    R=$1
    export PTZ_SOCK="$R/run/ptz.sock" PTZ_PIDFILE="$R/run/ptz.pid" PTZ_ROOT="$R" \
           PTZ_LOG="$R/logs/bridge.log" PTZ_TICK_MS=20 PTZ_DEF_TIMEOUT_MS=400 PTZ_HARD_TIMEOUT_MS=2000
    "$BRIDGE" daemon >/dev/null 2>&1 & DPID=$!
    ALLPIDS="$ALLPIDS $DPID"
    for i in $(seq 1 50); do "$BRIDGE" ping >/dev/null 2>&1 && break; sleep 0.05; done
}
c(){ "$BRIDGE" "$@"; }

echo "=== A. unit tests ==="
if "$UNIT"; then ok "coords unit"; else no "coords unit"; fi
if "$DUR"; then ok "duration parser unit"; else no "duration parser unit"; fi

echo "=== B. smooth daemon (mock motor) ==="
R=$(mock_tree 2048 1115); start_daemon "$R"
c ping >/dev/null 2>&1 && ok "ping" || no "ping"
c status | grep -q "bridge 1.4" && ok "reports version 1.4" || no "version 1.4"
c status | grep -q "active_speed_profile=compat" && ok "default profile=compat (1.3-identical)" || no "default profile compat"
[ "$(c is_moving)" = 0 ] && ok "idle is_moving=0" || no "idle is_moving"
echo "$(c position)" | grep -Eq '^-?[0-9]' && ok "position format" || no "position format"

# --- smoothness: held full-speed move stays continuously moving, pos advances
p0=$(c position | cut -d, -f1)
c right 1.0 1000 >/dev/null
moving_hits=0
for i in $(seq 1 8); do [ "$(c is_moving)" = 1 ] && moving_hits=$((moving_hits+1)); sleep 0.03; done
p1=$(c position | cut -d, -f1)
c stop all >/dev/null
[ "$moving_hits" -ge 7 ] && ok "continuous while held ($moving_hits/8 moving)" || no "continuous while held ($moving_hits/8)"
awk -v a="$p0" -v b="$p1" 'BEGIN{exit !(b>a)}' && ok "pan position advanced ($p0 -> $p1)" || no "pan advanced ($p0->$p1)"
[ "$(c is_moving)" = 0 ] && ok "stop halts motion" || no "stop halts"

# --- diagnostics + measured rate: mock models the real ~100/s (speed_step/6 at
#     600). The 1.1 scheduler commands ~600/s; observed tracks the driver (~100).
R=$(mock_tree 2048 1115); start_daemon "$R"
c right 1.0 3000 >/dev/null
sleep 1.3
rate=$(c status | sed -n 's/^pan_rate=\([0-9]*\).*/\1/p')
cmdr=$(c status | sed -n 's/^pan_command_rate=\([0-9]*\).*/\1/p')
c stop all >/dev/null
awk -v r="${rate:-0}" 'BEGIN{exit !(r>=40 && r<=260)}' && ok "measured rate tracks HW (~100/s): $rate/s" || no "measured rate ($rate/s)"
awk -v c="${cmdr:-0}" 'BEGIN{exit !(c>=500)}' && ok "bridge commands >= HW (cmd=$cmdr/s, not the limiter)" || no "command rate ($cmdr/s)"
grep -q 'diag:' "$R/logs/bridge.log" && ok "per-second diagnostics logged" || no "diagnostics line"
grep -q 'cmd=' "$R/logs/bridge.log" && ok "diag reports commanded steps/s" || no "diag cmd field"

# --- stop latency is time-bounded: after Stop, position settles quickly
R=$(mock_tree 2048 1115); start_daemon "$R"
c right 1.0 3000 >/dev/null; sleep 0.3
c stop all >/dev/null
p_a=$(c position | cut -d, -f1); sleep 0.25; p_b=$(c position | cut -d, -f1)
awk -v a="$p_a" -v b="$p_b" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<0.02)}' && ok "position settles after stop ($p_a -> $p_b)" || no "stop settle ($p_a->$p_b)"

# --- ContinuousMove without explicit timeout (uses default)
c right 1.0 >/dev/null && ok "ContinuousMove without timeout accepted" || no "no-timeout move"
c stop all >/dev/null

# --- watchdog: no refresh -> stops after the (short) default deadline
R=$(mock_tree); start_daemon "$R"
c right 1.0 300 >/dev/null; sleep 0.15
[ "$(c is_moving)" = 1 ] && ok "moving before deadline" || no "moving before deadline"
sleep 0.4
[ "$(c is_moving)" = 0 ] && ok "watchdog stops a held, unrefreshed move" || no "watchdog stop"

# --- refresh extends the deadline (simulated held joystick resending)
R=$(mock_tree); start_daemon "$R"
c right 1.0 300 >/dev/null
for i in $(seq 1 6); do sleep 0.12; c right 1.0 300 >/dev/null; done   # ~0.72s of refreshes
[ "$(c is_moving)" = 1 ] && ok "refresh keeps moving past original deadline" || no "refresh"
c stop all >/dev/null; sleep 0.45
[ "$(c is_moving)" = 0 ] && ok "stops after refresh ceases" || no "stops after refresh"

# --- stop immediately after start; repeated stop is idempotent
R=$(mock_tree); start_daemon "$R"
c right 1.0 1000 >/dev/null; c stop all >/dev/null
[ "$(c is_moving)" = 0 ] && ok "stop right after start" || no "stop after start"
c stop all >/dev/null; c stop all >/dev/null
[ "$(c is_moving)" = 0 ] && ok "repeated stop stays stopped" || no "repeated stop"

# --- direction reversal
c right 1.0 1000 >/dev/null; sleep 0.1; c left 1.0 1000 >/dev/null; sleep 0.1
[ "$(c is_moving)" = 1 ] && ok "reversal keeps moving" || no "reversal"
c stop all >/dev/null

# --- simultaneous pan + tilt
c right 1.0 1000 >/dev/null; c down 1.0 1000 >/dev/null; sleep 0.1
r=$(c status)
echo "$r" | grep -q 'pan_active=1' && echo "$r" | grep -q 'tilt_active=1' && ok "simultaneous pan+tilt" || no "simultaneous"
c stop all >/dev/null

# --- boundary: start pan near hi (4064), move right -> stops at boundary
R=$(mock_tree 4050 1115); start_daemon "$R"
c right 1.0 2000 >/dev/null; sleep 0.4
[ "$(c is_moving)" = 0 ] && ok "stops at boundary" || no "boundary stop"
px=$(c position | cut -d, -f1)
awk -v x="$px" 'BEGIN{exit !(x<=1.0001)}' && ok "position within bound ($px<=1.0)" || no "position within bound ($px)"

# --- stale / out-of-range position is refused (1.4 §E)
R=$(mock_tree 2048 1115); start_daemon "$R"
printf 'current-pos:999999\n' > "$R/sys/devices/platform/motor0/motor/current_pos"
c right 1.0 1000 >/dev/null 2>&1
[ "$(c is_moving)" = 0 ] && ok "refuse move on out-of-range position" || no "out-of-range not refused"
c status | grep -q 'out of range' && ok "last_error reports out-of-range position" || no "out-of-range last_error"
c ping >/dev/null 2>&1 && ok "daemon survives out-of-range position" || no "daemon crash on bad pos"
R=$(mock_tree 2048 1115); start_daemon "$R"   # fresh daemon for the checks below

# --- invalid velocity / timeout
c right 5 >/dev/null 2>&1; [ $? -ne 0 ] && ok "reject velocity 5" || no "reject velocity 5"
c right 0.5 -100 >/dev/null 2>&1; [ $? -ne 0 ] && ok "reject negative timeout" || no "reject neg timeout"
c right 0 >/dev/null && [ "$(c is_moving)" = 0 ] && ok "zero velocity = no move" || no "zero velocity"

# --- driver MOVE error -> axis stops, daemon survives
R=$(mock_tree); PTZ_FAKE_FAIL=1 start_daemon "$R"
c right 1.0 1000 >/dev/null; sleep 0.1
c ping >/dev/null 2>&1 && ok "daemon survives MOVE errors" || no "daemon crash on move error"
[ "$(c is_moving)" = 0 ] && ok "axis stops on driver error" || no "axis stuck on error"
c shutdown >/dev/null 2>&1

# --- missing sysfs/device -> start refused, daemon survives
R=$(mktemp -d); mkdir -p "$R/run" "$R/logs"   # no sys/dev nodes
start_daemon "$R"
c right 1.0 1000 >/dev/null 2>&1; [ $? -ne 0 ] && ok "refuse move with missing device" || no "missing device not refused"
c ping >/dev/null 2>&1 && ok "daemon survives missing device" || no "daemon crash missing device"
c shutdown >/dev/null 2>&1

# --- worker shutdown during motion is clean
R=$(mock_tree); start_daemon "$R"
c right 1.0 2000 >/dev/null; sleep 0.1
c shutdown >/dev/null && ok "shutdown during motion accepted" || no "shutdown during motion"
wait "$DPID" 2>/dev/null
c ping >/dev/null 2>&1; [ $? -eq 2 ] && ok "client rc=2 after shutdown" || no "post-shutdown rc"

# --- crash + recovery (SIGKILL then restart is idempotent)
R=$(mock_tree); start_daemon "$R"; K=$DPID
kill -9 "$K" 2>/dev/null; wait "$K" 2>/dev/null
start_daemon "$R"
c ping >/dev/null 2>&1 && ok "daemon recovers after crash (stale socket cleared)" || no "crash recovery"
c shutdown >/dev/null 2>&1; wait "$DPID" 2>/dev/null

# --- C. hardware speed PROFILES (1.4 single binary; same $BRIDGE, env-driven) --
echo "=== C. hardware-speed profiles (1.4) ==="
EB="${EXP_BRIDGE:-$BRIDGE}"
ec(){ PTZ_SOCK="$R/run/ptz.sock" "$EB" "$@"; }

# C1 compat default: NO SET_SPEED, speed_step stays 600, rate ~100
R=$(mock_tree 2048 1115)
PTZ_SOCK="$R/run/ptz.sock" PTZ_PIDFILE="$R/run/ptz.pid" PTZ_ROOT="$R" PTZ_LOG="$R/logs/b.log" \
  PTZ_DEF_TIMEOUT_MS=3000 "$EB" daemon >/dev/null 2>&1 & EP=$!; ALLPIDS="$ALLPIDS $EP"
for i in $(seq 1 50); do ec ping >/dev/null 2>&1 && break; sleep 0.05; done
ec status | grep -q 'active_speed_profile=compat' && ok "C1 compat profile default" || no "C1 compat default"
ec status | grep -q 'pan_speed_step=600' && ok "C1 compat keeps speed_step=600 (no SET_SPEED)" || no "C1 compat speed_step"
ec right 1.0 2000 >/dev/null; sleep 0.8; r0=$(ec status | sed -n 's/^pan_rate=\([0-9]*\).*/\1/p'); ec stop all >/dev/null
awk -v r="${r0:-0}" 'BEGIN{exit !(r>=40 && r<=260)}' && ok "C1 compat rate ~100/s ($r0)" || no "C1 compat rate ($r0)"
ec shutdown >/dev/null 2>&1; wait "$EP" 2>/dev/null

# C2 profile=hw, step 750, rate capped ~105 (reproduces the hardware ceiling)
R=$(mock_tree 2048 1115)
PTZ_SOCK="$R/run/ptz.sock" PTZ_PIDFILE="$R/run/ptz.pid" PTZ_ROOT="$R" PTZ_LOG="$R/logs/b.log" \
  PTZ_DEF_TIMEOUT_MS=3000 PTZ_SPEED_PROFILE=hw PTZ_PAN_SPEED_STEP=750 PTZ_FAKE_RATE_CAP=105 \
  "$EB" daemon >/dev/null 2>&1 & EP=$!; ALLPIDS="$ALLPIDS $EP"
for i in $(seq 1 50); do ec ping >/dev/null 2>&1 && break; sleep 0.05; done
ec status | grep -q 'active_speed_profile=hw' && ok "C2 hw profile active" || no "C2 hw profile"
ec right 1.0 2000 >/dev/null; sleep 0.9; rc=$(ec status | sed -n 's/^pan_rate=\([0-9]*\).*/\1/p')
ec status | grep -q 'pan_speed_step=750' && ok "C2 hw applies speed_step=750" || no "C2 applies 750"
ec status | grep -q 'pan_requested_speed=750' && ok "C2 reports requested_speed=750" || no "C2 requested_speed"
ec status | grep -q 'pan_driver_speed=750' && ok "C2 reports driver_speed=750" || no "C2 driver_speed"
awk -v r="${rc:-0}" 'BEGIN{exit !(r>=40 && r<=160)}' && ok "C2 step=750 rate capped ~105/s ($rc)" || no "C2 capped rate ($rc)"
ec stop all >/dev/null; ec shutdown >/dev/null 2>&1; wait "$EP" 2>/dev/null

# C3 per-axis limit / 800 exclusion: request 3000 -> clamped to hard max 750
R=$(mock_tree 2048 1115)
PTZ_SOCK="$R/run/ptz.sock" PTZ_PIDFILE="$R/run/ptz.pid" PTZ_ROOT="$R" PTZ_LOG="$R/logs/b.log" \
  PTZ_DEF_TIMEOUT_MS=2000 PTZ_SPEED_PROFILE=hw PTZ_PAN_SPEED_STEP=3000 \
  "$EB" daemon >/dev/null 2>&1 & EP=$!; ALLPIDS="$ALLPIDS $EP"
for i in $(seq 1 50); do ec ping >/dev/null 2>&1 && break; sleep 0.05; done
ec right 1.0 1500 >/dev/null; sleep 0.3
ec status | grep -q 'pan_requested_speed=750' && ok "C3 over-limit request clamped to 750 (never 800)" || no "C3 clamp"
ec status | grep -q 'pan_speed_step=750' && ok "C3 applied clamp 750" || no "C3 applied clamp"
ec stop all >/dev/null; ec shutdown >/dev/null 2>&1; wait "$EP" 2>/dev/null

# C4 exp750 profile shortcut -> requested 750
R=$(mock_tree 2048 1115)
PTZ_SOCK="$R/run/ptz.sock" PTZ_PIDFILE="$R/run/ptz.pid" PTZ_ROOT="$R" PTZ_LOG="$R/logs/b.log" \
  PTZ_DEF_TIMEOUT_MS=2000 PTZ_SPEED_PROFILE=exp750 \
  "$EB" daemon >/dev/null 2>&1 & EP=$!; ALLPIDS="$ALLPIDS $EP"
for i in $(seq 1 50); do ec ping >/dev/null 2>&1 && break; sleep 0.05; done
ec right 1.0 1200 >/dev/null; sleep 0.2
ec status | grep -q 'pan_requested_speed=750' && ok "C4 exp750 shortcut requests 750" || no "C4 exp750"
ec stop all >/dev/null; ec shutdown >/dev/null 2>&1; wait "$EP" 2>/dev/null

# C5 req != drv diagnostics
R=$(mock_tree 2048 1115)
PTZ_SOCK="$R/run/ptz.sock" PTZ_PIDFILE="$R/run/ptz.pid" PTZ_ROOT="$R" PTZ_LOG="$R/logs/b.log" \
  PTZ_DEF_TIMEOUT_MS=2000 PTZ_SPEED_PROFILE=hw PTZ_PAN_SPEED_STEP=750 PTZ_FAKE_DRV_SPEED=600 \
  "$EB" daemon >/dev/null 2>&1 & EP=$!; ALLPIDS="$ALLPIDS $EP"
for i in $(seq 1 50); do ec ping >/dev/null 2>&1 && break; sleep 0.05; done
ec right 1.0 1500 >/dev/null; sleep 0.4
{ ec status | grep -q 'pan_requested_speed=750' && ec status | grep -q 'pan_driver_speed=600'; } && ok "C5 diag catches requested(750)!=driver(600)" || no "C5 req!=drv diag"
ec stop all >/dev/null; ec shutdown >/dev/null 2>&1; wait "$EP" 2>/dev/null

# C6 SET_SPEED ioctl failure -> still moves at base, error recorded
R=$(mock_tree 2048 1115)
PTZ_SOCK="$R/run/ptz.sock" PTZ_PIDFILE="$R/run/ptz.pid" PTZ_ROOT="$R" PTZ_LOG="$R/logs/b.log" \
  PTZ_DEF_TIMEOUT_MS=2000 PTZ_SPEED_PROFILE=hw PTZ_PAN_SPEED_STEP=750 PTZ_FAKE_SPEED_FAIL=1 \
  "$EB" daemon >/dev/null 2>&1 & EP=$!; ALLPIDS="$ALLPIDS $EP"
for i in $(seq 1 50); do ec ping >/dev/null 2>&1 && break; sleep 0.05; done
ec right 1.0 1500 >/dev/null; sleep 0.3
[ "$(ec is_moving)" = 1 ] && ok "C6 SET_SPEED failure still moves (base speed)" || no "C6 speed-fail fallback"
awk -v e="$(ec status | sed -n 's/^pan_driver_errors=\([0-9]*\).*/\1/p')" 'BEGIN{exit !(e>=1)}' && ok "C6 driver_errors counted on SET_SPEED failure" || no "C6 driver_errors"
ec stop all >/dev/null; ec shutdown >/dev/null 2>&1; wait "$EP" 2>/dev/null

# C7 backward-compat env PTZ_HW_SPEED_ENABLED=1 -> hw profile
R=$(mock_tree 2048 1115)
PTZ_SOCK="$R/run/ptz.sock" PTZ_PIDFILE="$R/run/ptz.pid" PTZ_ROOT="$R" PTZ_LOG="$R/logs/b.log" \
  PTZ_DEF_TIMEOUT_MS=2000 PTZ_HW_SPEED_ENABLED=1 PTZ_PAN_SPEED_STEP=750 \
  "$EB" daemon >/dev/null 2>&1 & EP=$!; ALLPIDS="$ALLPIDS $EP"
for i in $(seq 1 50); do ec ping >/dev/null 2>&1 && break; sleep 0.05; done
ec status | grep -q 'active_speed_profile=hw' && ok "C7 PTZ_HW_SPEED_ENABLED maps to hw profile" || no "C7 compat env"
ec shutdown >/dev/null 2>&1; wait "$EP" 2>/dev/null

echo "=================================================================="
echo "SUMMARY-SMOOTH: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" = 0 ]
