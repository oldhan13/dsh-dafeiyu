@echo off
rem Restart the DSH host (Web GUI 3080 + QQ channel 8643), then let
rem start-dafeiyu.cmd fill the rest of the stack back in.
rem
rem   restart-host.cmd          -> restart now
rem   restart-host.cmd 40       -> wait 40 seconds first
rem
rem Log: restart-host.log (next to this file)
setlocal
set "DELAY=%~1"
if "%DELAY%"=="" set "DELAY=0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-host.ps1" -DelaySeconds %DELAY%
endlocal
