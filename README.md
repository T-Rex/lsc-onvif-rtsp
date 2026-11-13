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

Other Anyka AK3918-class cameras may work but are untested. A factory-reset
camera ships with **Telnet disabled**; the repo includes a tiny bootstrap SD card
that turns it on (and joins your Wi-Fi) for the one install step — it is built
onto the same card in the *Quick start* below.

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
| `prepare-sd.ps1` | **Interactive full-card builder** (Windows). Asks Wi-Fi / Telnet / FTP / ONVIF settings, then runs `build-sdcard.sh` in Docker. **Start here.** |
| `prepare-telnet-sd.ps1` | Interactive builder for **only** the Telnet-bootstrap card (`build-telnet-sd.sh`). |
| `build-sdcard.sh` | **Top-level build** → assembles `output/sd_card/` + `output/sd_card_telnet/` (runs in the container; driven by the env vars in *Build parameters* below) |
| `build-telnet-sd.sh` | Assembles only the Telnet-bootstrap card `output/sd_card_telnet/` (no compile) |
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

## Quick start: blank SD card → working ONVIF + RTSP

Start-to-finish from a **factory-reset camera** and a PC with **Docker Desktop**.
You answer a few prompts, build the SD-card contents in Docker, write them to one
FAT32 card, and run one command on the camera over Telnet. The card can **join
your Wi-Fi itself** (STA mode), so the camera does *not* need to be set up in the
SmartLife / Tuya app first. Nothing is flashed except one tiny autostart hook.

### Prerequisites
- **PC:** Docker Desktop (Linux containers). No compilers/WSL dev tools needed.
- **A FAT32 microSD card.** ~32 GB is typical; anything FAT32-formatted works.
  (For cards > 32 GB use Rufus or guiformat to force FAT32.)
- **Your Wi-Fi SSID + password** (for STA mode), and ideally a **static IP** you
  want the camera to take. The bootstrap joins the network and brings up Telnet;
  a factory-reset camera ships with Telnet **off**, which is why the card is needed.

### 1. Build the cards (on the PC, in Docker)
From the repo root, build the image once, then run the **interactive builder** — it
asks the questions and sets every parameter for you:

```powershell
docker compose build        # ARMv5 toolchain image — once, ~80 MB download
.\prepare-sd.ps1            # prompts for Wi-Fi / Telnet / FTP / ONVIF, then builds
```
`prepare-sd.ps1` walks through: **Wi-Fi mode** (STA = join your LAN, recommended; or
AP = stay a hotspot), **SSID + password**, **static IP + gateway** (blank = DHCP),
a **Telnet root password**, optional **FTP**, and optional **ONVIF** user/password.
What you type is written only into `output/` (git-ignored) and onto the card —
never into the repo. Add `-CopyTo E:\` to copy both card trees onto a formatted
card automatically. (`prepare-telnet-sd.ps1` builds just the bootstrap card.)

<details>
<summary>Prefer raw Docker (Linux/macOS, or scripting)? Set the env vars directly.</summary>

```powershell
# All settings are optional env vars; see "Build parameters" below.
docker run --rm `
  -e WIFI_MODE=sta -e WIFI_SSID='MyWiFi' -e WIFI_PASS='wifi-pass' `
  -e WIFI_IP=192.168.1.100 -e WIFI_GW=192.168.1.1 `
  -e TELNET_ROOT_PASSWORD='choose-a-password' `
  -e ONVIF_USER=admin -e ONVIF_PASS='onvif-pass' `
  -v "${PWD}:/src:ro" -v "${PWD}\output:/output" onvif-armv5-builder `
  bash -c "tr -d '\r' < /src/build-sdcard.sh > /tmp/b.sh && bash /tmp/b.sh"
```
(Linux/macOS: `-v "$PWD:/src:ro" -v "$PWD/output:/output"`.)
</details>

One run cross-compiles everything, runs the ABI check + QEMU ONVIF tests, and ends
with `sd_card ready at output/sd_card; telnet bootstrap at output/sd_card_telnet
(rc=0)`. If `rc` is not 0 or the command exits non-zero, **stop** and read the log.
It produces two folders:

- **`output/sd_card/`** — the ONVIF + PTZ package (`onvif/`), the `*_autostart.enabled`
  flags, `rtsp_factory.ini`, and the one-time `install/` autostart installer.
- **`output/sd_card_telnet/`** — the Telnet bootstrap (`_ht_ap_mode.conf`, `hostapd`,
  `hack.sh`, `custom/`, and `shadow` if you set a password). It opens a **root shell
  on port 24**, joins your Wi-Fi, and (optionally) starts FTP. Credentials are
  written only here (git-ignored), never into the repo.

### Build parameters
Both `prepare-*.ps1` wrappers set these for you; with raw `docker run` pass them as
`-e NAME=value`. All are optional — omit one to take its default.

| Variable | Used by | Meaning / default |
|---|---|---|
| `WIFI_MODE` | both cards | `sta` (join your Wi-Fi, camera on your LAN) or `ap` (stay a hotspot). Default `ap`. |
| `WIFI_SSID` | both | Network to join (STA) or advertise (custom AP). |
| `WIFI_PASS` | both | Wi-Fi / AP password. |
| `WIFI_SECURITY` | both | `wpa2` (default) or `open`. |
| `WIFI_IP` | both | Static IPv4 for the camera. **Blank = DHCP.** A fixed IP is strongly recommended so the camera's address never changes. |
| `WIFI_NETMASK` | both | Netmask for a static IP. Default `255.255.255.0`. |
| `WIFI_GW` | both | Gateway (router) IP for a static IP. |
| `TELNET_ROOT_PASSWORD` | telnet card | Root password for the bootstrap Telnet (port 24). **Blank = passwordless** root shell. Generates `shadow` on the card. |
| `FTP_ENABLE` | telnet card | `1` to start a root FTP server on the camera. Default off. |
| `FTP_PORT` | telnet card | FTP port. Default `21`. |
| `ONVIF_USER` | ONVIF | ONVIF (WS-UsernameToken) username. **Blank = no auth** (open on a trusted LAN). |
| `ONVIF_PASS` | ONVIF | ONVIF password (used with `ONVIF_USER`). |

In STA mode the builder also writes a `[wifi_station]` block into `rtsp_factory.ini`
so the factory `anyka_ipc`, when the autostart worker restarts it, stays on your
LAN instead of reverting to its own hotspot.

### 2. Write one FAT32 card (package + Telnet bootstrap)
You need both on the **one** card: the bootstrap gives you Telnet, the package is
what you install over it. Format the microSD as **FAT32**, copy the **contents of
`output/sd_card/`** to the card root, then copy the **contents of
`output/sd_card_telnet/`** on top (if asked to replace `README.md`, either is
fine). The root should then hold `onvif/`, `install/`, the `*.enabled`/`.ini`
flags, plus `_ht_ap_mode.conf`, `hostapd`, `hack.sh`, `custom/` (and `shadow`).

> FAT32 drops Unix execute bits and symlinks — expected; every script runs via
> `sh`. Copy plain files; don't ship an archive to unpack on the camera.

Eject the card and insert it into the powered-off camera.

### 3. Boot and Telnet in (port 24)
Power on and wait ~1 minute for Wi-Fi + the bootstrap. From the PC, connect to the
**bootstrap Telnet on port 24**:

```powershell
telnet <camera-ip> 24     # log in as root (your password), or straight to a shell
```
Confirm the package is present (with the bootstrap active the card is mounted at
**`/tmp/sd`**; on a plain boot without the bootstrap the firmware mounts it at
`/mnt`):
```sh
ls /tmp/sd                # expect: onvif  install  *_autostart.enabled  rtsp_factory.ini  hack.sh  custom …
```
If the connection is refused, give it another minute (first boot) and confirm the
camera is on your LAN (router DHCP list). Bootstrap logs: `/tmp/sd/logs/`.

### 4. Install autostart (one command) and reboot
```sh
sh /tmp/sd/install/install-autostart.sh
reboot
```
This installs `/etc/config/rtsp_autostart.sh` and hooks it into the camera's
`sensor_driver.sh` (saving the stock copy as `sensor_driver.sh.rtsp-original`).
This is the **only** write to flash; it is idempotent (safe to re-run) and prints
the exact commands to undo it. Everything else lives on the SD card.

### 5. Wait ~90–120 s, then verify
The boot worker waits for a real LAN Wi-Fi address and the factory app, restarts
`anyka_ipc` in RTSP factory mode, then starts ONVIF and (if enabled) PTZ. It is
deliberately patient (several staged waits), so first boot to a working ONVIF can
take a couple of minutes — this is expected. After it settles:

- **RTSP:** `rtsp://<camera-ip>:554/main_ch` — H.264 1920×1080 + AAC
  (test in VLC: *Media → Open Network Stream*).
- **ONVIF:** `http://<camera-ip>:8080/onvif/device_service`, WS-Discovery on UDP
  3702 — add the camera in ONVIF Device Manager, or in your NVR / Frigate /
  Blue Iris, and it should be auto-discovered.
- **PTZ:** ONVIF ContinuousMove / Stop work from that same client.

Health check any time over Telnet:
```sh
sh /tmp/sd/onvif/scripts/verify-installation.sh
```
Boot logs if something's off: `/tmp/sd/rtsp-autostart.log`,
`/tmp/sd/onvif/logs/onvif-boot.log`, and the Wi-Fi join log
`/tmp/sd/logs/wifi.*.log`.

### Turning things on/off
Everything is opt-in via marker files; all three are present after the build:
- Disable **PTZ** only: `rm /tmp/sd/onvif/ptz_autostart.enabled` (ONVIF + RTSP stay).
- Disable **ONVIF**: `rm /tmp/sd/onvif_autostart.enabled`.
- Disable **everything from the SD**: remove both `*_autostart.enabled`
  flags (delete them on the card, or `rm /tmp/sd/*_autostart.enabled`) and run the
  uninstall commands `install-autostart.sh` printed (restore
  `sensor_driver.sh.rtsp-original`, remove `/etc/config/rtsp_autostart.sh`).
- Close the **bootstrap Telnet**: once ONVIF/PTZ run on their own you can delete
  the bootstrap files from the card (`_ht_ap_mode.conf`, `hostapd`, `hack.sh`,
  `custom/`, `shadow`) — port 24 stops opening at boot. The bootstrap writes no
  flash, so this fully removes it.

### Changing settings later — edit the configs, no rebuild
Everything the builder asked is stored as plain text on the card, so you can change
it by pulling the card into your PC (or editing over Telnet/FTP) — **no Docker
rebuild needed**. Reboot the camera afterwards. The files, at the card root:

| File | What to change |
|---|---|
| `custom/configs/wifi.conf` | **Wi-Fi.** `MODE=ap\|sta`, `SSID`, `PASS`, `SECURITY=wpa2\|open`, and `IP`/`NETMASK`/`GW` (blank `IP` = DHCP). This is what the bootstrap uses to join the network. |
| `rtsp_factory.ini` → `[wifi_station]` | **Wi-Fi the factory app keeps after the RTSP restart** (`ssid`/`passphrase`/`ip`/`netmask`/`gateway`). Keep it in sync with `wifi.conf` so the camera doesn't drop off the LAN. |
| `custom/configs/hack.conf` | **Bootstrap services.** `TELNET`/`TELNET_PORT`, `FTP`/`FTP_PORT`, and the factory-sound mutes `MUTE_FACTORY_PROMPT`/`MUTE_ALL_SOUNDS`. |
| `onvif/etc/onvif_auth.conf` | **ONVIF login** (`username` / `password`). Empty file = open/no auth. |
| `onvif/etc/onvif_simple_server.conf` | ONVIF device identity and the single video profile (model, RTSP `url`, resolution). Normally leave as built. |
| `shadow` (card root) | The **Telnet root password** hash. Easiest to regenerate by re-running the builder; editing by hand means producing a crypt hash yourself. |

These are strict `KEY=value` shell files (no spaces around `=`, no quotes needed).
After editing Wi-Fi, change it in **both** `wifi.conf` and the `[wifi_station]`
block. To apply ONVIF changes without a reboot: `sh /tmp/sd/onvif/stop.sh; sh
/tmp/sd/onvif/start.sh`.

### Credentials (three independent layers)
- **Telnet (root login):** set at build time with `TELNET_ROOT_PASSWORD` (writes
  `shadow` onto the bootstrap card). No variable → passwordless root shell on
  port 24. This is the camera's root shell, separate from ONVIF.
- **ONVIF (WS-UsernameToken):** a user/password that `onvif_simple_server`
  enforces on the ONVIF SOAP calls. Set it at build time with
  `-e ONVIF_USER=admin -e ONVIF_PASS=…` (baked into the card's
  `onvif/etc/onvif_auth.conf`), or edit `onvif/etc/onvif_auth.conf` on the
  card later (no rebuild) and restart ONVIF (`sh /tmp/sd/onvif/stop.sh;
  sh /tmp/sd/onvif/start.sh`). Empty = open (fine for a trusted LAN during testing).
- **RTSP (`:554/main_ch`): no authentication is available.** The factory
  `anyka_ipc` RTSP server does not implement RTSP auth — its request parser has
  no `Authorization` field and it never sends a `401`/`WWW-Authenticate`
  challenge (verified against the firmware binary). The stream is open by design;
  this project does not modify the video path. If you must restrict it, do it at
  the network layer (firewall / VLAN / Wi-Fi isolation) — ONVIF credentials and
  the Telnet password do **not** protect RTSP.

All three live only on the SD card (and in git-ignored `output/`), never in the
repo. Passwords are stored in plain text on the FAT32 card, so treat the card as
sensitive.

To build only the ONVIF server or only the PTZ bridge, see `README-build.md` and
`ptz-smooth/release-1.4/docs/DEPLOYMENT.md`. The on-card `sdcard/README.md` has a
short copy of the camera-side steps.

## Safety and scope
No kernel / `ak_motor` / Device-Tree / Wi-Fi / factory-firmware changes. PTZ uses
only the verified `ak_motor` ioctls. The install touches flash exactly once (the
autostart hook); everything else runs from the SD and `/tmp`. Rollback and
recovery are covered in `ptz-smooth/release-1.4/docs/ROLLBACK.md`.

## Credits
ONVIF server: [roleoroleo/onvif_simple_server](https://github.com/roleoroleo/onvif_simple_server)
(pinned commit in `README-build.md`). BusyBox `httpd`. Toolchain:
[Bootlin](https://toolchains.bootlin.com) armv5-eabi musl.
