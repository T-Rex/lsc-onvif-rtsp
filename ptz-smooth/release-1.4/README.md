# onvif_ptz_bridge 1.4.0 — LSC Smart Connect PTZ 3007325 (Anyka AK39EV330)

Production update of the ONVIF PTZ bridge for the LSC 3007325 camera. Builds on
the proven **1.3** movement scheduler and adds configurable, safe **hardware
speed control**, richer **diagnostics**, stronger **stop/boundary/stale-state**
handling, and a **safe, staged deployment + rollback** workflow — without
touching the kernel, the `ak_motor` driver, Wi-Fi, RTSP, or the factory firmware.

> **Hardware reality:** the stepper runs at a driver-capped rate; raising
> `speed_step` yields only a marginal physical-speed change (≈600 vs 750 are
> close). 1.4 therefore delivers **control, reliability and diagnostics**
> improvements and a *configurable* speed profile — it does **not** promise a
> speed the hardware cannot provide. See `docs/SPEED_MAPPING.md`.

## What 1.4 is
- One unified ARMv5 binary. Default **compat** profile is byte-for-byte the 1.3
  behaviour (issues no `SET_SPEED`). An opt-in **hw**/**exp750** profile applies
  a per-axis `speed_step` via the verified ioctl and restores 600 on release.
- Same ONVIF integration, endpoints and CLI as 1.3 — no client reconfiguration.

## Layout
```
release-1.4/
├── bin/onvif_ptz_bridge        # the 1.4 binary (ARMv5TEJ, soft-float, static)
├── bin/ptz_control             # manual motor tool (unchanged)
├── bin/onvif_simple_server     # patched ONVIF CGI (unchanged)
├── www/onvif/ptz_service_files/ # ONVIF PTZ SOAP templates (alongside the others)
├── scripts/                    # deploy / backup / restore / verify / enable
├── config/onvif_ptz.env.example
└── docs/                       # this release's documentation
```

## Quick use
- Build + test (dev host, Docker): `sh scripts/run-tests.sh`
- Verify recovery readiness, stage, accept, promote, reboot-validate: see
  `docs/DEPLOYMENT.md`. Roll back any time: `docs/ROLLBACK.md`.

## Safety
Default speed ceiling excludes the factory tracking value 800. Stop has
priority; positions are range-checked; the default ~10 s ONVIF watchdog is
preserved; the stable 1.3 installation and the verified recovery archive are
never destroyed during deployment. See `docs/SAFETY.md` (inherited) and the
repo's `ANYKA_CAMERA_LIVE_TESTING_RECOVERY.md`.
