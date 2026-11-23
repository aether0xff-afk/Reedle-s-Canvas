@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Export-Reedle-Connection.ps1" %*
exit /b %ERRORLEVEL%
