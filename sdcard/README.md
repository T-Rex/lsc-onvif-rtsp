# ONVIF + PTZ for LSC Smart Connect PTZ 3007325 — SD card

Copy the **contents of this folder** to the root of a FAT32 microSD card, insert
it into the camera, and run the one-time installer. After that the camera serves
RTSP, ONVIF and PTZ automatically on every boot.

## What's here
```
onvif/                     the ONVIF + PTZ package (runs from the SD)
onvif_autostart.enabled    opt-in flag: start ONVIF at boot
rtsp_autostart.enabled     opt-in flag: start RTSP (factory mode) at boot
rtsp_factory.ini           RTSP factory-mode config
install/                   one-time autostart installer (see below)
```

## One-time setup (clean camera)
The camera launches its boot scripts from internal flash (`/etc/config`), which
an SD card cannot populate on its own. Run the installer **once** over Telnet to
hook the SD autostart into the boot sequence:

```sh
sh /mnt/install/install-autostart.sh
reboot
```

`install-autostart.sh` installs `/etc/config/rtsp_autostart.sh` and hooks it into
the camera's `sensor_driver.sh` (backing up the stock copy). It writes flash only
on the first run and is safe to re-run. To undo, it prints the exact restore
commands.

## After reboot (~90–120 s)
- RTSP: `rtsp://<camera-ip>:554/main_ch` (H.264 1920×1080 + AAC)
- ONVIF: `http://<camera-ip>:8080/onvif/device_service` (WS-Discovery on UDP 3702)
- PTZ: ONVIF ContinuousMove / Stop, via the bridge

Check health any time:
```sh
sh /mnt/onvif/scripts/verify-installation.sh
```

## Turn things off
- PTZ only: `rm /mnt/onvif/ptz_autostart.enabled` (ONVIF/RTSP stay)
- ONVIF: `rm /mnt/onvif_autostart.enabled`
- Everything from the SD: `rm /mnt/onvif_autostart.enabled /mnt/rtsp_autostart.enabled` and uninstall the flash hook (see `install-autostart.sh`).

Nothing here modifies the kernel, the motor driver, Wi-Fi or the factory
firmware. Details and build instructions: the project README.
