#Requires -RunAsAdministrator
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DistroName = 'PVE',
    [string]$TaskName = '',
    [switch]$EnableNestedVirtualization,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

if (-not $TaskName) {
    $TaskName = "WSL-$DistroName-Supervisor"
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Note {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Get-WslDistros {
    & wsl.exe --list --quiet 2>$null |
        ForEach-Object { ($_ -replace "`0", '').Trim() } |
        Where-Object { $_ }
}

function Assert-Distro {
    $list = @(Get-WslDistros)
    if ($list -notcontains $DistroName) {
        throw "WSL distro '$DistroName' was not found. Install it first or pass -DistroName."
    }
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

function Enable-NestedVirtualization {
    Write-Step 'Enabling WSL2 nested virtualization'
    $configPath = Join-Path $env:USERPROFILE '.wslconfig'
    $before = if (Test-Path -LiteralPath $configPath) { (Get-Content -LiteralPath $configPath | ForEach-Object { $_.Trim() }) -join "`n" } else { '' }
    Set-IniValue -Path $configPath -Section 'wsl2' -Key 'nestedVirtualization' -Value 'true'
    $after = (Get-Content -LiteralPath $configPath | ForEach-Object { $_.Trim() }) -join "`n"

    if ($before -ne $after) {
        & wsl.exe --shutdown
        Start-Sleep -Seconds 2
    }
}

function Install-LinuxKeepAlive {
    Write-Step "Installing the Linux-side health check in '$DistroName'"
    $linux = @'
set -euo pipefail

cat >/usr/local/sbin/pve-anchor <<'ANCHOR'
#!/bin/sh
exec /usr/bin/sleep infinity
ANCHOR
chmod 0755 /usr/local/sbin/pve-anchor

cat >/usr/local/sbin/pve-healthcheck <<'HEALTH'
#!/usr/bin/env bash
set -u

services=(pve-cluster pvestatd pvedaemon pveproxy pve-guests lxcfs)

if [[ -x /usr/local/lib/pve-wsl/update-hosts ]]; then
    /usr/local/lib/pve-wsl/update-hosts >/dev/null 2>&1 || true
fi

for service in "${services[@]}"; do
    if ! systemctl is-active --quiet "$service.service"; then
        logger -t pve-healthcheck "starting inactive service: $service"
        systemctl start "$service.service" >/dev/null 2>&1 || true
    fi
done

if ! curl -fsS -k --connect-timeout 5 https://127.0.0.1:8006/api2/json/version >/dev/null 2>&1; then
    logger -t pve-healthcheck "PVE API unavailable; restarting API services"
    systemctl restart pvedaemon.service pveproxy.service pvestatd.service >/dev/null 2>&1 || true
fi
HEALTH
chmod 0755 /usr/local/sbin/pve-healthcheck

cat >/etc/systemd/system/pve-wsl-healthcheck.service <<'UNIT'
[Unit]
Description=Check Proxmox VE services and the local API
Wants=network-online.target
After=network-online.target pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-healthcheck
UNIT

cat >/etc/systemd/system/pve-wsl-healthcheck.timer <<'TIMER'
[Unit]
Description=Run the Proxmox VE health check every minute

[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable pve-wsl-healthcheck.timer
systemctl restart pve-wsl-healthcheck.timer
systemctl enable pve-wsl-hosts pve-cluster pvestatd pvedaemon pveproxy pve-guests lxcfs >/dev/null 2>&1 || true
'@

    & wsl.exe -d $DistroName -u root -- bash -lc $linux
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to install the Linux-side health check.'
    }
}

function Get-KeepAlivePaths {
    $directory = Join-Path $env:LOCALAPPDATA 'Proxmox-VE-in-WSL2\keepalive'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    return Join-Path $directory "start-$DistroName-hidden.vbs"
}

function Install-WindowsKeepAlive {
    param([Parameter(Mandatory)][string]$VbsPath)

    Write-Step "Registering the Windows keep-alive task '$TaskName'"
    $vbs = @"
Option Explicit
On Error Resume Next

Dim shell, command, distro
distro = "$DistroName"
If WScript.Arguments.Count > 0 Then distro = WScript.Arguments(0)

Set shell = CreateObject("WScript.Shell")
command = Chr(34) & "C:\Windows\System32\wsl.exe" & Chr(34) & _
    " -d " & Chr(34) & distro & Chr(34) & " -u root --exec /usr/local/sbin/pve-anchor"

Do
    shell.Run command, 0, True
    WScript.Sleep 15000
Loop
"@
    Set-Content -LiteralPath $VbsPath -Value $vbs -Encoding ASCII

    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo `"$VbsPath`" `"$DistroName`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = 'PT20S'

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Force | Out-Null

    Start-ScheduledTask -TaskName $TaskName
}

function Remove-KeepAlive {
    param([Parameter(Mandatory)][string]$VbsPath)

    Write-Step "Removing the Windows keep-alive task '$TaskName'"
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    if (Test-Path -LiteralPath $VbsPath) {
        Remove-Item -LiteralPath $VbsPath -Force
    }

    Write-Step "Disabling the Linux-side health check in '$DistroName'"
    if (@(Get-WslDistros) -contains $DistroName) {
        & wsl.exe -d $DistroName -u root -- bash -lc 'systemctl disable --now pve-wsl-healthcheck.timer >/dev/null 2>&1 || true; rm -f /etc/systemd/system/pve-wsl-healthcheck.timer /etc/systemd/system/pve-wsl-healthcheck.service /usr/local/sbin/pve-healthcheck /usr/local/sbin/pve-anchor; systemctl daemon-reload'
    }
    else {
        Write-Note "Distro '$DistroName' was not found; skipped the Linux-side cleanup."
    }
}

function Test-PveApi {
    Write-Step 'Verifying the PVE API'
    & wsl.exe -d $DistroName -u root -- bash -lc 'for i in $(seq 1 30); do if curl -fsS -k --connect-timeout 2 https://127.0.0.1:8006/api2/json/version >/dev/null 2>&1; then echo "PVE API OK"; exit 0; fi; sleep 2; done; echo "PVE API did not become ready" >&2; exit 1'
    if ($LASTEXITCODE -ne 0) {
        throw 'The PVE API did not become ready.'
    }
}

$vbsPath = Get-KeepAlivePaths

if ($Uninstall) {
    Remove-KeepAlive -VbsPath $vbsPath
    Write-Host "`nKeep-alive removed." -ForegroundColor Green
    return
}

Assert-Distro

if ($EnableNestedVirtualization) {
    Enable-NestedVirtualization
}
else {
    $kvm = & wsl.exe -d $DistroName -u root -- bash -lc 'test -e /dev/kvm && echo yes || echo no' | Select-Object -Last 1
    if (-not $kvm -or $kvm.Trim() -ne 'yes') {
        Write-Note '/dev/kvm is missing. KVM guests will not start until nested virtualization is enabled.'
        Write-Note 'Rerun this script with -EnableNestedVirtualization to update .wslconfig and restart WSL.'
    }
}

Install-LinuxKeepAlive
Install-WindowsKeepAlive -VbsPath $vbsPath
Test-PveApi

Write-Host "`nKeep-alive configured." -ForegroundColor Green
Write-Host "Task: $TaskName"
Write-Host "Launcher: $vbsPath"
