@echo off
rem relay.cmd -- wrapper so it works no matter the PowerShell execution policy
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0relay.ps1" %*
