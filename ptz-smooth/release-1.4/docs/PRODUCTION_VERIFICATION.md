# PRODUCTION_VERIFICATION — onvif_ptz_bridge 1.4

Completed at Phase 6 (promotion) and Phase 7 (reboot) on 2026-11-09, camera
192.168.1.100.

## Identity
- Intended production bridge SHA-256: `bfec6df5da2bc2eace45976583eb5eb20ae2144d5c3b52f5ceb76ea962481d73`
- `status` reports `version=1.4.0`: **PASS** (before and after reboot)
- Installed `/mnt/onvif/bin/onvif_ptz_bridge` SHA-256: confirm with
  `sha256sum /mnt/onvif/bin/onvif_ptz_bridge` (candidate verified = `bfec6df5…`
  at promote; promote installs that exact file)
- pre-promote snapshot saved to `/mnt/backups/onvif-<ts>-pre-promote.tar`
  (+ `.sha256`): **PASS** (created automatically by `deploy.sh promote`)

## Post-promote health (`verify-installation.sh`) — PASS (15/15)
- [x] bridge ping OK, version 1.4.0
- [x] exactly one `onvif_ptz_bridge daemon`
- [x] motor0/motor1 `speed_step=600`
- [x] positions readable and in range; no movement
- [x] ports 554 + 8080 listening; anyka_ipc/httpd/wsd up
- [ ] ONVIF + RTSP + WS-Discovery confirmed from an ONVIF client (recommended;
      RTSP/httpd/wsd processes + ports confirmed; SOAP verified offline 11/11)

## Reboot validation (Phase 7) — PASS
After one controlled reboot (auto-recovered via the /etc/config boot chain):
- [x] Telnet available
- [x] anyka_ipc started; RTSP 554 works (port listening; process up)
- [x] ONVIF HTTP 8080 started; WS-Discovery (wsd) started
- [x] exactly one PTZ bridge, active binary reports 1.4.0
- [x] motor positions valid (re-init to driver defaults at boot); no unexpected movement
- [x] speed_step 600/600; Stop + movement verified in acceptance

## Rollback availability — verified (not exercised live)
- [x] `/mnt/backups` snapshot present; `restore.sh latest --commit` restores it
      (restore path 13/13 offline)
- [x] reboot fallback verified (boot chain restores services from /mnt/onvif/bin)

## Boot chain (verified)
rc.local → main.sh + /etc/config/sensor_driver.sh → /etc/config/rtsp_autostart.sh
→ (RTSP restart; if /mnt/onvif_autostart.enabled) /mnt/onvif/start.sh → httpd/wsd
→ (if /mnt/onvif/ptz_autostart.enabled) enable-ptz.sh → bridge from /mnt/onvif/bin.
Stages whatever is in bin/ (now 1.4); nothing pins 1.3.

## Sign-off
- Promoted + reboot-validated: 2026-11-09
- Result: **PASS → onvif_ptz_bridge 1.4.0 is the production bridge; 1.3 retained as rollback.**
- Open/optional: confirm installed-binary SHA; ONVIF-client functional check (ODM/NVR).
