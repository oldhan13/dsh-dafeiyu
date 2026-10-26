@echo off
rem Open the call window (desktop pet voice call). ASCII only on purpose.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0call.ps1"
