# 桌宠上的那个「通话窗」—— 她在这儿跟你打电话
#
# 它自己不出声音：声音全在 petcall.py 那边（默认麦克风 → 默认扬声器）。
# 这个窗只做三件事：
#   ① 起 / 收那个 python 进程
#   ② 每 120ms 读一次 state\call\petcall.json，把状态画出来
#   ③ 「挂断」写一行到 petcall.cmd，让 python 自己收尾
#
# 2026-10-26 美化版：整窗自绘（渐变底 + 呼吸光环 + 圆角气泡 + 渐变压断键）。
#
# ⚠ 两个踩过的坑，改这个文件前先看：
#   ① PowerShell 变量名**不区分大小写**：窗口尺寸千万别叫 $W/$H —— 画的时候
#      `$w = $stage.Width` 会把全局的 $W 改掉（pet-wf.ps1 里 pHead/phead 也是这个坑）。
#      所以这里窗口尺寸叫 $WINW/$WINH，控件尺寸叫 $CW/$CH/$TW/$BW。
#   ② 用 `powershell -WindowStyle Hidden` 启动时，STARTUPINFO 是 SW_HIDE，它会作用到
#      **第一个创建的窗体**上 ⇒ 窗口看不见。Shown 里必须补一刀 ShowWindow(SW_SHOW)。
#
# 用法： dafeiyu\pet\call.cmd   ·   桌宠右键菜单「打电话」   ·   面板上那个「话」
#   拖窗口任意处可以移动；Esc 或 ✕ 就是挂断。

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # ...\default-workspace
$callDir  = Join-Path $root 'dafeiyu\tools\call'
$stateDir = Join-Path $root 'dafeiyu\state\call'
$json     = Join-Path $stateDir 'petcall.json'
$cmd      = Join-Path $stateDir 'petcall.cmd'
$outLog   = Join-Path $stateDir 'petcall.out.log'
$errLog   = Join-Path $stateDir 'petcall.err.log'
$paintLog = Join-Path $stateDir 'call-paint.err.log'

if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
Remove-Item $cmd, $json, $paintLog -ErrorAction SilentlyContinue
Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

function Trace-Paint($tag, $err) {
    try {
        Add-Content -Path $paintLog -Encoding UTF8 `
            -Value ("{0} {1}: {2} :: {3}" -f (Get-Date -Format 'HH:mm:ss'), $tag, $err.GetType().Name, $err.Message)
    } catch { }
}

# ---------------------------------------------------------------- 起 / 收 通话进程
$script:child = $null
# 用哪个 python：有**装齐过的** .venv 就用它，否则用 PATH 里的。
# ★ 规矩在 tools\call\bootstrap.py 的 target_python() 里，两边必须一致。
#   判据是 .venv\.deps-ok 那个记号，不是"有 .venv 就算" —— 那台机器上就留过半个 .venv
#   （只有 numpy），照"有就用"起会让一通本来能用的电话当场 import 失败。
function Get-CallPythonExe {
    $venvPy = Join-Path $callDir '.venv\Scripts\python.exe'
    $mark = Join-Path $callDir '.venv\.deps-ok'
    if ((Test-Path $venvPy) -and (Test-Path $mark)) { return $venvPy }
    return 'python'
}

function Start-Call {
    $script:child = Start-Process -FilePath (Get-CallPythonExe) `
        -ArgumentList @('petcall.py') -WorkingDirectory $callDir -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
}

function Stop-Call {
    # 先礼后兵：写 hangup 让它自己收尾（会把流水落盘）
    try {
        if (Test-Path $stateDir) { Set-Content -Path $cmd -Value 'hangup' -Encoding UTF8 -NoNewline }
    } catch { }
    for ($i = 0; $i -lt 25; $i++) {
        if (-not $script:child -or $script:child.HasExited) { break }
        Start-Sleep -Milliseconds 120
    }
    if ($script:child -and -not $script:child.HasExited) {
        try { $script:child.Kill() } catch { }
    }
    Remove-Item $cmd -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 音色来源（选项）
# 跟 tools\call\config.py 共用同一个 state\call\config.json：
# 这里是给人点的，命令行 `python config.py cloud` 也能改，两边不打架。
$CFG = Join-Path $stateDir 'config.json'
$script:VOICES = @(
    @{ id = 'piper';  short = '本地 piper' },
    @{ id = 'cloud';  short = '云端 CosyVoice' },
    @{ id = 'openai'; short = 'OpenAI TTS' }
)

function Read-Voice {
    try {
        if (Test-Path $CFG) {
            $c = Get-Content $CFG -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.tts -and $c.tts.backend) { return [string]$c.tts.backend }
        }
    } catch { }
    return 'piper'
}

function Set-Voice([string]$id) {
    $c = $null
    try { if (Test-Path $CFG) { $c = Get-Content $CFG -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    if (-not $c) { $c = [pscustomobject]@{} }
    if (-not $c.PSObject.Properties['tts']) {
        $c | Add-Member -NotePropertyName tts -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $c.tts.PSObject.Properties['backend']) {
        $c.tts | Add-Member -NotePropertyName backend -NotePropertyValue $id -Force
    } else {
        $c.tts.backend = $id
    }
    ($c | ConvertTo-Json -Depth 8) | Set-Content -Path $CFG -Encoding UTF8
}

function Voice-Text([string]$id) {
    foreach ($v in $script:VOICES) { if ($v.id -eq $id) { return "音色·$($v.short)" } }
    return "音色·$id"
}

function Next-Voice([string]$id) {
    $ids = @($script:VOICES | ForEach-Object { $_.id })
    $i = [array]::IndexOf($ids, $id)
    if ($i -lt 0) { return $ids[0] }
    return $ids[($i + 1) % $ids.Count]
}

function Restart-Call {
    Stop-Call
    Start-Sleep -Milliseconds 250
    try { Start-Call } catch { }
}

# ---------------------------------------------------------------- 画图的公共零件
function New-RoundPath([single]$x, [single]$y, [single]$wid, [single]$hei, [single]$rad) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($rad -le 0.5) {
        $p.AddRectangle((New-Object System.Drawing.RectangleF($x, $y, $wid, $hei)))
        return $p
    }
    if ($rad * 2 -gt $wid) { $rad = $wid / 2 }
    if ($rad * 2 -gt $hei) { $rad = $hei / 2 }
    $d = $rad * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc(($x + $wid - $d), $y, $d, $d, 270, 90)
    $p.AddArc(($x + $wid - $d), ($y + $hei - $d), $d, $d, 0, 90)
    $p.AddArc($x, ($y + $hei - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Set-DoubleBuffered($ctrl) {
    try {
        $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
        $prop = $ctrl.GetType().GetProperty('DoubleBuffered', $flags)
        if ($prop) { $prop.SetValue($ctrl, $true, $null) }
    } catch { }
}

function Get-BgBrush([int]$bw, [int]$bh) {
    $r = New-Object System.Drawing.Rectangle 0, 0, $bw, $bh
    return New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $r,
        [System.Drawing.Color]::FromArgb(23, 30, 44),
        [System.Drawing.Color]::FromArgb(10, 14, 21),
        [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
}

# ---------------------------------------------------------------- 状态盘
$PAL = @{
    listening = @{ text = '在听你说'; c = [System.Drawing.Color]::FromArgb(95, 182, 255) }
    thinking  = @{ text = '在想…'; c = [System.Drawing.Color]::FromArgb(255, 196, 107) }
    speaking  = @{ text = '她在说'; c = [System.Drawing.Color]::FromArgb(255, 179, 71) }
    idle      = @{ text = '已挂断'; c = [System.Drawing.Color]::FromArgb(122, 136, 156) }
    starting  = @{ text = '正在接通…'; c = [System.Drawing.Color]::FromArgb(122, 136, 156) }
    failed    = @{ text = '没接通'; c = [System.Drawing.Color]::FromArgb(226, 110, 110) }
}
$script:vis = @{ state = 'starting'; level = 0.0; seconds = 0; heard = ''; reply = ''; alive = $true; ready = $false }
$script:tick = 0
$script:closing = $false

# ---------------------------------------------------------------- 窗口
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

$WINW = 348; $WINH = 536
$f = New-Object System.Windows.Forms.Form
$f.Text = '汐 · 通话'
$f.FormBorderStyle = 'None'
$f.StartPosition   = 'Manual'
$f.ShowInTaskbar   = $false
$f.TopMost         = $true
$f.BackColor       = [System.Drawing.Color]::FromArgb(10, 14, 21)
$f.Size            = New-Object System.Drawing.Size($WINW, $WINH)
$f.KeyPreview      = $true
Set-DoubleBuffered $f

# 摆在鱼的上方（读 pet\state.json 那条鱼的位置），读不到就退回右下角
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$posX = $wa.Right - $WINW - 28
$posY = $wa.Bottom - $WINH - 28
try {
    $petState = Join-Path $root 'dafeiyu\pet\state.json'
    if (Test-Path $petState) {
        $ps = Get-Content $petState -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ps.left -and $ps.bottom) {
            $posX = [int]$ps.left - [int]($WINW / 2) + 40
            $posY = [int]$ps.bottom - $WINH - 76
        }
    }
} catch { }
$posX = [int][math]::Max($wa.Left + 8, [math]::Min($posX, $wa.Right - $WINW - 8))
$posY = [int][math]::Max($wa.Top + 8, [math]::Min($posY, $wa.Bottom - $WINH - 8))
$f.Location = New-Object System.Drawing.Point($posX, $posY)

$f.Region = New-Object System.Drawing.Region (New-RoundPath 0 0 $WINW $WINH 22)
$f.Add_Paint({
    param($s, $e)
    try {
        $b = Get-BgBrush $f.Width $f.Height
        $e.Graphics.FillRectangle($b, 0, 0, $f.Width, $f.Height)
        $b.Dispose()
    } catch { Trace-Paint 'form' $_.Exception }
})

# ---- 顶栏
$title = New-Object System.Windows.Forms.Label
$title.Text = '通话'
$title.ForeColor = [System.Drawing.Color]::FromArgb(112, 126, 146)
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$title.AutoSize = $true
$title.BackColor = [System.Drawing.Color]::Transparent
$title.Location = New-Object System.Drawing.Point(24, 18)
$f.Controls.Add($title)

$close = New-Object System.Windows.Forms.Label
$close.Text = '✕'
$close.ForeColor = [System.Drawing.Color]::FromArgb(112, 126, 146)
$close.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$close.AutoSize = $false
$close.Size = New-Object System.Drawing.Size(28, 26)
$close.TextAlign = 'MiddleCenter'
$close.BackColor = [System.Drawing.Color]::Transparent
$close.Location = New-Object System.Drawing.Point(($WINW - 46), 14)
$close.Cursor = 'Hand'
$f.Controls.Add($close)
$close.Add_MouseEnter({ $close.ForeColor = [System.Drawing.Color]::White })
$close.Add_MouseLeave({ $close.ForeColor = [System.Drawing.Color]::FromArgb(112, 126, 146) })

# 音色来源：点一下切下一个（本地免费 → 云端 CosyVoice → OpenAI）
$voiceLbl = New-Object System.Windows.Forms.Label
$voiceLbl.Text = '音色·本地 piper'
$voiceLbl.ForeColor = [System.Drawing.Color]::FromArgb(112, 126, 146)
$voiceLbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$voiceLbl.AutoSize = $false
$voiceLbl.Size = New-Object System.Drawing.Size(150, 26)
$voiceLbl.TextAlign = 'MiddleRight'
$voiceLbl.BackColor = [System.Drawing.Color]::Transparent
$voiceLbl.Location = New-Object System.Drawing.Point(($WINW - 206), 14)
$voiceLbl.Cursor = 'Hand'
$f.Controls.Add($voiceLbl)
$script:voiceLbl = $voiceLbl
$voiceLbl.Add_Click({
    $next = Next-Voice (Read-Voice)
    Set-Voice $next
    $script:voiceLbl.Text = Voice-Text $next
    $script:vis.state = 'starting'
    Restart-Call
})
$voiceLbl.Add_MouseEnter({ $script:voiceLbl.ForeColor = [System.Drawing.Color]::White })
$voiceLbl.Add_MouseLeave({ $script:voiceLbl.ForeColor = [System.Drawing.Color]::FromArgb(112, 126, 146) })

# ---- 舞台：光环 + 头像 + 状态 + 计时 + 电平
$stage = New-Object System.Windows.Forms.Panel
$stage.Location = New-Object System.Drawing.Point(0, 44)
$stage.Size = New-Object System.Drawing.Size($WINW, 258)
$stage.BackColor = [System.Drawing.Color]::FromArgb(12, 17, 26)
Set-DoubleBuffered $stage
$f.Controls.Add($stage)

$stage.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $CW = $stage.Width
        $CH = $stage.Height

        $bg = Get-BgBrush $CW $CH
        $g.FillRectangle($bg, 0, 0, $CW, $CH)
        $bg.Dispose()

        $st = "$($script:vis.state)"
        $pal = $PAL[$st]
        if (-not $pal) { $pal = $PAL['starting'] }
        $accent = $pal.c

        $cx = $CW / 2
        $cy = 104
        $baseR = 56

        $beat = [math]::Sin($script:tick * 0.16) * 0.5 + 0.5
        $amp = if ($st -eq 'speaking') { 9.0 } elseif ($st -eq 'thinking') { 5.0 } else { 4.0 }
        $pulse = [single](($script:vis.level) * 0.6 + $beat * 0.4)

        # 外发光：一圈圈往下淡
        for ($i = 14; $i -ge 1; $i--) {
            $rr = $baseR + $i * 3.2 + $pulse * $amp
            $a = [int](26 * (1 - $i / 15.0) * (0.45 + $pulse * 0.85))
            if ($a -lt 2) { continue }
            $col = [System.Drawing.Color]::FromArgb($a, $accent.R, $accent.G, $accent.B)
            $pp = New-Object System.Drawing.Drawing2D.GraphicsPath
            $pp.AddEllipse(($cx - $rr), ($cy - $rr), ($rr * 2), ($rr * 2))
            $br = New-Object System.Drawing.SolidBrush($col)
            $g.FillPath($br, $pp)
            $br.Dispose(); $pp.Dispose()
        }

        # 头像本体：径向渐变
        $fp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $fp.AddEllipse(($cx - $baseR), ($cy - $baseR), ($baseR * 2), ($baseR * 2))
        $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($fp)
        $pgb.CenterPoint = New-Object System.Drawing.PointF([single]$cx, [single]($cy - $baseR * 0.35))
        $top = if ($st -eq 'speaking') { [System.Drawing.Color]::FromArgb(255, 214, 160) }
               elseif ($st -eq 'thinking') { [System.Drawing.Color]::FromArgb(255, 224, 180) }
               else { [System.Drawing.Color]::FromArgb(150, 210, 255) }
        $bot = if ($st -eq 'speaking') { [System.Drawing.Color]::FromArgb(226, 128, 40) }
               elseif ($st -eq 'thinking') { [System.Drawing.Color]::FromArgb(212, 148, 52) }
               else { [System.Drawing.Color]::FromArgb(52, 122, 208) }
        $pgb.CenterColor = $top
        $pgb.SurroundColors = @($bot)
        $g.FillPath($pgb, $fp)
        $pgb.Dispose()

        # 高光
        $hl = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(58, 255, 255, 255))
        $g.FillEllipse($hl, [single]($cx - $baseR * 0.55), [single]($cy - $baseR * 0.78),
            [single]($baseR * 1.1), [single]($baseR * 0.62))
        $hl.Dispose()
        $fp.Dispose()

        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'
        $sf.LineAlignment = 'Center'

        # 「汐」
        $gf = New-Object System.Drawing.Font('Microsoft YaHei UI', 27, [System.Drawing.FontStyle]::Bold)
        $wb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(246, 251, 255))
        $g.DrawString('汐', $gf, $wb, (New-Object System.Drawing.RectangleF(0, [single]($cy - 28), [single]$CW, 56)), $sf)
        $wb.Dispose(); $gf.Dispose()

        # 状态文字
        $sfont = New-Object System.Drawing.Font('Microsoft YaHei UI', 11.5)
        $sbrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(216, 228, 242))
        $g.DrawString($pal.text, $sfont, $sbrush,
            (New-Object System.Drawing.RectangleF(0, [single]($cy + $baseR + 20), [single]$CW, 26)), $sf)
        $sbrush.Dispose(); $sfont.Dispose()

        # 计时
        $sec = [int]$script:vis.seconds
        $ts = ('{0:00}:{1:00}' -f [int]($sec / 60), ($sec % 60))
        $tf = New-Object System.Drawing.Font('Consolas', 9)
        $tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(96, 110, 130))
        $g.DrawString($ts, $tf, $tb,
            (New-Object System.Drawing.RectangleF(0, [single]($cy + $baseR + 46), [single]$CW, 20)), $sf)
        $tb.Dispose(); $tf.Dispose(); $sf.Dispose()

        # 电平条（圆头）
        $n = 13; $barW = 3.0; $gap = 6.0
        $tot = $n * $barW + ($n - 1) * $gap
        $x0 = ($CW - $tot) / 2
        $by = $cy + $baseR + 80
        $lvl = [double]$script:vis.level
        if ($st -eq 'speaking') { $lvl = 0.34 + 0.42 * $beat }
        $pen = New-Object System.Drawing.Pen($accent, [single]$barW)
        $pen.StartCap = 'Round'
        $pen.EndCap = 'Round'
        $dim = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(48, 96, 140), [single]$barW)
        $dim.StartCap = 'Round'
        $dim.EndCap = 'Round'
        for ($i = 0; $i -lt $n; $i++) {
            $dd = [math]::Abs($i - ($n - 1) / 2) / (($n - 1) / 2)
            $hh = [math]::Max(2.0, [math]::Min(18.0, $lvl * 46 * (1 - $dd * 0.62)))
            $xx = [single]($x0 + $i * ($barW + $gap) + $barW / 2)
            $use = if ($hh -gt 7) { $pen } else { $dim }
            $g.DrawLine($use, $xx, [single]($by - $hh / 2), $xx, [single]($by + $hh / 2))
        }
        $pen.Dispose(); $dim.Dispose()
    } catch { Trace-Paint 'stage' $_.Exception }
})

# ---- 转写：两个圆角气泡
$trans = New-Object System.Windows.Forms.Panel
$trans.Location = New-Object System.Drawing.Point(0, 306)
$trans.Size = New-Object System.Drawing.Size($WINW, 156)
$trans.BackColor = [System.Drawing.Color]::FromArgb(10, 14, 21)
Set-DoubleBuffered $trans
$f.Controls.Add($trans)

$trans.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $TW = $trans.Width
        $TH = $trans.Height
        $bg = Get-BgBrush $TW $TH
        $g.FillRectangle($bg, 0, 0, $TW, $TH)
        $bg.Dispose()

        $bfont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
        $fmt = New-Object System.Drawing.StringFormat
        # ⚠ 别设 FormatFlags = WordBreak —— StringFormatFlags 里**没有**这个成员，
        #   设了会抛「枚举值无效」，整块画不出来，变成白底红叉。给矩形宽度它自己会折行。
        $fmt.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $padX = 11.0; $padY = 7.0
        $maxW = $TW - 96.0
        $yy = 8.0

        $heard = "$($script:vis.heard)"
        $reply = "$($script:vis.reply)"

        # 你（靠右、暗一点）
        if ($heard) {
            $sz = $g.MeasureString($heard, $bfont, ([int]$maxW), $fmt)
            $boxW = [single][math]::Min($maxW, $sz.Width + $padX * 2)
            $boxH = [single][math]::Min(46.0, $sz.Height + $padY * 2)
            $boxX = [single]($TW - 22 - $boxW)
            $p1 = New-RoundPath $boxX $yy $boxW $boxH 10
            $br1 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(34, 42, 58))
            $g.FillPath($br1, $p1); $br1.Dispose()
            $tb1 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(148, 162, 182))
            $g.DrawString($heard, $bfont, $tb1,
                (New-Object System.Drawing.RectangleF([single]($boxX + $padX), [single]($yy + $padY),
                    [single]($boxW - $padX * 2), [single]($boxH - $padY * 2))), $fmt)
            $tb1.Dispose(); $p1.Dispose()
            $yy += $boxH + 8
        }

        # 汐（靠左、蓝一点；正在说的时候描个边）
        if ($reply) {
            $sz2 = $g.MeasureString($reply, $bfont, ([int]$maxW), $fmt)
            $boxW2 = [single][math]::Min($maxW, $sz2.Width + $padX * 2)
            $boxH2 = [single][math]::Min(58.0, $sz2.Height + $padY * 2)
            $p2 = New-RoundPath 22 $yy $boxW2 $boxH2 10
            $br2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(26, 52, 82))
            $g.FillPath($br2, $p2); $br2.Dispose()
            if ($script:vis.state -eq 'speaking') {
                $pen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(120, 95, 182, 255), [single]1.2)
                $g.DrawPath($pen2, $p2); $pen2.Dispose()
            }
            $tb2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(226, 238, 250))
            $g.DrawString($reply, $bfont, $tb2,
                (New-Object System.Drawing.RectangleF([single]($padX + 22), [single]($yy + $padY),
                    [single]($boxW2 - $padX * 2), [single]($boxH2 - $padY * 2))), $fmt)
            $tb2.Dispose(); $p2.Dispose()
        }

        if (-not $heard -and -not $reply) {
            $hintF = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
            $hintB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(74, 86, 104))
            $sf2 = New-Object System.Drawing.StringFormat
            $sf2.Alignment = 'Center'
            $g.DrawString('说话就行，她能听见', $hintF, $hintB,
                (New-Object System.Drawing.RectangleF(0, 54, [single]$TW, 24)), $sf2)
            $hintB.Dispose(); $hintF.Dispose(); $sf2.Dispose()
        }

        $bfont.Dispose(); $fmt.Dispose()
    } catch { Trace-Paint 'trans' $_.Exception }
})

# ---- 压断键（自绘：渐变 + 圆角 + 悬停变亮）
$BTW = 168; $BTH = 44
$btn = New-Object System.Windows.Forms.Panel
$btn.Size = New-Object System.Drawing.Size($BTW, $BTH)
$btn.Location = New-Object System.Drawing.Point([int](($WINW - $BTW) / 2), ($WINH - 74))
$btn.BackColor = [System.Drawing.Color]::FromArgb(24, 16, 20)
$btn.Cursor = 'Hand'
Set-DoubleBuffered $btn
$btn.Region = New-Object System.Drawing.Region (New-RoundPath 0 0 $BTW $BTH 22)
$f.Controls.Add($btn)
$script:hover = $false

$btn.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $BW = $btn.Width
        $BH = $btn.Height
        $dead = ("$($script:vis.state)" -eq 'idle') -or (-not $script:vis.alive)
        if ($dead) {
            $db = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(34, 42, 56))
            $g.FillRectangle($db, 0, 0, $BW, $BH)
            $db.Dispose()
        } else {
            $rr = New-Object System.Drawing.Rectangle 0, 0, $BW, $BH
            $topC = if ($script:hover) { [System.Drawing.Color]::FromArgb(232, 104, 104) } else { [System.Drawing.Color]::FromArgb(212, 84, 84) }
            $botC = if ($script:hover) { [System.Drawing.Color]::FromArgb(190, 62, 62) } else { [System.Drawing.Color]::FromArgb(164, 52, 52) }
            $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $rr, $topC, $botC, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            $g.FillRectangle($br, 0, 0, $BW, $BH)
            $br.Dispose()
        }
        $txt = if ($dead) { '关闭' } else { '挂 断' }
        $fnt = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
        $wb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 244, 244))
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'
        $sf.LineAlignment = 'Center'
        $g.DrawString($txt, $fnt, $wb, (New-Object System.Drawing.RectangleF(0, 0, [single]$BW, [single]$BH)), $sf)
        $wb.Dispose(); $fnt.Dispose(); $sf.Dispose()
    } catch { Trace-Paint 'btn' $_.Exception }
})
$btn.Add_MouseEnter({ $script:hover = $true; $btn.Invalidate() })
$btn.Add_MouseLeave({ $script:hover = $false; $btn.Invalidate() })

# ---------------------------------------------------------------- 拖动
$script:drag = $false; $script:dx = 0; $script:dy = 0
$down = {
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:drag = $true; $script:dx = $e.X; $script:dy = $e.Y
    }
}
$move = {
    param($s, $e)
    if ($script:drag) {
        $f.Left = $f.Left + ($e.X - $script:dx)
        $f.Top  = $f.Top + ($e.Y - $script:dy)
    }
}
$up = { param($s, $e) $script:drag = $false }
foreach ($c in @($f, $title, $stage, $trans)) {
    $c.add_MouseDown($down); $c.add_MouseMove($move); $c.add_MouseUp($up)
}

# ---------------------------------------------------------------- 时钟
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120
$timer.add_Tick({
    $script:tick++
    $st = $null
    try {
        if (Test-Path $json) {
            $raw = Get-Content -Path $json -Raw -Encoding UTF8 -ErrorAction Stop
            if ($raw.Trim()) { $st = $raw | ConvertFrom-Json }
        }
    } catch { }

    if ($st) {
        $script:vis.state   = "$($st.state)"
        $script:vis.level   = [double]$st.level
        $script:vis.seconds = [double]$st.seconds
        $script:vis.heard   = "$($st.heard)"
        $script:vis.reply   = "$($st.reply)"
        $script:vis.alive   = [bool]$st.alive
        $script:vis.ready   = [bool]$st.ready
        if (-not $st.ready -and $st.state -ne 'failed') { $script:vis.state = 'starting' }
        if ($st.state -eq 'failed') { $script:vis.reply = "$($st.heard)" }
    }

    if ($script:vis.alive -eq $false -and -not $script:closing) {
        $script:closing = $true
        $script:vis.state = 'idle'
    }

    $stage.Invalidate()
    $trans.Invalidate()
    $btn.Invalidate()
})

# ---------------------------------------------------------------- 事件
$hangup = {
    if ($script:closing) { $f.Close(); return }
    $script:closing = $true
    $timer.Stop()
    Stop-Call
    $f.Close()
}

$btn.Add_Click($hangup)
$close.Add_Click($hangup)
$f.add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { & $hangup } })
$f.add_FormClosing({
    param($s, $e)
    if (-not $script:closing) { $script:closing = $true; Stop-Call }
    $timer.Stop()
})

# ---------------------------------------------------------------- 走
Add-Type -Namespace Dfy -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
'@

$f.add_Shown({
    try {
        [void][Dfy.Win]::ShowWindow($f.Handle, 5)      # SW_SHOW
        [void][Dfy.Win]::SetForegroundWindow($f.Handle)
    } catch { }
    $script:voiceLbl.Text = Voice-Text (Read-Voice)
    $timer.Start()
    try { Start-Call }
    catch {
        $script:vis.state = 'failed'
        $script:vis.reply = "起不来 python：$($_.Exception.Message)"
    }
})

[void]$f.ShowDialog()
