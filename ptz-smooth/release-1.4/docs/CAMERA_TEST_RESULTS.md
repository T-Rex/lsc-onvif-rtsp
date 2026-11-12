# CAMERA_TEST_RESULTS — onvif_ptz_bridge 1.4

Status key: PASS / FAIL / PENDING / N-A. Live tests run on the physical camera
192.168.1.100 on 2026-11-09.

## Offline (Docker; no hardware) — DONE
| Suite | Result |
|-------|--------|
| Unit + daemon (mock motor), `tests/run-tests.sh` | **54/54 PASS** |
| ONVIF SOAP (CGI under QEMU), `tests/soap-tests.sh` | **11/11 PASS** |
| Hardened recovery, `tests/test-restore.sh` (busybox sh + dash) | **13/13 PASS** |
| ABI | ELF32 ARM EABI5, **v5TEJ**, **soft-float**, **static** (no dynamic section) |
| bridge 1.4.0 SHA-256 | `bfec6df5da2bc2eace45976583eb5eb20ae2144d5c3b52f5ceb76ea962481d73` |

## Live (physical camera) — DONE
| Test | Result | Notes |
|------|--------|-------|
| 1 Startup / verify-installation | **PASS** | 15/15; version=1.4.0; one daemon; no auto-move |
| 2 Pan bounded move + Stop | **PASS** | right 2665→3331, left →3007; direction correct; Stop halts |
| 3 Tilt bounded move + Stop | **PASS** | down 700→970; Stop halts |
| 4 Repeated ContinuousMove | PASS (offline) | offline 54-suite covers no-restart/coalescing; not stress-tested live |
| 5 Direction change | **PASS** | right then left reversal; no residual motion |
| 6 Speed profile 600 vs 750 | N-A | kept compat/600 by decision (driver-capped; no gain expected) |
| 7 ONVIF client (ODM/NVR) | PENDING | recommended; SOAP path verified offline 11/11 + via bridge CLI live |
| 8 Failure handling | PASS (offline mocks) | not crashed live |
| 9 Restart candidate | **PASS** | enable-ptz restart → idle, one daemon, version 1.4.0 |
| 10 Restore previous install | available, not exercised live | `/mnt/backups` snapshot + `restore.sh`; restore path 13/13 offline; reboot fallback verified |
| Reboot validation (Phase 7) | **PASS** | auto-recovered: Telnet, anyka_ipc, RTSP 554, httpd 8080, wsd, one 1.4 bridge, 600/600, no movement |

## Driver-error / speed observations (live)
- `pan_driver_errors=0`, `tilt_driver_errors=0`, `last_error=none` throughout.
- `pan_driver_speed=600`, `tilt_driver_speed=600` (compat; no SET_SPEED issued).
- Measured pan steps/s not re-measured (prior investigation: driver-capped ~110;
  600 vs 750 close — reason 1.4 ships compat/600).
- Post-reboot positions re-init to driver defaults (pan 2048, tilt 990); `is_moving=0`.
