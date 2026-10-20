@echo off
rem Start DSH Web from this folder, with TEMP pointed outside the workspace.
rem Why: the Windows ACL sandbox requires the temp root to be OUTSIDE the
rem workspace. The default tmpdir sits under <HOME>; if your workspace is also
rem under <HOME>, a session shell then fails with
rem "temp root must be outside the workspace".
rem So TEMP goes to a sibling folder of this repo (..\.dafeiyu-temp).
setlocal
for %%I in ("%~dp0.") do set "HERE=%%~fI"
for %%I in ("%~dp0..") do set "PARENT=%%~fI"
set "TMP=%PARENT%\.dafeiyu-temp"
set "TEMP=%TMP%"
if not exist "%TMP%" mkdir "%TMP%" >nul 2>&1
cd /d "%HERE%"
npx @deepseek-ai/dsh web
