Option Explicit
Dim shell, distro, command, result, expression
If WScript.Arguments.Count <> 1 Then WScript.Quit 2
distro = WScript.Arguments(0)
Set expression = New RegExp
expression.Pattern = "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"
If Not expression.Test(distro) Then WScript.Quit 2
Set shell = CreateObject("WScript.Shell")
command = Chr(34) & shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wsl.exe") & Chr(34) & " -d " & distro & " -u root --exec /usr/local/sbin/pve-anchor"
' Wait for WSL so Task Scheduler tracks its lifetime and IgnoreNew prevents duplicates.
result = shell.Run(command, 0, True)
WScript.Quit result
