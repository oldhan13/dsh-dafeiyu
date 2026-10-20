#requires -Version 5.1
<#
  pet-say.ps1 - 把一句话说到桌面上（她自己的嘴）。
  用法：
    pet-say.ps1 "我先睡了，明天见"
    pet-say.ps1 -Clear        # 把气泡清掉
  原理：写 dafeiyu\pet\say.txt，桌宠每秒看一眼，变了就把这句顶到气泡里（25 秒后自己消失）。
#>
param(
  [Parameter(Position = 0)][string]$Text,
  [switch]$Clear
)

$SAY = ((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) + '\dafeiyu\pet\say.txt')
$utf8 = New-Object System.Text.UTF8Encoding($false)   # 不写 BOM，桌宠那边读得干净

if ($Clear -or -not $Text) {
  [System.IO.File]::WriteAllText($SAY, '', $utf8)
  Write-Output '{"ok":true,"cleared":true}'
  exit 0
}

[System.IO.File]::WriteAllText($SAY, $Text.Trim(), $utf8)
Write-Output ('{"ok":true,"said":' + (ConvertTo-Json $Text -Compress) + '}')
