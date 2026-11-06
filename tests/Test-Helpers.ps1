#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Common.ps1"
$count = 0
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; $script:count++ }
$temp = Join-Path $env:TEMP ('pve-regression-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp | Out-Null
try {
    $ini = Join-Path $temp 'wslconfig'
    [IO.File]::WriteAllText($ini, "[wsl2]`nmemory=8GB`n[experimental]`nautoMemoryReclaim=gradual`n")
    Set-IniValue -Path $ini -Section wsl2 -Key nestedVirtualization -Value true
    $text = [IO.File]::ReadAllText($ini)
    Assert-True ($text.Contains('memory=8GB')) 'Existing WSL settings were lost'
    Assert-True ($text.Contains('autoMemoryReclaim=gradual')) 'Other sections were lost'
    Assert-True ($text.IndexOf('nestedVirtualization=true') -lt $text.IndexOf('[experimental]')) 'Key inserted into wrong section'
    Set-IniValue -Path $ini -Section wsl2 -Key nestedVirtualization -Value true
    Assert-True (([regex]::Matches([IO.File]::ReadAllText($ini), 'nestedVirtualization=')).Count -eq 1) 'Duplicate INI keys'
    Set-IniValue -Path $ini -Section new -Key option -Value yes
    Assert-True ([IO.File]::ReadAllText($ini).Contains("[new]`r`noption=yes")) 'Missing new section'
    foreach ($name in 'PVE', 'PVE-test-src', 'A_1', 'Ubuntu-24.04') { Assert-DistroName $name; $count++ }
    foreach ($name in '../PVE', 'PVE;echo', 'bad name', '') {
        $rejected = $false
        try { Assert-DistroName $name } catch { $rejected = $true }
        Assert-True $rejected "Unsafe distro name accepted: $name"
    }
    foreach ($file in Get-ChildItem "$PSScriptRoot\..\scripts\*.ps1") {
        $errors = $null; $tokens = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "PowerShell parse failed: $($file.Name)"
    }
    # Import only the preflight function from AST; do not execute the installer.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path "$PSScriptRoot\..\scripts\Install-PVE.ps1").Path, [ref]$tokens, [ref]$errors)
    $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-PvePassword'}, $true)
    Assert-True ($null -ne $function) 'Password prompt function missing'
    Assert-True (-not ([IO.File]::ReadAllText("$PSScriptRoot\..\scripts\Install-PVE.ps1") -match 'PVE_ROOT_PASSWORD=')) 'Password exposed in process arguments'
    Write-Host "PASS: $count assertions (no WSL changes)" -ForegroundColor Green
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
