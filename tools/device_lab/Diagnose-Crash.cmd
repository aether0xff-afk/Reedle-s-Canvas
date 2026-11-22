@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Reedle-Tests.ps1" -Mode Diagnose %*
set "result=%errorlevel%"
echo.
echo Return the new ZIP in the results folder. This command does not run the iPad workload.
pause
exit /b %result%
