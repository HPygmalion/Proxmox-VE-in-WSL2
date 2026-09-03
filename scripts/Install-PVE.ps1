#Requires -RunAsAdministrator
#Requires -Version 5.1

param(
    [string]$DistroName = 'PVE',
    [string]$InstallPath = 'D:\WSL\PVE',
    [string]$Hostname = 'HPygmalion',
    [string]$BootstrapUrl = 'https://raw.githubusercontent.com/HPygmalion/Proxmox-VE-in-WSL2/main/scripts/bootstrap-pve.sh'
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-Windows11 {
    $version = [System.Environment]::OSVersion.Version
    if ($version.Build -lt 22000) {
        throw "Windows 11 or Windows Server 2025+ is required. Current build: $($version.Build)"
    }
}

function Assert-WindowsVirtualization {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cpu.VirtualizationFirmwareEnabled -ne $true) {
        Write-Warning 'Virtualization is not reported as enabled in Windows.'
        Write-Warning 'Enable Intel VT-x / AMD-V in BIOS/UEFI before installing PVE.'
    }
}

function Ensure-WSL2 {
    $wsl = Get-Command wsl -ErrorAction SilentlyContinue
    if (-not $wsl) {
        Write-Step 'Installing WSL'
        wsl --install --no-distribution
        throw 'WSL was installed. Please reboot Windows, then run this script again.'
    }

    $version = & wsl --version 2>$null
    if (-not $version) {
        throw 'WSL command exists but did not return version. Update WSL and try again.'
    }

    Write-Step 'Updating WSL'
    & wsl --update | Out-Host
    & wsl --set-default-version 2 | Out-Host
}

function Ensure-Debian {
    Write-Step "Ensuring Debian 13 WSL distro is installed"
    $list = & wsl --list --quiet 2>$null
    if ($list -notcontains 'Debian') {
        & wsl --install -d Debian --no-launch
        throw 'Debian WSL was installed. Please reboot Windows if prompted, then run this script again.'
    }
}

function Assert-FreshDebian {
    $pve = & wsl -d Debian -u root -- bash -lc 'command -v pveversion' 2>$null
    if ($pve) {
        throw 'Target Debian already contains Proxmox VE. This script only installs into a clean Debian.'
    }
}

function Invoke-Bootstrap {
    Write-Step 'Downloading PVE bootstrap script'
    $temp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP 'proxmox-wsl2') -Force
    $script = Join-Path $temp.FullName 'bootstrap-pve.sh'
    Invoke-WebRequest -Uri $BootstrapUrl -OutFile $script -UseBasicParsing

    Write-Step "Preparing hostname: $Hostname"
    & wsl -d Debian -u root -- bash -lc "hostnamectl set-hostname '$Hostname'; printf '%s\n' '$Hostname' > /etc/hostname"

    Write-Step 'Installing Proxmox VE 9.2 and configuring WSL integration'
    Get-Content $script -Raw | & wsl -d Debian -u root -- bash

    if ($LASTEXITCODE -ne 0) {
        throw 'Bootstrap script failed. See output above.'
    }
}

function Import-ToTarget {
    Write-Step "Exporting clean Debian and importing as $DistroName"
    $temp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP 'proxmox-wsl2') -Force
    $tarFile = Join-Path $temp.FullName 'pve-wsl2.tar'

    & wsl --shutdown
    & wsl --export Debian $tarFile
    if ($LASTEXITCODE -ne 0) { throw 'Failed to export Debian.' }

    & wsl --unregister Debian
    if ($LASTEXITCODE -ne 0) { throw 'Failed to unregister Debian.' }

    New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
    & wsl --import $DistroName $InstallPath $tarFile --version 2
    if ($LASTEXITCODE -ne 0) { throw 'Failed to import PVE distro.' }

    & wsl --set-default $DistroName
    Remove-Item $tarFile -Force -ErrorAction SilentlyContinue
}

function Start-PVE {
    Write-Step 'Starting PVE services'
    & wsl -d $DistroName -u root -- bash -lc 'systemctl start pve-cluster pvestatd pvedaemon pveproxy lxcfs; sleep 5; systemctl is-active pve-cluster pvestatd pvedaemon pveproxy lxcfs'

    Write-Step 'Verifying PVE API'
    & wsl -d $DistroName -u root -- bash -lc 'ss -ltn | grep -q ":8006 " && echo "Web UI: https://localhost:8006"'
}

Assert-Windows11
Assert-WindowsVirtualization
Ensure-WSL2
Ensure-Debian
Assert-FreshDebian
Invoke-Bootstrap
Import-ToTarget
Start-PVE

Write-Host "`nInstallation complete." -ForegroundColor Green
Write-Host "Open https://localhost:8006 and login as root with the password you set."
Write-Host "Realm: Linux PAM"
