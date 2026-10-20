# fish-draw.ps1 —— 把那条胖鱼画成"会动的一帧"。
#
# 来由（2026-10-20 上午）：他说要动态，我原先说要等分层素材。查到 make-avatar.ps1
# 才知道那条鱼不是贴图，是 GDI+ 的几何：鱼身一个椭圆、尾巴一个五点多边形、眼睛一个挖洞。
# 既然几何在手，就不存在"切部件要素材"这回事 —— 改顶点就是摆尾，改椭圆就是呼吸。
#
# 用法（被 dot-source）：
#   . 'C:\...\dafeiyu\pet\fish-draw.ps1'
#   $bmp = New-Object Drawing.Bitmap 512,512
#   $g = [Drawing.Graphics]::FromImage($bmp)
#   Draw-Fish -G $g -Phase 0.7 -Talk 0
#
# 坐标系沿用 make-avatar.ps1 的 512×512 设计稿，缩放交给调用方的 Graphics.Transform。
# 这样头像、桌宠、预览帧用的是同一套坐标，改一处三处都跟着变。

function New-FishPalette {
  [pscustomobject]@{
    Body = [System.Drawing.Color]::FromArgb(255, 228, 242, 247)
    Dark = [System.Drawing.Color]::FromArgb(255, 12, 30, 38)
    Bubble = [System.Drawing.Color]::FromArgb(110, 228, 242, 247)
    # 透明底：桌宠要靠 TransparencyKey 抠掉背景，所以这里必须是纯透明
    None = [System.Drawing.Color]::FromArgb(0, 0, 0, 0)
  }
}

function Get-FishTailPolygon {
  # 原图那五点，别改：一整块三角会成领结，半圆会跟鱼身糊成葫芦（make-avatar.ps1 踩过）。
  @(
    [System.Drawing.PointF]::new(160, 236),
    [System.Drawing.PointF]::new(160, 276),
    [System.Drawing.PointF]::new(58, 320),
    [System.Drawing.PointF]::new(88, 256),
    [System.Drawing.PointF]::new(58, 192)
  )
}

function Rotate-PointF([System.Drawing.PointF]$p, [double]$cx, [double]$cy, [double]$deg) {
  $r = $deg * [Math]::PI / 180.0
  $c = [Math]::Cos($r); $s = [Math]::Sin($r)
  $dx = $p.X - $cx; $dy = $p.Y - $cy
  [System.Drawing.PointF]::new(
    [float]($cx + $dx * $c - $dy * $s),
    [float]($cy + $dx * $s + $dy * $c)
  )
}

<#
  Draw-Fish —— 画一帧。

  Phase    相位（弧度）。一直加，鱼就一直在动。~0.06/帧 @60ms ≈ 16fps 的自然速度。
  Talk     0..1，说话强度。摆尾与起伏的幅度跟着涨，眼睛会眯一点。
  Blink    0..1，眨眼。到 1 时眼睛压成一条缝。
  BodyScale 整体缩放（1.0 = 原大），给不同尺寸的窗口用。
#>
function Draw-Fish {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Graphics]$G,
    [double]$Phase = 0.0,
    [double]$Talk = 0.0,
    [double]$Blink = 0.0,
    [double]$BodyScale = 1.0,
    # Dash  0..1：点一下「游一下」的进度（0 = 没在动，0.5 = 冲得最远）
    [double]$Dash = 0.0,
    # Pops  泡泡列表，每个元素 {x,y,r,age,life}（设计稿 512 坐标）。空数组 = 没有泡泡。
    [object[]]$Pops = @(),
    # EyeDx / EyeDy：眼珠往哪看（设计稿像素，±9 / ±6 以内）。跟着鼠标、或"在想事情"时抬起来。
    [double]$EyeDx = 0.0,
    [double]$EyeDy = 0.0,
    # Tint 0..1：把鱼身往暖红里拉一点 —— 卡住了 / 出错的时候用。0 = 原色。
    [double]$Tint = 0.0,
    [switch]$Bubbles
  )

  $pal = New-FishPalette

  # 三个量，全部由 Phase 推出来 —— 不要各自的随机，那样会显得抽搐而不是呼吸。
  $bob = 3.2 * [Math]::Sin($Phase) * (1.0 + 1.4 * $Talk)          # 整条鱼上下浮
  $breath = 1.0 + 0.016 * [Math]::Sin($Phase * 1.35)               # 呼吸：竖着鼓一点
  # 冲刺：sin 走一个 0→1→0 的山包，所以「冲出去」和「退回来」是同一条曲线，不会突然跳。
  $dashArc = [Math]::Sin([Math]::PI * $Dash)
  $dashX = 48.0 * $dashArc                                   # 整条鱼横移
  $swing = 9.0 * [Math]::Sin($Phase * 0.85) * (1.0 + 1.8 * $Talk) + 18.0 * $dashArc  # 尾巴摆得更凶

  # ⚠ 缩放只做一件事：p 乘 scale，再叠一个像素级的 bob。
  #
  # 第一版想「绕设计稿中心 (256,256) 缩放再搬回来」，写了两趟 256 平移，
  # 矩阵于是变成 (0.75,0,0,0.75,-64,-64) —— 本该是 +64，正好多减 128，鱼整个被推歪。
  # 根因：GDI+ 用行向量 (p 乘 M)，T(256)*S*T(-256) 算出来是 0.75*(p+256)-256，不是 0.75*(p-256)+256；
  # Append 是「先应用先写的那个」，顺序反着写就成了这样。
  # 而这两趟本来也没用：512/2 = 256，画布中心就是原点，缩放天然居中。
  # 所以只要 Scale + Translate(bob)，且 bob 在 Scale 之后（它不该被缩放）。
  $saved = $G.Save()
  $base = New-Object System.Drawing.Drawing2D.Matrix
  $MO = [System.Drawing.Drawing2D.MatrixOrder]::Append
  try {
    if ([Math]::Abs($BodyScale - 1.0) -gt 0.0001) {
      $base.Scale([float]$BodyScale, [float]$BodyScale, $MO)
    }
    $base.Translate([float]$dashX, [float]$bob, $MO)
    $G.Transform = $base
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $G.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    # Tint：往暖红里混 —— 不是换色，是"气色变了"。混太多会像受伤，所以上限靠调用方夹在 0.35。
    $bodyCol = $pal.Body
    if ($Tint -gt 0.001) {
      $tt = [Math]::Min(1.0, $Tint)
      $bodyCol = [System.Drawing.Color]::FromArgb(255,
        [int]($pal.Body.R * (1 - $tt) + 236 * $tt),
        [int]($pal.Body.G * (1 - $tt) + 146 * $tt),
        [int]($pal.Body.B * (1 - $tt) + 146 * $tt))
    }
    $brush = New-Object System.Drawing.SolidBrush($bodyCol)
    try {
      # ---- 尾巴：先画，根部被鱼身盖住，所以旋转留下的缝看不见 ----
      # 旋转中心取 (152,256)：比接缝 (160,256) 再往里 8px，给 ±9° 留余量。
      $cx = 152.0; $cy = 256.0
      $rot = New-Object System.Drawing.PointF[] 5
      $src = Get-FishTailPolygon
      for ($i = 0; $i -lt 5; $i++) { $rot[$i] = Rotate-PointF $src[$i] $cx $cy $swing }
      $tailPath = New-Object System.Drawing.Drawing2D.GraphicsPath
      $tailPath.AddPolygon($rot)
      $G.FillPath($brush, $tailPath)
      $tailPath.Dispose()

      # ---- 鱼身：椭圆，呼吸时竖向鼓、横向微收（像真在换气） ----
      $w = 300.0 * (1.0 - 0.004 * [Math]::Sin($Phase * 1.35))
      $h = 264.0 * $breath
      $x = 294.0 - $w / 2.0      # 原椭圆中心 (294,256) 不动，只改宽高
      $y = 256.0 - $h / 2.0
      $G.FillEllipse($brush, [float]$x, [float]$y, [float]$w, [float]$h)

      # ---- 眼睛：原图用底色挖洞。眨眼就把它压扁 ----
      $eyeH = 26.0 * (1.0 - 0.88 * $Blink)
      if ($eyeH -lt 3.0) { $eyeH = 3.0 }
      $eyeBrush = New-Object System.Drawing.SolidBrush($pal.Dark)
      try {
        $G.FillEllipse($eyeBrush, [float](368 + $EyeDx), [float](196 + (26 - $eyeH) / 2.0 + $EyeDy), [float]26, [float]$eyeH)
      }
      finally { $eyeBrush.Dispose() }

      # ---- 气泡：原图那两个，说话时才冒 ----
      if ($Bubbles -or $Talk -gt 0.15) {
        $pen = New-Object System.Drawing.Pen($pal.Bubble, 4)
        try {
          $rise = 2.5 * [Math]::Sin($Phase * 2.1)
          $G.DrawEllipse($pen, [float]404, [float](96 + $rise), [float]34, [float]34)
          $G.DrawEllipse($pen, [float]366, [float](44 - $rise), [float]20, [float]20)
        }
        finally { $pen.Dispose() }
      }
    }
    finally { $brush.Dispose() }
  }
  finally {
    # Restore 而不是 ResetTransform：调用方可能本来就有自己的变换，别一把抹掉。
    try { $G.Restore($saved) } catch { }
    $base.Dispose()
  }

  # ---- 泡泡 ----
  # 放在 transform 外面画：泡泡一旦吐出来就离开鱼了，鱼再冲刺它不该跟着跑。
  # 画成空心圈（不是实心），跟头像上那两个气泡是同一套语言。
  foreach ($p in $Pops) {
    if ($null -eq $p) { continue }
    $life = [double]$p.life
    if ($life -le 0) { continue }
    # 夹到 0..1：年龄可能为负（错开出现）或超出寿命，不夹的话 alpha 会小于 0 或大于 255，直接抛异常
    $a = 1.0 - ([double]$p.age / $life)
    if ($a -lt 0.0) { $a = 0.0 } elseif ($a -gt 1.0) { $a = 1.0 }
    if ($a -le 0.02) { continue }
    $alpha = [int](240 * $a)
    if ($alpha -lt 8) { continue }
    if ($alpha -gt 255) { $alpha = 255 }
    if ($alpha -lt 8) { continue }
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($alpha, 248, 252, 255), 3.5)
    try {
      # 泡泡画在 transform 外面，所以坐标得自己乘缩放比 —— 否则在 256 的画布上，
      # 设计稿里的 x=430 直接跑到画布外面去了（第一版就是一粒都看不见）。
      $rr = [double]$p.r * (0.75 + 0.5 * (1.0 - $a))   # 越飘越大
      $G.DrawEllipse($pen, [float]($p.x * $BodyScale), [float]($p.y * $BodyScale), `
        [float]($rr * $BodyScale), [float]($rr * $BodyScale))
    }
    finally { $pen.Dispose() }
  }
}

# 给静态场景用：一张 512×512 的透明位图，画好一帧。
function New-FishFrame {
  param([int]$Size = 512, [double]$Phase = 0.0, [double]$Talk = 0.0, [double]$Blink = 0.0, [switch]$Bubbles)
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.Clear([System.Drawing.Color]::Transparent)
    Draw-Fish -G $g -Phase $Phase -Talk $Talk -Blink $Blink -BodyScale ($Size / 512.0) -Bubbles:$Bubbles
  }
  finally { $g.Dispose() }
  return $bmp
}
