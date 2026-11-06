#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DistroName = 'PVE',
    [string]$TaskName = '',
    [switch]$LinuxOnly,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
Assert-DistroName $DistroName
if (-not $TaskName) { $TaskName = "WSL-$DistroName-Supervisor" }
$description = "Proxmox-VE-in-WSL2 keep-alive for $DistroName (current Windows user)"

function Assert-OwnedTask {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Description -ne $description) {
        throw "Task '$TaskName' belongs to a different launcher. Choose another -TaskName; it will not be overwritten or removed."
    }
    return $existing
}

if ($Uninstall) {
    if (-not $LinuxOnly) {
        $existing = Assert-OwnedTask
        if ($existing) {
            Stop-ScheduledTask -TaskName $TaskName
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
    }
    if (@(Get-WslDistros) -contains $DistroName) {
        $remove = @'
set -e
if systemctl list-unit-files pve-wsl-healthcheck.timer --no-legend | grep -q pve-wsl-healthcheck; then
    systemctl disable --now pve-wsl-healthcheck.timer
fi
rm -f /etc/systemd/system/pve-wsl-healthcheck.timer /etc/systemd/system/pve-wsl-healthcheck.service /usr/local/sbin/pve-healthcheck /usr/local/sbin/pve-anchor
systemctl daemon-reload
'@
        if ((Invoke-WslBash -Distro $DistroName -Script $remove) -ne 0) { throw 'Linux keep-alive removal failed.' }
    }
    Write-Host 'Keep-alive removed. PVE and guests were not stopped.'
    return
}

if (@(Get-WslDistros) -notcontains $DistroName) { throw "WSL distro '$DistroName' does not exist." }
if (-not $LinuxOnly) { $existing = Assert-OwnedTask }
Test-PveApi -Distro $DistroName
$linux = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-keepalive.sh'))
if ((Invoke-WslBash -Distro $DistroName -Script $linux) -ne 0) { throw 'Linux health-check installation failed.' }
if ($LinuxOnly) { Write-Host 'Linux health-check installed; Windows login task explicitly skipped.'; return }

# Direct WSL anchor, with no wrapper that can die with WSL's console session.
# The minute trigger retries after termination; IgnoreNew prevents duplicates.
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wsl.exe" -Argument "-d $DistroName -u root --exec /usr/local/sbin/pve-anchor" -WorkingDirectory $env:SystemRoot
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$login = New-ScheduledTaskTrigger -AtLogOn -User $identity
$login.Delay = 'PT20S'
$retry = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
$trigger = @($login, $retry)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
try {
    if ($existing) { Stop-ScheduledTask -TaskName $TaskName }
    Register-ScheduledTask -TaskName $TaskName -Description $description -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $task = Get-ScheduledTask -TaskName $TaskName
    if ($task.State -ne 'Running') { throw "Task state is $($task.State), not Running." }
}
catch {
    throw "Windows keep-alive registration failed: $($_.Exception.Message). Retry from an Administrator PowerShell for the SAME Windows user. Linux health-check remains installed."
}
Write-Host "Keep-alive verified: $TaskName (login of $identity). Windows sleep/reboot cannot be prevented by this task."
