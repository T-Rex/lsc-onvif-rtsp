# Telnet bootstrap SD card (factory-reset camera)

A factory-reset LSC Smart Connect PTZ 3007325 ships with **Telnet disabled**, so
there is no way in to run the ONVIF autostart installer. This tiny, compile-free
SD payload opens a root Telnet shell for exactly that bootstrap step, then you
switch to the real ONVIF/PTZ card.

It writes **no flash**: a reboot *without* this card leaves the camera exactly as
the factory left it.

## How it works
On this firmware the boot chain is `init → rcS → rc.local → /usr/sbin/main.sh →
/tmp/service.sh`, and `service.sh` checks marker files on the SD:

- `_ht_ap_mode.conf` makes the firmware copy `/mnt/hostapd` to `/tmp/hostapd` and
  run it very early — **before** the main app. We put our own `hostapd` there; it
  is not a real access point, just a hook that runs `/mnt/hack.sh`.
- `hack.sh` optionally bind-mounts our `shadow` over the live one (to set the root
  password for this boot only), then launches `custom/scripts/telnet.sh` and
  `custom/scripts/wifi.sh`.
- `telnet.sh` keeps a `telnetd` alive on port **24**. With a `shadow` present it
  requires a login (`root` + your password); without one it serves a passwordless
  root shell so you can never lock yourself out of a factory-reset unit.
- `wifi.sh` reads `custom/configs/wifi.conf` and puts the camera where you want it.

### Network mode (wifi.conf)
The `_ht_ap_mode.conf` hook makes the stock firmware bring `wlan0` up as an
**access point**. That is handy for a quick local Telnet, but usually you want
the camera on your LAN, so `wifi.sh` can switch it:

- **`MODE=sta`** — tear the AP down and join an existing Wi-Fi network (your
  SSID/password), so the camera gets a LAN address and Telnet is reachable from
  your normal network. Switching the Realtek rtl8188 driver from AP to STA is
  firmware-specific, so `wifi.sh` tries several methods **and writes a full
  firmware probe + result to `logs/wifi.*.log` on the card** — if the join fails
  the first time, that log is exactly what we need to tune it.
- **`MODE=ap`** — leave the camera as its own hotspot. A custom SSID/password is
  best-effort (the firmware may ignore it and keep its factory AP name).

> Credit: the boot-chain hijack was discovered by
> [guino/LSCOutdoor1080P](https://github.com/guino/LSCOutdoor1080P); this payload
> is a trimmed, credential-free adaptation of that approach.

## Build it
Easiest — the interactive wrapper asks AP vs STA and collects the SSID / Wi-Fi
password / Telnet root password, then builds the card:

```powershell
.\prepare-telnet-sd.ps1
```

Or drive the builder directly with env vars (`build-telnet-sd.sh`, compile-free):

```powershell
# STA: join your LAN, with a Telnet root password
docker run --rm -e TELNET_ROOT_PASSWORD='choose-a-password' `
  -e WIFI_MODE='sta' -e WIFI_SSID='YourWiFi' -e WIFI_PASS='your-wifi-pass' `
  -v "${PWD}:/src:ro" -v "${PWD}\output:/output" onvif-armv5-builder `
  bash -c "tr -d '\r' < /src/build-telnet-sd.sh > /tmp/b.sh && SRC=/src OUT=/output bash /tmp/b.sh"

# AP, passwordless root shell (simplest; camera stays its own hotspot)
docker run --rm -e WIFI_MODE='ap' `
  -v "${PWD}:/src:ro" -v "${PWD}\output:/output" onvif-armv5-builder `
  bash -c "tr -d '\r' < /src/build-telnet-sd.sh > /tmp/b.sh && SRC=/src OUT=/output bash /tmp/b.sh"
```

The full `build-sdcard.sh` also produces this card (it calls `build-telnet-sd.sh`)
and honours the same `TELNET_ROOT_PASSWORD` / `WIFI_*` env vars.

## Use it
1. Format a microSD as FAT32 (Rufus/guiformat for cards > 32 GB), copy the
   **contents of `output/sd_card_telnet/`** to its root, insert it, power on,
   wait ~60–90 s.
2. **STA:** the camera joins your network — find its IP in the router's DHCP list,
   then `telnet <camera-ip> 24`. **AP:** connect a device to the camera's hotspot,
   then `telnet <camera-ip> 24`. Log in as `root` (with your password, or straight
   to a shell if you built it passwordless).
3. Swap in the ONVIF/PTZ card (`output/sd_card/`) and run
   `sh /mnt/install/install-autostart.sh` — see the top-level README.

If STA does not come up, pull the card and check `logs/wifi.*.log` — it holds a
firmware probe (available tools, wifi scripts, hostapd/udhcpd config) and the
join result, which pinpoints the exact method for your firmware.

The files here are a template; the actual card is what the builder writes to
`output/sd_card_telnet/`. Your Wi-Fi and root passwords are **never** stored in the
repo — only in `wifi.conf` / `shadow` on the card you build (under `output/`).
