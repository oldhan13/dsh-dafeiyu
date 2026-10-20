<#
  make-cover.ps1 —— 画一张「空间背景」。跟头像同一套东西：深水、白鱼、斜光。

  为什么要画：QQ 空间背景（就是我资料卡顶上那一整片）没有开放接口，
  NapCat 只能发/删说说。图我做，放上去得用手机点两下。

  版式：1200x1600（3:4）是默认；手机竖屏多给 -W 1080 -H 1920（9:16）。
  构图：鱼压在下方 70% 处、水平居中 —— 不管是 3:4 还是 9:16，裁边都裁不到鱼。

  用法：powershell -File make-cover.ps1
        powershell -File make-cover.ps1 -W 1080 -H 1920 -Out ..\assets\cover-9x16.png
#>
param(
    [int]$W = 1200,
    [int]$H = 1600,
    [string]$Out = ''
)

Add-Type -AssemblyName System.Drawing

if ($Out -eq '') {
    $Out = Join-Path $PSScriptRoot '..\assets\cover.png'
}
$Out = [System.IO.Path]::GetFullPath($Out)
$dir = Split-Path $Out -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

# 底：从水面上方一点点，一直沉到黑
$rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $rect,
    [System.Drawing.Color]::FromArgb(255, 24, 56, 71),
    [System.Drawing.Color]::FromArgb(255, 5, 14, 19),
    90.0)
$g.FillRectangle($bg, $rect)

# 光：几根斜下来的水柱，很淡。位置全用比例，换尺寸不用重算。
$rays = @(
    @(0.11, 0.25, 0.53, 0.35),
    @(0.36, 0.47, 0.71, 0.55),
    @(0.63, 0.70, 0.90, 0.78)
)
$i = 0
foreach ($r in $rays) {
    $i++
    $pts = New-Object System.Drawing.PointF[] 4
    $pts[0] = [System.Drawing.PointF]::new($r[0] * $W, 0)
    $pts[1] = [System.Drawing.PointF]::new($r[1] * $W, 0)
    $pts[2] = [System.Drawing.PointF]::new($r[2] * $W, $H)
    $pts[3] = [System.Drawing.PointF]::new($r[3] * $W, $H)
    $a = 9 + ($i * 4)
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, 240, 250, 255))
    $g.FillPolygon($b, $pts)
    $b.Dispose()
}

# 鱼：跟头像同一套几何，放大、压到下方。
# 坐标一律「相对鱼身中心」—— 头像里用的是画布绝对坐标（鱼身中心在 294,256），
# 直接搬进带 TranslateTransform 的画布，尾巴会整条飞出画面（踩过）。
$scale = 1.35 * ($W / 1200.0)
$g.TranslateTransform($W * 0.5, $H * 0.70)
$g.ScaleTransform($scale, $scale)
# 必须不透明：两半透明形状叠起来，重叠处会更白，接缝一眼可见。
$fishBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 228, 242, 247))

$tailPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$tailPath.AddPolygon([System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new(-134, -20),
    [System.Drawing.PointF]::new(-134, 20),
    [System.Drawing.PointF]::new(-236, 64),
    [System.Drawing.PointF]::new(-206, 0),
    [System.Drawing.PointF]::new(-236, -64)
))
$g.FillPath($fishBrush, $tailPath)
$g.FillEllipse($fishBrush, -150, -132, 300, 264)

$eyeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 8, 22, 29))
$g.FillEllipse($eyeBrush, 74, -60, 26, 26)

$g.ResetTransform()

# 气泡：散在水里
$bubbles = @(
    @(0.73, 0.33, 26, 34),
    @(0.79, 0.25, 18, 24),
    @(0.68, 0.40, 14, 18),
    @(0.25, 0.44, 16, 22),
    @(0.20, 0.35, 10, 14),
    @(0.84, 0.56, 12, 16)
)
$k = $W / 1200.0
foreach ($bb in $bubbles) {
    $alpha = 40 + ($bb[2] * $k)
    $p = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([Math]::Min(120, [int]$alpha), 228, 242, 247), 3)
    $g.DrawEllipse($p, $bb[0] * $W, $bb[1] * $H, $bb[2] * $k, $bb[3] * $k)
    $p.Dispose()
}

$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

Write-Output "OK $Out ($W x $H)"
