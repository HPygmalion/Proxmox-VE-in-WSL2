# Read-only live stdin regression; does not install or change the named distro.
param([Parameter(Mandatory)][string]$Distro)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Common.ps1"
$previous = [Console]::InputEncoding
try {
    foreach ($encoding in @((New-Object Text.UTF8Encoding($true)), (New-Object Text.UTF8Encoding($false)))) {
        [Console]::InputEncoding = $encoding
        $code = Invoke-WslBash -Distro $Distro -Script 'set -e; printf "stdin quotes: %s\n" "a b"; exit 7'
        if ($code -ne 7 -or $code -is [array]) { throw 'BOM/exit-status regression.' }
        if ([Console]::InputEncoding.GetPreamble().Length -ne $encoding.GetPreamble().Length) { throw 'Console input encoding was not restored.' }
    }
    Write-Host 'PASS: BOM and BOM-free caller encodings, stdout and exit-code separation'
}
finally { [Console]::InputEncoding = $previous }
