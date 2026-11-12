# ONVIF_COMPATIBILITY — onvif_ptz_bridge 1.4

1.4 changes only the PTZ **bridge** behind the existing ONVIF CGI
(`onvif_simple_server`). The ONVIF server, endpoints, templates, device auth,
media profiles, RTSP URL and WS-Discovery are **unchanged**, so no ONVIF client
needs to be reconfigured after upgrading.

- Device service: `http://<cam>:8080/onvif/device_service`
- PTZ service:    `http://<cam>:8080/onvif/ptz_service`
- RTSP (unchanged): `rtsp://<cam>:554/main_ch` (H.264 1920×1080 + AAC)
- WS-Discovery: UDP 3702 via `wsd_simple_server` (scopes unchanged).

## Verified by the offline SOAP suite (CGI under QEMU, 11/11 pass)
- `GetCapabilities` advertises PTZ
- `GetProfiles` includes the PTZConfiguration
- `GetStreamUri` returns the RTSP URL unchanged
- `GetNodes` / PTZ node present
- `GetStatus` returns PanTilt position
- `ContinuousMove` accepted → starts motion; honours the ONVIF `Timeout`
  (e.g. `PT3S` → 3000 ms watchdog; `PT0.3S` auto-stops ~0.3 s)
- `Stop` halts motion
- WS-Security auth is enforced (requests without a valid token are rejected)

## Supported PTZ methods (actual set — nothing added just to tick a box)
| Method | Status |
|--------|--------|
| GetNodes / GetNode | supported |
| GetConfigurations / GetConfiguration / GetConfigurationOptions | supported (templates present) |
| GetStatus | supported (position + moving) |
| ContinuousMove | supported (pan/tilt; speed→duty cycle; Timeout watchdog) |
| Stop | supported (priority) |
| RelativeMove | bounded nudge via the bridge `rel` path (small clamped translation) |
| AbsoluteMove / Presets | templates exist but are **not** validated in 1.4 — treat as unsupported until live-tested; do not advertise as working |

Zoom is not present (the camera has no zoom); the `*_nozoom` templates are used.

## What 1.4 must not break (and does not, per the suite)
GetCapabilities, GetProfiles, GetStreamUri, GetStatus, GetConfigurationOptions,
ContinuousMove, Stop, PTZ speed handling, device authentication, media profiles,
RTSP URLs, WS-Discovery — all preserved. Re-run `tests/soap-tests.sh` (via
`scripts/run-tests.sh`) after any change; confirm live with ONVIF Device Manager
or an NVR during acceptance (Test 7).
