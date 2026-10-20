@echo off
rem One-click entry -- double-click this file.
rem   dafeiyu.cmd            start (or report what is already running)
rem   dafeiyu.cmd -Status    only look, change nothing
rem   dafeiyu.cmd -Open      also open the web UI in your browser
rem   dafeiyu.cmd -Setup     force the deploy UI
setlocal
set "ARGS=%*"

if /i "%ARGS%"=="-Setup" goto setup

rem Never configured on this machine? Open the deploy UI instead of guessing.
rem (The deploy UI writes dafeiyu\state\machine.json; that file is gitignored.)
if exist "%~dp0dafeiyu\state\machine.json" goto start
if not "%DAFEIYU_BOT_QQ%"=="" goto start

:setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dafeiyu\tools\setup-ui.ps1"
exit /b 0

:start
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
echo.
echo If this is the first run on this machine, try:  dafeiyu.cmd -Setup
pause
exit /b 1
