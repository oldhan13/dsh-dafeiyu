#requires -Version 5.1
<#
  pet-wf.ps1 - 桌面上的大肥鱼（WinForms 版）。
  透明置顶、可拖动；双击说话，右键出菜单，托盘里也有一个。
  不经过 QQ —— 说话直接开她自己那个会话（dsh web 3080）。

  ── 2026-10-20 上午：从「一张贴图 + 整体上下平移」换成「每帧重画」 ──
  来由：他说静止的图标是贴纸，会动的才是有人在那。我原以为要等分层素材，
  查了 make-avatar.ps1 才发现这条鱼是几何画出来的（鱼身椭圆 / 尾巴多边形 / 眼睛挖洞），
  所以"切部件"根本不需要素材：改顶点就是摆尾，改椭圆就是呼吸。
  画法抽在 fish-draw.ps1，预览用 preview-fish.ps1。
  现在每帧画的是：浮（bob）+ 呼吸（椭圆微鼓）+ 摆尾（多边形绕接缝旋转）+ 眨眼 + 说话时幅度加大冒气泡。
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# 这个进程必须自己是 DPI 感知的：否则 Location 会被系统按 150% 缩放，窗口落在屏幕外（第一版就这么丢的）。
Add-Type -Namespace W -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][W.Dpi]::SetProcessDPIAware()

# 项目根 —— 从脚本自己的位置往上两级（pet → dafeiyu → 根）。
# 2026-10-22：原来这里是写死的一行绝对路径，本机调试留下的；别人 clone 到别处，
# 这一行就指到他自己硬盘上的一个不存在目录 ⇒ fish-draw.ps1 dot-source 失败 ⇒ 桌宠直接起不来。
# $PSScriptRoot 只有在 -Command 里跑时才为空，那时退回当前目录。
$ROOT = $PWD.Path
if ($PSScriptRoot) { $ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$PET = Join-Path $ROOT 'dafeiyu\pet'
$STATE = Join-Path $PET 'state.json'
$LOG = Join-Path $PET 'pet.log'
$AVATAR = Join-Path $ROOT 'dafeiyu\assets\avatar.png'
$CONTROL = Join-Path $ROOT 'dafeiyu\tools\control.ps1'
$WEB = 'http://127.0.0.1:3080'
$SAY = Join-Path $PET 'say.txt'
# 她此刻在干什么 —— 面板那条线（desk/bridge.mjs）每轮会写：thinking / acting / idle / error。
# 鱼的样子跟着它变：想事情时抬眼、动手时摆尾更快、卡住时气色变暖红。这是"壳跟里面对得上"。
$ACTFILE = Join-Path $PET 'activity.json'

if (-not (Test-Path $PET)) { New-Item -ItemType Directory -Path $PET -Force | Out-Null }
function Trace([string]$m) {
  try { "$(Get-Date -Format 'HH:mm:ss.fff')  $m" | Add-Content -Path $LOG -Encoding UTF8 } catch { }
}
Trace '--- start (winforms, animated)'

# 画法：dot-source 进来，Draw-Fish / New-FishFrame 都出自那里
. (Join-Path $PET 'fish-draw.ps1')

# 双击鱼时展开的对话框：同一个进程、同一个作用域（2026-10-20 中午他不要"另开一个浮窗"了）。
# 它自带 Show-Panel / Hide-Panel / Test-PanelOpen，鱼窗藏起来、面板从鱼的位置长出来。
. (Join-Path $PET 'panel.ps1')

$mtx = New-Object System.Threading.Mutex($false, 'Global\dafeiyu-pet-window')
try { $got = $mtx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { Trace 'already running'; exit 0 }

function Read-State { try { Get-Content $STATE -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null } }
# 记 left + bottom 而不是 left + top：窗口高度是动态的（气泡长了会长高），只记 top 会漂。
function Save-State($x, $bottom) { @{ left = [int]$x; bottom = [int]$bottom } | ConvertTo-Json | Set-Content $STATE -Encoding UTF8 }

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$st = Read-State

# 鱼区固定高度。窗口总高 = 鱼 + 气泡，气泡越长窗口越高 —— 但底边钉住、往上长，
# 这样鱼永远落在同一处、一样大。（2026-10-20 他问"为什么语句一长小鱼也跟着变小"：
# 旧版窗口高度写死，气泡吃掉的每个像素都在挤 pb，而 PictureBox 的 Zoom 是等比的，鱼就跟着缩。）
$FISH_H = 190

$x0 = $wa.Right - 278
$bottomY = $wa.Bottom - 12
if ($null -ne $st) {
  if ([int]$st.left -gt $wa.Left -and [int]$st.left -lt ($wa.Right - 238)) { $x0 = [int]$st.left }
  if ($null -ne $st.bottom) {
    $b = [int]$st.bottom
    if ($b -gt ($wa.Top + 240) -and $b -lt ($wa.Bottom + 40)) { $bottomY = $b }
  }
  elseif ($null -ne $st.top) {
    # 旧 state.json 只有 top（那时候窗口高度恒为 290）
    $b = [int]$st.top + 290
    if ($b -gt ($wa.Top + 240) -and $b -lt ($wa.Bottom + 40)) { $bottomY = $b }
  }
}
$y0 = $bottomY - $FISH_H

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.TopMost = $true
$form.ShowInTaskbar = $false
# 抠图色用纯黑，不用 Fuchsia。
# Fuchsia 是「绝对不出现的颜色」，但它跟深水底一混合就是紫边 —— 鱼和圆角四周一圈看得见。
# 纯黑不会：抗锯齿边变成「更深的深水色」，跟桌面自然融在一起。
# 前提是画面里没有纯黑像素：鱼眼是 (12,30,38)、水底 (17,39,51)、气泡 (22,22,26)，都不撞。
$form.BackColor = [System.Drawing.Color]::Black
$form.TransparencyKey = [System.Drawing.Color]::Black
$form.Size = New-Object System.Drawing.Size(248, $FISH_H)
$form.Location = New-Object System.Drawing.Point($x0, $y0)
$script:pfishForm = $form          # 面板要拿它的矩形当"展开起点"，关掉时再把它叫回来

# ---- 画布：一张 256×256 的透明位图，每帧重画同一张（不新建，免得 GC 抖）----
$CANVAS = 256
$script:fishBmp = New-Object System.Drawing.Bitmap($CANVAS, $CANVAS, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$script:fishG = [System.Drawing.Graphics]::FromImage($script:fishBmp)
$script:fishScale = $CANVAS / 512.0

# ---- 水底 ----
# 为什么不把背景留成纯透明：TransparencyKey 只能抠**纯色**，抗锯齿产生的半透明像素
# 会跟 Fuchsia 混合，整条鱼轮廓立刻出现一圈紫边（第一版就是）。加一块不透明的深色圆角底，
# 鱼的抗锯齿边就只跟这块浅深色混合，紫边只剩下四角圆角那 1px。
# 2026-10-22：底板也从平涂改成上浅下深 —— 上沿像透进来的光，下沿沉进暗处。
# 这块牌子本身就是"水"：水波（Draw-WaterLines）画在它上面，鱼再盖住中间那段。
$script:bgRect = New-Object System.Drawing.RectangleF(0, 0, [float]$CANVAS, [float]$CANVAS)
$script:bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($script:bgRect, [System.Drawing.Color]::FromArgb(255, 24, 53, 69), [System.Drawing.Color]::FromArgb(255, 11, 26, 36), 90.0)
$script:bgPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$rad = 22
$script:bgPath.AddArc(0, 0, $rad * 2, $rad * 2, 180, 90)
$script:bgPath.AddArc($CANVAS - $rad * 2, 0, $rad * 2, $rad * 2, 270, 90)
$script:bgPath.AddArc($CANVAS - $rad * 2, $CANVAS - $rad * 2, $rad * 2, $rad * 2, 0, 90)
$script:bgPath.AddArc(0, $CANVAS - $rad * 2, $rad * 2, $rad * 2, 90, 90)
$script:bgPath.CloseFigure()

$pb = New-Object System.Windows.Forms.PictureBox
$pb.Image = $script:fishBmp
$pb.SizeMode = 'Zoom'
$pb.Location = New-Object System.Drawing.Point(0, 0)
$pb.BackColor = [System.Drawing.Color]::Transparent
$pb.Enabled = $false
# 每 60ms 换一次画面，不双缓冲会闪。PictureBox 没公开这个属性，用反射打开。
try {
  $dp = $pb.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
  if ($dp) { $dp.SetValue($pb, $true) }
} catch { Trace ('doublebuffer failed: ' + $_.Exception.Message) }
[void]$form.Controls.Add($pb)

# 气泡：白底黑字（2026-10-20 上午他要的）。
# 原来那块是深底白字、8.5 号、176 宽 —— 在桌面上像一行小提示，不像"她在说话"。
# 现在白色好认、黑字在浅底上最清楚，字号提到 10.5，四周留内边距，圆角靠 Region 裁。
$lbl = New-Object System.Windows.Forms.Label
# 气泡要跟着字数长高：AutoSize + MaximumSize(宽度) 才会自动换行并撑开。
$lbl.AutoSize = $true
$lbl.MaximumSize = New-Object System.Drawing.Size(232, 0)
$lbl.MinimumSize = New-Object System.Drawing.Size(232, 0)
$lbl.Location = New-Object System.Drawing.Point(4, 4)
$lbl.TextAlign = 'MiddleCenter'
$lbl.BackColor = [System.Drawing.Color]::White
$lbl.ForeColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
$lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
$lbl.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$lbl.Text = ''
# 气泡可点（2026-10-20 下午）：原来它是 Enabled=$false 的死块，读到的是一句想接的话，
# 25 秒后自己没了，要接还得从头打字。现在点它 = 把那句接进面板。
# 代价：从气泡上按下不能拖窗口 —— 拖鱼身或底边，够用。
$lbl.Enabled = $true
$lbl.Cursor = 'Hand'
[void]$form.Controls.Add($lbl)
$lbl.BringToFront()
$lbl.Add_MouseUp({ Receive-Bubble })
$lbl.Add_MouseEnter({
    $script:hover = $true
    $script:lastTouch = Get-Date
    try { $lbl.BackColor = [System.Drawing.Color]::FromArgb(238, 244, 252) } catch { }
  })
$lbl.Add_MouseLeave({
    $script:hover = $false
    try { $lbl.BackColor = [System.Drawing.Color]::White } catch { }
  })

# 气泡长高多少，鱼就往下让多少 —— 不然字会把鱼脸糊住。
# 把矩形标签裁成圆角。WinForms 的 Label 不能直接设圆角，但 Region 可以裁它的绘制区域
# —— 底色跟着被裁，看起来就是圆角气泡。Region 是硬边，白底在深色桌面上看不出来。
function Set-BubbleRound {
  if ($lbl.Width -le 2 -or $lbl.Height -le 2) { return }
  $r = [Math]::Min(18, [Math]::Min($lbl.Width, $lbl.Height) / 2)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
  $path.AddArc($lbl.Width - $r * 2, 0, $r * 2, $r * 2, 270, 90)
  $path.AddArc($lbl.Width - $r * 2, $lbl.Height - $r * 2, $r * 2, $r * 2, 0, 90)
  $path.AddArc(0, $lbl.Height - $r * 2, $r * 2, $r * 2, 90, 90)
  $path.CloseFigure()
  $lbl.Region = New-Object System.Drawing.Region($path)
  $path.Dispose()
}

function Layout-Pet {
  $bubbleH = 0
  if ($lbl.Text -ne '') {
    $lbl.Width = $lbl.MinimumSize.Width
    $bubbleH = $lbl.PreferredHeight
    $lbl.Height = $bubbleH
  }
  $lbl.Visible = ($lbl.Text -ne '')

  # 总高 = 鱼 + 气泡（+8 间隙）。没有气泡时窗口就只有鱼那么高。
  $needH = $FISH_H
  if ($bubbleH -gt 0) { $needH = $FISH_H + $bubbleH + 8 }

  # 改高度之前先按「底边不动」把 Top 重算，否则窗口会往下长、鱼跑出屏幕。
  if ($form.Height -ne $needH) { $form.Height = $needH }
  $form.Top = $script:bottomY - $needH

  if ($bubbleH -gt 0) { Set-BubbleRound }
  $pb.Location = New-Object System.Drawing.Point(0, [int]($needH - $FISH_H))
  $pb.Size = New-Object System.Drawing.Size($form.ClientSize.Width, $FISH_H)
}

function Say-Bubble([string]$text, [int]$secs = 8) {
  $lbl.Text = $text
  Layout-Pet
  $script:until = (Get-Date).AddSeconds($secs)
  $script:lastTouch = Get-Date
  Trace ('bubble: ' + $text)
}

# ---- 她在干什么（activity.json，bridge.mjs 每轮写）----
$script:act = 'idle'
$script:actNote = ''
$script:lastTouch = Get-Date
$script:eyeX = 0.0
$script:eyeY = 0.0
$script:tint = 0.0
$script:hover = $false
$script:hoverX = 0.0
$script:hoverY = 0.0

function Update-Activity {
  try {
    if (-not (Test-Path $ACTFILE)) { return }
    $j = Get-Content $ACTFILE -Raw -Encoding UTF8 | ConvertFrom-Json
    $st = [string]$j.state
    # bridge 挂了 / 一轮结束了没来得及写 idle：超过 20 秒就当它已经空下来，
    # 否则鱼会永远停在"在想"，那比不动更假。
    $ms = [int64]$j.at
    $age = ((Get-Date).ToUniversalTime() - [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime).TotalSeconds
    if ($age -gt 20 -and $st -ne 'idle') { $st = 'idle' }
    if ($st -ne $script:act) {
      $note = ([string]$j.note)
      if ($note) { Trace ('activity: ' + $st + ' (' + $note + ')') } else { Trace ('activity: ' + $st) }
      $script:act = $st
      $script:lastTouch = Get-Date      # 她在动，就别算"没人理"
    }
  } catch { Trace ('activity read failed: ' + $_.Exception.Message) }
}

# ---- 热键：Ctrl+Alt+F 叫出 / 收起面板 ----
# 双击鱼要瞄；热键是给"手已经在键盘上"的时候用的。
Add-Type -Namespace W -Name FHot -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool RegisterHotKey(System.IntPtr hWnd, int id, int fsModifiers, int vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(System.IntPtr hWnd, int id);
'@
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Windows.Forms;
public class DfyHotKeyWindow : NativeWindow {
  public event EventHandler Pressed;
  public void Attach(IntPtr h) { this.AssignHandle(h); }
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x0312) { var p = this.Pressed; if (p != null) { p(this, EventArgs.Empty); } return; }
    base.WndProc(ref m);
  }
}
'@

function Switch-Panel {
  $script:lastTouch = Get-Date
  if (Test-PanelOpen) { Hide-Panel; return }
  if (-not $form.Visible) { $form.Show() }
  Open-Chat
}

# 点气泡 = 「这句我想接」。把她刚说的那句接进面板，别让它 25 秒后自己消失。
function Receive-Bubble {
  $t = $lbl.Text
  if (-not $t) { return }
  $lbl.Text = ''
  Layout-Pet
  $script:lastTouch = Get-Date
  Trace 'bubble: clicked -> panel'
  Open-Chat
  if (Test-PanelOpen) { Add-PanelMsg 'her' $t; $script:pfollow = $true }
}

# 找「大肥鱼」那个聊天窗，有就把它弄回前台。
# ⚠ 2026-10-20 中午起这段不再用于双击 —— 他要的是「图标自己展开成对话框」，不是另开一个窗。
# 只留作兜底：万一旧 chat.ps1 还开着（升级前起的那个进程），别让它变成看不见的孤儿窗。
Add-Type -Namespace W -Name ChatWin -MemberDefinition @"
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern System.IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
"@

function Close-OldChatWindow {
  # 升级前那个独立聊天窗（chat.ps1）如果还活着，就让它自己关掉 —— 它会释放互斥量、正常退出。
  $h = [W.ChatWin]::FindWindowW($null, '大肥鱼')
  if ($h -eq [IntPtr]::Zero) { return }
  try {
    [void][W.ChatWin]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    Trace 'closed legacy chat window'
  } catch { Trace ('close legacy chat failed: ' + $_.Exception.Message) }
}

function Open-Chat {
  # 双击鱼 = 鱼自己长成聊天框（不再 Start-Process 另一个窗口）。
  # 面板跟鱼同一个进程：多开、单实例、窗口丢到屏幕外这些问题都不存在了。
  try {
    Close-OldChatWindow
    $bridgeUp = $false
    try {
      $r = Invoke-WebRequest -Uri 'http://127.0.0.1:3079/health' -UseBasicParsing -TimeoutSec 2
      $bridgeUp = ($r.StatusCode -eq 200)
    } catch { }
    Trace ('open-chat: bridge=' + $bridgeUp)
    if ($bridgeUp) {
      if (Show-Panel) { return }
      Say-Bubble '面板没展开，再双击我一次。'
      return
    }
    $edge = Get-Command msedge.exe -ErrorAction SilentlyContinue
    if ($edge) { Start-Process msedge.exe -ArgumentList "--app=$WEB", '--window-size=560,780' }
    else { Start-Process $WEB }
    Say-Bubble '聊天框没起来，先开网页。'
  } catch {
    Trace ('open-chat failed: ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message)
    Say-Bubble '面板打不开，看 pet.log。'
  }
}
function Take-Shot {
  $dir = Join-Path $ROOT 'dafeiyu\assets\shots'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $out = Join-Path $dir ('pet-' + (Get-Date -Format 'yyMMdd-HHmmss') + '.png')
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CONTROL -Shot -Out $out | Out-Null
  if (Test-Path $out) { Set-Clipboard -Value $out; Say-Bubble ('拍好了：' + (Split-Path $out -Leaf)) }
  else { Say-Bubble '没拍成。' }
}
function Open-Home { Start-Process 'http://127.0.0.1:3077/' }

# 打开配置界面（2026-10-21 他要的：「右键菜单加一项打开配置」）。
# 为什么另起一个进程：部署界面是个 WinForms 模态窗，在鱼这个进程里 ShowDialog 会把鱼卡住
# （模态循环在等窗口关闭，鱼的动画和气泡全都停）。所以只负责把它叫出来，不接它的返回值。
function Open-Setup {
  $ui = Join-Path $ROOT 'dafeiyu\tools\setup-ui.ps1'
  if (-not (Test-Path $ui)) { Say-Bubble '找不到配置界面。'; return }
  try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ui
    Trace 'open-setup'
    Say-Bubble '配置界面开了。'
  } catch {
    Trace ('open-setup failed: ' + $_.Exception.Message)
    Say-Bubble '配置界面打不开，看 pet.log。'
  }
}

# ---- 点一下会做事 ----
# 两个动作，随机挑：吐泡泡（55%）、游一下（37%）、偶尔两个一起来（8%）。
# 泡泡是从嘴边冒出来的空心小圈，向上飘、边飘边大边淡；冲刺是整条鱼横移出去再回来 + 尾巴甩得更凶。
$script:pops = New-Object System.Collections.ArrayList
$script:dash = 0.0
$script:clickTimer = $null
$script:suppressClick = $false
$script:downPt = $null

function Start-Pops([int]$Max = 0) {
  # 起点在嘴边：鱼身椭圆右缘 x=444、中心 y=256，所以嘴巴大约在 (432, 252)
  if ($Max -gt 0) { $n = Get-Random -Minimum 1 -Maximum ($Max + 1) }
  else { $n = Get-Random -Minimum 3 -Maximum 7 }
  for ($i = 0; $i -lt $n; $i++) {
    [void]$script:pops.Add([pscustomobject]@{
        x     = 418 + (Get-Random -Minimum -14 -Maximum 16)
        y     = 246 + (Get-Random -Minimum -14 -Maximum 14)
        r     = 18 + (Get-Random -Minimum 0 -Maximum 13)
        age   = 0
        life  = 55 + (Get-Random -Minimum 0 -Maximum 35)
        drift = (Get-Random -Minimum -22 -Maximum 23) / 100.0
      })
  }
}

function Start-Dash { $script:dash = 0.02 }

function Invoke-Poke {
  $r = Get-Random -Minimum 0 -Maximum 100
  if ($r -lt 55) { Start-Pops; Trace 'poke: bubbles' }
  elseif ($r -lt 92) { Start-Dash; Trace 'poke: swim' }
  else { Start-Pops; Start-Dash; Trace 'poke: bubbles+swim' }
}

# ---- 拖动 / 点击 ----
$script:dragging = $false
$script:dragX = 0
$script:dragY = 0
$form.Add_MouseDown({
    if ($_.Button -eq 'Left') {
      $script:dragging = $true
      $script:dragX = $_.X
      $script:dragY = $_.Y
      $script:downPt = [System.Windows.Forms.Cursor]::Position
      $script:suppressClick = $false
      $script:lastTouch = Get-Date
    }
  })
$form.Add_MouseMove({
    if ($script:dragging) {
      $form.Left = $form.Left + ($_.X - $script:dragX)
      $form.Top = $form.Top + ($_.Y - $script:dragY)
      # 拖的时候底边在变，随时更新，否则气泡一变高窗口就跳回原处
      $script:bottomY = $form.Top + $form.Height
    }
    # 不拖的时候：鼠标挪过 = 他在，记一笔（别让鱼以为没人）；同时给眼神一个落点
    $script:hover = $true
    $script:lastTouch = Get-Date
    $script:hoverX = [double]$_.X - ($form.ClientSize.Width / 2.0)
    $script:hoverY = [double]$_.Y - ($form.ClientSize.Height / 2.0)
  })
$form.Add_MouseLeave({ $script:hover = $false })
# ⚠ 这里**不用 $form.Add_Click**。
# 试过：这个窗口带 TransparencyKey，加上 PictureBox 盖满整层，Click 事件根本没到 form
# （点了没反应，pet.log 里连 poke 都没记）。而 MouseUp 是可靠的 —— 拖动本来就走它。
# 所以「单击做事 / 双击开聊天」全在 MouseUp 里自己判：
#   · 按下到抬起移动 > 4px  ⇒ 拖动，什么都不做（否则每次拖完鱼都吐一串泡泡）
#   · 没移动 且 距上次点击 < 420ms ⇒ 双击，开聊天，并取消上一次还挂着的单击动作
#   · 否则 ⇒ 单击：挂一个 220ms 的定时器再动手，给"第二下"留出反悔的机会
$script:lastUp = $null
$form.Add_MouseUp({
    $script:dragging = $false
    $cur = [System.Windows.Forms.Cursor]::Position
    $moved = $false
    if ($null -ne $script:downPt) {
      if ([Math]::Abs($cur.X - $script:downPt.X) -gt 4 -or [Math]::Abs($cur.Y - $script:downPt.Y) -gt 4) { $moved = $true }
    }
    $script:bottomY = $form.Top + $form.Height
    Save-State $form.Left $script:bottomY

    if ($moved) { $script:lastUp = $null; return }   # 拖动，不算点击

    $now = Get-Date
    $isDouble = ($null -ne $script:lastUp) -and (($now - $script:lastUp).TotalMilliseconds -lt 420)

    if ($isDouble) {
      $script:lastUp = $null
      if ($null -ne $script:clickTimer) {
        $script:clickTimer.Stop()
        $script:clickTimer.Dispose()
        $script:clickTimer = $null
      }
      Open-Chat
      return
    }

    $script:lastUp = $now
    if ($null -ne $script:clickTimer) {
      $script:clickTimer.Stop()
      $script:clickTimer.Dispose()
    }
    $script:clickTimer = New-Object System.Windows.Forms.Timer
    $script:clickTimer.Interval = 220
    $script:clickTimer.Add_Tick({
        $script:clickTimer.Stop()
        $script:clickTimer.Dispose()
        $script:clickTimer = $null
        Invoke-Poke
      })
    $script:clickTimer.Start()
  })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$mChat = $menu.Items.Add('说话')
$mShot = $menu.Items.Add('看一眼屏幕')
$mHome = $menu.Items.Add('她的主页')
$mCfg = $menu.Items.Add('打开配置')
[void]$menu.Items.Add('-')
$mHide = $menu.Items.Add('躲到托盘')
$mExit = $menu.Items.Add('退出')
$mChat.Add_Click({ Open-Chat })
$mShot.Add_Click({ Take-Shot })
$mHome.Add_Click({ Open-Home })
$mCfg.Add_Click({ Open-Setup })
$mHide.Add_Click({ $form.Hide() })
$mExit.Add_Click({ $script:quit = $true; $form.Close() })
$form.ContextMenuStrip = $menu

# ---- 托盘 ----
$ni = New-Object System.Windows.Forms.NotifyIcon
try {
  $small = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($small)
  $g.SmoothingMode = 'HighQuality'
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.DrawImage([System.Drawing.Image]::FromFile($AVATAR), 0, 0, 32, 32)
  $g.Dispose()
  $ni.Icon = [System.Drawing.Icon]::FromHandle($small.GetHicon())
} catch { Trace ('icon failed: ' + $_.Exception.Message) }
$ni.Text = '大肥鱼'
$ni.Visible = $true
$tm = New-Object System.Windows.Forms.ContextMenuStrip
$tShow = $tm.Items.Add('叫出来')
$tChat = $tm.Items.Add('说话')
$tShot = $tm.Items.Add('看一眼屏幕')
$tHome = $tm.Items.Add('她的主页')
$tCfg = $tm.Items.Add('打开配置')
[void]$tm.Items.Add('-')
$tExit = $tm.Items.Add('退出')
$ni.ContextMenuStrip = $tm
$tShow.Add_Click({ $form.Show(); $form.Activate() })
$tChat.Add_Click({ Open-Chat })
$tShot.Add_Click({ Take-Shot })
$tHome.Add_Click({ Open-Home })
$tCfg.Add_Click({ Open-Setup })
$tExit.Add_Click({ $script:quit = $true; $form.Close() })
$ni.Add_DoubleClick({ $form.Show(); $form.Activate(); Open-Chat })

# ---- 呼吸 ----
$script:bottomY = $form.Top + $form.Height
$script:phase = 0.0
$script:talk = 0.0
$script:blink = 0.0
$script:blinkLeft = 0
$script:until = (Get-Date).AddSeconds(-1)
$script:quit = $false
# 启动时先把 say.txt 现在的戳吃掉：否则每次重启都会把昨天那句话重新念一遍
$script:sayStamp = ''
try { if (Test-Path $SAY) { $script:sayStamp = (Get-Item $SAY).LastWriteTimeUtc.Ticks.ToString() } } catch { }
$script:tickCount = 0
$script:nextBlink = 90          # 帧计数到这儿眨一次（60ms/帧 ≈ 5.4 秒）
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60
$timer.Add_Tick({
    $script:tickCount++
    if (($script:tickCount % 3) -eq 0) { Update-Activity }

    # ---- 她现在的状态 → 游速 / 眼神 / 气色 ----
    # 这不是装饰：她说"在想"时抬眼、动手时摆尾快、卡住时气色发暖，都是给眼睛读的信息。
    $step = 0.06
    $eyeTX = 0.0; $eyeTY = 0.0
    switch ($script:act) {
      'thinking' { $step = 0.105; $eyeTX = 5.0; $eyeTY = -4.0 }
      'acting' { $step = 0.150; $eyeTX = 7.0; $eyeTY = 1.0 }
      'error' { $step = 0.020; $eyeTX = -6.0; $eyeTY = 4.0 }
    }

    # ---- 睡着了：十分钟没人理它，就闭眼、慢下来 ----
    # 不是"省电"，是有个落差：他在，它动；他走了，它就静下来。醒了要有反应。
    $idleSec = ((Get-Date) - $script:lastTouch).TotalSeconds
    $sleeping = ($idleSec -gt 600 -and $script:act -eq 'idle')
    if ($sleeping) { $step = 0.016; $eyeTX = -2.0; $eyeTY = 5.0 }

    # 鼠标在窗口上时，眼珠跟着它转（比"定时环顾"自然，也不用计时器）
    if ($script:hover) {
      $eyeTX = [Math]::Max(-9.0, [Math]::Min(9.0, $script:hoverX / 12.0))
      $eyeTY = [Math]::Max(-6.0, [Math]::Min(6.0, $script:hoverY / 14.0))
    }
    $script:eyeX = $script:eyeX + ($eyeTX - $script:eyeX) * 0.18
    $script:eyeY = $script:eyeY + ($eyeTY - $script:eyeY) * 0.18

    # 卡住时的暖色：上来快、退下去慢（一眼能看见，但不至于一直红着）
    $tintT = if ($script:act -eq 'error') { 0.32 } else { 0.0 }
    $script:tint = $script:tint + ($tintT - $script:tint) * 0.06

    $script:phase += $step
    if ($script:phase -gt 6283.0) { $script:phase -= 6283.0 }   # 2π×1000，防长跑精度漂

    # 眨眼：一次 6 帧（约 0.36 秒），间隔 4~8 秒随机 —— 固定节奏像机器，不像活的
    if ($sleeping) {
      $script:blink = 0.86
    }
    else {
      if ($script:tickCount -ge $script:nextBlink) {
        $script:blinkLeft = 6
        $script:nextBlink = $script:tickCount + 70 + (Get-Random -Minimum 0 -Maximum 70)
      }
      if ($script:blinkLeft -gt 0) {
        $script:blinkLeft--
        $script:blink = [Math]::Sin([Math]::PI * (1.0 - $script:blinkLeft / 6.0))
      }
      else { $script:blink = 0.0 }
    }

    # 说话强度：气泡还在时起伏，气泡没了就慢慢收回去（不是硬切）
    if ((Get-Date) -lt $script:until) {
      $script:talk = 0.55 + 0.45 * [Math]::Sin($script:phase * 2.2)
    }
    elseif ($script:talk -gt 0.0) {
      $script:talk = [Math]::Max(0.0, $script:talk - 0.12)
    }

    if ((Get-Date) -gt $script:until -and $lbl.Text -ne '') { $lbl.Text = ''; Layout-Pet }

    # 状态带来的小气泡：想事情时偶尔一颗（像在念叨），动手时密一点。
    # 只有状态在跑的时候才有 —— 平时安静，不拿泡泡当背景音。
    if (-not $sleeping -and -not $script:dragging) {
      if ($script:act -eq 'acting' -and ($script:tickCount % 22) -eq 0) { Start-Pops 2 }
      elseif ($script:act -eq 'thinking' -and ($script:tickCount % 46) -eq 0) { Start-Pops 1 }
      elseif ($script:act -eq 'idle' -and $script:pops.Count -eq 0 -and (Get-Random -Maximum 900) -eq 0) { Start-Pops 2 }
    }

    # 泡泡往上飘、边飘边淡；飘完（age 到 life）就从表里删掉
    if ($script:pops.Count -gt 0) {
      for ($pi = $script:pops.Count - 1; $pi -ge 0; $pi--) {
        $pp = $script:pops[$pi]
        $pp.age = $pp.age + 1
        $pp.y = $pp.y - 2.30
        $pp.x = $pp.x + $pp.drift
        if ($pp.age -ge $pp.life) { [void]$script:pops.RemoveAt($pi) }
      }
    }
    # 冲刺走一个 0→1 的进度，走完归零；0 就是常态
    if ($script:dash -gt 0.0) {
      $script:dash = $script:dash + 0.045
      if ($script:dash -ge 1.0) { $script:dash = 0.0 }
    }

    if (-not $script:dragging -and -not (Test-PanelOpen)) {
      try {
        $script:fishG.Clear([System.Drawing.Color]::Transparent)
        $script:fishG.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $script:fishG.FillPath($script:bgBrush, $script:bgPath)
        # 水波：画在底板上、鱼的身后（鱼随后把中间盖掉，只剩两侧露出来）
        Draw-WaterLines -G $script:fishG -Canvas $CANVAS -Phase $script:phase
        $popsArr = if ($script:pops.Count -gt 0) { $script:pops.ToArray() } else { @() }
        Draw-Fish -G $script:fishG -Phase $script:phase -Talk $script:talk -Blink $script:blink `
          -BodyScale $script:fishScale -Dash $script:dash -Pops $popsArr `
          -EyeDx $script:eyeX -EyeDy $script:eyeY -Tint $script:tint
        $pb.Invalidate()
      } catch { Trace ('draw failed: ' + $_.Exception.Message) }
    }

    # 每秒看一眼 say.txt：她想在桌面上说话，就往这个文件里写一句。
    # 面板开着的时候改走面板 —— 她挑的时机说的话，别因为鱼被收起来就变成没人看见的一句。
    if (($script:tickCount % 16) -eq 0) {
      try {
        if (Test-Path $SAY) {
          $stamp = (Get-Item $SAY).LastWriteTimeUtc.Ticks.ToString()
          if ($stamp -ne $script:sayStamp) {
            $script:sayStamp = $stamp
            $line = (Get-Content $SAY -Raw -Encoding UTF8)
            if ($line) { $line = $line.Trim() }
            if ($line) {
              if (Test-PanelOpen) { Add-PanelMsg 'her' $line; $script:pfollow = $true }
              else { Say-Bubble $line 25 }
            }
          }
        }
      } catch { }
    }
  })
$timer.Start()

$form.Add_Shown({
    Trace ('shown at {0},{1} size {2}x{3}' -f $form.Left, $form.Top, $form.Width, $form.Height)
    # 热键要等窗口句柄存在才注册得了，所以放 Add_Shown，不放构造处
    try {
      $script:hot = New-Object DfyHotKeyWindow
      $script:hot.Attach($form.Handle)
      $script:hot.add_Pressed({ Trace 'hotkey pressed'; Switch-Panel })
      # 候选表：Ctrl+Alt+F 实测被输入法占着（registered=False），所以挨个试，第一个成功的就是它。
      $cands = @(
        @{ mod = 3; vk = 0x46; name = 'Ctrl+Alt+F' },
        @{ mod = 3; vk = 0x44; name = 'Ctrl+Alt+D' },
        @{ mod = 3; vk = 0x4A; name = 'Ctrl+Alt+J' },
        @{ mod = 3; vk = 0x42; name = 'Ctrl+Alt+B' },
        @{ mod = 6; vk = 0x46; name = 'Ctrl+Shift+F' }
      )
      $script:hotName = ''
      foreach ($c in $cands) {
        if ([W.FHot]::RegisterHotKey($form.Handle, 0xB001, [int]$c.mod, [int]$c.vk)) {
          $script:hotName = [string]$c.name
          break
        }
      }
      if ($script:hotName) { Trace ('hotkey ' + $script:hotName + ' registered') }
      else { Trace 'hotkey: 一个都没注册上（都被别的程序占了）' }
    } catch { Trace ('hotkey failed: ' + $_.Exception.Message) }
    $hint = if ($script:hotName) { '我在。双击我，或者 ' + $script:hotName + '。' } else { '我在。双击我。' }
    Say-Bubble $hint
  })
$form.Add_FormClosing({
    Trace ('form closing: ' + $_.CloseReason)
    try { [void][W.FHot]::UnregisterHotKey($form.Handle, 0xB001) } catch { }
  })

# 兜底：UI 线程里任何未捕获异常都只记一行日志，不让整个窗口进程跟着死。
# 2026-10-20 上午桌宠在 9:32 之后无声消失过一次（pet.log 里既没有 closed 也没有报错），
# 定时器里 Layout-Pet / Invalidate 抛异常是嫌疑之一 —— WinForms 默认会让进程直接下去。
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Trace ('ui exception: ' + $e.Exception.GetType().Name + ': ' + $e.Exception.Message)
  })

# ⚠ 这里不能用 ShowDialog。
# 面板展开时要把鱼藏起来，而「把跑着 ShowDialog 的那个窗体 Hide 掉」会让模态循环当场返回
# —— 鱼一藏，整个桌宠就退出了（实测 12:07:57：panel shown 之后 14ms 就是 form closing）。
# 换成 Application.Run：Hide/Show 随便来，进程只认「窗体被关掉」这一件事。
[System.Windows.Forms.Application]::Run($form)
$timer.Stop()
if ($script:pform) { try { $script:pform.Close(); $script:pform.Dispose() } catch { } }
$script:fishG.Dispose()
$script:fishBmp.Dispose()
$ni.Visible = $false
$ni.Dispose()
try { $mtx.ReleaseMutex() } catch { }
Trace 'closed'
