@echo off
rem Stop the background pieces. The DSH host window is not touched.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dafeiyu\tools\stop-dafeiyu.ps1" %*
