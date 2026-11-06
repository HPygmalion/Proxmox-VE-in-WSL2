# Opt-in live helper checks: changes ONLY the supplied disposable test distro.
param([Parameter(Mandatory)][string]$Distro)
$ErrorActionPreference = 'Stop'
if ($Distro -notmatch '^PVE-(acceptance|test)') { throw 'Use a disposable PVE-acceptance*/PVE-test* distro.' }
. "$PSScriptRoot\..\scripts\Common.ps1"
$script = 'printf "quotes survive: %s\n" "a b"; printf "stderr preserved\n" >&2; exit 7'
$code = Invoke-WslBash -Distro $Distro -Script $script
if ($code -is [array] -or $code -ne 7) { throw 'Exit code or stdout handling regression.' }
$script = 'printf "UTF-8: ' + [char]0x4e2d + [char]0x6587 + '\n"'
if ((Invoke-WslBash -Distro $Distro -Script $script) -ne 0) { throw 'Unicode stdin regression.' }
# Exercise quotes/spaces/non-ASCII without exposing a password to process args.
$secret = ConvertTo-SecureString ('temporary' + [char]0x4e2d + ' a"b' + "'" + ':c') -AsPlainText -Force
Set-PveRootPassword -Distro $Distro -Password $secret
Write-Host 'PASS: native exit status, quotes, UTF-8, secure password stdin'
