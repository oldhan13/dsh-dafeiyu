# ledger-tidy-hidden.ps1 -- run ledger-tidy.cmd with no visible window.
#
# Replaces ledger-tidy-silent.vbs (2026-10-20). Windows 11 24H2 now pops a
# "VBScript is deprecated" dialog every time wscript.exe starts, and the
# DaFeiYu-LedgerTidy scheduled task started it twice an hour -- so he got a
# popup that looked like "confirm running?" every half hour.
# Reference: Application event log, provider VBScriptDeprecationAlert, id 4096.
#
# ASCII only: Windows PowerShell 5.1 reads this fine without a BOM.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cmd  = Join-Path $here 'ledger-tidy.cmd'
& $cmd
