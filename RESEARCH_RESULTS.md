# Research results — Anyka AK39EV330 PTZ / timer / autostart

Condensed, reusable findings from the reverse-engineering done for this project.
The raw material (disassembly, kernel dumps, CSV captures, per-step update notes,
live-test logs) is kept locally under `research/` (gitignored) and is not needed
to build or run the release. Everything the application depends on is summarised
here.

## 1. Target hardware
- Camera: **LSC Smart Connect PTZ 3007325**; SoC **Anyka AK39EV330** (build id
  AK3918EV330); CPU **ARM926EJ-S**, **ARMv5TEJ**, 32-bit, **soft-float**.
- Kernel **Linux 4.4.192V2.1**, BusyBox userspace, `/bin/sh` (ash).
- Rootfs `/usr` read-only squashfs; `/etc/config` writable JFFS2; `/tmp` tmpfs
  (~17 MB); microSD FAT32 at `/mnt` (~32 GB); Wi-Fi `wlan0`.
- Working RTSP (factory `anyka_ipc`, Factory Mode): `rtsp://<cam>:554/main_ch`,
  H.264 1920×1080 + AAC. Tuya disabled. The video path is not modified.

## 2. Motors and the stepping driver (`ak_motor.ko`, v1.0.04)
- Pan = `/dev/motor0` (sysfs `hw-timer:2`), **IRQ 28**; Tilt = `/dev/motor1`
  (`hw-timer:3`), **IRQ 27**. Clock-event is `ak_ce_timer` **IRQ 39** (100 Hz).
- Motors are HZF-24BYJ48; `total_steps` pan **4096**, tilt **2230**; 8-phase
  half-step table (DTB `pwm-tbl-cw = 9 1 3 2 6 4 c 8`).
- Verified ioctls (magic `'m'`): MOVE `0x40046d40` (async, signed rel steps,
  auto-stops at bounds), STOP `0x40046d42` (blocking decel), GET_STATUS
  `0x40046d43` (32-byte struct), SET_SPEED `0x40046d20` (writes `speed_step`
  directly; sysfs `speed_step` is **read-only**). `0x40046d44` is a NO-OP.
- `speed_step` → timer reload: `ak_timer_start` computes `reload =
  12_000_000/speed_step − 1` (DTB `/timer clock-frequency = 12000000`, 12 MHz),
  periodic auto-reload, no per-IRQ software re-arm.

## 3. PTZ speed ceiling (VERIFIED) — why speed can't be meaningfully raised
Measured position advances at only **~110 steps/s** at `speed_step=600`, and
**raising `speed_step` barely helps** (600 ≈ 750 physically). Verified cause:
1. **Intentional ÷4 divider inside `ak_motor.ko`'s timer handler** — a counter
   increments every motor IRQ; `current_pos` advances (and a GPIO phase is
   written) only on every 4th IRQ (cruise). Ramp phases gate slightly
   differently (observed IRQ:step ratio ~4.2 cruise, higher during accel).
2. A **~500 IRQ/s effective service ceiling**: a 600 Hz request delivers only
   ~500 serviced IRQ/s → ~110–120 steps/s; 750 delivers ~510–530 → ~120/s. The
   handler cost (idiv + per-phase GPIO writes) and ack-after-callback coalescing
   cap the delivered rate regardless of the programmed reload.

Consequences, all confirmed: raising `speed_step` (600/750/even higher) does not
materially change step rate; repeated MOVE while already moving is *pending* (the
driver extends the run, no restart/ramp reset); the limiter is kernel-side, so a
real speedup would need an `ak_motor.ko`/kernel change — **out of scope**. The
factory uses the same ioctls/driver (config speed ×10 → `speed_step`); it only
*looks* faster because it does long continuous homing sweeps, not short nudges.

## 4. Factory speed config
`/etc/config/_ht_hw_settings.ini` (iniparser): `pan_def_speed`/`tilt_def_speed`
(normal) and `pan_tracking_speed`/`tilt_tracking_speed` (tracking). `anyka_ipc`
does `speed_step = config_speed × 10` (so def 60 → 600; tracking 80 → 800). The
DTB `speed-step=200` is only the boot default, overridden by `anyka_ipc`. **800
(tracking) is deliberately never selected by the bridge.**

## 5. Timer MMIO map and the unresolved anomaly (not a dependency)
- Static map `VA 0xF0008000 → PA 0x08000000` (kernel `map_desc`); `devmem` needs
  the **physical** address. The SARADC DT node (`/soc/saradc@08000000`) overlaps
  this window in `/proc/iomem`; the real timer registers coexist there.
- Per-channel registers (physical, from the timer driver's request jump-table):
  pan id2 load `0x080000BC`/ctrl `0x080000C0`; tilt id3 `0x080000C4`/`0x080000C8`;
  clock-event id6 `0x080000F4`/`0x080000F8` (load `0x1D4C0` = 120000 = 12 MHz/100);
  clocksource id7 `0x080000FC`/`0x08000100`.
- **Anomaly (unresolved, intentionally not acted on):** during a *confirmed*
  continuous pan move, the per-motor channel's ctrl register (`0x080000C0`,
  bit28 = enable) read as **disabled** the whole time the motor was physically
  stepping, while only the system clock-event/clocksource showed enabled. Three
  independent indicators (sysfs `hw-timer:2/3`, the driver jump-table, and the
  DTB `hwirq→virq` map, virq = hwirq+24) all point to ids 2/3 for pan/tilt, yet
  those registers never left idle during motion. Leading hypotheses: stepping is
  actually driven inside the always-on 100 Hz clock-event callback (the per-motor
  "timer" being a software abstraction), or the real channel is one of ids 8–10
  not sampled, or bit28 isn't the live enable for those channels. **This does not
  affect the application** — the step-rate cause (§3) rests on `/proc/interrupts`
  rate counting and disassembly, independent of MMIO. Per project decision, no
  further `devmem`/MMIO work is done and the driver is never modified.

## 6. Boot / autostart chain (as installed on the camera)
```
/etc/init.d/rc.local
  → /usr/sbin/main.sh                 (factory: anyka_ipc, telnetd, Wi-Fi)
  → /etc/config/sensor_driver.sh      (sensor init; appended RTSP_SD_AUTOSTART_V1)
      → /etc/config/rtsp_autostart.sh (waits Wi-Fi + anyka_ipc; restarts anyka_ipc
          in RTSP factory mode from /mnt/rtsp_factory.ini; ONVIF_SD_AUTOSTART_V1:
          if /mnt/onvif_autostart.enabled → sh /mnt/onvif/start.sh)
          → /mnt/onvif/start.sh        (httpd + wsd; SMOOTH_PTZ_AUTOSTART_V1:
              if /mnt/onvif/ptz_autostart.enabled → scripts/enable-ptz.sh → bridge)
```
- The two `/etc/config` scripts live in **JFFS2 (flash)**, so a clean camera
  needs them installed once (the SD alone can't place them). The release ships a
  one-time installer for this; originals are backed up as `*.before-onvif` /
  `sensor_driver.sh.rtsp-original`.
- Gate flags on the SD: `/mnt/rtsp_autostart.enabled`, `/mnt/onvif_autostart.enabled`,
  `/mnt/onvif/ptz_autostart.enabled`. `start.sh`/`enable-ptz.sh` stage whatever is
  in `/mnt/onvif/bin`, so nothing pins a specific bridge version.
- Runtime caveats confirmed live: camera has **no `tr`, no `gzip`** → camera-side
  scripts avoid both (archives are uncompressed `.tar`). `setsid` is present;
  `nohup` is not. `speed_step` resets to the driver default (600) at boot.

## 7. ONVIF / RTSP integration facts
- ONVIF via `onvif_simple_server` (roleoroleo) CGI behind BusyBox `httpd` on TCP
  **8080**; WS-Discovery `wsd_simple_server` on UDP **3702**; RTSP unchanged on
  **554**. The CGI carries a small patch so ONVIF `ContinuousMove` `Timeout`
  (e.g. `PT3S`) is passed to the bridge as a watchdog deadline.
- Config uses the upstream `%s` placeholder so the advertised address follows
  DHCP; no hardcoded IP at runtime. Device identity uses a stable, non-sensitive
  per-device serial derived from the MAC (not the MAC itself).

## 8. Application decision summary
The deployed bridge (see `ptz-smooth/release-1.4/`) ships the **compat** speed
profile by default (no `SET_SPEED`; identical to the proven 1.3 behaviour),
because §3 means a hardware speed gain is not achievable through supported
interfaces. Improvements are in control smoothness, Stop/boundary/stale-state
handling, diagnostics, and a safe staged deploy/rollback. The kernel, `ak_motor`
driver, Device Tree, Wi-Fi and factory firmware are never modified.
