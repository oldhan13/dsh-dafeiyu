@echo off
rem speak.cmd -- like say.cmd, but with prosody markers (see speak.ps1).
rem   [[slow]]...[[/slow]]   slower   [[fast]]...[[/fast]]   faster
rem   [[s]] 0.15s   [[p]] 0.35s   [[pp]] 0.7s   (pauses)
rem Prints the mp3 path on the last line.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0speak.ps1" %*
