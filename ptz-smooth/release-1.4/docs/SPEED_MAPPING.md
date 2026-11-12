# SPEED_MAPPING — ONVIF speed ↔ motor behaviour (1.4)

## Two independent knobs
1. **ONVIF normalized speed** (0.0–1.0 in a ContinuousMove Velocity). Mapped, as
   in 1.3, to a **duty cycle**: how many steps the daemon feeds per 20 ms tick
   (`budget_steps()` in `coords.c`), capped by `SM_MAX_PER_TICK`. This is how
   "slow vs fast" joystick input is honoured on a fixed-rate stepper. It is
   **not** multiplied into a `speed_step`.
2. **Hardware `speed_step`** (Hz) — the motor's step frequency, set via the
   `SET_SPEED` ioctl. Governed by the **speed profile**, independent of the
   ONVIF velocity value.

Keeping these separate is deliberate: the driver's position-rate response to
`speed_step` is **non-linear and driver-capped** (measured ~110 steps/s whether
`speed_step` is 600 or 750; see the repo PTZ investigation). We therefore do not
pretend a monotonic ONVIF→Hz curve.

## Profiles (`PTZ_SPEED_PROFILE`)
| Profile  | SET_SPEED? | speed_step | Use |
|----------|-----------|-----------|-----|
| `compat` (default) | no | driver default (600) | identical to 1.3; safest |
| `hw`     | yes | `PTZ_{PAN,TILT}_SPEED_STEP` (default 600), clamped ≤ limit ≤ 750 | explicit speed init/restore |
| `exp750` | yes | 750 | the only *tested* experimental step |

Per-axis clamps: `PTZ_PAN_SPEED_MAX`, `PTZ_TILT_SPEED_MAX` (default 750). The
build also enforces a hard ceiling of **750**; **800** (factory tracking) is
never selectable here. A request above the limit is clamped (reported as
`pan_requested_speed`), never rejected silently.

## Lifecycle
`SET_SPEED` is issued **once** when an axis opens for a motion session (only if
the target differs from what is already applied — no redundant ioctls), and the
default **600 is restored** when the axis is released (every time both axes go
idle, and on shutdown). sysfs `speed_step` is read-only, so this close-time
restore (or a reboot) is the only way back to 600.

## Choosing a profile
- Leave **compat** for production unless a measured, accepted benefit justifies
  `hw`. Acceptance Test 6 compares 600 vs 750 on the real camera; if 750 gives
  no meaningful, reliable improvement, **keep 600/compat** (UPDATE-09 §14.6).
- `status` reports `active_speed_profile`, `pan_requested_speed` and
  `pan_driver_speed` so requested vs applied vs driver-reported are all visible.
