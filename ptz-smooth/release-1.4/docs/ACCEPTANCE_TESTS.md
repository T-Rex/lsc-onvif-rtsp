# ACCEPTANCE_TESTS — onvif_ptz_bridge 1.4 (live, bounded)

Run after staging (candidate 1.4 active in RAM). Movement tests require
per-action operator authorization (§13). Before every move: read position, check
available distance, pick a safe direction, confirm Stop works, use a bounded
duration, keep the operator able to stop, and return the motors to a safe
position afterward. Do not repeat the physical speed tests already done; do not
run automatic long sweeps. Record results in `CAMERA_TEST_RESULTS.md`.

The offline equivalents (mock motor / QEMU) already pass: 54/54 daemon, 11/11
SOAP, 13/13 restore. The live tests confirm the real device.

## Test 1 — Startup (read-only)
`sh scripts/verify-installation.sh` → bridge responds, `version=1.4.0`, motor
handles ok, ONVIF PTZ endpoint present, **no automatic movement** at startup,
exactly one daemon.

## Test 2 — Pan (bounded, authorized)
Read `current_pos`; pick a direction with ≥ a few hundred steps of room. Issue a
short bounded move (e.g. `right 1.0 3000`). Verify: direction correct, motion
smooth, position advances, `Stop` halts it, motor stays stopped.

## Test 3 — Tilt (bounded, authorized)
Same checks on tilt (`up`/`down`), within tilt's range (`total_steps` 2230).

## Test 4 — Repeated ContinuousMove (authorized)
Send several same-direction ContinuousMove refreshes (simulated held joystick).
Verify from the bridge log/status: **no motor restart** between refreshes, no
jerk from control logic, no unnecessary driver ioctls (`pan_move_count` grows
steadily, not in bursts), and `Stop` still takes priority immediately.

## Test 5 — Direction change (authorized, one safe reversal)
From a safe mid-range position, move one way briefly, then reverse. Confirm no
motion continues in the previous direction after the reversal.

## Test 6 — Hardware speed profile (optional, authorized)
Only if a speed profile is wanted. Compare `compat`/600 vs `exp750`/750 over the
same bounded distance; measure actual position speed and Stop behaviour. **Do not
claim success from `speed_step` alone.** If 750 gives no meaningful, reliable
improvement, keep 600/compat as production (§14.6). Never select 800.

## Test 7 — ONVIF (real client)
With ONVIF Device Manager / an NVR on the LAN: verify GetStatus, ContinuousMove,
Stop, and that Media + RTSP still stream (H.264 1920×1080 + AAC).

## Test 8 — Failure handling (mocks; no live crash)
Covered offline (MOVE error, STATUS error, missing device, SET_SPEED failure,
out-of-range position). Do not intentionally crash the live driver or interrupt
physical movement unsafely.

## Test 9 — Restart (candidate)
`onvif_ptz_bridge shutdown` then restart via `enable-ptz.sh`; confirm it returns
to idle with **no motor movement** and one daemon.

## Test 10 — Recovery
Confirm `restore.sh latest --commit` reactivates the previous install from its
`/mnt/backups` snapshot (expected version, 600/600, one daemon, ONVIF/RTSP/WSD).
Reboot is the always-safe fallback.

## Pass criteria (§15)
Starts; ONVIF/RTSP/WS-Discovery intact; pan+tilt work; Stop reliable; boundaries
enforced; no driver errors (`pan/tilt_driver_errors=0`); one daemon; no
unexpected movement; no responsiveness regression; speed_step back to 600 when
idle; rollback to 1.3 available.
