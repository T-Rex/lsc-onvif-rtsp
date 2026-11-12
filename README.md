# ONVIF + PTZ for the LSC Smart Connect PTZ 3007325 (Anyka AK39EV330)

A standalone **ONVIF** server with working **PTZ**, running directly on a cheap
Anyka-based Wi-Fi PTZ camera, exposing its existing RTSP stream to ONVIF clients
(ONVIF Device Manager, NVRs, Frigate/Blue Iris/etc.) — **without** modifying the
kernel, the motor driver, Wi-Fi or the factory firmware.

Everything is cross-compiled in Docker to a static **ARMv5TEJ / soft-float**
binary set and assembled into an `sd_card/` folder you copy to a microSD card.

## Verified on
| | |
|---|---|
| Camera | **LSC Smart Connect PTZ 3007325** |
| SoC | Anyka **AK39EV330** (build id AK3918EV330), ARM926EJ-S, **ARMv5TEJ**, soft-float |
| Kernel | Linux **4.4.192V2.1**, BusyBox userspace |
| Firmware | **V3.286.81.13_BUNDLE** (version 3.286.81.13), Factory Mode / RTSP enabled, Tuya disabled |
| Stream | RTSP H.264 1920×1080 + AAC at `rtsp://<camera-ip>:554/main_ch` |

Other Anyka AK3918-class cameras may work but are untested. The camera needs root
Telnet (and FTP for file copy), which this model ships with.

## What you get
- **ONVIF Device + Media services** on TCP **8080**, **WS-Discovery** on UDP
  **3702**: GetDeviceInformation, GetCapabilities, GetServices, GetProfiles,
  GetStreamUri (returns the real RTSP URL), one Profile-S H.264 1920×1080 profile
  with AAC audio info. Optional WS-UsernameToken auth.
- **PTZ** (`onvif_ptz_bridge` 1.4): smooth ONVIF ContinuousMove/Stop with a
  velocity→duty-cycle model, boundary + stale-state safety, Stop priority, the
  ONVIF `Timeout` honoured as a watchdog, and rich read-only diagnostics.
- RTSP is left entirely to the factory `anyka_ipc`; nothing here transcodes,
  proxies or records.

> **Speed note:** the motor stepping rate is capped by the closed `ak_motor`
> kernel driver (~110 steps/s), so PTZ speed is a hardware limit, not something
> this software can raise. The bridge ships a `compat` speed profile by default
> and does **not** promise a speed increase. See `RESEARCH_RESULTS.md`.

## Repository layout
| Path | What it is |
|---|---|
| `build-sdcard.sh` | **Top-level build** → assembles `output/sd_card/` (runs in the container) |
| `build.sh` | ONVIF-server build: fetches/compiles `onvif_simple_server`, `wsd_simple_server`, BusyBox `httpd` (runs in the container) |
| `Dockerfile`, `docker-compose.yml` | The ARMv5 build image (Bootlin musl toolchain + QEMU) |
| `patches/` | Source patches for `onvif_simple_server` and BusyBox `httpd` |
| `config/` | BusyBox `httpd` build config fragment |
| `package/` | Base ONVIF camera package (`start.sh`/`stop.sh`/`status.sh`, `etc/`, `lib/`) |
| `tests/` | ABI verification + QEMU ONVIF/SOAP integration tests for the server build |
| `ptz-control/` | Motor device layer (`ak_motor` ioctl ABI) and the `ptz_control` manual tool |
| `patches/ptz-smooth/` | The PTZ `ContinuousMove` **Timeout** CGI patch (applied via `EXTRA_PATCHES`) |
| `ptz-smooth/release-1.4/` | The **PTZ bridge 1.4**: source, camera scripts, docs, tests, PTZ SOAP templates |
| `sdcard/` | Static SD files: autostart installer, opt-in flags, RTSP config, the `start.sh` PTZ-autostart snippet |
| `docs/` | ONVIF deployment guide |
| `RESEARCH_RESULTS.md` | Distilled reverse-engineering findings (motors, timer, autostart, speed cap) |
| `README-build.md` | Detailed notes on the ONVIF-server build |

`output/` (build artifacts) and `research/` (raw reverse-engineering material,
kernel dumps, logs) are git-ignored.

## Build (Docker Desktop on Windows / Linux)
Needs only Docker. First build the toolchain image once, then build the SD card:

```powershell
# from the repo root
docker compose build                      # build the ARMv5 toolchain image (once)
docker run --rm -v "${PWD}:/src:ro" -v "${PWD}\output:/output" onvif-armv5-builder `
  bash -c "tr -d '\r' < /src/build-sdcard.sh > /tmp/b.sh && bash /tmp/b.sh"
```
(Linux/macOS: `-v "$PWD:/src:ro" -v "$PWD/output:/output"`.)

Result: **`output/sd_card/`** — a verified, static ARMv5 build. The build fails
non-zero if compilation, the ABI check or the ONVIF tests fail. To build only the
ONVIF server or only the bridge, see `README-build.md` and
`ptz-smooth/release-1.4/docs/BUILD.md`.

## Install on the camera
1. Copy the **contents of `output/sd_card/`** to the root of a FAT32 microSD and
   insert it (files land under `/mnt`).
2. Over Telnet, run the one-time autostart installer and reboot:
   ```sh
   sh /mnt/install/install-autostart.sh
   reboot
   ```
3. After ~90–120 s: RTSP on 554, ONVIF on 8080, WS-Discovery on 3702, PTZ live.
   Check: `sh /mnt/onvif/scripts/verify-installation.sh`.

The installer writes one small boot hook into `/etc/config` (flash) so the SD
package autostarts; it backs up the stock file and prints how to undo it. Full
details: `sdcard/README.md` and `ptz-smooth/release-1.4/docs/DEPLOYMENT.md`.

## Safety and scope
No kernel / `ak_motor` / Device-Tree / Wi-Fi / factory-firmware changes. PTZ uses
only the verified `ak_motor` ioctls. The install touches flash exactly once (the
autostart hook); everything else runs from the SD and `/tmp`. Rollback and
recovery are covered in `ptz-smooth/release-1.4/docs/ROLLBACK.md`.

## Credits
ONVIF server: [roleoroleo/onvif_simple_server](https://github.com/roleoroleo/onvif_simple_server)
(pinned commit in `README-build.md`). BusyBox `httpd`. Toolchain:
[Bootlin](https://toolchains.bootlin.com) armv5-eabi musl.
