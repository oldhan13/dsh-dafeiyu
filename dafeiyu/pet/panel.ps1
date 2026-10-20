#requires -Version 5.1
<#
  panel.ps1 —— 双击鱼时"长出来"的对话框。

  2026-10-20 中午他要的：「不想和桌宠对话时还要单独拉一个浮窗出来，双击图标时图标展开变成对话框，
  头像出现在每个对话框的左侧，就像 QQ 聊天界面那样」。

  所以这里不再是另一个窗口进程（原来 chat.ps1 靠 Start-Process 起，于是永远有第二个窗）
  —— 面板和鱼在**同一个进程**里，共用一个生命周期：
    · 双击鱼 → 鱼藏起来，面板从鱼的矩形**长**到最终大小（右下角对齐，往上往左展开）
    · 关掉面板（✕ 或 Esc）→ 鱼原地回来
  消息行：她在左（圆头像 + 深灰气泡），他在右（绿色气泡，无头像），跟 QQ 一样。

  由 pet-wf.ps1 点源进来 —— $script: 指向 pet-wf 的脚本作用域，所以 $ROOT / $AVATAR / Trace 都能用。
  ⚠ 事件处理器里**只能用 $script: 变量**：PowerShell 的 scriptblock 抓的是脚本作用域，
    不是定义处函数的局部帧（第一版就栽在这上面，tick 里读到的全是 $null）。
#>

$PCOL_BG = [System.Drawing.Color]::FromArgb(24, 24, 28)
$PCOL_BAR = [System.Drawing.Color]::FromArgb(33, 33, 39)
$PCOL_LINE = [System.Drawing.Color]::FromArgb(44, 44, 52)
$PCOL_HER = [System.Drawing.Color]::FromArgb(58, 58, 66)
$PCOL_MINE = [System.Drawing.Color]::FromArgb(149, 236, 105)
$PCOL_TXT_HER = [System.Drawing.Color]::FromArgb(240, 240, 245)
$PCOL_TXT_MINE = [System.Drawing.Color]::FromArgb(20, 20, 20)
$PCOL_DIM = [System.Drawing.Color]::FromArgb(132, 132, 148)

$script:pW = 420
$script:pH = 620
$script:pHead = 64
$script:pFoot = 84

$script:pform = $null
$script:pwrap = $null
$script:pbox = $null
$script:pbtn = $null
$script:pmic = $null
$script:ptip = $null
$script:pclose = $null
$script:pvoiceLbl = $null
$script:pmood = $null
$script:pmoodLast = $null
$script:plist = $null
$script:ppending = $null
$script:pwaiting = $false
$script:ptyping = $null
$script:pavatar = @{}
$script:precording = $false
$script:popen = $false
# 她主动发来的话（比如后台 agent 跑完的结果）：bridge 那边排队，面板每两秒取一次。
# pout 是"已经收到第几条"，打开面板时先对齐一次，免得和读历史重复显示。
$script:pout = 0
$script:pfishForm = $null
$script:panim = $null
$script:plastText = $null
$script:plastWho = $null
$script:plastAt = $null
$script:precent = New-Object System.Collections.ArrayList
$script:pmsgFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
$script:ptimeFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
# 两条消息隔多久才再标一次时间（QQ / 微信也是这个量级）：5 分钟。换天必标。
$script:ptimeGap = 300

$BRIDGE = 'http://127.0.0.1:3079'
$STT = Join-Path $ROOT 'dafeiyu\tools\stt-siliconflow.ps1'
$SPEAKPLAY = Join-Path $ROOT 'dafeiyu\tools\speak-play.ps1'
$SAYTMPDIR = 'C:\dsh-temp'
$PSTATE = Join-Path $PET 'panel-state.json'
$WAV = 'C:\dsh-temp\desk-rec.wav'
$WAVOUT = 'C:\dsh-temp\desk-rec'
$REC_ALIAS = 'dfyrec'

# ---- 声音（2026-10-20 下午加）----
# 默认关：他明确说过"做成开关，别默认吵"。开了之后她每条回复都会念出来，
# 合成 + 播放交给 tools\speak-play.ps1 那个脱管进程，面板本身不阻塞。
$script:pvoice = $false
$script:pwelcomeJob = $null
$script:pwelcomeDone = 0

function Save-PanelState {
  # open 也要写：bridge 靠它决定"结果要不要再用气泡喊一声" —— 面板开着就不喊，否则一条显示两遍
  try { @{ voice = [bool]$script:pvoice; open = [bool]$script:popen } | ConvertTo-Json -Compress | Set-Content $PSTATE -Encoding UTF8 } catch { }
}
function Load-PanelState {
  try {
    if (Test-Path $PSTATE) {
      $o = (Get-Content $PSTATE -Raw -Encoding UTF8) | ConvertFrom-Json
      $script:pvoice = [bool]$o.voice
    }
  } catch { }
}
function Set-PanelVoice([bool]$on) {
  $script:pvoice = $on
  Save-PanelState
  if ($script:pvoiceLbl) {
    if ($on) { $script:pvoiceLbl.ForeColor = [System.Drawing.Color]::FromArgb(149, 236, 105) }
    else { $script:pvoiceLbl.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 136) }
  }
  Trace ('panel: voice=' + $on)
}

# 念一句。不清洗文本 —— TTS 只念字，标点会读成停顿，反而对。
function Speak-PanelText([string]$text) {
  if (-not $script:pvoice) { return }
  $t = ($text -replace '[\r\n]+', ' ').Trim()
  if (-not $t) { return }
  # 回复里常带路径和命令，念出来是噪音；只念前 200 字，够听出语气了。
  if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
  try {
    if (-not (Test-Path $SAYTMPDIR)) { New-Item -ItemType Directory -Path $SAYTMPDIR -Force | Out-Null }
    $tmp = Join-Path $SAYTMPDIR ('panel-say-' + [DateTime]::Now.ToString('HHmmssfff') + '.txt')
    [IO.File]::WriteAllText($tmp, $t, (New-Object System.Text.UTF8Encoding($false)))
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SPEAKPLAY, '-TextFile', $tmp
    ) | Out-Null
    Trace ('panel: speak ' + $t.Length + ' chars')
  } catch { Trace ('panel speak failed: ' + $_.Exception.Message) }
}

function Panel-Post([string]$text) {
  # quiet：面板自己会显示她的回复，别让 bridge 再往 say.txt 写一遍
  # （写了就会被鱼头顶的气泡那条监听再递进面板 —— 一次发送两遍消息）
  $body = @{ text = $text; quiet = $true } | ConvertTo-Json -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  return (Invoke-RestMethod -Uri "$BRIDGE/say" -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15).id
}
function Panel-Reply([string]$id) { return Invoke-RestMethod -Uri "$BRIDGE/reply?id=$id" -TimeoutSec 15 }
function Panel-History([int]$n) { return @(Invoke-RestMethod -Uri "$BRIDGE/history?n=$n" -TimeoutSec 15) }
function Panel-Outbox([int]$since) { return Invoke-RestMethod -Uri "$BRIDGE/outbox?since=$since" -TimeoutSec 8 }

# 她主动发来的（后台 agent 跑完的结果就走这条）。
# 面板关着的时候不取 —— 攒在 bridge 那边，下次打开先读历史、再把游标推到最新，一条只显示一次。
function Poll-PanelOutbox {
  if (-not (Test-PanelOpen)) { return }
  try {
    $r = Panel-Outbox $script:pout
    if ($null -eq $r -or $null -eq $r.items) { return }
    foreach ($m in @($r.items)) {
      if ($null -eq $m) { continue }
      $script:pout = [int]$m.seq
      Add-PanelMsg 'her' ([string]$m.text) $m.at
      Update-PanelMood
      Speak-PanelText ([string]$m.text)
    }
  } catch { Trace ('panel outbox failed: ' + $_.Exception.Message) }
}

# 圆形头像：不用额外素材，把 avatar.png 裁成圆。缓存住，每条消息复用同一张位图。
function Get-PanelAvatar([int]$size) {
  $k = [string]$size
  if ($script:pavatar.ContainsKey($k)) { return $script:pavatar[$k] }
  $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddEllipse(0, 0, ($size - 1), ($size - 1))
  $g.SetClip($path)
  $img = $null
  try { if (Test-Path $AVATAR) { $img = [System.Drawing.Image]::FromFile($AVATAR) } } catch { }
  if ($img) {
    $g.DrawImage($img, 0, 0, $size, $size)
    $img.Dispose()
  } else {
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 130, 200))
    $g.FillPath($br, $path)
    $br.Dispose()
  }
  $g.ResetClip()
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 120, 140, 160), 1)
  $edge = New-Object System.Drawing.Drawing2D.GraphicsPath
  $edge.AddEllipse(0.5, 0.5, ($size - 2), ($size - 2))
  $g.DrawPath($pen, $edge)
  $g.Dispose()
  $edge.Dispose()
  $pen.Dispose()
  $path.Dispose()
  $script:pavatar[$k] = $bmp
  return $bmp
}

function New-PanelRoundPath($w, $h, $r) {
  if ($w -le 2 -or $h -le 2) { $r = 1 }
  $r = [Math]::Min($r, [Math]::Min($w, $h) / 2)
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
  $p.AddArc(($w - $r * 2), 0, $r * 2, $r * 2, 270, 90)
  $p.AddArc(($w - $r * 2), ($h - $r * 2), $r * 2, $r * 2, 0, 90)
  $p.AddArc(0, ($h - $r * 2), $r * 2, $r * 2, 90, 90)
  $p.CloseFigure()
  return $p
}

function Set-PanelRound($ctrl, [int]$r) {
  if ($ctrl.Width -le 2 -or $ctrl.Height -le 2) { return }
  $old = $ctrl.Region
  $ctrl.Region = New-Object System.Drawing.Region((New-PanelRoundPath $ctrl.Width $ctrl.Height $r))
  if ($old) { try { $old.Dispose() } catch { } }
}

# DoubleBuffered 是 protected 属性，PS 里只能走反射打开。
# 展开动画时没它会有几帧没画完的底 —— 看起来就是黑一下。
function Enable-PanelDoubleBuffer($ctrl) {
  try {
    $p = $ctrl.GetType().GetProperty('DoubleBuffered', ([System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic))
    if ($p) { $p.SetValue($ctrl, $true, $null) }
  } catch { }
}

# 展开动画用：把圆角矩形做成 Region（**客户区坐标**）。
# ⚠ 别用"每帧改窗口 Bounds"那版做动画 —— 子控件每帧重排 ⇒ 卡；没画到的区域是黑底 ⇒ 黑框；
#   上次会话留下的绿色气泡被挤成一条 ⇒ 一道绿框闪过。只揭 Region，三个毛病一起没了。
function New-PanelRegion($x, $y, $w, $h, [int]$r) {
  if ($w -lt 8) { $w = 8 }
  if ($h -lt 8) { $h = 8 }
  $r = [Math]::Min($r, [Math]::Min($w, $h) / 2)
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x, $y, ($r * 2), ($r * 2), 180, 90)
  $p.AddArc(($x + $w - $r * 2), $y, ($r * 2), ($r * 2), 270, 90)
  $p.AddArc(($x + $w - $r * 2), ($y + $h - $r * 2), ($r * 2), ($r * 2), 0, 90)
  $p.AddArc($x, ($y + $h - $r * 2), ($r * 2), ($r * 2), 90, 90)
  $p.CloseFigure()
  $reg = New-Object System.Drawing.Region($p)
  $p.Dispose()
  return $reg
}

function Set-PanelRegionRect([int]$x, [int]$y, [int]$w, [int]$h) {
  if (-not $script:pform) { return }
  $r = 18
  if ($w -lt 90) { $r = [Math]::Max(8, [int]($w / 4)) }
  $old = $script:pform.Region
  $script:pform.Region = New-PanelRegion $x $y $w $h $r
  if ($old) { try { $old.Dispose() } catch { } }
}

# 量气泡：先量不换行的宽度，再按这个宽度折行量高 —— 一次把尺寸定死。
# （AutoSize + MaximumSize 会二次换行，把字挤到气泡外面，chat.ps1 里踩过。）
function Get-PanelBubbleSize($font, [string]$text, [int]$maxW) {
  $np = [System.Windows.Forms.TextFormatFlags]::NoPadding
  $wb = [System.Windows.Forms.TextFormatFlags]::WordBreak
  $one = [System.Windows.Forms.TextRenderer]::MeasureText($text, $font, (New-Object System.Drawing.Size(100000, 0)), $np)
  $w = [Math]::Min($maxW, $one.Width)
  if ($w -lt 18) { $w = 18 }
  $h = [System.Windows.Forms.TextRenderer]::MeasureText($text, $font, (New-Object System.Drawing.Size($w, 0)), ($wb -bor $np)).Height
  if ($h -lt 18) { $h = 18 }
  return New-Object System.Drawing.Size($w, $h)
}

# 一行的宽度：横向不留滚动条（不是 QQ 那种能左右拖的界面），所以按"扣掉竖滚动条"算死。
function Get-PanelRowWidth {
  $sw = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
  $w = $script:pwrap.ClientSize.Width - $sw - 4
  if ($w -lt 220) { $w = 220 }
  return [int]$w
}

# 去重：同一条回复有两条路进面板（/reply 轮询 + say.txt 监听）。
# 光比整句不够 —— say.txt 只留 80 字，长回复过去是"整句 vs 它的前 80 字"，比对不上就显示两遍。
# 所以比前 40 字的归一化前缀：相等、或一方是另一方的前缀，40 秒内算同一条。
function Test-PanelDup([string]$who, [string]$text) {
  $n = ($text -replace '\s+', ' ').Trim()
  if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }
  if (-not $n) { return $false }
  $now = Get-Date
  foreach ($r in @($script:precent)) {
    if (-not $r) { continue }
    if ($r.who -ne $who) { continue }
    if (($now - $r.at).TotalSeconds -gt 40) { continue }
    $o = [string]$r.key
    if ($o -eq $n) { return $true }
    if ($o.Length -ge 12 -and $n.Length -ge 12 -and ($o.StartsWith($n) -or $n.StartsWith($o))) { return $true }
  }
  return $false
}
function Register-PanelMsg([string]$who, [string]$text) {
  $n = ($text -replace '\s+', ' ').Trim()
  if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }
  $script:precent.Add([pscustomobject]@{ who = $who; key = $n; at = (Get-Date) }) | Out-Null
  while ($script:precent.Count -gt 12) { $script:precent.RemoveAt(0) }
}

# 时间分隔条：QQ 那样，隔得久了才在两句话中间插一行灰字，紧挨着的话不重复标。
# 格式随远近变化：今天只给时分，昨天说"昨天"，今年给月日，跨年给年。
function Format-PanelTime([datetime]$t) {
  $now = Get-Date
  if ($t.Date -eq $now.Date) { return $t.ToString('HH:mm') }
  if ($t.Date -eq $now.Date.AddDays(-1)) { return '昨天 ' + $t.ToString('HH:mm') }
  if ($t.Year -eq $now.Year) { return $t.ToString('M月d日 HH:mm') }
  return $t.ToString('yyyy年M月d日 HH:mm')
}

function Add-PanelTimeSep([datetime]$t) {
  $rowW = Get-PanelRowWidth
  $row = New-Object System.Windows.Forms.Panel
  $row.Size = New-Object System.Drawing.Size($rowW, 30)
  $row.Margin = New-Object System.Windows.Forms.Padding(0)
  $row.BackColor = $PCOL_BG
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.AutoSize = $false
  $lbl.Size = New-Object System.Drawing.Size($rowW, 30)
  $lbl.Location = New-Object System.Drawing.Point(0, 0)
  $lbl.TextAlign = 'MiddleCenter'
  $lbl.Font = $script:ptimeFont
  $lbl.ForeColor = $PCOL_DIM
  $lbl.BackColor = [System.Drawing.Color]::Transparent
  $lbl.Text = Format-PanelTime $t
  [void]$row.Controls.Add($lbl)
  [void]$script:pwrap.Controls.Add($row)
  $script:plist.Add($row)
}

function Add-PanelMsg([string]$who, [string]$text, $at = $null) {
  if (-not $script:pwrap) { return }
  if (-not $text) { return }
  if (Test-PanelDup $who $text) { return }
  Register-PanelMsg $who $text
  $script:plastText = $text
  $script:plastWho = $who

  # ---- 什么时候插时间 ----
  $when = Get-Date
  if ($null -ne $at) {
    try {
      if ($at -is [datetime]) { $when = $at }
      elseif ($at -is [long] -or $at -is [int] -or $at -is [double]) { $when = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$at).LocalDateTime }
      else { $when = [datetime]$at }
    } catch { $when = Get-Date }
  }
  $needSep = $false
  if ($null -eq $script:plastAt) { $needSep = $true }
  else {
    if ($when.Date -ne $script:plastAt.Date) { $needSep = $true }
    elseif ((($when - $script:plastAt).TotalSeconds) -gt $script:ptimeGap) { $needSep = $true }
  }
  if ($needSep) { Add-PanelTimeSep $when }
  $script:plastAt = $when

  $rowW = Get-PanelRowWidth
  $maxW = $rowW - 52 - 14
  if ($maxW -lt 120) { $maxW = 120 }

  # 尺寸交给 Label 自己算（AutoSize + MaximumSize），别再拿 MeasureText 去估：
  # 实测估算比实际渲染少一行（中文长句、破折号处断行跟估算不一样），气泡底部就被切掉一截。
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Font = $script:pmsgFont
  $lbl.AutoSize = $true
  $lbl.MaximumSize = New-Object System.Drawing.Size($maxW, 0)
  $lbl.BackColor = [System.Drawing.Color]::Transparent
  $lbl.ForeColor = $(if ($who -eq 'me') { $PCOL_TXT_MINE } else { $PCOL_TXT_HER })
  $lbl.Text = $text
  $ps = $lbl.PreferredSize
  if ($ps.Width -lt 18 -or $ps.Height -lt 18) { $ps = New-Object System.Drawing.Size(18, 18) }
  $bw = $ps.Width + 26
  $bh = $ps.Height + 18
  $rowH = [Math]::Max($bh, 34) + 8          # 8 = 行间距，靠行本身撑出来
  $lbl.AutoSize = $false
  $lbl.Size = $ps
  $lbl.Location = New-Object System.Drawing.Point(13, 9)

  $bubble = New-Object System.Windows.Forms.Panel
  $bubble.Size = New-Object System.Drawing.Size($bw, $bh)
  $bubble.BackColor = $(if ($who -eq 'me') { $PCOL_MINE } else { $PCOL_HER })
  $bubble.Region = New-Object System.Drawing.Region((New-PanelRoundPath $bw $bh 14))
  [void]$bubble.Controls.Add($lbl)

  $row = New-Object System.Windows.Forms.Panel
  $row.Size = New-Object System.Drawing.Size($rowW, $rowH)
  $row.Margin = New-Object System.Windows.Forms.Padding(0)
  $row.BackColor = $PCOL_BG

  if ($who -eq 'me') {
    $bubble.Location = New-Object System.Drawing.Point(([int]($rowW - $bw - 10)), 0)
  } else {
    $bubble.Location = New-Object System.Drawing.Point(52, 0)
    $av = New-Object System.Windows.Forms.PictureBox
    $av.Size = New-Object System.Drawing.Size(34, 34)
    $av.SizeMode = 'Normal'
    $av.BackColor = $PCOL_BG
    $av.Image = Get-PanelAvatar 34
    $av.Location = New-Object System.Drawing.Point(10, 1)
    [void]$row.Controls.Add($av)
    $script:plist.Add($av)
  }
  [void]$row.Controls.Add($bubble)
  [void]$script:pwrap.Controls.Add($row)
  $script:plist.Add($row)

  # 让布局落定再滚 —— FlowLayoutPanel 自己维护滚动范围，不用我们算。
  # ScrollControlIntoView 只保证"看得见"，最后一行常常只露一半（实测）⇒ 直接顶到底。
  $script:pwrap.PerformLayout()
  Panel-ScrollToEnd
}

function Remove-PanelTyping {
  if ($script:ptyping) {
    try { $script:pwrap.Controls.Remove($script:ptyping); $script:ptyping.Dispose() } catch { }
    $script:ptyping = $null
  }
}

function Add-PanelTyping {
  Remove-PanelTyping
  $rowW = Get-PanelRowWidth
  $row = New-Object System.Windows.Forms.Panel
  $row.Size = New-Object System.Drawing.Size($rowW, 44)
  $row.Margin = New-Object System.Windows.Forms.Padding(0)
  $row.BackColor = $PCOL_BG

  $av = New-Object System.Windows.Forms.PictureBox
  $av.Size = New-Object System.Drawing.Size(34, 34)
  $av.SizeMode = 'Normal'
  $av.BackColor = $PCOL_BG
  $av.Image = Get-PanelAvatar 34
  $av.Location = New-Object System.Drawing.Point(10, 1)
  [void]$row.Controls.Add($av)

  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = '……'
  $lbl.AutoSize = $true
  $lbl.ForeColor = $PCOL_DIM
  $lbl.Font = $script:pmsgFont
  $lbl.BackColor = [System.Drawing.Color]::Transparent
  $lbl.Location = New-Object System.Drawing.Point(52, 6)
  [void]$row.Controls.Add($lbl)

  [void]$script:pwrap.Controls.Add($row)
  $script:ptyping = $row
  $script:pwrap.PerformLayout()
  Panel-ScrollToEnd
}

# 顶到底：AutoScrollPosition 给个超大值，系统会自己夹到最大值。
# （.VerticalScroll.Value 在自绘滚动条上是"只改数值、内容不动"，chat.ps1 里记过这个坑。）
function Panel-ScrollToEnd {
  # AutoScrollPosition 给个超大值，系统自己夹到真正能滚到的位置。
  # ⚠ 别用 VerticalScroll.Value = Maximum：Maximum 不是"到底"，还要减 LargeChange
  #   （实测 Maximum=3591、能到的只有 3319，差 272px ⇒ 最后一行总露不全）。
  # ⚠ 而且加完控件当场设没用 —— 滚动范围要等这一轮布局消息处理完才算出来（实测还是差一行）。
  #   所以当场设一次，再用 BeginInvoke 排到消息队列后面再设一次。
  try {
    $script:pwrap.AutoScrollPosition = New-Object System.Drawing.Point(0, 100000)
    $script:pwrap.PerformLayout()
    [void]$script:pwrap.BeginInvoke([System.Windows.Forms.MethodInvoker]{
        try {
          $script:pwrap.AutoScrollPosition = New-Object System.Drawing.Point(0, 100000)
          $script:pwrap.PerformLayout()
        } catch { }
      })
  } catch { }
}

function Clear-PanelMsgs {
  foreach ($c in $script:plist) {
    try { $script:pwrap.Controls.Remove($c); $c.Dispose() } catch { }
  }
  $script:plist.Clear()
  Remove-PanelTyping
  $script:plastText = $null
  $script:plastWho = $null
  $script:plastAt = $null
  $script:precent.Clear()
  try { $script:pwrap.AutoScrollPosition = New-Object System.Drawing.Point(0, 0) } catch { }
}

function Load-PanelHistory {
  Clear-PanelMsgs
  try {
    $h = Panel-History 30
    if ($h.Count -eq 0) { Add-PanelMsg 'her' '我在。' }
    foreach ($m in $h) {
      # at 是 jsonl 里记的毫秒时间戳 —— 打开面板看到的是当时几点说的，不是"刚刚"
      if ($m.role -eq 'user') { Add-PanelMsg 'me' $m.text $m.at } else { Add-PanelMsg 'her' $m.text $m.at }
    }
  } catch {
    Trace ('panel history failed: ' + $_.Exception.Message)
    Add-PanelMsg 'her' '（连不上她：bridge 没起来）'
  }
  # 历史里已经有的，就当"已经收到过"：把游标推到现在，免得 outbox 再把它们显示一遍
  try { $script:pout = [int](Panel-Outbox 0).max } catch { }
}

function Set-PanelTip([string]$t) { if ($script:ptip) { $script:ptip.Text = $t } }

function Panel-Send {
  if ($script:pwaiting -or $script:precording) { return }
  $t = $script:pbox.Text.Trim()
  if (-not $t) { return }
  $script:pbox.Text = ''
  Add-PanelMsg 'me' $t
  try {
    $script:ppending = Panel-Post $t
    $script:pwaiting = $true
    $script:pbtn.Enabled = $false
    Add-PanelTyping
    Set-PanelTip '她在想……'
  } catch {
    Trace ('panel say failed: ' + $_.Exception.Message)
    Add-PanelMsg 'her' '（没送出去，看看 bridge 还活着没有）'
    Set-PanelTip 'Enter 发送 · Shift+Enter 换行'
  }
}

# ---- 录音（winmm MCI，不装任何依赖；逻辑照搬 chat.ps1，实测过）----
Add-Type -Namespace W -Name PMci -MemberDefinition @'
[DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern int mciSendString(string command, System.Text.StringBuilder buffer, int len, System.IntPtr hwnd);
'@ -ErrorAction SilentlyContinue

function Panel-Mci([string]$cmd) {
  $rc = [W.PMci]::mciSendString($cmd, $null, 0, [IntPtr]::Zero)
  if ($rc -ne 0) { Trace ("panel mci failed rc=$rc cmd=$cmd") }
  return $rc
}
function Panel-StartRec {
  if ($script:precording) { return }
  [void](Panel-Mci "close $REC_ALIAS")
  if (Test-Path $WAV) { Remove-Item $WAV -Force -ErrorAction SilentlyContinue }
  $rc = Panel-Mci "open new type waveaudio alias $REC_ALIAS"
  if ($rc -ne 0) { Add-PanelMsg 'her' '（麦克风打不开）'; return }
  # 不要 set 采样率/声道：这台机器的麦克风阵列不支持 16k 单声道，设了 record 直接返回 328。
  $rc = Panel-Mci "record $REC_ALIAS"
  if ($rc -ne 0) { Add-PanelMsg 'her' '（开始录音失败）'; return }
  $script:precording = $true
  $script:precStart = Get-Date
  $script:pmic.BackColor = [System.Drawing.Color]::FromArgb(190, 60, 60)
  $script:pmic.Text = '停'
  Set-PanelTip '在听…… 再点一下结束'
}
function Panel-StopRec {
  if (-not $script:precording) { return }
  $script:precording = $false
  [void](Panel-Mci "stop $REC_ALIAS")
  $rc = Panel-Mci "save $REC_ALIAS `"$WAV`""
  [void](Panel-Mci "close $REC_ALIAS")
  $script:pmic.BackColor = [System.Drawing.Color]::FromArgb(52, 52, 62)
  $script:pmic.Text = '说'
  $secs = [math]::Round(((Get-Date) - $script:precStart).TotalSeconds, 1)
  Trace ("panel record stop ${secs}s wav=" + (Test-Path $WAV))
  if (-not (Test-Path $WAV) -or (Get-Item $WAV).Length -lt 2000) { Set-PanelTip '太短了，再说一次'; return }
  Set-PanelTip '听写中……'
  $script:pform.Refresh()
  try {
    $feed = $WAV
    $ff = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($ff) {
      $w16 = 'C:\dsh-temp\desk-rec16.wav'
      & $ff.Source -y -loglevel error -i $WAV -ar 16000 -ac 1 $w16 | Out-Null
      if (Test-Path $w16) { $feed = $w16 }
    }
    # 先看有没有声音：没声音送识别会挂 40 秒。峰值低于 300 就当没说。
    try {
      $raw = [IO.File]::ReadAllBytes($feed)
      $peak = 0
      for ($i = 44; $i -lt ($raw.Length - 1); $i += 2) {
        $v = [BitConverter]::ToInt16($raw, $i)
        if ($v -lt 0) { $v = -$v }
        if ($v -gt $peak) { $peak = $v }
        if ($peak -gt 3000) { break }
      }
      if ($peak -lt 300) { Set-PanelTip ('没听到声音（峰值 ' + $peak + '）'); return }
    } catch { }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $STT -Audio $feed -Out $WAVOUT 2>$null | Out-Null
    $txt = ''
    if (Test-Path "$WAVOUT.txt") { $txt = (Get-Content "$WAVOUT.txt" -Raw -Encoding UTF8).Trim() }
    if ($txt) {
      $script:pbox.Text = $txt
      $script:pbox.SelectionStart = $script:pbox.TextLength
      Set-PanelTip '说完了就按 Enter'
    } else { Set-PanelTip '没听清，再说一次' }
  } catch {
    Trace ('panel stt failed: ' + $_.Exception.Message)
    Set-PanelTip '听写失败（看 stt.log）'
  }
}

# 标题下那行 = 她此刻的心情。数据是她自己那页主页的 data/mood.json（`{mood, at}`），
# 后台心跳和她的 MOOD: 出口都会改它 —— 所以面板不用问她，直接读盘。
# 读不到 / 空着就退回一句普通的，别让标题底下空一块。
function Update-PanelMood {
  if (-not $script:pmood) { return }
  $txt = ''
  try {
    $p = Join-Path $ROOT 'dafeiyu\homepage\data\mood.json'
    if (Test-Path $p) {
      $o = ([System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p))) | ConvertFrom-Json
      $txt = [string]$o.mood
    }
  } catch { }
  $txt = ($txt -replace '\s+', ' ').Trim()
  if (-not $txt) { $txt = '在这儿说' }
  try {
    # 不用 AutoEllipsis：它在这里一个字都画不出来（Label 高 20 < 字体高 22，实测整行消失）。
    # 自己按宽度截，超了就补个省略号。
    $maxW = $script:pmood.Width - 8
    if ($maxW -gt 60) {
      $tr = [System.Windows.Forms.TextRenderer]
      if ($tr::MeasureText($txt, $script:pmood.Font).Width -gt $maxW) {
        while ($txt.Length -gt 3 -and $tr::MeasureText(($txt + '…'), $script:pmood.Font).Width -gt $maxW) {
          $txt = $txt.Substring(0, $txt.Length - 1)
        }
        $txt = $txt + '…'
      }
    }
    $script:pmood.Text = $txt
    if ($txt -ne $script:pmoodLast) {
      $script:pmoodLast = $txt
      Trace ('panel mood: ' + $txt + ' | ' + $script:pmood.Bounds + ' head=' + $script:pHead)
    }
  } catch { Trace ('panel mood failed: ' + $_.Exception.Message) }
}

# ---- 他回来了：让她先说一句「你不在的时候我做了什么」----
# 只在真的离开过一阵（>15 分钟）时触发。这不是定时问候 —— 定时问候他否过；
# 这是"人回来，先知道刚才发生过什么"，话头在她那儿，落点在他这儿。
function Maybe-Welcome {
  try {
    if ($script:pwelcomeJob) { return }
    $last = 0
    $h = @(Panel-History 1)
    if ($h.Count -gt 0 -and $null -ne $h[0].at) { $last = [int64]$h[0].at }
    if ($last -le 0) { return }
    if ($last -le $script:pwelcomeDone) { return }
    $gap = ((Get-Date).ToUniversalTime() - [DateTimeOffset]::FromUnixTimeMilliseconds($last).UtcDateTime).TotalMinutes
    if ($gap -lt 15) { return }
    $script:pwelcomeDone = $last
    Set-PanelTip '她在回想刚才的事……'
    # 用后台 job 去等模型，别冻住 UI：/welcome 一次要十几秒。
    $script:pwelcomeJob = Start-Job -ScriptBlock {
      param($u)
      try { (Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 150).Content } catch { '' }
    } -ArgumentList ("$BRIDGE/welcome?since=$last")
    Trace ('panel: welcome job for gap ' + [int]$gap + ' min')
  } catch { Trace ('welcome start failed: ' + $_.Exception.Message) }
}

# 每 400ms 顺手看一眼那个 job 完了没有（跟回复轮询共用同一个定时器）
function Poll-PanelWelcome {
  if (-not $script:pwelcomeJob) { return }
  try {
    $st = $script:pwelcomeJob.State
    if ($st -ne 'Completed' -and $st -ne 'Failed' -and $st -ne 'Stopped') { return }
    $job = $script:pwelcomeJob
    $script:pwelcomeJob = $null
    $raw = ''
    try { $raw = [string](Receive-Job $job -ErrorAction SilentlyContinue) } catch { }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Set-PanelTip 'Enter 发送 · Shift+Enter 换行'
    if (-not $raw) { return }
    $o = $null
    try { $o = $raw | ConvertFrom-Json } catch { }
    if ($o -and $o.ok -and $o.text) {
      Add-PanelMsg 'her' $o.text
      $script:pfollow = $true
      Update-PanelMood
      Speak-PanelText ([string]$o.text)
      Trace ('panel: welcome ' + $o.mins + ' min -> ' + $o.text)
    }
  } catch { Trace ('welcome poll failed: ' + $_.Exception.Message); $script:pwelcomeJob = $null }
}

function Initialize-Panel {
  if ($script:pform) { return }

  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = 'None'
  $f.StartPosition = 'Manual'
  $f.TopMost = $true
  $f.ShowInTaskbar = $false
  $f.BackColor = $PCOL_BG
  $f.ForeColor = [System.Drawing.Color]::White
  $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
  $f.Size = New-Object System.Drawing.Size($script:pW, $script:pH)
  # 不设 MinimumSize：展开动画要从鱼的 248×190 长起，MinimumSize 会把它夹住。
  $f.KeyPreview = $true
  Enable-PanelDoubleBuffer $f

  # ---- 顶部 ----
  $head = New-Object System.Windows.Forms.Panel
  $head.Dock = 'Top'
  $head.Height = $script:pHead
  $head.BackColor = $PCOL_BAR
  [void]$f.Controls.Add($head)
  Enable-PanelDoubleBuffer $head

  $av = New-Object System.Windows.Forms.PictureBox
  $av.Size = New-Object System.Drawing.Size(34, 34)
  $av.SizeMode = 'Normal'
  $av.BackColor = $PCOL_BAR
  $av.Image = Get-PanelAvatar 34
  $av.Location = New-Object System.Drawing.Point(14, 11)
  [void]$head.Controls.Add($av)

  $nm = New-Object System.Windows.Forms.Label
  $nm.Text = '大肥鱼'
  $nm.AutoSize = $true
  $nm.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11.5, [System.Drawing.FontStyle]::Bold)
  $nm.ForeColor = [System.Drawing.Color]::FromArgb(244, 244, 248)
  $nm.BackColor = [System.Drawing.Color]::Transparent
  $nm.Location = New-Object System.Drawing.Point(56, 7)
  [void]$head.Controls.Add($nm)

  # 标题下面那行原本写死"在这儿说"，字还被压掉一截 —— 改成显示她此刻的心情
  # （读 homepage/data/mood.json，那是她自己写的那栏"现在"）。没有就退回一句话。
  $sub = New-Object System.Windows.Forms.Label
  $sub.Text = '在这儿说'
  $sub.AutoSize = $false
  $sub.Size = New-Object System.Drawing.Size(($script:pW - 100), 26)
  $sub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
  $sub.ForeColor = $PCOL_DIM
  $sub.BackColor = [System.Drawing.Color]::Transparent
  # 位置按名字那一行的**实测**高度算：11.5pt 粗体 AutoSize 出来有 36 高，写死 34 会被它压掉一截
  $sub.Location = New-Object System.Drawing.Point(57, ([Math]::Max(30, ($nm.Top + $nm.Height - 6))))
  $sub.Anchor = 'Left,Top,Right'
  [void]$head.Controls.Add($sub)
  $sub.BringToFront()
  $script:pmood = $sub
  # 顶栏高度跟着这一行走：8.5pt 在这个 DPI 下字体高 22px（实测），留 26 才不把字压掉
  $head.Height = $sub.Top + $sub.Height + 6
  $script:pHead = $head.Height
  Update-PanelMood

  # 收起（变回鱼）—— 不用真按钮，Label 就够了，省得 Tab 焦点跑来跑去
  $x = New-Object System.Windows.Forms.Label
  $x.Text = '✕'
  $x.AutoSize = $false
  $x.Size = New-Object System.Drawing.Size(28, 28)
  $x.TextAlign = 'MiddleCenter'
  $x.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
  $x.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 186)
  $x.BackColor = [System.Drawing.Color]::Transparent
  $x.Location = New-Object System.Drawing.Point(($script:pW - 42), 14)
  $x.Anchor = 'Top,Right'
  $x.Cursor = 'Hand'
  [void]$head.Controls.Add($x)
  $script:pclose = $x
  $x.Add_Click({ Hide-Panel })
  $x.Add_MouseEnter({ $script:pclose.ForeColor = [System.Drawing.Color]::White })
  $x.Add_MouseLeave({ $script:pclose.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 186) })

  # 声音开关（默认关）。念不念由他点，别替他决定；状态存 panel-state.json，下次开面板还记着。
  $vo = New-Object System.Windows.Forms.Label
  $vo.Text = '声'
  $vo.AutoSize = $false
  $vo.Size = New-Object System.Drawing.Size(28, 28)
  $vo.TextAlign = 'MiddleCenter'
  $vo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
  $vo.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 136)
  $vo.BackColor = [System.Drawing.Color]::Transparent
  $vo.Location = New-Object System.Drawing.Point(($script:pW - 78), 14)
  $vo.Anchor = 'Top,Right'
  $vo.Cursor = 'Hand'
  [void]$head.Controls.Add($vo)
  $script:pvoiceLbl = $vo
  Load-PanelState
  if ($script:pvoice) { $vo.ForeColor = [System.Drawing.Color]::FromArgb(149, 236, 105) }
  $vo.Add_Click({ Set-PanelVoice (-not $script:pvoice) })
  $vo.Add_MouseEnter({ $script:pvoiceLbl.ForeColor = [System.Drawing.Color]::White })
  $vo.Add_MouseLeave({
      if ($script:pvoice) { $script:pvoiceLbl.ForeColor = [System.Drawing.Color]::FromArgb(149, 236, 105) }
      else { $script:pvoiceLbl.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 136) }
    })

  # 拖窗口：无边框只能自己拖，抓顶部空白处
  $script:pdrag = $false
  $script:pdx = 0
  $script:pdy = 0
  $head.Add_MouseDown({
      if ($_.Button -eq 'Left') { $script:pdrag = $true; $script:pdx = $_.X; $script:pdy = $_.Y }
    })
  $head.Add_MouseMove({
      if ($script:pdrag) {
        $script:pform.Left = $script:pform.Left + ($_.X - $script:pdx)
        $script:pform.Top = $script:pform.Top + ($_.Y - $script:pdy)
      }
    })
  $head.Add_MouseUp({ $script:pdrag = $false })
  $nm.Add_MouseDown({ $script:pdrag = $true; $script:pdx = $_.X; $script:pdy = $_.Y })
  $nm.Add_MouseMove({
      if ($script:pdrag) {
        $script:pform.Left = $script:pform.Left + ($_.X - $script:pdx)
        $script:pform.Top = $script:pform.Top + ($_.Y - $script:pdy)
      }
    })
  $nm.Add_MouseUp({ $script:pdrag = $false })

  # ---- 消息区：FlowLayoutPanel。让布局自己算滚动范围，别手工维护 AutoScrollMinSize
  #      （手工那版实测两个毛病：新消息沉在视口下面、以及越滚越乱）。----
  # ⚠ 顺序要紧：Dock 是**后加的先进**，所以 Fill 必须先加、Bottom 后加。
  #   反过来（先 Bottom 后 Fill）Fill 会占满整个客户区、底部一大截藏在输入条底下
  #   —— 表现就是"最后一行永远露不全"（实测如此，chat.ps1 那行注释说的是同一件事）。
  $wrap = New-Object System.Windows.Forms.FlowLayoutPanel
  $wrap.Dock = 'Fill'
  $wrap.AutoScroll = $true
  $wrap.FlowDirection = 'TopDown'
  $wrap.WrapContents = $false
  $wrap.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 8)
  $wrap.BackColor = $PCOL_BG
  [void]$f.Controls.Add($wrap)
  $script:pwrap = $wrap
  Enable-PanelDoubleBuffer $wrap
  $script:plist = New-Object System.Collections.ArrayList

  # ---- 输入条（Dock=Bottom，必须排在 Fill 之后加）----
  $foot = New-Object System.Windows.Forms.Panel
  $foot.Dock = 'Bottom'
  $foot.Height = $script:pFoot
  $foot.BackColor = $PCOL_BAR
  [void]$f.Controls.Add($foot)
  Enable-PanelDoubleBuffer $foot

  $boxHost = New-Object System.Windows.Forms.Panel
  $boxHost.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
  $boxHost.Location = New-Object System.Drawing.Point(12, 12)
  $boxHost.Size = New-Object System.Drawing.Size(286, 40)
  $boxHost.Anchor = 'Left,Top,Right'
  $boxHost.Region = New-Object System.Drawing.Region((New-PanelRoundPath 286 40 18))
  [void]$foot.Controls.Add($boxHost)

  $box = New-Object System.Windows.Forms.TextBox
  $box.BorderStyle = 'None'
  $box.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
  $box.ForeColor = [System.Drawing.Color]::White
  $box.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
  $box.Location = New-Object System.Drawing.Point(14, 9)
  $box.Width = 258
  $box.Anchor = 'Left,Top,Right'
  [void]$boxHost.Controls.Add($box)
  $script:pbox = $box

  $mic = New-Object System.Windows.Forms.Button
  # '🎤' 在 Microsoft YaHei UI 里没有字形，渲染成豆腐块（实测）。按钮上换汉字，跟"发"配对。
  $mic.Text = '说'
  $mic.Size = New-Object System.Drawing.Size(40, 40)
  $mic.Location = New-Object System.Drawing.Point(306, 12)
  $mic.Anchor = 'Top,Right'
  $mic.FlatStyle = 'Flat'
  $mic.FlatAppearance.BorderSize = 0
  $mic.BackColor = [System.Drawing.Color]::FromArgb(52, 52, 62)
  $mic.ForeColor = [System.Drawing.Color]::White
  $mic.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
  $mic.Cursor = 'Hand'
  [void]$foot.Controls.Add($mic)
  $mic.Region = New-Object System.Drawing.Region((New-PanelRoundPath 40 40 18))
  $script:pmic = $mic

  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = '发'
  $btn.Size = New-Object System.Drawing.Size(54, 40)
  $btn.Location = New-Object System.Drawing.Point(354, 12)
  $btn.Anchor = 'Top,Right'
  $btn.FlatStyle = 'Flat'
  $btn.FlatAppearance.BorderSize = 0
  $btn.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 200)
  $btn.ForeColor = [System.Drawing.Color]::White
  $btn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
  $btn.Cursor = 'Hand'
  $btn.Region = New-Object System.Drawing.Region((New-PanelRoundPath 54 40 18))
  [void]$foot.Controls.Add($btn)
  $script:pbtn = $btn

  $tip = New-Object System.Windows.Forms.Label
  $tip.Text = 'Enter 发送 · Shift+Enter 换行 · 点「说」开口'
  $tip.ForeColor = $PCOL_DIM
  $tip.AutoSize = $true
  $tip.BackColor = [System.Drawing.Color]::Transparent
  $tip.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
  $tip.Location = New-Object System.Drawing.Point(16, 57)
  [void]$foot.Controls.Add($tip)
  $script:ptip = $tip

  # （消息区移到输入条前面去了，见上）

  # ---- 事件 ----
  $mic.Add_Click({ if ($script:precording) { Panel-StopRec } else { Panel-StartRec } })
  $btn.Add_Click({ Panel-Send })
  $box.Add_KeyDown({
      if ($_.KeyCode -eq 'Enter' -and -not $_.Shift) { $_.SuppressKeyPress = $true; Panel-Send }
    })
  $btn.Add_MouseEnter({ $script:pbtn.BackColor = [System.Drawing.Color]::FromArgb(90, 150, 220) })
  $btn.Add_MouseLeave({ $script:pbtn.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 200) })
  $mic.Add_MouseEnter({ if (-not $script:precording) { $script:pmic.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 84) } })
  $mic.Add_MouseLeave({ if (-not $script:precording) { $script:pmic.BackColor = [System.Drawing.Color]::FromArgb(52, 52, 62) } })
  $f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { Hide-Panel } })

  # ---- 定时器：每 400ms 问一次回复 ----
  $script:ptick = 0
  $t = New-Object System.Windows.Forms.Timer
  $t.Interval = 40
  $t.Add_Tick({
      $script:ptick = $script:ptick + 1
      if (($script:ptick % 10) -eq 0) { Poll-PanelWelcome }
      if (($script:ptick % 50) -eq 0) { Poll-PanelOutbox }
      if (-not $script:pwaiting -or -not $script:ppending) { return }
      if (($script:ptick % 10) -ne 0) { return }
      try {
        $r = Panel-Reply $script:ppending
        if ($r.status -eq 'thinking') { return }
        Remove-PanelTyping
        $script:pwaiting = $false
        $script:ppending = $null
        $script:pbtn.Enabled = $true
        Set-PanelTip 'Enter 发送 · Shift+Enter 换行'
        Add-PanelMsg 'her' $r.text
        Update-PanelMood          # 她刚说完话，心情多半也变了
        Speak-PanelText ([string]$r.text)
      } catch {
        Remove-PanelTyping
        $script:pwaiting = $false
        $script:ppending = $null
        $script:pbtn.Enabled = $true
        Set-PanelTip 'Enter 发送 · Shift+Enter 换行'
        Add-PanelMsg 'her' '（回复断了，重发一次试试）'
        Trace ('panel reply failed: ' + $_.Exception.Message)
      }
    })
  $t.Start()

  # 录音超过 45 秒自动停，别一直占着麦克风
  $g = New-Object System.Windows.Forms.Timer
  $g.Interval = 1000
  $g.Add_Tick({ if ($script:precording -and ((Get-Date) - $script:precStart).TotalSeconds -gt 45) { Panel-StopRec } })
  $g.Start()

  # 心情每 60 秒重读一次：她的心跳/主页可能刚改过 mood.json，面板开着就别停在旧的那句
  $m = New-Object System.Windows.Forms.Timer
  $m.Interval = 60000
  $m.Add_Tick({ if (Test-PanelOpen) { Update-PanelMood } })
  $m.Start()

  $script:pform = $f
}

function Set-PanelShape { Set-PanelRound $script:pform 18 }

# 从鱼的矩形"长"到最终大小 —— 右下角对齐，往上往左展开。
function Show-Panel {
  try { Initialize-Panel } catch {
    Trace ('panel init failed: ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message)
    return $false
  }
  if ($script:popen) { $script:pform.Activate(); return $true }
  if (-not $script:pform) { return $false }

  $fish = $script:pfishForm
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $w = $script:pW
  $h = $script:pH
  if ($null -ne $fish) {
    $left = $fish.Right - $w
    $top = $fish.Bottom - $h
    if ($left -lt ($wa.Left + 8)) { $left = $wa.Left + 8 }
    if ($top -lt ($wa.Top + 8)) { $top = $wa.Top + 8 }
    if (($left + $w) -gt ($wa.Right - 8)) { $left = $wa.Right - 8 - $w }
    if (($top + $h) -gt ($wa.Bottom - 8)) { $top = $wa.Bottom - 8 - $h }
  } else {
    $left = $wa.Right - $w - 40
    $top = $wa.Bottom - $h - 40
  }

  $target = New-Object System.Drawing.Rectangle([int]$left, [int]$top, [int]$w, [int]$h)
  $from = $target
  if ($null -ne $fish) { $from = $fish.Bounds }

  # 窗口**一次就摆到最终尺寸**，然后靠 Region 一点点揭开。
  # 为什么不逐帧改 Bounds（旧版）：
  #   ① 子控件每帧重排 ⇒ 卡；② 新露出来的区域是先画底色再画控件 ⇒ 黑框；
  #   ③ 上次会话留下的绿色气泡被 248 宽挤成一条 ⇒ 绿框闪一下。
  # 现在尺寸恒定，历史和气泡在"揭开"之前就按最终宽度排好了。
  # ⚠ Region 必须在 Show() **之前**设好：否则第一帧会按 420×620 整块画出来闪一下。
  $script:pform.Bounds = $target
  $oldReg = $script:pform.Region
  $script:pform.Region = $null
  if ($oldReg) { try { $oldReg.Dispose() } catch { } }

  $fw = 0; $fh = 0
  if ($null -ne $fish) {
    # 气泡会把鱼窗顶高，所以两个都夹一下，别让起始 Region 大过面板本身
    $fw = [int][Math]::Min($w, [Math]::Max(80, $from.Width))
    $fh = [int][Math]::Min($h, [Math]::Max(80, $from.Height))
    Set-PanelRegionRect ($w - $fw) ($h - $fh) $fw $fh
    # ⚠ 别在动画期间把消息区藏起来再在末帧显示：那一下要冷画十几行气泡（实测 +129ms），
    #   看着就是"展开完了抖一下"。让它一直可见，重画成本摊到每帧（每帧 ~23ms）反而顺。
  }

  $script:pform.Show()
  $script:popen = $true
  Save-PanelState          # 告诉 bridge「面板开着」——它就不再用气泡喊一遍
  if ($null -ne $fish) { $fish.Hide() }
  $script:pform.Activate()
  $script:pform.BringToFront()
  Load-PanelHistory
  Panel-ScrollToEnd
  Update-PanelMood
  Maybe-Welcome          # 他离开过一阵的话，她先开口说一句刚才的事
  $script:pbox.Focus()
  Trace ('panel: shown at ' + $target)

  if ($null -eq $fish) { Set-PanelShape; return $true }

  $script:panimW0 = $fw
  $script:panimH0 = $fh
  $script:panimW1 = [int]$w
  $script:panimH1 = [int]$h
  $script:panimI = 0
  # 帧数少、间隔大：每一帧改 Region 都要整窗重画（实测 15~32ms），帧一多就变成"一跳一跳"。
  # 5 帧 ≈ 110ms，配上同时淡入 —— 眼睛读到的是"从鱼那儿长出来"，读不到那几帧的抖动。
  $script:panimN = 5

  $script:pform.Opacity = 0.25
  $script:panimT0 = [DateTime]::Now
  $script:panimLast = $script:panimT0
  $script:panimDts = New-Object System.Collections.ArrayList
  $a = New-Object System.Windows.Forms.Timer
  $a.Interval = 20
  $a.Add_Tick({
      $now = [DateTime]::Now
      [void]$script:panimDts.Add([int](($now - $script:panimLast).TotalMilliseconds))
      $script:panimLast = $now
      $script:panimI = $script:panimI + 1
      $k = $script:panimI / [double]$script:panimN
      $e = 1 - [Math]::Pow(1 - $k, 3)          # ease-out
      $cw = [int]($script:panimW0 + ($script:panimW1 - $script:panimW0) * $e)
      $ch = [int]($script:panimH0 + ($script:panimH1 - $script:panimH0) * $e)
      $cx = $script:panimW1 - $cw
      $cy = $script:panimH1 - $ch
      try { $script:pform.Opacity = 0.25 + 0.75 * $e } catch { }
      try { Set-PanelRegionRect $cx $cy $cw $ch } catch { }
      if ($script:panimI -ge $script:panimN) {
        try { $script:panim.Stop(); $script:panim.Dispose() } catch { }
        $script:panim = $null
        $script:pform.Opacity = 1.0
        Set-PanelShape
        # 卡不卡就看这一行：interval 设的是 20ms，avg 远超它就是重绘在拖
        $ms = ([DateTime]::Now - $script:panimT0).TotalMilliseconds
        Trace ('panel: anim {0} ticks / {1:0} ms (avg {2:0.0}) dts={3}' -f $script:panimI, $ms, ($ms / [Math]::Max(1, $script:panimI)), ($script:panimDts -join ','))
      }
    })
  $script:panim = $a
  $a.Start()
  return $true
}

function Hide-Panel {
  Trace 'panel: hide called'
  if (-not $script:pform -or -not $script:popen) { return }
  $script:popen = $false
  Save-PanelState          # 面板收了：结果改成走鱼头顶的气泡
  if ($script:panim) { try { $script:panim.Stop(); $script:panim.Dispose() } catch { }; $script:panim = $null }
  if ($script:pwrap) { $script:pwrap.Visible = $true }   # 动画中途收起过的话，别把消息区留在隐藏状态
  try { $script:pform.Opacity = 1.0 } catch { }        # 淡入被打断的话别把面板留在半透明
  try { $script:pform.Hide() } catch { }
  if ($null -ne $script:pfishForm) {
    try { Layout-Pet } catch { }
    $script:pfishForm.Show()
    $script:pfishForm.Activate()
  }
}

# 面板开着的时候鱼不动了（省 CPU），但 say.txt 的气泡仍要收着
function Test-PanelOpen { return [bool]$script:popen }
