<#
.SYNOPSIS
    Interactive builder for the FULL deployment SD card (ONVIF + RTSP + PTZ),
    including the Telnet bootstrap with your Wi-Fi settings.

.DESCRIPTION
    Asks how the camera should reach the network (AP / STA + SSID/password), the
    Telnet root password, and optional ONVIF credentials, then runs the full
    build-sdcard.sh inside the onvif-armv5-builder Docker image. It produces:
        output\sd_card\         - ONVIF + PTZ package + one-time installer
        output\sd_card_telnet\  - Telnet bootstrap (keeps Telnet on + joins Wi-Fi)
    Copy BOTH onto one FAT32 card (see the printed steps).

    Credentials you type are written ONLY into output\ (git-ignored) and onto the
    card - never into the repository. RTSP (:554/main_ch) is open by design; the
    factory server has no RTSP authentication.

    Run from the repo root:   .\prepare-sd.ps1
#>
[CmdletBinding()]
param(
    [string]$Image = "onvif-armv5-builder",
    [string]$CopyTo = ""   # optional drive/path to copy the finished card onto, e.g. E:\
)
$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot
if (-not (Test-Path (Join-Path $repo "build-sdcard.sh"))) {
    throw "Run this from the repo root (build-sdcard.sh not found next to the script)."
}

function Read-Secret([string]$Prompt) {
    $s = Read-Host -Prompt $Prompt -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

Write-Host ""
Write-Host "=== Full SD card builder (ONVIF + RTSP + PTZ) ===" -ForegroundColor Cyan

# --- Network (for the Telnet bootstrap that ships on the same card) ---
Write-Host "How should the camera reach the network?"
Write-Host "  [1] STA - join an existing Wi-Fi network (camera on your LAN)  <- recommended"
Write-Host "  [2] AP  - camera stays its own hotspot"
$modeSel = Read-Host "Choose 1 or 2 [1]"
if ([string]::IsNullOrWhiteSpace($modeSel)) { $modeSel = "1" }
$env_args = @()
if ($modeSel -eq "2") {
    $env_args += "-e","WIFI_MODE=ap"
    $ssid = Read-Host "Custom AP SSID (blank = factory default)"
    if (-not [string]::IsNullOrWhiteSpace($ssid)) {
        $pass = Read-Secret "AP password (WPA2; min 8 chars)"
        $env_args += "-e","WIFI_SSID=$ssid","-e","WIFI_PASS=$pass"
        Write-Host "Note: a custom AP SSID is best-effort; the firmware may keep its factory name." -ForegroundColor Yellow
    }
} else {
    $ssid = Read-Host "Wi-Fi SSID to join (exactly as it appears)"
    $sec  = Read-Host "Security: [1] WPA2  [2] open  [1]"
    $security = if ($sec -eq "2") { "open" } else { "wpa2" }
    $pass = ""
    if ($security -eq "wpa2") { $pass = Read-Secret "Wi-Fi password" }
    $env_args += "-e","WIFI_MODE=sta","-e","WIFI_SSID=$ssid","-e","WIFI_PASS=$pass","-e","WIFI_SECURITY=$security"
    $staticIp = Read-Host "Static IP for the camera, or blank for DHCP"
    if (-not [string]::IsNullOrWhiteSpace($staticIp)) {
        $gw = Read-Host "Gateway (router) IP"
        $env_args += "-e","WIFI_IP=$staticIp","-e","WIFI_GW=$gw"
    }
}

# --- Telnet root password ---
Write-Host ""
$tp = Read-Secret "Telnet root password (blank = passwordless root shell on port 24)"
if (-not [string]::IsNullOrWhiteSpace($tp)) { $env_args += "-e","TELNET_ROOT_PASSWORD=$tp" }

# --- FTP (optional) ---
$ftp = Read-Host "Enable root FTP on the camera? (y/N)"
if ($ftp -match '^[Yy]') {
    $env_args += "-e","FTP_ENABLE=1"
    $fp = Read-Host "FTP port [21]"
    if (-not [string]::IsNullOrWhiteSpace($fp)) { $env_args += "-e","FTP_PORT=$fp" }
}

# --- ONVIF auth (optional) ---
Write-Host ""
Write-Host "ONVIF authentication (WS-UsernameToken). Blank username = open (trusted LAN)." -ForegroundColor DarkGray
$ou = Read-Host "ONVIF username (blank = no auth)"
if (-not [string]::IsNullOrWhiteSpace($ou)) {
    $op = Read-Secret "ONVIF password"
    $env_args += "-e","ONVIF_USER=$ou","-e","ONVIF_PASS=$op"
}
Write-Host "RTSP (:554/main_ch) is open by design - the factory server has no RTSP auth." -ForegroundColor DarkGray

# --- Build ---
$outDir = Join-Path $repo "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host ""
Write-Host "Building full card (Docker; cross-compile + QEMU tests, a few minutes)..." -ForegroundColor Cyan
$inner = "tr -d '\r' < /src/build-sdcard.sh > /tmp/b.sh && bash /tmp/b.sh"
$dockerArgs = @("run","--rm") + $env_args + @(
    "-v","${repo}:/src:ro",
    "-v","${outDir}:/output",
    $Image,"bash","-c",$inner
)
& docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw "Docker build failed (exit $LASTEXITCODE). Built the image? Run: docker compose build" }

# --- Optional copy onto a formatted card ---
if (-not [string]::IsNullOrWhiteSpace($CopyTo)) {
    if (-not (Test-Path $CopyTo)) { throw "CopyTo path '$CopyTo' not found. Format the card FAT32 first." }
    Write-Host ""
    Write-Host "Copying both card trees onto $CopyTo ..." -ForegroundColor Cyan
    robocopy (Join-Path $outDir "sd_card")        $CopyTo /E /NFL /NDL /NJH /NJS | Out-Null
    robocopy (Join-Path $outDir "sd_card_telnet") $CopyTo /E /NFL /NDL /NJH /NJS | Out-Null
    Write-Host "Copied. Eject the card and put it in the camera." -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Card trees:" -ForegroundColor Green
Write-Host "  $outDir\sd_card\        (ONVIF + RTSP + PTZ + installer)"
Write-Host "  $outDir\sd_card_telnet\ (Telnet bootstrap + your Wi-Fi)"
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Format a microSD as FAT32 (Rufus/guiformat for > 32 GB)."
Write-Host "  2. Copy the CONTENTS of output\sd_card\ to the card root, THEN copy the"
Write-Host "     CONTENTS of output\sd_card_telnet\ on top (replace README.md if asked)."
Write-Host "     (Or re-run with  -CopyTo E:\  to copy both automatically.)"
Write-Host "  3. Insert, power on, wait ~60-90 s, then:  telnet <camera-ip> 24"
Write-Host "  4. On the camera:  sh /tmp/sd/install/install-autostart.sh   then   reboot"
Write-Host "  5. Wait ~90-120 s. Verify: RTSP rtsp://<ip>:554/main_ch, ONVIF http://<ip>:8080,"
Write-Host "     PTZ via your ONVIF client. Health check: sh /tmp/sd/onvif/scripts/verify-installation.sh"
