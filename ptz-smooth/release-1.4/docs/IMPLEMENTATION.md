# IMPLEMENTATION — onvif_ptz_bridge 1.4

Source: `release-1.4/src/{bridge.c,bridge.h,coords.c,log.c}` +
`release-1.4/src/ptz-control/{motor.c,sysfs.c,dev_linux.c,motor.h,ak_motor_abi.h}`.
Only `bridge.c`/`bridge.h` changed vs 1.3; the device/ioctl layer and the pure
coord math are unchanged and still unit-tested.

## Architecture (unchanged from 1.3)
A single daemon owns the motor descriptors and drives motion with an event-loop
`poll()` on a Unix socket. CLI invocations are thin clients. `/dev/motor{0,1}`
are opened once per motion session and kept open (the driver auto-stops on
close). MOVE (`0x40046d40`) is asynchronous and *extends* a same-direction move,
so a small velocity-scaled cushion is fed every `SM_TICK_MS` (20 ms) and the
motor never halts between feeds. ONVIF velocity is approximated by **duty cycle**
(steps fed per tick), bounded by `SM_MAX_PER_TICK`.

## A. Hardware speed control
- `dev_set_speed()` issues the verified `SET_SPEED` ioctl `0x40046d20` (writes
  the driver's `speed_step` directly; sysfs `speed_step` is read-only, so a
  clean close re-SET to 600 — or a reboot — is the only way back).
- Profile selection in `main()`: `PTZ_SPEED_PROFILE` ∈ {compat,hw,exp750};
  `PTZ_HW_SPEED_ENABLED=1` maps to `hw` for back-compat. Per-axis target
  `PTZ_{PAN,TILT}_SPEED_STEP` (default 600) and clamp `PTZ_{PAN,TILT}_SPEED_MAX`
  (default & hard ceiling 750).
- `axis_target_step()` clamps `want` to `[1, min(limit,750)]` — **800 excluded**.
- `axis_open()`: under `hw`, if `want != applied_speed` it calls `SET_SPEED`
  once, records `applied_speed`, and logs; if equal it **skips** the ioctl (no
  redundant calls). Failure increments `drv_errors`, sets `last_error`, and
  keeps the base speed (movement still proceeds).
- `axis_close()`: under `hw`, if `applied_speed != 600` it re-SETs 600 before
  closing. Because the daemon closes the fds whenever both axes go idle, the
  baseline is restored after every motion session and on shutdown.
- `SET_SPEED` is issued only at open, never mid-move → **no move restart**.

## B. ONVIF speed mapping
See `SPEED_MAPPING.md`. ONVIF normalized speed (0..1) continues to map to duty
cycle (compat semantics preserved). The hardware `speed_step` is a *separate*,
configurable policy, not an arbitrary multiply of the ONVIF value; the driver's
response is non-linear and the mapping is documented and profile-gated.

## C. Smooth ContinuousMove
Unchanged proven behaviour: `start_dir()` only resets the session on a genuine
new move or a reversal (`!active || dir != s`); a same-direction refresh just
extends the deadline, so repeated ContinuousMove does **not** restart the
acceleration profile or re-prime the cushion → no jerk, minimal ioctls. The
driver coalesces MOVEs into the running move.

## D. Stop priority
`stop` is handled synchronously in `handle()` before the next worker tick.
`axis_stop()` clears `active`, **and now `primed`/`budget`**, issues the blocking
STOP ioctl (real latency recorded in `stop_lat_ms`), and `release_if_idle()`
closes the fds (driver auto-stop + speed restore). No stale feed can occur after
Stop. Shutdown calls `stop_all()`.

## E. Boundary & stale-state safety
- Bounds `[margin, total-margin]`, margin 32, from sysfs `total_steps`.
- `start_dir()` refuses to move if the start position is unreadable or outside
  `[0,total]` (no driving on a stale/garbage reading).
- `axis_tick()` range-checks every position read (STATUS, else sysfs); an
  out-of-range value stops the axis and records `last_error`.
- Boundary reached → `axis_stop("boundary")`. Direction change near a limit is
  still allowed (a reversal re-evaluates room in the new direction).
- No automatic calibration/homing is ever initiated.

## F. Diagnostics
`status` prints the §F field set (see CHANGELOG) plus all 1.3 fields, so the
existing `ptz-status.sh` and any field parser keep working. `last_error` holds
the most recent failure string; `uptime` is daemon seconds; per-axis counts and
driver-reported speed come from the STATUS ioctl.

## Tests
`tests/run-tests.sh` (54 checks): coords/duration units; smooth daemon against
`mock_motor.c`; profiles (compat/hw/exp750, clamp-to-750, req≠drv, SET_SPEED
failure, back-compat env); boundary; out-of-range refusal; watchdog; reversal;
simultaneous axes; error survival; crash recovery. `tests/soap-tests.sh` (11):
ONVIF CGI under QEMU. `tests/test-restore.sh` (13): hardened recovery.
