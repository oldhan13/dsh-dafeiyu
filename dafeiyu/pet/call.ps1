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
#   判据是 `.venv\.deps-ok` 那个记号，不是"有 .venv 就算" —— 这台机器上就留过半个 .venv
#   （只有 numpy），照那条起会让一通本来能用的电话当场 import 失败。
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
    $script:child = $null
    # ★ 兜底（2026-10-26 19:0x 他报「点 × 之后电话没挂断」）：
    #   `$script:child` 只在**这一份**脚本起的进程上有值 —— 窗口被重复打开过、或者上一次
    #   Restart-Call 里 Start-Process 抛过错，就会留下**没人管**的 petcall.py：
    #   窗口关了，它还在占着麦克风照常听。所以这里按命令行特征扫一遍，全部收掉（排除自己）。
    try {
        Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*petcall.py*' -and $_.ProcessId -ne $PID } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    } catch { }
    Remove-Item $cmd -ErrorAction SilentlyContinue
    # ★ 收尾兜底（2026-10-26 20:3x 抓到的）：`res.release` 住在 petcall 的 finally 里，
    #   **被 -Force 打死的那一通永远不会走到那儿** —— 于是
    #     ① `state\call\session.json` 留着一个死 pid；
    #     ② `state\call\wallpaper.paused` 留着记号，**动态壁纸就一直停在那儿不放了**
    #        （实测现场：记号还在，wallpaper64 的 videodecode 却是 95%，两边说的是反的）。
    #   `res.py reap` 就是专门清这两样、并且在「没人在通话」时把壁纸还回去的。
    #   有超时：它只是收尾，绝不能因为它把挂断卡住。
    try {
        $r = Start-Process -FilePath (Get-CallPythonExe) -ArgumentList @('res.py', 'reap') `
            -WorkingDirectory $callDir -WindowStyle Hidden -PassThru
        for ($j = 0; $j -lt 25; $j++) {
            if ($r.HasExited) { break }
            Start-Sleep -Milliseconds 120
        }
        if (-not $r.HasExited) { try { $r.Kill() } catch { } }
    } catch { }
}

# ---------------------------------------------------------------- 音色来源（选项）
# 跟 tools\call\config.py 共用同一个 state\call\config.json：
# 这里是给人点的，命令行 `python config.py cloud` 也能改，两边不打架。
$CFG = Join-Path $stateDir 'config.json'
$script:VOICES = @(
    @{ id = 'piper';  short = '本地 piper' },
    @{ id = 'sovits'; short = '她自己的声音' },
    @{ id = 'cloud';  short = '云端 CosyVoice' }
)
# ★ 2026-10-26 19:0x 他报「切换音色有 bug，桌宠的声音没变化」，两个原因：
#   ① 这张表**漏了 sovits**（那时刚接上）⇒ 从 sovits 点一下会跳到表头 piper，从 piper 点只能在
#      piper→cloud→openai 之间绕，**永远回不到 sovits**；
#   ② 表里那个 **openai 没有 key**，切过去 engine 会静默退回 piper ⇒ 连着点几下听到的全是同一个声音，
#      看起来像「切换没生效」。
#   ⇒ 表里只留**真的能出声**的三个；openai 需要 key，等配了 key 再手动 base64 加回来。

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

# ================================================================ 画图缓存
# ★ 2026-10-26 20:2x —— 「一通话就卡」里**真正属于我们、也真正改得动**的那一份，就在这儿。
#   原来的画法是**每 120ms 把整套 GDI+ 对象重造一遍**：14 个光环椭圆各配一个
#   GraphicsPath + 一个 SolidBrush，再加 6 个 Font、3 个 StringFormat、4 个 Pen、
#   2 个 LinearGradientBrush —— 一帧四十来个对象，一秒八帧。
#   用 `C:\dsh-temp\paint-soak.ps1` 把这三段 Paint 抄出来空跑 35 秒，量到：
#       **9.4% 单核不停手 · 每帧 10~12ms · 偶发 20~50ms 的顿**
#   而 35 秒里 ws 一直是 113MB —— **它不泄漏，它只是一直在烧**。
#   ⇒ 规矩改成：**只造一次的，造一次**；光环不再造 Path（FillEllipse 本来就不需要 Path），
#     alpha 量化后连刷子也一起缓存。
#   ⚠ 以后再往下面三个 Paint 里加东西，先问一句：**这个能缓存吗**。
$STAGE_W = $WINW; $STAGE_H = 258
$TRANS_W = $WINW; $TRANS_H = 156
$CX = $STAGE_W / 2; $CY = 104; $BASE_R = 56

$script:oFont = @{}       # 字体
$script:oBrush = @{}       # 刷子
$script:oPen = @{}       # 笔
$script:oFmt = @{}      # StringFormat
$script:oGlow = @{}    # 光环刷子（按 alpha 量化缓存；换状态时清空）
$script:oAvatar = @{}  # 头像渐变刷（按状态缓存）
$script:oMz = @{}      # MeasureString 结果（按文本缓存）
$script:gfxAccent = $null
$script:jsonMt = $null
$script:sigT = ''
$script:sigS = ''
$script:accentNow = $PAL['starting'].c

function Get-AvatarBrush([string]$st) {
    if ($script:oAvatar.ContainsKey($st)) { return $script:oAvatar[$st] }
    if ($st -eq 'speaking') {
        $top = [System.Drawing.Color]::FromArgb(255, 214, 160); $bot = [System.Drawing.Color]::FromArgb(226, 128, 40)
    } elseif ($st -eq 'thinking') {
        $top = [System.Drawing.Color]::FromArgb(255, 224, 180); $bot = [System.Drawing.Color]::FromArgb(212, 148, 52)
    } else {
        $top = [System.Drawing.Color]::FromArgb(150, 210, 255); $bot = [System.Drawing.Color]::FromArgb(52, 122, 208)
    }
    $br = New-Object System.Drawing.Drawing2D.PathGradientBrush($script:oAvatarPath)
    $br.CenterPoint = New-Object System.Drawing.PointF([single]$CX, [single]($CY - $BASE_R * 0.35))
    $br.CenterColor = $top
    $br.SurroundColors = @($bot)
    $script:oAvatar[$st] = $br
    return $br
}

function Get-GlowBrush([int]$a) {
    if ($a -lt 2) { $a = 2 }
    $k = [int]([math]::Floor($a / 4.0)) * 4      # 量化：alpha 最大也就 26，桶数少得很
    if ($k -lt 2) { $k = 2 }
    if ($script:oGlow.ContainsKey($k)) { return $script:oGlow[$k] }
    $acc = $script:accentNow
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($k, $acc.R, $acc.G, $acc.B))
    $script:oGlow[$k] = $b
    return $b
}

function Get-LevelPen([string]$st) {
    $k = "pen_$st"
    if ($script:oPen.ContainsKey($k)) { return $script:oPen[$k] }
    $pen = New-Object System.Drawing.Pen($script:accentNow, [single]3.0)
    $pen.StartCap = 'Round'
    $pen.EndCap = 'Round'
    $script:oPen[$k] = $pen
    return $pen
}

function Measure-Cached($g, [string]$k, [string]$text) {
    $key = "$k|$text"
    if ($script:oMz.ContainsKey($key)) { return $script:oMz[$key] }
    if ($script:oMz.Count -gt 48) { $script:oMz.Clear() }
    $sz = $g.MeasureString($text, $script:oFont.bubble, [int]($TRANS_W - 96.0), $script:oFmt.bubble)
    $script:oMz[$key] = $sz
    return $sz
}

function Build-Gfx {
    # ---- 字体
    $script:oFont.title  = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $script:oFont.close  = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $script:oFont.voice  = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $script:oFont.glyph  = New-Object System.Drawing.Font('Microsoft YaHei UI', 27, [System.Drawing.FontStyle]::Bold)
    $script:oFont.status = New-Object System.Drawing.Font('Microsoft YaHei UI', 11.5)
    $script:oFont.timer  = New-Object System.Drawing.Font('Consolas', 9)
    $script:oFont.bubble = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $script:oFont.hint   = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $script:oFont.btn    = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)

    # ---- 背景渐变（尺寸是死的，造一次用到底）
    $script:oBrush.formBg  = Get-BgBrush $WINW $WINH
    $script:oBrush.stageBg = Get-BgBrush $STAGE_W $STAGE_H
    $script:oBrush.transBg = Get-BgBrush $TRANS_W $TRANS_H

    # ---- 文字刷子
    $script:oBrush.glyph   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(246, 251, 255))
    $script:oBrush.status  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(216, 228, 242))
    $script:oBrush.timer   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(96, 110, 130))
    $script:oBrush.heardTxt = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(148, 162, 182))
    $script:oBrush.heardBg  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(34, 42, 58))
    $script:oBrush.replyTxt = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(226, 238, 250))
    $script:oBrush.replyBg  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(26, 52, 82))
    $script:oBrush.hint     = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(74, 86, 104))
    $script:oBrush.btnTxt   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 244, 244))
    $script:oBrush.btnDead  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(34, 42, 56))
    $script:oBrush.hl       = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(58, 255, 255, 255))

    # ---- 笔
    $script:oPen.lvlDim = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(48, 96, 140), [single]3.0)
    $script:oPen.lvlDim.StartCap = 'Round'
    $script:oPen.lvlDim.EndCap = 'Round'
    $script:oPen.replyEdge = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(120, 95, 182, 255), [single]1.2)

    # ---- 对齐
    $script:oFmt.center = New-Object System.Drawing.StringFormat
    $script:oFmt.center.Alignment = 'Center'
    $script:oFmt.center.LineAlignment = 'Center'
    $script:oFmt.bubble = New-Object System.Drawing.StringFormat
    # ⚠ 别设 FormatFlags = WordBreak —— StringFormatFlags 里没有这个成员，设了整块画不出来
    $script:oFmt.bubble.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter

    # ---- 头像那块：几何是死的，刷子按状态缓存（Path 得活到最后，刷子引用它）
    $script:oAvatarPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $script:oAvatarPath.AddEllipse(($CX - $BASE_R), ($CY - $BASE_R), ($BASE_R * 2), ($BASE_R * 2))
}
Build-Gfx

$f.Region = New-Object System.Drawing.Region (New-RoundPath 0 0 $WINW $WINH 22)
$f.Add_Paint({
    param($s, $e)
    try {
        $e.Graphics.FillRectangle($script:oBrush.formBg, 0, 0, $f.Width, $f.Height)
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

        $g.FillRectangle($script:oBrush.stageBg, 0, 0, $STAGE_W, $STAGE_H)

        $st = "$($script:vis.state)"
        $pal = $PAL[$st]
        if (-not $pal) { $pal = $PAL['starting'] }
        $script:accentNow = $pal.c
        # 光环刷子是按 accent 缓存出来的 —— 换了状态就得换一批颜色
        if ($script:gfxAccent -ne $st) {
            $script:gfxAccent = $st
            $script:oGlow.Clear()
        }

        $beat = [math]::Sin($script:tick * 0.16) * 0.5 + 0.5
        $amp = if ($st -eq 'speaking') { 9.0 } elseif ($st -eq 'thinking') { 5.0 } else { 4.0 }
        $pulse = [single](($script:vis.level) * 0.6 + $beat * 0.4)

        # 外发光：一圈圈往下淡。
        # ★ 原来每圈造一个 GraphicsPath + 一个 SolidBrush；FillEllipse 根本不需要 Path，
        #   刷子按 alpha 量化缓存 ⇒ 一帧 0 个新对象（原来 28 个）。
        for ($i = 14; $i -ge 1; $i--) {
            $rr = $BASE_R + $i * 3.2 + $pulse * $amp
            $a = [int](26 * (1 - $i / 15.0) * (0.45 + $pulse * 0.85))
            if ($a -lt 2) { continue }
            $gb = Get-GlowBrush $a
            $g.FillEllipse($gb,
                [single]($CX - $rr), [single]($CY - $rr), [single]($rr * 2), [single]($rr * 2))
        }

        # 头像本体：径向渐变（刷子按状态缓存）
        $ab = Get-AvatarBrush $st
        $g.FillPath($ab, $script:oAvatarPath)

        # 高光
        $g.FillEllipse($script:oBrush.hl,
            [single]($CX - $BASE_R * 0.55), [single]($CY - $BASE_R * 0.78),
            [single]($BASE_R * 1.1), [single]($BASE_R * 0.62))

        # 「汐」
        $g.DrawString('汐', $script:oFont.glyph, $script:oBrush.glyph,
            (New-Object System.Drawing.RectangleF(0, [single]($CY - 28), [single]$STAGE_W, 56)),
            $script:oFmt.center)

        # 状态文字
        $g.DrawString($pal.text, $script:oFont.status, $script:oBrush.status,
            (New-Object System.Drawing.RectangleF(0, [single]($CY + $BASE_R + 20), [single]$STAGE_W, 26)),
            $script:oFmt.center)

        # 计时
        $sec = [int]$script:vis.seconds
        $ts = ('{0:00}:{1:00}' -f [int]($sec / 60), ($sec % 60))
        $g.DrawString($ts, $script:oFont.timer, $script:oBrush.timer,
            (New-Object System.Drawing.RectangleF(0, [single]($CY + $BASE_R + 46), [single]$STAGE_W, 20)),
            $script:oFmt.center)

        # 电平条（圆头）
        $n = 13; $barW = 3.0; $gap = 6.0
        $tot = $n * $barW + ($n - 1) * $gap
        $x0 = ($STAGE_W - $tot) / 2
        $by = $CY + $BASE_R + 80
        $lvl = [double]$script:vis.level
        if ($st -eq 'speaking') { $lvl = 0.34 + 0.42 * $beat }
        $pen = Get-LevelPen $st
        for ($i = 0; $i -lt $n; $i++) {
            $dd = [math]::Abs($i - ($n - 1) / 2) / (($n - 1) / 2)
            $hh = [math]::Max(2.0, [math]::Min(18.0, $lvl * 46 * (1 - $dd * 0.62)))
            $xx = [single]($x0 + $i * ($barW + $gap) + $barW / 2)
            $use = if ($hh -gt 7) { $pen } else { $script:oPen.lvlDim }
            $g.DrawLine($use, $xx, [single]($by - $hh / 2), $xx, [single]($by + $hh / 2))
        }
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
        $g.FillRectangle($script:oBrush.transBg, 0, 0, $TRANS_W, $TRANS_H)

        # ⚠ 别设 FormatFlags = WordBreak —— StringFormatFlags 里**没有**这个成员，
        #   设了会抛「枚举值无效」，整块画不出来，变成白底红叉。给矩形宽度它自己会折行。
        $padX = 11.0; $padY = 7.0
        $maxW = $TRANS_W - 96.0
        $yy = 8.0

        $heard = "$($script:vis.heard)"
        $reply = "$($script:vis.reply)"

        # 你（靠右、暗一点）
        if ($heard) {
            $sz = Measure-Cached $g 'h' $heard
            $boxW = [single][math]::Min($maxW, $sz.Width + $padX * 2)
            $boxH = [single][math]::Min(46.0, $sz.Height + $padY * 2)
            $boxX = [single]($TRANS_W - 22 - $boxW)
            $p1 = New-RoundPath $boxX $yy $boxW $boxH 10
            $g.FillPath($script:oBrush.heardBg, $p1)
            $g.DrawString($heard, $script:oFont.bubble, $script:oBrush.heardTxt,
                (New-Object System.Drawing.RectangleF([single]($boxX + $padX), [single]($yy + $padY),
                    [single]($boxW - $padX * 2), [single]($boxH - $padY * 2))), $script:oFmt.bubble)
            $p1.Dispose()
            $yy += $boxH + 8
        }

        # 汐（靠左、蓝一点；正在说的时候描个边）
        if ($reply) {
            $sz2 = Measure-Cached $g 'r' $reply
            $boxW2 = [single][math]::Min($maxW, $sz2.Width + $padX * 2)
            $boxH2 = [single][math]::Min(58.0, $sz2.Height + $padY * 2)
            $p2 = New-RoundPath 22 $yy $boxW2 $boxH2 10
            $g.FillPath($script:oBrush.replyBg, $p2)
            if ($script:vis.state -eq 'speaking') { $g.DrawPath($script:oPen.replyEdge, $p2) }
            $g.DrawString($reply, $script:oFont.bubble, $script:oBrush.replyTxt,
                (New-Object System.Drawing.RectangleF([single]($padX + 22), [single]($yy + $padY),
                    [single]($boxW2 - $padX * 2), [single]($boxH2 - $padY * 2))), $script:oFmt.bubble)
            $p2.Dispose()
        }

        if (-not $heard -and -not $reply) {
            $g.DrawString('说话就行，她能听见', $script:oFont.hint, $script:oBrush.hint,
                (New-Object System.Drawing.RectangleF(0, 54, [single]$TRANS_W, 24)), $script:oFmt.center)
        }
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
        $dead = ("$($script:vis.state)" -eq 'idle') -or (-not $script:vis.alive)
        if ($dead) {
            $g.FillRectangle($script:oBrush.btnDead, 0, 0, $BTW, $BTH)
        } else {
            # 渐变刷子按「悬停 / 不悬停」各造一次，挂进 $script:oBrush 里（这个键只在这儿用）
            $k = if ($script:hover) { 'btnHover' } else { 'btnNormal' }
            if (-not $script:oBrush.ContainsKey($k)) {
                $rr = New-Object System.Drawing.Rectangle 0, 0, $BTW, $BTH
                $topC = if ($script:hover) { [System.Drawing.Color]::FromArgb(232, 104, 104) } else { [System.Drawing.Color]::FromArgb(212, 84, 84) }
                $botC = if ($script:hover) { [System.Drawing.Color]::FromArgb(190, 62, 62) } else { [System.Drawing.Color]::FromArgb(164, 52, 52) }
                $script:oBrush[$k] = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $rr, $topC, $botC, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            }
            $g.FillRectangle($script:oBrush[$k], 0, 0, $BTW, $BTH)
        }
        $txt = if ($dead) { '关闭' } else { '挂 断' }
        $g.DrawString($txt, $script:oFont.btn, $script:oBrush.btnTxt,
            (New-Object System.Drawing.RectangleF(0, 0, [single]$BTW, [single]$BTH)), $script:oFmt.center)
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
# ★ 2026-10-26 20:2x 这条也跟着改了。原来每次 Tick 都做两件白烧的事：
#   ① `Get-Content` + `ConvertFrom-Json` **每 120ms 解析一遍**（文件其实 100ms 才写一次，
#      而且大部分时候内容片段根本没变）⇒ 改成**看 mtime，变了才读**；
#   ② 三个控件**每 120ms 全部 Invalidate**，哪怕状态一个字都没变
#      ⇒ 改成：文字变了才重画气泡和按钮；动画（听/想/说）才重画舞台；
#      已挂断 / 没接通的时候一帧都不画（那时候窗口本来就快关了）。
$script:jsonMt = $null
$script:sigT = ''
$script:sigS = ''

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120
$timer.add_Tick({
    $script:tick++
    $st = $null
    try {
        if (Test-Path $json) {
            $mt = [System.IO.File]::GetLastWriteTimeUtc($json)
            if ($mt -ne $script:jsonMt) {
                $script:jsonMt = $mt
                $raw = [System.IO.File]::ReadAllText($json, [System.Text.Encoding]::UTF8)
                if ($raw.Trim()) { $st = $raw | ConvertFrom-Json }
            }
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

    # ---- 按需重画
    $v = $script:vis
    $stx = "$($v.state)"

    $sigT = "$stx|$($v.heard)|$($v.reply)"
    if ($sigT -ne $script:sigT) {
        $script:sigT = $sigT
        $trans.Invalidate()
        $btn.Invalidate()
    }

    $sigS = "$stx|$([int]$v.seconds)"
    if ($sigS -ne $script:sigS) {
        $script:sigS = $sigS
        $stage.Invalidate()
    }

    # 光环 / 电平要动的时候才每帧重画；挂着不动的时候不烧那一份
    if ($stx -ne 'idle' -and $stx -ne 'failed') { $stage.Invalidate() }
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
