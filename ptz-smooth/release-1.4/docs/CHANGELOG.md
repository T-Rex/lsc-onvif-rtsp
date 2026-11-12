# Changelog

## 1.4.0 — production update (builds on 1.3.0)

### Added
- **Unified hardware-speed support** in one binary, gated by a runtime profile
  (`PTZ_SPEED_PROFILE`): `compat` (default, == 1.3, no `SET_SPEED`), `hw`
  (apply configured per-axis `speed_step`), `exp750` (shortcut for `hw` @ 750).
  The former separate experimental build is retired.
- **Per-axis speed limits** (`PTZ_PAN_SPEED_MAX`/`PTZ_TILT_SPEED_MAX`) plus a
  compile-time hard ceiling of **750** — the factory tracking value **800 is
  never selectable automatically**.
- **Speed lifecycle**: `SET_SPEED` applied once at session open, restored to 600
  on release; redundant `SET_SPEED` calls are skipped; failures are counted and
  reported, movement continues at the base speed. `SET_SPEED` never restarts an
  in-flight move.
- **Extended `status` diagnostics** (§F): `version`, `uptime`,
  `active_speed_profile`, `pan/tilt_position`, `pan/tilt_requested_speed`,
  `pan/tilt_driver_speed`, `pan/tilt_move_count`, `pan/tilt_stop_count`,
  `pan/tilt_driver_errors`, `last_error`. Existing 1.3 fields are preserved.
- **Stale/garbage position handling** (§E): a move is refused if the start
  position is unreadable or out of `[0,total]`; a tick that reads an
  out-of-range position stops the axis and records the error.
- **New operational scripts**: `deploy.sh` (staged candidate + production
  promote, version-agnostic), `backup.sh` (timestamped snapshots to
  `/mnt/backups`), `restore.sh` (pick-a-snapshot restore), `verify-installation.sh`,
  dev-host `run-tests.sh`. Scripts carry no version suffix — the latest is the
  working one.

### Changed
- `restore.sh` is **hardened**: extract to a staging dir, validate (structure,
  required files, and the archive's `.sha256` sidecar), then atomic-swap and
  restart; on a failed health check the previous installation is put back.
  `/mnt/onvif` is never left missing. No `gzip`, no `tr`. It supersedes the
  earlier `restore-working.sh` / `rollback-v1.3.sh`, now folded into one
  version-agnostic script driven by the `/mnt/backups` snapshots.
- **Layout**: WS-Discovery templates moved to `www/onvif/wsd` and the PTZ SOAP
  templates to `www/onvif/ptz_service_files` (alongside the other
  `*_service_files`); nothing lives in a top-level `templates/` or `ptz/` dir.
  The PTZ CGI timeout patch now lives in the repo's top-level
  `patches/ptz-smooth/`.
- `axis_stop` now also clears the prime/budget state so a stale cushion can never
  cause a feed after Stop (reinforces Stop priority, §D).
- `enable-ptz.sh` loads `config/onvif_ptz.env` (speed profile + scheduler knobs).

### Unchanged (preserved)
- The proven 1.1/1.3 fixed-cushion movement scheduler (the 1.2 adaptive cushion
  regression is **not** reintroduced).
- ONVIF endpoints, SOAP method set, RTSP URL, WS-Discovery, device auth, CLI.
- No kernel / `ak_motor` / Device Tree / Wi-Fi / factory-firmware changes.

### Known limitations
- Physical pan/tilt speed is driver-capped (~110 steps/s); `hw`/750 is only
  marginally faster than 600 and is shipped **off by default**.
- The timer-register anomaly from the earlier investigation is documented but
  intentionally **not** a dependency of this application (UPDATE-09 §8, §24).
