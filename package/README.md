# onvif-camera: ONVIF for the LSC Smart Connect PTZ 3007325

ONVIF Device/Media service and WS-Discovery for the camera's existing RTSP
stream (`rtsp://<ip>:554/main_ch`, H.264 1920x1080 + AAC from `anyka_ipc`).
Runs from the microSD card and `/tmp`; writes nothing to internal flash.

Copy this folder to the card as `onvif` (the camera sees `/mnt/onvif`), then
over Telnet:

```sh
sh /mnt/onvif/start.sh     # start (safe to repeat)
sh /mnt/onvif/status.sh    # state, PIDs, ports, URLs, log tails
sh /mnt/onvif/stop.sh      # stop; RTSP keeps running
```

ONVIF device service: `http://<camera-ip>:8080/onvif/device_service`

Always run the scripts with `sh`: FAT32 does not keep execute permissions.

## Contents

```
bin/httpd                   BusyBox 1.36.1 httpd (static, CGI, ONVIF patch)
bin/onvif_simple_server     ONVIF CGI (static)
bin/wsd_simple_server       WS-Discovery daemon (static)
etc/onvif_simple_server.conf   identity, interface, port, scopes, video profile
etc/onvif_auth.conf         optional ONVIF user/password (empty = off)
etc/httpd.conf              IP allow list for port 8080 (private ranges only)
etc/onvif.env               script settings (log location, debug levels)
www/onvif/*_files/          SOAP response templates used by the CGI
www/onvif/scripts/          helper scripts for GetDNS / GetNTP
www/onvif/wsd/              WS-Discovery Hello/Bye/ProbeMatches templates
                            (not linked into the served web root; read by -t)
lib/common.sh               shared shell functions
logs/                       log files
start.sh stop.sh status.sh  control scripts (POSIX sh / BusyBox)
VERSION                     component versions and upstream commit
SHA256SUMS                  checksums of all files (sha256sum -c SHA256SUMS)
deployment-guide.md         full installation, test and removal guide
```

All binaries are statically linked for ARM926EJ-S (ARMv5TEJ, EABI5,
soft-float) and need no libraries from the camera.

Runtime files: `/tmp/onvif` (binaries, generated config, web root, PID
files; removed by `stop.sh`) and `/tmp/onvif.lock` while a script runs.

Read `deployment-guide.md` for testing with PowerShell and ONVIF Device
Manager, authentication, access control, and the known limitations.
