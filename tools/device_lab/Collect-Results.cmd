@echo off
call "%~dp0Run-Tests.cmd" -Mode Collect -Seconds 90 %*
exit /b %errorlevel%
