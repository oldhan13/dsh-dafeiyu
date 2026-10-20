# speak-play.ps1 -- say it out loud, once, and exit.
#
# Made for the desktop panel (2026-10-20): the panel is a WinForms process and must not
# block while a sentence is synthesized, so the panel spawns this script detached.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File speak-play.ps1 -TextFile <utf8 file>
#
# ASCII only on purpose: this file is launched by a short-lived powershell.exe and the
# machine ACP is 936, so a non-ASCII source without BOM would decode as GBK garbage.
# The Chinese text travels in a UTF-8 *file*, never on the command line.
#
# It reads the text, calls speak.ps1 (same folder, keeps the [[slow]] / [[p]] prosody
# markers), takes the last line it prints as the mp3 path, and plays it through winmm MCI.

param(
  [Parameter(Mandatory = $true)][string]$TextFile,
  [switch]$KeepFile
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace W -Name PlayMci -MemberDefinition @'
[DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern int mciSendString(string command, System.Text.StringBuilder buffer, int len, System.IntPtr hwnd);
'@

function Mci([string]$cmd) {
  $rc = [W.PlayMci]::mciSendString($cmd, $null, 0, [IntPtr]::Zero)
  if ($rc -ne 0) { throw ("mci failed rc=" + $rc + " cmd=" + $cmd) }
}

if (-not (Test-Path $TextFile)) { exit 2 }
$text = (Get-Content -Path $TextFile -Raw -Encoding UTF8)
if ($null -eq $text) { exit 2 }
$text = $text.Trim()
if (-not $KeepFile) { Remove-Item $TextFile -Force -ErrorAction SilentlyContinue }
if ($text -eq '') { exit 0 }

$speak = Join-Path $PSScriptRoot 'speak.ps1'
if (-not (Test-Path $speak)) { exit 3 }

$out = & $speak -Text $text 2>&1
$lines = @($out | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
$mp3 = $lines[-1]
if (-not $mp3 -or -not (Test-Path $mp3)) {
  # speak.ps1 prints diagnostics on failure; keep one line for the log next to the panel.
  $err = Join-Path 'C:\dsh-temp' 'speak-play.err.log'
  ($lines -join "`n") | Set-Content -Path $err -Encoding UTF8
  exit 4
}

try {
  Mci ('open "' + $mp3 + '" type mpegvideo alias dfyplay')
  Mci 'play dfyplay wait'
}
finally {
  try { Mci 'close dfyplay' } catch { }
}
exit 0
