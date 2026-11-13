<#
.SYNOPSIS
    Interactive builder for the Telnet bootstrap SD card.

.DESCRIPTION
    Asks how you want the camera to come up (AP = its own hotspot, or STA = join
    an existing Wi-Fi network), collects the SSID / password / Telnet root
    password, then runs build-telnet-sd.sh inside the onvif-armv5-builder Docker
    image to assemble output\sd_card_telnet\.

    All credentials you type are written ONLY into output\ (git-ignored) and onto
    the SD card you make from it - never into the repository.

    Run from the repo root:   .\prepare-telnet-sd.ps1
#>
[CmdletBinding()]
param(
    [string]$Image = "onvif-armv5-builder"
)
$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot
if (-not (Test-Path (Join-Path $repo "build-telnet-sd.sh"))) {
    throw "Run this from the repo root (build-telnet-sd.sh not found next to the script)."
}

function Read-Secret([string]$Prompt) {
    $s = Read-Host -Prompt $Prompt -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

Write-Host ""
Write-Host "=== Telnet bootstrap SD card builder ===" -ForegroundColor Cyan
Write-Host "How should the camera come up on the network?"
Write-Host "  [1] STA - join an existing Wi-Fi network (camera appears on your LAN)  <- recommended"
Write-Host "  [2] AP  - camera stays its own hotspot (connect to it, then telnet)"
$modeSel = Read-Host "Choose 1 or 2 [1]"
if ([string]::IsNullOrWhiteSpace($modeSel)) { $modeSel = "1" }

$env_args = @()
$wifiMode = if ($modeSel -eq "2") { "ap" } else { "sta" }

if ($wifiMode -eq "sta") {
    $ssid = Read-Host "Wi-Fi SSID to join (exactly as it appears)"
    $sec  = Read-Host "Security: [1] WPA2  [2] open  [1]"
    $security = if ($sec -eq "2") { "open" } else { "wpa2" }
    $pass = ""
    if ($security -eq "wpa2") { $pass = Read-Secret "Wi-Fi password" }
    $staticIp = Read-Host "Static IP for the camera, or blank for DHCP (find it in your router)"
    $env_args += "-e","WIFI_MODE=sta"
    $env_args += "-e","WIFI_SSID=$ssid"
    $env_args += "-e","WIFI_PASS=$pass"
    $env_args += "-e","WIFI_SECURITY=$security"
    if (-not [string]::IsNullOrWhiteSpace($staticIp)) {
        $gw = Read-Host "Gateway (router) IP"
        $env_args += "-e","WIFI_IP=$staticIp"
        $env_args += "-e","WIFI_GW=$gw"
    }
} else {
    Write-Host "AP mode. Leave SSID blank to keep the camera's factory hotspot name." -ForegroundColor DarkGray
    $ssid = Read-Host "Custom AP SSID (blank = factory default)"
    $env_args += "-e","WIFI_MODE=ap"
    if (-not [string]::IsNullOrWhiteSpace($ssid)) {
        $pass = Read-Secret "AP password (WPA2; min 8 chars)"
        $env_args += "-e","WIFI_SSID=$ssid"
        $env_args += "-e","WIFI_PASS=$pass"
        Write-Host "Note: a custom AP SSID is best-effort - the stock firmware may ignore it and keep its factory name." -ForegroundColor Yellow
    }
}

Write-Host ""
$tp = Read-Secret "Telnet root password (blank = passwordless root shell on port 24)"
if (-not [string]::IsNullOrWhiteSpace($tp)) { $env_args += "-e","TELNET_ROOT_PASSWORD=$tp" }

# FTP (optional)
$ftp = Read-Host "Enable root FTP on the camera? (y/N)"
if ($ftp -match '^[Yy]') {
    $env_args += "-e","FTP_ENABLE=1"
    $fp = Read-Host "FTP port [21]"
    if (-not [string]::IsNullOrWhiteSpace($fp)) { $env_args += "-e","FTP_PORT=$fp" }
}

# Make sure output/ exists on the host so the bind mount lands.
$outDir = Join-Path $repo "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host ""
Write-Host "Building telnet card (Docker)..." -ForegroundColor Cyan
$inner = "tr -d '\r' < /src/build-telnet-sd.sh > /tmp/b.sh && SRC=/src OUT=/output bash /tmp/b.sh"
$dockerArgs = @("run","--rm") + $env_args + @(
    "-v","${repo}:/src:ro",
    "-v","${outDir}:/output",
    $Image,"bash","-c",$inner
)
& docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw "Docker build failed (exit $LASTEXITCODE). Is the '$Image' image built? Run: docker compose build" }

Write-Host ""
Write-Host "Done. Card contents are in:  $outDir\sd_card_telnet\" -ForegroundColor Green
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Format a microSD as FAT32 (use Rufus/guiformat for cards > 32 GB)."
Write-Host "  2. Copy the CONTENTS of output\sd_card_telnet\ to the card root."
Write-Host "  3. Insert, power on, wait ~60-90 s."
if ($wifiMode -eq "sta") {
    Write-Host "  4. The camera joins '$ssid' and appears on your LAN; find its IP in the"
    Write-Host "     router's DHCP list, then:  telnet <camera-ip> 24"
    Write-Host "  5. If it does NOT appear, pull the card and send me logs\wifi.*.log from it"
    Write-Host "     (it contains a full firmware probe) - I'll tune the join and rebuild."
} else {
    Write-Host "  4. Connect a device to the camera's Wi-Fi, then:  telnet <camera-ip> 24"
}
