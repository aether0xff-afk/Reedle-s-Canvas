@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-Reedle-Server.ps1" %*
exit /b %errorlevel%
