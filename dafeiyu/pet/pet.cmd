@echo off
rem Launch the desktop pet (Da Fei Yu). ASCII only on purpose.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0pet-wf.ps1"