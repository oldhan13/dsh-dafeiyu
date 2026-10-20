# preview-fish.ps1 —— 把鱼动起来的样子导出成一串帧，给人看一眼再决定要不要换上。
# 不碰桌宠进程，只是离线画图。
param(
  [int]$Frames = 60,
  [double]$Step = 0.06,
  [double]$Talk = 0.0,
  [int]$Size = 512,
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'fish-draw.ps1')

if (-not $OutDir) {
  $OutDir = Join-Path $env:TEMP ('fishprev-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$bgA = [System.Drawing.Color]::FromArgb(255, 20, 46, 59)
$bgB = [System.Drawing.Color]::FromArgb(255, 8, 22, 29)

for ($i = 0; $i -lt $Frames; $i++) {
  $phase = $i * $Step
  # 说话时按 phase 起落，让预览里能看出"说的时候更活"
  $t = if ($Talk -gt 0) { $Talk * (0.55 + 0.45 * [Math]::Sin($phase * 1.7)) } else { 0.0 }

  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # 预览用深水底，才看得见白鱼；桌宠那边是透明底
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $bgA, $bgB, 55.0)
    $g.FillRectangle($bg, $rect)
    $bg.Dispose()

    Draw-Fish -G $g -Phase $phase -Talk $t -BodyScale ($Size / 512.0) -Bubbles:($t -gt 0.15)
  }
  finally { $g.Dispose() }

  $f = Join-Path $OutDir ('f{0:d3}.png' -f $i)
  $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

Write-Output $OutDir
