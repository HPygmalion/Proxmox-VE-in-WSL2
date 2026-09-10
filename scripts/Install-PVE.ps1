#Requires -RunAsAdministrator
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DistroName = 'PVE',
    [string]$InstallPath = '',
    [string]$Hostname = 'pve-lab',
    [string]$BootstrapUrl = 'https://raw.githubusercontent.com/HPygmalion/Proxmox-VE-in-WSL2/main/scripts/bootstrap-pve.sh',
    [ValidateSet('tsinghua', 'official')]
    [string]$Mirror = 'tsinghua',
    [switch]$SkipKeepAlive,
    [switch]$RemoveSourceDebian,
    [switch]$AllowMissingKvm
)

$ErrorActionPreference = 'Stop'
$script:DebianExisted = $false

if (-not $InstallPath) {
    $InstallPath = Join-Path $env:LOCALAPPDATA 'WSL\PVE'
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Note {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
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
        Write-Warning 'Hardware virtualization (Intel VT-x / AMD-V) is not reported as enabled. KVM guests may fail until it is enabled in UEFI/BIOS.'
    }
}

function Get-WslDistros {
    & wsl.exe --list --quiet 2>$null |
        ForEach-Object { ($_ -replace "`0", '').Trim() } |
        Where-Object { $_ }
}

function Ensure-WSL2 {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        Write-Step 'Installing WSL'
        & wsl.exe --install --no-distribution
        throw 'WSL was installed. Reboot Windows, then run this script again.'
    }

    Write-Step 'Updating WSL'
    & wsl.exe --update | Out-Host
    & wsl.exe --set-default-version 2 | Out-Host
}

function Set-IniValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) { $lines.Add($line) }
    }

    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[([^\]]+)\]\s*$' -and $matches[1].Trim() -ieq $Section) {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }
        $lines.Add("[$Section]")
        $lines.Add("$Key=$Value")
    }
    else {
        $nextHeaderIndex = $lines.Count
        for ($i = $headerIndex + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[([^\]]+)\]\s*$') {
                $nextHeaderIndex = $i
                break
            }
        }

        $keyIndex = -1
        for ($i = $headerIndex + 1; $i -lt $nextHeaderIndex; $i++) {
            if ($lines[$i] -match '^\s*([^=#;]+?)\s*=' -and $matches[1].Trim() -ieq $Key) {
                $keyIndex = $i
                break
            }
        }

        if ($keyIndex -ge 0) {
            $lines[$keyIndex] = "$Key=$Value"
        }
        else {
            $lines.Insert($headerIndex + 1, "$Key=$Value")
        }
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

function Enable-WslNestedVirtualization {
    Write-Step 'Enabling WSL2 nested virtualization (KVM support)'
    $configPath = Join-Path $env:USERPROFILE '.wslconfig'
    $before = if (Test-Path -LiteralPath $configPath) { (Get-Content -LiteralPath $configPath | ForEach-Object { $_.Trim() }) -join "`n" } else { '' }
    Set-IniValue -Path $configPath -Section 'wsl2' -Key 'nestedVirtualization' -Value 'true'
    $after = (Get-Content -LiteralPath $configPath | ForEach-Object { $_.Trim() }) -join "`n"

    if ($before -ne $after) {
        Write-Note 'Restarting WSL so the new .wslconfig takes effect.'
        & wsl.exe --shutdown
        Start-Sleep -Seconds 2
    }
}

function Ensure-Debian {
    Write-Step 'Ensuring the Debian WSL distro is installed'
    $list = @(Get-WslDistros)

    if ($list -contains $DistroName) {
        throw "The target WSL distro '$DistroName' already exists. Remove it first or choose another -DistroName."
    }

    if ($list -contains 'Debian') {
        $script:DebianExisted = $true
        Write-Note 'Reusing the existing Debian distro; it will not be removed automatically.'
    }
    else {
        & wsl.exe --install -d Debian --no-launch
        if ($LASTEXITCODE -ne 0) { throw 'Failed to install the Debian WSL distro.' }
        $script:DebianExisted = $false
    }

    & wsl.exe -d Debian -u root -- true
    if ($LASTEXITCODE -ne 0) { throw 'The Debian WSL distro could not be started.' }
}

function Enable-DebianSystemd {
    Write-Step 'Enabling systemd inside Debian'
    $bash = @'
set -e
cfg=/etc/wsl.conf
touch "$cfg"
if grep -q '^\[boot\]' "$cfg"; then
    if grep -q '^systemd=' "$cfg"; then
        sed -i 's/^systemd=.*/systemd=true/' "$cfg"
    else
        sed -i '/^\[boot\]/a systemd=true' "$cfg"
    fi
else
    printf '\n[boot]\nsystemd=true\n' >> "$cfg"
fi
'@

    & wsl.exe -d Debian -u root -- bash -lc $bash
    if ($LASTEXITCODE -ne 0) { throw 'Failed to enable systemd in Debian.' }

    & wsl.exe --terminate Debian | Out-Null
    $init = & wsl.exe -d Debian -u root -- bash -lc 'ps -p 1 -o comm=' 2>$null | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or -not $init) {
        throw 'Debian did not restart after enabling systemd.'
    }
    if ($init.Trim() -ne 'systemd') {
        throw "systemd is not PID 1 inside Debian (got '$($init.Trim())')."
    }
}

function Assert-FreshDebian {
    $pve = & wsl.exe -d Debian -u root -- bash -lc 'command -v pveversion' 2>$null
    if ($pve) {
        throw 'The source Debian distro already contains Proxmox VE. Use a clean Debian distro.'
    }
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $rest = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

function Set-DebianHostname {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
        throw "Invalid hostname: $Name"
    }
    & wsl.exe -d Debian -u root -- bash -lc "hostnamectl set-hostname '$Name' && printf '%s\n' '$Name' > /etc/hostname"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set the Debian hostname.' }
}

function Invoke-Bootstrap {
    Write-Step 'Downloading the PVE bootstrap script'
    $temp = Join-Path $env:TEMP 'proxmox-wsl2'
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $localScript = Join-Path $temp 'bootstrap-pve.sh'
    Invoke-WebRequest -Uri $BootstrapUrl -OutFile $localScript -UseBasicParsing

    Set-DebianHostname -Name $Hostname

    $wslScript = ConvertTo-WslPath -WindowsPath $localScript
    $remoteScript = '/tmp/pve-bootstrap.sh'
    $prepare = "tr -d '\r' < '$wslScript' > '$remoteScript' && chmod 0700 '$remoteScript'"
    & wsl.exe -d Debian -u root -- bash -lc $prepare
    if ($LASTEXITCODE -ne 0) { throw 'Failed to stage the bootstrap script inside Debian.' }

    Write-Step "Installing Proxmox VE 9.2 (mirror: $Mirror)"
    & wsl.exe -d Debian -u root -- env "PVE_MIRROR=$Mirror" bash $remoteScript
    if ($LASTEXITCODE -ne 0) { throw 'The bootstrap script failed. See the output above.' }

    & wsl.exe -d Debian -u root -- rm -f $remoteScript | Out-Null
}

function Import-ToTarget {
    Write-Step "Exporting Debian and importing it as '$DistroName'"
    $temp = Join-Path $env:TEMP 'proxmox-wsl2'
    $tarFile = Join-Path $temp 'pve-wsl2.tar'
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    & wsl.exe --terminate Debian | Out-Null
    & wsl.exe --export Debian $tarFile
    if ($LASTEXITCODE -ne 0) { throw 'Failed to export Debian.' }

    New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
    & wsl.exe --import $DistroName $InstallPath $tarFile --version 2
    if ($LASTEXITCODE -ne 0) { throw 'Failed to import the PVE distro.' }

    Remove-Item -LiteralPath $tarFile -Force -ErrorAction SilentlyContinue

    if ($RemoveSourceDebian -or -not $script:DebianExisted) {
        Write-Step 'Removing the temporary Debian source distro'
        & wsl.exe --unregister Debian | Out-Null
    }
    else {
        Write-Note 'Keeping the original Debian distro registered (use -RemoveSourceDebian to remove it).'
    }

    & wsl.exe --set-default $DistroName | Out-Null
}

function Start-PVE {
    Write-Step 'Enabling and starting the PVE services'
    & wsl.exe -d $DistroName -u root -- bash -lc 'systemctl enable pve-wsl-hosts pve-cluster pvestatd pvedaemon pveproxy pve-guests lxcfs >/dev/null 2>&1 || true; systemctl start pve-wsl-hosts pve-cluster pvestatd pvedaemon pveproxy pve-guests lxcfs; systemctl is-active pve-wsl-hosts pve-cluster pvestatd pvedaemon pveproxy lxcfs'
    if ($LASTEXITCODE -ne 0) { throw 'One or more PVE services failed to start.' }
}

function Test-PveApi {
    Write-Step 'Verifying the PVE API'
    & wsl.exe -d $DistroName -u root -- bash -lc 'for i in $(seq 1 30); do if curl -fsS -k --connect-timeout 2 https://127.0.0.1:8006/api2/json/version >/dev/null 2>&1; then echo "PVE API OK"; exit 0; fi; sleep 2; done; echo "PVE API did not become ready" >&2; exit 1'
    if ($LASTEXITCODE -ne 0) { throw 'The PVE API did not become ready.' }
}

function Assert-KvmAvailable {
    Write-Step 'Checking KVM availability'
    $result = & wsl.exe -d $DistroName -u root -- bash -lc 'test -e /dev/kvm && echo yes || echo no' | Select-Object -Last 1
    if ($result.Trim() -ne 'yes') {
        if ($AllowMissingKvm) {
            Write-Warning '/dev/kvm is missing. KVM guests will not start until nested virtualization is enabled.'
        }
        else {
            throw '/dev/kvm is missing. Enable Windows virtualization and rerun, or pass -AllowMissingKvm to install LXC-only.'
        }
    }
    else {
        Write-Note '/dev/kvm is present.'
    }
}

function Enable-PveKeepAlive {
    $keepAliveScript = Join-Path $PSScriptRoot 'Enable-PVEKeepAlive.ps1'
    if (-not (Test-Path -LiteralPath $keepAliveScript)) {
        Write-Warning "Keep-alive helper not found at $keepAliveScript; skipping autostart registration."
        return
    }

    try {
        & $keepAliveScript -DistroName $DistroName
    }
    catch {
        throw "Failed to configure the PVE keep-alive task: $($_.Exception.Message)"
    }
}

Assert-Windows11
Assert-WindowsVirtualization
Ensure-WSL2
Enable-WslNestedVirtualization
Ensure-Debian
Enable-DebianSystemd
Assert-FreshDebian
Invoke-Bootstrap
Import-ToTarget
Start-PVE
Test-PveApi
Assert-KvmAvailable

if ($SkipKeepAlive) {
    Write-Note 'Skipping keep-alive registration because -SkipKeepAlive was specified.'
}
else {
    Enable-PveKeepAlive
}

Write-Host "`nInstallation complete." -ForegroundColor Green
Write-Host 'Open https://localhost:8006 and log in as root with the password you set.'
Write-Host 'Realm: Linux PAM'
