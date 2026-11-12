# DEPLOYMENT — onvif_ptz_bridge (staged, non-destructive)

Follow the phases in order. Every live-affecting step asks for a typed `YES`.
`deploy.sh` snapshots the current install to `/mnt/backups` before replacing it,
so the previously working install is never destroyed. No `tr`/`gzip`/python on
the camera. Movement tests need per-action operator authorization.

## 0. Copy the package to the SD (Windows PowerShell + FTP, or Telnet `tar`)
Transfer the archive from Windows to the camera's SD over FTP (busybox ftpd,
root path), then extract on the camera:
```powershell
# Windows PowerShell, from the repo root. Upload the uncompressed tar in BINARY mode.
$cam = "192.168.1.100"
$ftp = [System.Net.FtpWebRequest]::Create("ftp://$cam/onvif-ptz-bridge-1.4.0-armv5.tar")
$ftp.Credentials = New-Object System.Net.NetworkCredential("root","<telnet-password>")
$ftp.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
$ftp.UseBinary = $true
$bytes = [System.IO.File]::ReadAllBytes("output\onvif-ptz-bridge-1.4.0-armv5.tar")
$s = $ftp.GetRequestStream(); $s.Write($bytes,0,$bytes.Length); $s.Close()
"uploaded $($bytes.Length) bytes"
```
(Or use any FTP client in BINARY mode; the file lands at `/mnt/...` on the SD.)
Verify the SHA on the camera before extracting:
```sh
sha256sum /mnt/onvif-ptz-bridge-1.4.0-armv5.tar   # compare to output/SHA256SUMS on the dev host
```
Then extract it to a **staging** dir that does not touch the live install:
```sh
# on the camera (Telnet), uncompressed tar:
mkdir -p /mnt/onvif-next.stage
tar -xf /mnt/onvif-ptz-bridge-1.4.0-armv5.tar -C /mnt/onvif-next.stage
mv /mnt/onvif-next.stage/onvif-ptz-bridge-1.4.0 /mnt/onvif-next
```
FAT32 drops exec bits — the scripts run via `sh`, and `deploy.sh` chmods the
staged binaries before use.

## Phase 1 — recovery readiness
```sh
sh /mnt/onvif/scripts/backup.sh pre-deploy           # snapshot current install -> /mnt/backups
sh /mnt/onvif/scripts/restore.sh list                # confirm the snapshot is listed
sh /mnt/onvif/scripts/restore.sh latest              # DRY-RUN: prints the safe staged plan
```
`restore.sh` is the hardened recovery (staging → validate → atomic swap →
rollback on failure). Use `--commit` only to actually recover. (`deploy.sh
promote` also takes its own snapshot automatically, so this manual one is just
belt-and-braces.)

## Phase 4 — live staging (candidate in RAM; /mnt/onvif untouched)
```sh
sh /mnt/onvif-next/scripts/deploy.sh dry             # review the plan
sh /mnt/onvif-next/scripts/deploy.sh stage           # asks YES
```
This verifies the candidate package (and its `SHA256SUMS` if present), proves the
candidate executes and reports its version, confirms no motion, stops the running
bridge gracefully, starts the candidate from `/tmp`, and checks exactly one
daemon. `/mnt/onvif` is left untouched.

## Phase 5 — live acceptance (see ACCEPTANCE_TESTS.md)
```sh
sh /mnt/onvif-next/scripts/verify-installation.sh    # read-only health + identity
```
Then the bounded movement + ONVIF tests. **Each motor move needs operator
authorization**: read position, pick a safe direction/bounded duration, keep Stop
available, return to a safe position after. Do not repeat the physical speed
tests already done; Test 6 (600 vs 750) only if a speed profile is wanted.

## Phase 6 — production promotion (persistent install)
Only after acceptance passes:
```sh
sh /mnt/onvif-next/scripts/deploy.sh promote         # asks YES
```
Snapshots the current `/mnt/onvif` to `/mnt/backups/onvif-<ts>-pre-promote.tar`,
installs the candidate binary + scripts + config + PTZ templates into `/mnt/onvif`
(atomic `.new`+`mv`), restarts via `enable-ptz.sh`, and confirms the daemon
reports the candidate version with exactly one daemon. The pre-promote snapshot is
the rollback target (`restore.sh latest --commit`).

## Phase 7 — reboot validation
After confirming the boot path and that Telnet can be recovered, reboot once and
re-check with `verify-installation.sh`: Telnet, `anyka_ipc`, RTSP 554, ONVIF 8080,
WS-Discovery, exactly one bridge, valid positions, no unexpected movement,
speed_step 600/600, Stop + movement work. If it fails, run
`restore.sh latest --commit` (or reboot — the SD autostart restores the install).

## Post-deployment checks (§19)
```sh
sh /mnt/onvif/scripts/ptz-status.sh
/tmp/onvif/bin/onvif_ptz_bridge ping
/tmp/onvif/bin/onvif_ptz_bridge status
cat /sys/devices/platform/motor0/motor/current_pos
cat /sys/devices/platform/motor1/motor/current_pos
cat /sys/devices/platform/motor0/motor/speed_step
cat /sys/devices/platform/motor1/motor/speed_step
ps | grep -E '[a]nyka_ipc|[h]ttpd|[w]sd|[o]nvif_ptz_bridge'
netstat -lnt
```
Confirm the reported `version=` and the bridge SHA-256 match the intended build;
verify HTTP/ONVIF/RTSP/WS-Discovery from the dev machine (a running process alone
does not prove a working service).
