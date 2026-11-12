# Deployment guide: ONVIF for the LSC Smart Connect PTZ 3007325

This package adds an ONVIF Device + Media service and WS-Discovery to the
camera. The existing RTSP stream of `anyka_ipc` is advertised unchanged:

    rtsp://<camera-ip>:554/main_ch    (H.264 1920x1080, AAC)

Everything runs from the microSD card and from RAM (`/tmp/onvif`). Nothing
is written to the internal flash, `anyka_ipc` is not stopped or modified,
and no boot script is changed.

| Component | Port | Program |
| --- | --- | --- |
| ONVIF SOAP (Device, Media, DeviceIO, Events) | TCP 8080 | BusyBox `httpd` + `onvif_simple_server` (CGI) |
| WS-Discovery | UDP 3702 (multicast 239.255.255.250) | `wsd_simple_server` |

Device service URL: `http://<camera-ip>:8080/onvif/device_service`

In the examples the camera has the address `192.168.1.100`. Replace it if
DHCP gave the camera another address. The ONVIF configuration itself
contains no fixed IP address.

---

## 0. Build the package (Windows, Docker Desktop)

PowerShell, in the project folder:

```powershell
cd C:\Users\T-Rex\Documents\Projects\onvif-server
docker compose build
docker compose run --rm build
```

Results in `.\output`:

```
output\onvif-camera\          the deployment folder
output\onvif-camera.tar.gz    the same folder as an archive
output\SHA256SUMS
output\build-report.md
output\deployment-guide.md
```

Check the archive checksum:

```powershell
Get-FileHash .\output\onvif-camera.tar.gz -Algorithm SHA256
Get-Content .\output\SHA256SUMS
```

---

## 1. Copy the package to the microSD card

The package must end up as `/mnt/onvif` on the camera (the card is mounted
at `/mnt`). The scripts work from any folder, but this guide uses
`/mnt/onvif`.

FAT32 keeps neither Unix permissions nor symbolic links, and the package
does not depend on them. `start.sh` copies the three binaries to `/tmp`
(tmpfs), marks them executable there, and builds the web root in `/tmp`.
Always run the scripts with `sh`.

### Option A: card reader on the PC

Power off the camera, take the card out, put it into the PC. With the card
as drive `E:`:

```powershell
# from the build output folder
Copy-Item -Recurse .\output\onvif-camera E:\onvif

# or from the archive (tar.exe is part of Windows 10/11)
tar -xzf .\output\onvif-camera.tar.gz -C E:\
Rename-Item E:\onvif-camera onvif
```

Eject the card safely, put it back, power the camera on.

### Option B: FTP while the camera runs

Upload the archive with the `curl.exe` that ships with Windows. Where the
file lands depends on the FTP server's root directory: try `/mnt/` first.

```powershell
curl.exe -T .\output\onvif-camera.tar.gz "ftp://192.168.1.100/mnt/" --user root:YOUR_PASSWORD
```

Then unpack it on the camera over Telnet (step 2):

```sh
cd /mnt
gunzip -c onvif-camera.tar.gz | tar -xf -     # or: tar -xzf onvif-camera.tar.gz
mv onvif-camera onvif
rm onvif-camera.tar.gz
```

If `/mnt/onvif` already exists from an earlier version, stop it first
(`sh /mnt/onvif/stop.sh`). Then keep a copy of your edited `etc/` files
and replace the folder.

Optional integrity check on the camera, if its BusyBox has `sha256sum`:

```sh
cd /mnt/onvif && sha256sum -c SHA256SUMS
```

---

## 2. Connect with Telnet

Windows: enable the Telnet client once in an administrator PowerShell, or
use PuTTY (connection type "Telnet").

```powershell
dism /online /Enable-Feature /FeatureName:TelnetClient
telnet 192.168.1.100
```

Log in as `root`.

---

## 3. Start ONVIF manually

One command:

```sh
sh /mnt/onvif/start.sh
```

Expected output (addresses and IDs will differ):

```
=== ONVIF start (...) from /mnt/onvif
Interface wlan0 has address 192.168.1.100
ONVIF authentication: disabled (set user/password in /mnt/onvif/etc/onvif_auth.conf to enable)
Serial number: LSC-XXXXXXXXXXXX
httpd running, PID 1234, TCP port 8080
wsd_simple_server running, PID 1240, UDP port 3702
ONVIF device service: http://192.168.1.100:8080/onvif/device_service
RTSP stream (unchanged): rtsp://192.168.1.100:554/main_ch
```

`start.sh` waits up to 60 s for an IPv4 address on `wlan0`, refuses to
start if TCP 8080 is used by another program, and does nothing if ONVIF is
already running. Running it twice never creates duplicate processes.

What it does:

1. Copies `bin/httpd`, `bin/onvif_simple_server` and `bin/wsd_simple_server`
   to `/tmp/onvif/bin` and runs `chmod 755` on them there (about 0.7 MB of
   tmpfs).
2. Writes `/tmp/onvif/etc/onvif_simple_server.conf` (mode 600) from
   `etc/onvif_simple_server.conf`. It removes CR characters, replaces
   `serial_num=AUTO` and adds the credentials from `etc/onvif_auth.conf`.
3. Builds the web root `/tmp/onvif/www/onvif/`. The endpoints
   `device_service`, `media_service`, `deviceio_service` and `events_service`
   are symlinks to the CGI binary. The XML templates are symlinks to
   `/mnt/onvif/www/onvif/*_files` and are read from the card.
4. Starts `httpd -f -p 8080` with `setsid`, and starts `wsd_simple_server -i
   wlan0 -x http://%s:8080/onvif/device_service ...`, which runs as a daemon.

The serial number is derived from a hash of the wlan0 MAC address. It is
stable across reboots and does not reveal the MAC. To report the real serial
number, set `serial_num=` in `etc/onvif_simple_server.conf`.

The device UUID (WS-Discovery endpoint and `GetEndpointReference`) is
generated by onvif_simple_server from the wlan0 MAC address as a UUIDv5.
It is the same in both programs and across reboots.

---

## 4. Check processes and logs

```sh
sh /mnt/onvif/status.sh       # processes, PIDs, memory, sockets, URLs, log tails
ps | grep /tmp/onvif/bin
cat /mnt/onvif/logs/onvif-control.log      # what start/stop did
cat /mnt/onvif/logs/httpd.log              # httpd errors
cat /mnt/onvif/logs/wsd_simple_server.log  # WS-Discovery daemon
cat /mnt/onvif/logs/onvif_simple_server.log  # last CGI request
```

`status.sh` exits with 0 when httpd and WS-Discovery are both running.

More logging:

| What | How |
| --- | --- |
| Full trace of every SOAP request (CGI) | `echo 5 > /tmp/onvif/onvif_simple_server.debug`, then read `logs/onvif_simple_server.log` (rewritten for every request). `rm /tmp/onvif/onvif_simple_server.debug` turns it off. |
| WS-Discovery trace | `WSD_DEBUG=5` in `etc/onvif.env`, then restart |
| Every HTTP request | `HTTPD_VERBOSE=1` in `etc/onvif.env`, then restart |
| Keep logs in RAM instead of the SD card | `LOG_IN_RAM=1` in `etc/onvif.env`; logs are then in `/tmp/onvif/log` |

---

## 5. Test port 8080

On the camera:

```sh
grep -i ':1F90 ' /proc/net/tcp     # 1F90 = 8080; state 0A = LISTEN
```

From Windows PowerShell:

```powershell
Test-NetConnection 192.168.1.100 -Port 8080

$cam = "192.168.1.100"
function Invoke-Onvif($service, $body) {
    $env = '<?xml version="1.0" encoding="UTF-8"?>' +
      '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" ' +
      'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" ' +
      'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" ' +
      'xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body>' + $body + '</s:Body></s:Envelope>'
    (Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://${cam}:8080/onvif/$service" `
        -ContentType 'application/soap+xml; charset=utf-8' -Body $env).Content
}

Invoke-Onvif device_service '<tds:GetDeviceInformation/>'
Invoke-Onvif device_service '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>'
Invoke-Onvif device_service '<tds:GetServices><tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>'
Invoke-Onvif media_service  '<trt:GetProfiles/>'
Invoke-Onvif media_service  '<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup><trt:ProfileToken>Profile_0</trt:ProfileToken></trt:GetStreamUri>'
```

Expected results:

- `GetDeviceInformation`: Manufacturer `LSC`, Model `LSC Smart PTZ 3007325`,
  FirmwareVersion `3.286.81.13`, HardwareId `AK3918EV330`.
- `GetCapabilities`: the XAddr values contain the current camera IP and port
  8080. There is no PTZ and no Imaging section.
- `GetProfiles`: one profile `Profile_0`, H264 1920x1080, AAC audio encoder.
- `GetStreamUri`: `rtsp://192.168.1.100:554/main_ch`.

If authentication is enabled, `GetDeviceInformation`, `GetProfiles` and
`GetStreamUri` need a WS-UsernameToken. `GetCapabilities`, `GetServices` and
`GetSystemDateAndTime` still answer without one. Use an ONVIF client
(step 7) to test with credentials.

---

## 6. Test WS-Discovery (UDP 3702)

On the camera:

```sh
grep ':0E76 ' /proc/net/udp       # 0E76 = 3702, socket must exist
cat /mnt/onvif/logs/wsd_simple_server.log
```

From Windows PowerShell, a standard ONVIF Probe:

```powershell
$cam = "192.168.1.100"
$probe = @"
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
<s:Header><a:Action s:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action>
<a:MessageID>uuid:$([guid]::NewGuid())</a:MessageID>
<a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>
<a:To s:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To></s:Header>
<s:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></s:Body></s:Envelope>
"@
function Send-Probe($target) {
    $udp = New-Object System.Net.Sockets.UdpClient 0
    $udp.Client.ReceiveTimeout = 3000
    $b = [Text.Encoding]::UTF8.GetBytes($probe)
    [void]$udp.Send($b, $b.Length, $target, 3702)
    $ep = New-Object System.Net.IPEndPoint([Net.IPAddress]::Any, 0)
    try { while ($true) { $r = $udp.Receive([ref]$ep); "--- reply from $($ep.Address)"; [Text.Encoding]::UTF8.GetString($r) } }
    catch { "--- no more replies" } finally { $udp.Close() }
}
Send-Probe $cam                # unicast probe: tests the daemon itself
Send-Probe "239.255.255.250"   # multicast probe: what ONVIF clients send
```

The `ProbeMatches` answer must contain:

- `<d:Types>tdn:NetworkVideoTransmitter</d:Types>`
- `<d:XAddrs>http://192.168.1.100:8080/onvif/device_service</d:XAddrs>`
- the scopes from `etc/onvif_simple_server.conf` (Profile/Streaming,
  type/video_encoder, type/audio_encoder, hardware/3007325,
  name/LSC_Smart_PTZ_3007325). PTZ and Profile T are not advertised.

If the unicast probe works and the multicast probe gets no answer, check
three things: the Windows firewall (allow inbound UDP for PowerShell, or test
from another device), PCs with several network adapters (Docker/Hyper-V
vEthernet; the multicast may leave on the wrong adapter), and access points
that filter multicast between Wi-Fi and LAN (IGMP snooping, "multicast
enhancement", client isolation).

---

## 7. Verify in an ONVIF client

ONVIF Device Manager (Windows):

1. Start ODM. The camera should appear in the device list (WS-Discovery).
   If it does not, use "Add" and enter
   `http://192.168.1.100:8080/onvif/device_service`.
2. If you enabled authentication, enter the user and password from
   `etc/onvif_auth.conf` at the top left.
3. "Identification" shows LSC / LSC Smart PTZ 3007325 / 3.286.81.13.
4. "Live video" plays `Profile_0` over RTSP from `anyka_ipc`.

NVR or other client (Synology, Frigate, Blue Iris, Unifi, ...): add an ONVIF
camera with host `192.168.1.100`, port `8080`, and the ONVIF credentials or
none. The client receives `rtsp://192.168.1.100:554/main_ch` through
`GetStreamUri`.

If a client fails, try the compatibility switches in
`etc/onvif_simple_server.conf` one at a time, restarting after each change:
`adv_fault_if_unknown=1`, `adv_fault_if_set=1`, and `adv_synology_nvr=1` for
Synology.

---

## 8. Stop ONVIF without interrupting RTSP

```sh
sh /mnt/onvif/stop.sh
```

`stop.sh` signals only processes whose command line starts with
`/tmp/onvif/bin/` (httpd and wsd_simple_server). WS-Discovery sends a "Bye".
`anyka_ipc`, and with it RTSP, keeps running. The tmpfs files in
`/tmp/onvif` are removed; the logs on the card stay.

Check that RTSP still works, for example with VLC or
`ffplay -rtsp_transport tcp rtsp://192.168.1.100:554/main_ch`.

Restart: `sh /mnt/onvif/stop.sh; sh /mnt/onvif/start.sh`.

A reboot of the camera also stops ONVIF, because only RAM is used. There is
no autostart yet.

---

## 9. Remove the package

```sh
sh /mnt/onvif/stop.sh
rm -rf /mnt/onvif
rm -rf /tmp/onvif /tmp/onvif.lock    # normally already gone after stop.sh
```

That is all. The package never wrote to `/etc`, `/etc/config`, `/usr` or any
MTD partition.

---

## Configuration reference

All files are in `/mnt/onvif/etc/` and can be edited on the PC (Windows line
endings are handled). Restart after a change.

| File | Content |
| --- | --- |
| `onvif_simple_server.conf` | Device identity, interface (`ifs=wlan0`), port (`port=8080`), scopes, the video profile. Upstream format: `key=value`, comments only on their own line, **line order matters**. |
| `onvif_auth.conf` | `user=` / `password=` for ONVIF authentication (empty user = disabled) |
| `httpd.conf` | IP allow/deny list for port 8080 |
| `onvif.env` | Script settings: `WAIT_IP_SECS`, `LOG_IN_RAM`, `WSD_DEBUG`, `HTTPD_VERBOSE`, `MIN_TMP_FREE_KB` |

### Authentication

`onvif_simple_server` checks WS-Security UsernameToken with PasswordDigest,
which is what ONVIF clients send.

```
user=admin
password=choose-a-password
```

- Off by default, for the first tests on the trusted LAN.
- These credentials protect only the ONVIF SOAP calls. They do not protect
  RTSP, Telnet or FTP.
- `GetSystemDateAndTime`, `GetCapabilities`, `GetServices`,
  `GetServiceCapabilities` and `GetUsers` are always answered (clients need
  them before logging in).
- Without authentication, any client that can reach port 8080 can call
  `SystemReboot`, which reboots the camera.
- There is no replay protection (the `Created` timestamp is not checked) and
  no HTTPS. Treat it as protection against accidental access on the LAN, not
  against an attacker on the network.

### Network access

`httpd.conf` allows only loopback and the private address ranges (10/8,
172.16/12, 192.168/16) by default. To allow only your camera subnet, use:

```
A:127.0.0.1
A:192.168.100.0/24
D:*
```

WS-Discovery (UDP 3702) has no access list. It only reveals the device URL.
Do not forward ports 8080 or 3702 from the internet to the camera.

### Frame rate and bit rate

The configuration uses `framerate=0` and `bitrate=0`, meaning "unknown",
because the encoder settings of `anyka_ipc` have not been measured. The ONVIF
schema requires numbers in the VideoEncoderConfiguration, so onvif_simple_server
reports its built-in defaults there (30 fps, 5000 kbit/s), and 0 as the
VideoSource frame rate. Clients do not use these values for playback; they
read the real values from the RTSP stream.

To report real values, measure the stream on the PC with FFmpeg:

```powershell
ffprobe -v error -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,width,height,avg_frame_rate,r_frame_rate rtsp://192.168.1.100:554/main_ch
ffmpeg -rtsp_transport tcp -i rtsp://192.168.1.100:554/main_ch -t 60 -c copy -f null -    # last line: average bitrate
```

Then set, for example, `framerate=15` and `bitrate=2048` (kbit/s) in
`onvif_simple_server.conf` and restart.

The AAC values in the AudioEncoderConfiguration (16 kHz, 50 kbit/s) are fixed
in the upstream code and were not measured either. `ffprobe ... -select_streams a:0`
shows the real sample rate. The same applies to `Quality` (100), `GovLength`
(40) and `H264Profile` (High) in the VideoEncoderConfiguration, which come from
the upstream template `media_service_files`. `ffprobe -show_entries
stream=profile` shows the real H.264 profile.

---

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `ERROR: no IPv4 address on wlan0` | Wi-Fi not connected yet. Run again later, or raise `WAIT_IP_SECS`. |
| `TCP port 8080 is already in use` | Another program listens on 8080: `grep ':1F90 ' /proc/net/tcp`. Change `port=` in `onvif_simple_server.conf`. |
| `wsd_simple_server did not start` | `logs/wsd_simple_server.log`. Is UDP 3702 already used by `anyka_ipc`? Run `grep ':0E76 ' /proc/net/udp` **before** starting. |
| httpd answers 403 | The client address is not allowed in `etc/httpd.conf`. |
| HTTP 500 / SOAP fault for every call | `echo 5 > /tmp/onvif/onvif_simple_server.debug`, repeat the request, read `logs/onvif_simple_server.log`. |
| Authentication fails | Camera clock: many clients compare it. Check the time with `date`; GetSystemDateAndTime reports it. Check the user/password in `etc/onvif_auth.conf`. |
| `/tmp has less free space` | `df /tmp`. The package needs about 0.7 MB in `/tmp`. |
| Scripts fail with `^M` or `not found` | The files were saved with Windows line endings by an editor. `start.sh` strips CR from the config files, but the `.sh` scripts themselves must keep LF. Copy them from the package again. |

## Later: autostart

The camera already starts RTSP from the SD card. To add ONVIF later, call
`sh /mnt/onvif/start.sh` from that mechanism **after** `anyka_ipc` and Wi-Fi
are up (`start.sh` waits for the IP address by itself), for example:

```sh
sh /mnt/onvif/start.sh > /dev/null 2>&1 &
```
