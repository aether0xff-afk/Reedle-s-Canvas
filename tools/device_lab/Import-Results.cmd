@echo off
if "%~1"=="" (
    echo Drag the exported Device Lab JSON onto this file to create the result ZIP.
    pause
    exit /b 2
)
call "%~dp0Run-Tests.cmd" -Mode Import -Report "%~f1"
exit /b %errorlevel%
