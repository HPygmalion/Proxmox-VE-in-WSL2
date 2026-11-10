# Runs an installer-owned test build; never contains production credentials.
param([string]$DistroName = 'PVE-acceptance', [string]$InstallPath = '', [switch]$Resume, [switch]$SkipKeepAlive, [switch]$EnableNat)
$ErrorActionPreference = 'Stop'
# Random credential is ONLY for this disposable acceptance-test distro.
$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$rng.Dispose()
$secret = ConvertTo-SecureString ([Convert]::ToBase64String($bytes)) -AsPlainText -Force
[Array]::Clear($bytes, 0, $bytes.Length)
. "$PSScriptRoot\..\scripts\Common.ps1"
if (-not $Resume -and (@(Get-WslDistros) -contains "$DistroName-src")) { $Resume = $true }
& "$PSScriptRoot\..\scripts\Install-PVE.ps1" -DistroName $DistroName -Hostname pve-acceptance -RootPassword $secret -EnableNat:$EnableNat -NoSetDefault -Resume:$Resume -SkipKeepAlive:$SkipKeepAlive -InstallPath $InstallPath
exit $LASTEXITCODE
