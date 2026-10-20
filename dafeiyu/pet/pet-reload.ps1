# 改完 pet/panel.ps1 或 pet-wf.ps1 之后跑这个：归一 BOM、语法检查、重启桌宠。
# ⚠ BOM 是必需的：本机 ACP=936，无 BOM 的 UTF-8 .ps1 会被按 GBK 解，中文全成乱码。
# ⚠ 但也**只能有一个** BOM：两个 BOM 会让 PowerShell 把 "#requires" 当成命令。
$ErrorActionPreference = 'Stop'
$ws = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # dafeiyu\pet -> 项目根

foreach ($p in @("$ws\dafeiyu\pet\pet-wf.ps1", "$ws\dafeiyu\pet\panel.ps1", "$ws\dafeiyu\pet\fish-draw.ps1")) {
  $name = [System.IO.Path]::GetFileName($p)
  $raw = [System.IO.File]::ReadAllBytes($p)
  $text = [System.Text.Encoding]::UTF8.GetString($raw)
  $bomCount = 0
  while ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1); $bomCount++ }
  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
  if ($errs.Count) {
    "SYNTAX $name :"
    $errs | ForEach-Object { '  line ' + $_.Extent.StartLineNumber + ': ' + $_.Message }
    exit 1
  }
  if ($bomCount -ne 1) { "BOM normalized: $name (was $bomCount)" }
  [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($true)))
}
'parse ok, single BOM'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match '-File\s+("[^"]*|[^"]*)pet-wf\.ps1' -and $_.CommandLine -notmatch 'Get-CimInstance' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "killed $($_.ProcessId)" }
Start-Sleep -Milliseconds 900
Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "$ws\dafeiyu\pet\pet-wf.ps1" `
  -WorkingDirectory $ws -WindowStyle Hidden
Start-Sleep -Seconds 4
Get-Content "$ws\dafeiyu\pet\pet.log" -Tail 3 -Encoding UTF8
