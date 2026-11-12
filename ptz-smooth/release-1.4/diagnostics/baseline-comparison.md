# baseline-comparison — 1.3 (stable) vs 1.4

| Aspect | 1.3.0 (stable) | 1.4.0 |
|--------|----------------|-------|
| Binaries | two (stable + experimental `-DPTZ_HW_SPEED`) | **one** unified binary |
| Default behaviour | fixed-cushion scheduler, no SET_SPEED | **identical** (compat profile) |
| Hardware speed | experimental build only, env-gated | first-class **profile** (compat/hw/exp750), default off |
| Speed limits | step passed through (exp) | **per-axis clamp + hard ceiling 750**; 800 excluded |
| SET_SPEED lifecycle | set on open, restore on close (exp) | same + **skip redundant**, error-counted, never mid-move |
| Stop | priority, clears active | priority, **also clears prime/budget** (no stale feed) |
| Stale position | position read each tick | **refuse/stop on unreadable or out-of-range** position |
| `status` fields | 1.3 set | 1.3 set **+ §F**: version, uptime, profile, positions, requested/driver speed, move/stop/error counts, last_error |
| Recovery script | move-aside-then-extract (could leave /mnt/onvif missing) | **staged → validate → atomic swap → rollback on failure** |
| Deploy/rollback | enable/disable + experimental revert | **deploy.sh (stage/promote) + backup.sh/restore.sh (timestamped /mnt/backups) + verify-installation** |
| ONVIF / RTSP / WSD | works | **unchanged** (11/11 SOAP) |
| Kernel / driver / DT / Wi-Fi | untouched | **untouched** |

## Behavioural equivalence (why no regression by default)
With no `PTZ_SPEED_PROFILE` / `onvif_ptz.env`, 1.4 selects `compat`: it never
issues `SET_SPEED` and runs the same proven scheduler, so an unconfigured 1.4 is
functionally the 1.3 stable bridge plus extra read-only diagnostics.

## Offline measurements (mock motor models the ~110 steps/s HW cap)
- compat: `speed_step` stays 600, observed rate ~100/s (mock), as 1.3.
- hw/750 with the cap modelled: `speed_step`=750 applied and reported, observed
  rate still ~100/s — reproduces the real-hardware ceiling. This is why 1.4 does
  not promise a physical speed gain and ships `compat` by default.

## Live comparison (fill during acceptance Test 6)
| Metric | 1.3 / compat-600 | 1.4 / exp750 |
|--------|------------------|--------------|
| pan steps/s (bounded) | ____ | ____ |
| tilt steps/s (bounded) | ____ | ____ |
| Stop latency (ms) | ____ | ____ |
| driver_errors | ____ | ____ |
Decision: keep 600/compat unless 750 shows a meaningful, reliable gain.
