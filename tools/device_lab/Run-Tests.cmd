@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Reedle-Tests.ps1" %*
set "result=%errorlevel%"
echo.
echo Keep the result ZIP in this kit's results folder for return to Codex.
pause
exit /b %result%
