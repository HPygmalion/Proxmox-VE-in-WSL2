# Shared Windows PowerShell 5.1 helpers. Dot-source; this file performs no setup.
function Assert-DistroName {
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
        throw 'Distro names must be 1-64 letters, digits, dots, underscores or hyphens.'
    }
}

function Get-WslDistros {
    $names = & wsl.exe --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not list WSL distributions.' }
    $names | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ }
}

function Invoke-WslInput {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$InputText
    )
    Assert-DistroName $Distro
    # Command is a fixed executable chosen by the caller, never user shell code.
    if ($Command -notin @('bash -s', 'chpasswd')) { throw 'Unsupported input command.' }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'wsl.exe'
    $executable = if ($Command -eq 'chpasswd') { '/usr/sbin/chpasswd' } else { '/bin/bash -s' }
    $info.Arguments = "--distribution $Distro --user root --exec $executable"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        # .NET Framework derives the redirected stdin writer from Console's
        # encoding. Force BOM-free UTF-8 while creating it, then restore the host.
        $previousEncoding = [Console]::InputEncoding
        try {
            [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
            [void]$process.Start()
            $stdin = $process.StandardInput
        }
        finally { [Console]::InputEncoding = $previousEncoding }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $stdin.Write(($InputText -replace "`r`n", "`n") + "`n")
        $stdin.Close()
        $process.WaitForExit()
        $outText = $stdout.GetAwaiter().GetResult()
        $errText = $stderr.GetAwaiter().GetResult()
        if ($outText) { Write-Host $outText.TrimEnd() }
        if ($errText) { Write-Host $errText.TrimEnd() }
        return [int]$process.ExitCode
    }
    finally { $process.Dispose() }
}

function Invoke-WslBashReady {
    # WSL occasionally fails to create a distro instance right after another
    # distro stops (Wsl/Service/CreateInstance/E_UNEXPECTED). Only the first
    # command of a step is retried, and only when every attempt failed, so a
    # script that ran is never run twice.
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$Script,
        [int]$Attempts = 3,
        [int]$DelaySeconds = 5
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $code = Invoke-WslBash -Distro $Distro -Script $Script
        if ($code -eq 0) { return 0 }
        if ($attempt -lt $Attempts) {
            Write-Warning "WSL did not accept a command in '$Distro' (attempt $attempt of $Attempts); retrying."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return $code
}

function Invoke-WslBash {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$Script
    )
    # UTF-8/LF stdin avoids both PS 5.1 native argument quoting and temp files.
    return (Invoke-WslInput -Distro $Distro -Command 'bash -s' -InputText $Script)
}

function Set-PveRootPassword {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][Security.SecureString]$Password
    )
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ([string]::IsNullOrEmpty($plain) -or $plain -match "[\r\n\x00]") {
            throw 'The root password must not be empty or contain line breaks or NUL.'
        }
        $code = Invoke-WslInput -Distro $Distro -Command 'chpasswd' -InputText "root:$plain"
        if ($code -ne 0) { throw 'Failed to set the PVE root password.' }
    }
    finally {
        $plain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-PveApi {
    param([string]$Distro = $DistroName)
    Write-Host "`n==> Verifying the PVE API" -ForegroundColor Cyan
    $check = @'
for i in $(seq 1 30); do
    code=$(curl -sk --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' https://127.0.0.1:8006/api2/json/version) || code=000
    case "$code" in
        200|401) echo "PVE API ready (HTTP $code)"; exit 0 ;;
    esac
    sleep 2
done
echo "PVE API did not become ready (last HTTP $code)" >&2
exit 1
'@
    if ((Invoke-WslBash -Distro $Distro -Script $check) -ne 0) {
        throw 'The PVE API did not become ready.'
    }
}

function Set-IniValue {
    param([string]$Path, [string]$Section, [string]$Key, [string]$Value)
    $lines = if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path) } else { @() }
    $result = New-Object 'System.Collections.Generic.List[string]'
    $inside = $false
    $seenSection = $false
    $written = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^]]+)\]\s*$') {
            if ($inside -and -not $written) { $result.Add("$Key=$Value"); $written = $true }
            $inside = $matches[1].Trim() -ieq $Section
            if ($inside) { $seenSection = $true }
        }
        if ($inside -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            if (-not $written) { $result.Add("$Key=$Value"); $written = $true }
        }
        else { $result.Add($line) }
    }
    if (-not $seenSection) { $result.Add("`n[$Section]") }
    if (-not $written) { $result.Add("$Key=$Value") }
    [IO.File]::WriteAllText($Path, (($result -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
}
