#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DistroName = 'PVE',
    [string]$InstallPath = '',
    [ValidatePattern('^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$')]
    [string]$Hostname = 'pve-lab',
    [ValidateSet('tsinghua', 'official')][string]$Mirror = 'tsinghua',
    [string]$NatSubnet = '10.10.10.0/24',
    [Security.SecureString]$RootPassword,
    [switch]$NoNat,
    [switch]$SkipKeepAlive,
    [switch]$AllowMissingKvm,
    [switch]$NoSetDefault,
    [switch]$ForceWslShutdown,
    [switch]$Resume,
    [switch]$UpdateWsl
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$SourceDistro = "$DistroName-src"
if (-not $InstallPath) { $InstallPath = Join-Path $env:LOCALAPPDATA "WSL\$DistroName" }
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
# Keep both large build artifacts on the target drive, not LOCALAPPDATA.
$SourceInstallPath = "$InstallPath-src"
$TransferArchive = "$InstallPath-transfer.tar"
$stateDirectory = Join-Path $env:LOCALAPPDATA 'Proxmox-VE-in-WSL2\installs'
$stage = 'preflight'
$exitCode = 1

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }

function Assert-Preflight {
    Assert-DistroName $DistroName
    Assert-DistroName $SourceDistro
    if ([Environment]::OSVersion.Version.Build -lt 22000) { throw 'Windows 11 or Windows Server 2025+ is required.' }
    if ($NatSubnet -notmatch '^(10\.(\d{1,3})\.(\d{1,3})|192\.168\.(\d{1,3})|172\.(1[6-9]|2\d|3[01])\.(\d{1,3}))\.0/24$') {
        throw 'NatSubnet must be a private IPv4 /24 network ending in .0/24.'
    }
    foreach ($octet in $NatSubnet.Split('/')[0].Split('.')) {
        if ([int]$octet -gt 255) { throw 'NatSubnet contains an invalid IPv4 octet.' }
    }
    if ($InstallPath -notmatch '^[A-Za-z]:\\' -or $InstallPath -match '[\x00-\x1f]') {
        throw 'InstallPath must be a local drive path.'
    }
    foreach ($file in 'bootstrap-pve.sh','Common.ps1','Enable-PVEKeepAlive.ps1','install-keepalive.sh') {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) { throw "Missing $file. Download/extract the complete repository, not one script." }
    }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'Install WSL first: wsl --install --no-distribution. Reboot, then rerun this installer.' }
    $distros = @(Get-WslDistros)
    $script:targetExists = $distros -contains $DistroName
    if ($targetExists -and -not $Resume) { throw "Target '$DistroName' already exists. Nothing will be overwritten; choose a new -DistroName." }
    if (-not $targetExists -and (Test-Path -LiteralPath $InstallPath)) {
        if (@(Get-ChildItem -LiteralPath $InstallPath -Force).Count) { throw "InstallPath is not empty: $InstallPath" }
    }
    $drive = Get-PSDrive -Name $InstallPath.Substring(0,1) -ErrorAction Stop
    if ($drive.Free -lt 15GB) { throw 'At least 15 GiB of free disk space is required.' }
    $running = @(& wsl.exe --list --running --quiet 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    foreach ($other in $running) {
        if ($other -in @($DistroName, $SourceDistro)) { continue }
        $probe = 'if command -v pveversion >/dev/null 2>&1; then exit 10; fi'
        if ((Invoke-WslBash -Distro $other -Script $probe) -eq 10) {
            throw "PVE is running in '$other'. Stop its guests and keep-alive first; two PVE nodes must not share WSL ports."
        }
    }
    $script:statePath = Join-Path $stateDirectory "$DistroName.json"
    $script:state = $null
    if ($targetExists -or ($distros -contains $SourceDistro)) {
        if (-not $Resume -or -not (Test-Path -LiteralPath $statePath)) {
            throw "Build distro '$SourceDistro' exists. Use -Resume only for a build owned by this installer; no distro is deleted automatically."
        }
        $script:state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        if ($state.Distro -ne $DistroName -or $state.Source -ne $SourceDistro -or $state.InstallPath -ne $InstallPath -or $state.Hostname -ne $Hostname -or $state.NatSubnet -ne $NatSubnet -or $state.NoNat -ne [bool]$NoNat -or $state.Mirror -ne $Mirror) {
            throw 'Resume parameters differ from the original install. Use the same options or a new distro name.'
        }
    }
}

function Read-PvePassword {
    if ($RootPassword) { return $RootPassword }
    if ([Console]::IsInputRedirected) { throw 'No terminal is available. Supply -RootPassword as a SecureString; no password is generated.' }
    Write-Host 'Choose the root password for the PVE web UI. It is never printed or saved.'
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $first = Read-Host -AsSecureString 'Root password'
        $second = Read-Host -AsSecureString 'Repeat password'
        $a = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($a)
            $repeat = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
            if ($plain.Length -gt 0 -and $plain -ceq $repeat -and $plain -notmatch "[\r\n\x00]") { return $first }
        }
        finally {
            $plain = $null; $repeat = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
        }
        Write-Warning 'Passwords must match exactly, be nonempty, and contain no line breaks.'
    }
    throw 'Password confirmation failed; no installation was started.'
}

function Initialize-Wsl {
    if ($UpdateWsl) {
        Write-Step 'Updating WSL (may require administrator approval)'
        & wsl.exe --update | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'WSL update failed. Update WSL separately and rerun without -UpdateWsl.' }
    }
    # A global shutdown is never implicit while another distro is running.
    $config = Join-Path $env:USERPROFILE '.wslconfig'
    $before = if (Test-Path -LiteralPath $config) { [IO.File]::ReadAllText($config) } else { '' }
    if ($before -notmatch '(?im)^\s*nestedVirtualization\s*=\s*true\s*$') {
        Set-IniValue -Path $config -Section wsl2 -Key nestedVirtualization -Value true
        $running = @(& wsl.exe --list --running --quiet 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
        if ($running.Count -and -not $ForceWslShutdown) {
            throw '.wslconfig was updated. Stop your guests, run wsl --shutdown, then rerun. No running distro was stopped.'
        }
        & wsl.exe --shutdown
        if ($LASTEXITCODE -ne 0) { throw 'Could not restart WSL after configuring nested virtualization.' }
    }
}

function New-BuildDistro {
    if ($script:state) { Write-Step "Resuming '$SourceDistro'"; return }
    if ((Test-Path -LiteralPath $SourceInstallPath) -and @(Get-ChildItem -LiteralPath $SourceInstallPath -Force).Count) {
        throw "Build directory is not empty: $SourceInstallPath. Nothing will be overwritten."
    }
    if (Test-Path -LiteralPath $TransferArchive) { throw "Transfer archive already exists: $TransferArchive. Preserve or move it before installing." }
    Write-Step "Creating a clean Debian build distro '$SourceDistro' at $SourceInstallPath"
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $script:state = [pscustomobject]@{ Distro=$DistroName; Source=$SourceDistro; InstallPath=$InstallPath; Hostname=$Hostname; Mirror=$Mirror; NatSubnet=$NatSubnet; NoNat=[bool]$NoNat; BootstrapComplete=$false }
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    & wsl.exe --install -d Debian --name $SourceDistro --location $SourceInstallPath --no-launch
    if ($LASTEXITCODE -ne 0) {
        if (@(Get-WslDistros) -contains $SourceDistro) { throw 'WSL partially created the build distro. Inspect it before retrying with -Resume.' }
        Write-Warning 'Initial Debian download failed; retrying using --web-download.'
        & wsl.exe --install -d Debian --name $SourceDistro --location $SourceInstallPath --no-launch --web-download
        if ($LASTEXITCODE -ne 0) { throw 'Debian download failed. Check network access to the Microsoft WSL distribution catalog and image host.' }
    }
}

function Initialize-Build {
    $setup = @'
set -euo pipefail
if command -v pveversion >/dev/null && [[ ! -f /etc/pve-wsl-build ]]; then
    echo 'This distro already contains PVE and is not an installer-owned build.' >&2
    exit 1
fi
touch /etc/pve-wsl-build
# Minimal WSL image: keep unrelated sections, set keys in their own section.
if ! grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
    printf '\n[boot]\nsystemd=true\n' >>/etc/wsl.conf
else
    sed -i '/^\[boot\]/,/^\[/ { s/^systemd=.*/systemd=true/; }' /etc/wsl.conf
    if ! grep -q '^systemd=true$' /etc/wsl.conf; then sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf; fi
fi
'@
    if ((Invoke-WslBash -Distro $SourceDistro -Script $setup) -ne 0) { throw 'Failed to configure systemd in the build distro.' }
    & wsl.exe --terminate $SourceDistro
    if ($LASTEXITCODE -ne 0) { throw 'Failed to restart the build distro.' }
    $name = $Hostname
    $check = "set -e`n[ `"`$(cat /proc/1/comm)`" = systemd ]`nhostnamectl set-hostname '$name'`nprintf '%s\n' '$name' > /etc/hostname`n"
    if ((Invoke-WslBash -Distro $SourceDistro -Script $check) -ne 0) { throw 'systemd did not start in the build distro.' }
    Set-PveRootPassword -Distro $SourceDistro -Password $script:password
}

function Invoke-Bootstrap {
    $nat = if ($NoNat) { '0' } else { '1' }
    $noKvm = if ($AllowMissingKvm) { '1' } else { '0' }
    $body = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'bootstrap-pve.sh')) -replace "`r`n", "`n"
    # Only non-secret, validated configuration is embedded in the staged script.
    $prefix = "export PVE_MIRROR='$Mirror' PVE_NAT='$nat' PVE_NAT_SUBNET='$NatSubnet' PVE_ALLOW_NO_KVM='$noKvm' PVE_SKIP_PASSWORD=1`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($prefix + $body))
    $stageScript = "set -e`nprintf '%s' '$encoded' | base64 -d > /root/pve-bootstrap.sh`nchmod 700 /root/pve-bootstrap.sh`n"
    if ((Invoke-WslBash -Distro $SourceDistro -Script $stageScript) -ne 0) { throw 'Failed to stage the bootstrap script.' }
    Write-Step 'Installing PVE; package-manager progress follows (can take tens of minutes)'
    # Run a real file, not bash -s: passwd and package scripts must not consume
    # the remainder of the script from stdin. All secrets were set separately.
    & wsl.exe -d $SourceDistro -u root --exec bash /root/pve-bootstrap.sh
    if ($LASTEXITCODE -ne 0) { throw "Bootstrap failed. Keep '$SourceDistro' and rerun with the same options plus -Resume after fixing the cause." }
    $state.BootstrapComplete = $true
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Import-Target {
    $archive = $TransferArchive
    Write-Step "Exporting verified build to '$DistroName'"
    if ((Invoke-WslBash -Distro $SourceDistro -Script 'sync') -ne 0) { throw 'Could not sync the build filesystem.' }
    & wsl.exe --terminate $SourceDistro
    if ($LASTEXITCODE -ne 0) { throw 'Could not stop the build distro.' }
    & wsl.exe --export $SourceDistro $archive
    if ($LASTEXITCODE -ne 0) { throw 'Build export failed; source distro is preserved.' }
    New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
    & wsl.exe --import $DistroName $InstallPath $archive --version 2
    if ($LASTEXITCODE -ne 0) { throw "Import failed; source and archive remain at $archive." }
    $state | Add-Member -NotePropertyName Imported -NotePropertyValue $true -Force
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    Complete-Target
}

function Complete-Target {
    $archive = $TransferArchive
    # Keep both source and archive until the imported target passes all checks.
    Test-PveApi -Distro $DistroName
    $services = 'for unit in pve-wsl-hosts pve-cluster pvestatd pvedaemon pveproxy lxcfs pve-guests; do systemctl is-active --quiet "$unit" || { echo "Inactive: $unit" >&2; exit 1; }; done'
    if ((Invoke-WslBash -Distro $DistroName -Script $services) -ne 0) { throw 'An imported PVE service is not active.' }
    if (-not $SkipKeepAlive) { & "$PSScriptRoot\Enable-PVEKeepAlive.ps1" -DistroName $DistroName }
    else { Write-Warning 'Windows and Linux keep-alive setup was explicitly skipped.' }
    if (-not $NoSetDefault) {
        & wsl.exe --set-default $DistroName
        if ($LASTEXITCODE -ne 0) { throw 'Could not set the default WSL distro.' }
    }
    Write-Step 'Removing only the successful installer-owned build and transfer archive'
    if (@(Get-WslDistros) -contains $SourceDistro) {
        & wsl.exe --unregister $SourceDistro
        if ($LASTEXITCODE -ne 0) { throw "Could not remove '$SourceDistro'. Target works; retry finalization with -Resume." }
    }
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Remove-Item -LiteralPath $statePath -Force
}

try {
    Assert-Preflight
    if ($targetExists) {
        if (-not $state.Imported) { throw 'Existing target is not a recorded successful import; inspect it manually. Nothing will be overwritten.' }
        $stage = 'resuming target validation and keep-alive'
        Complete-Target
    }
    else {
        $script:password = Read-PvePassword
        $stage = 'WSL configuration'
        Initialize-Wsl
        $stage = 'Debian download'
        New-BuildDistro
        $stage = 'build initialization'
        Initialize-Build
        $stage = 'PVE bootstrap'
        Invoke-Bootstrap
        $stage = 'export, import and keep-alive verification'
        Import-Target
    }
    Write-Host "`nInstallation complete: $DistroName" -ForegroundColor Green
    Write-Host 'Open https://localhost:8006 (self-signed certificate), root / Linux PAM.'
    Write-Host 'Use the password you chose. No password was generated, printed or saved.'
    $exitCode = 0
}
catch {
    Write-Host "`nINSTALLATION FAILED at: $stage" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host 'No existing target distro was overwritten. Installer-owned build/archives are preserved for diagnosis.'
}
finally { $script:password = $null }
exit $exitCode
