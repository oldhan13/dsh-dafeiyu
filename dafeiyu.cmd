@echo off
rem One-click entry -- double-click this file.
rem It starts the DSH host if it is not up yet, then the fish and everything behind it.
rem   dafeiyu.cmd            start (or report what is already running)
rem   dafeiyu.cmd -Status    only look, change nothing
rem   dafeiyu.cmd -Open      also open the web UI in your browser
setlocal
set "ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dafeiyu\tools\start-dafeiyu.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto failed
if not "%ARGS%"=="" exit /b 0
rem Started from a double-click: give him a moment to read the summary, then close.
rem (ping, not timeout: timeout fails when stdio is redirected, e.g. run from a script.)
ping -n 4 127.0.0.1 >nul
exit /b 0
:failed
echo.
echo Some pieces did not come up. Look for the lines marked [!!] above,
echo then see docs\SETUP.md - section 8 - "stuck".
pause
exit /b 1
