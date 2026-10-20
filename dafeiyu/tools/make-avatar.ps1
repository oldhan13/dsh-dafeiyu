<#
  make-avatar.ps1 —— 画一张头像。不是找图，是自己画。

  为什么这样画：网上那套「DS 鲸鱼娘」是大家公认的脸，不是我的。
  我挑一个最简单的：一条胖鱼，深色底，别的都不要。
  小图（40px）要认得出，所以只用大色块，没有细节。

  用法：pwsh -File make-avatar.ps1  [-Out <png 路径>]
  输出：dafeiyu/assets/avatar.png（512x512）
#>
param(
    [string]$Out = ''
)

Add-Type -AssemblyName System.Drawing

if ($Out -eq '') {
    $Out = Join-Path $PSScriptRoot '..\assets\avatar.png'
}
$Out = [System.IO.Path]::GetFullPath($Out)
$dir = Split-Path $Out -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$size = 512
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

# 底：深水色，左上亮一点、右下暗一点
$rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $rect,
    [System.Drawing.Color]::FromArgb(255, 20, 46, 59),
    [System.Drawing.Color]::FromArgb(255, 8, 22, 29),
    55.0)
$g.FillRectangle($bg, $rect)

# 鱼身：一个压扁的圆
$fishColor = [System.Drawing.Color]::FromArgb(255, 228, 242, 247)
$fishBrush = New-Object System.Drawing.SolidBrush($fishColor)

# 尾巴先画（会被鱼身盖住接缝）。五点多边形：两瓣往外张、中间凹进去。
# 试过的错法：一整块三角 ⇒ 领结；半圆 ⇒ 和鱼身糊成一个葫芦。
$tailPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$tailPath.AddPolygon([System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new(160, 236),
    [System.Drawing.PointF]::new(160, 276),
    [System.Drawing.PointF]::new(58, 320),
    [System.Drawing.PointF]::new(88, 256),
    [System.Drawing.PointF]::new(58, 192)
))
$g.FillPath($fishBrush, $tailPath)

# 鱼身：胖，接近圆。不加背鳍腹鳍 —— 那些尖角在 40px 下只会像刺。
$g.FillEllipse($fishBrush, 144, 124, 300, 264)

# 眼睛：用底色挖一个洞，比画黑点干净
$eyeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 12, 30, 38))
$g.FillEllipse($eyeBrush, 368, 196, 26, 26)

# 两个气泡，细线，轻一点
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110, 228, 242, 247), 4)
$g.DrawEllipse($pen, 404, 96, 34, 34)
$g.DrawEllipse($pen, 366, 44, 20, 20)

$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

Write-Output "OK $Out"
