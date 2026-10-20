@echo off
rem Deploy UI -- double-click this file the first time.
rem It checks the machine, asks for the two QQ numbers, installs, starts and verifies.
rem Same thing as: dafeiyu\tools\setup-ui.ps1
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dafeiyu\tools\setup-ui.ps1" %*
exit /b %ERRORLEVEL%
