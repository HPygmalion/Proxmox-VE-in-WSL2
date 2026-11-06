@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-PVE.ps1" %*
set "result=%errorlevel%"
echo.
if not "%result%"=="0" echo Installation did not complete. Read the error above; existing distros were not overwritten.
pause
exit /b %result%
