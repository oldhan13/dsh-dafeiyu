@echo off
rem Keep the project ledger under its line budget. ASCII only.
"node" "%~dp0ledger-tidy.mjs" >> "%~dp0ledger-tidy.log" 2>&1
rem Refresh the opening brief (memory/brief.md) so both sessions wake up oriented.
"node" "%~dp0make-brief.mjs" >> "%~dp0ledger-tidy.log" 2>&1
rem Keep the presence watcher alive (state/presence.json: is he at the keyboard right now).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0presence.ps1" -Ensure >> "%~dp0ledger-tidy.log" 2>&1