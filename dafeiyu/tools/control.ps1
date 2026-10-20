#requires -Version 5.1
<#
  control.ps1 - 大肥鱼操作这台电脑的工具箱。
  一次性动词：截屏 / 看窗口 / 切窗口 / 点鼠标 / 打字 / 按键 / 开程序 / 看进程 / 跑命令。
  用法（每个动词单跑一条）：
    -Windows                              列出有窗口的程序（标题/进程/pid/位置/是否前台）
    -Shot [-Out 路径]                     截全屏（默认 assets/shots/<时间>.png）
    -Activate "标题片段"                  把窗口切到前台
    -Click "x,y" [-Button right] [-Double] 点某个坐标
    -Type "中文也行"                      把文字粘到当前焦点（走剪贴板，中文安全）
    -Keys "ctrl+s"                        按组合键
    -Open "路径或 URL"                    启动程序/打开文件/打开网址
    -Procs [-Name 片段]                   进程列表（默认按内存前 30）
    -Screen                               分辨率与显示器
    -Run "命令"                           跑一条命令并返回输出
    -Tree "窗口标题片段" [-Depth 5] [-Max 250]
                                          把这个窗口的界面结构（UIA 树）吐出来：
                                          类型、名字、坐标、能不能点、输入框里现有的值。
                                          ★ 找不到元素时先跑这个，别靠坐标猜。
    -ClickLabel "按钮名" -Win "窗口标题片段" [-Partial] [-Double]
                                          按**名字**点控件（先用 Invoke，点不动才用鼠标点中心）。
                                          窗口被挪过也不怕 —— 坐标是现查的。
    -WaitFor "控件名" -Win "窗口标题片段" [-Timeout 20] [-Partial]
                                          等某个控件出现（轮询），超时退出码 1。
  输出一律是 JSON，方便直接读。
#>
param(
  [switch]$Windows,
  [string]$Activate,
  [string]$Click,
  [ValidateSet('left', 'right', 'middle')][string]$Button = 'left',
  [switch]$Double,
  [string]$Type,
  [string]$Keys,
  [string]$Open,
  [switch]$Procs,
  [string]$Name,
  [switch]$Screen,
  [string]$Run,
  [switch]$Shot,
  [string]$Out,
  [string]$Tree,
  [int]$Depth = 5,
  [int]$Max = 250,
  [string]$ClickLabel,
  [string]$WaitFor,
  [string]$Win,
  [string]$Label,
  [switch]$Partial,
  [int]$Timeout = 20,
  [int]$Interval = 400
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# DPI 感知：不声明的话，截出来的只是「虚拟化」的一半屏幕，坐标也和真实像素差 1.5 倍。
Add-Type -Namespace W -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][W.Dpi]::SetProcessDPIAware()

Add-Type -Namespace W -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, int e);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
'@

function Emit($obj) { $obj | ConvertTo-Json -Depth 4 -Compress }

# ================= UIA：按名字找控件（不靠猜坐标） =================
# 为什么要有这一节：今晚他挪了一下窗口，我记的坐标就全废了，只能重新查一遍。
# 有 UIA 之后可以「点那个叫『发』的按钮」—— 位置现查，窗口挪到哪都对。
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

function Get-UiaWindow([string]$match) {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
  $fallback = $null
  foreach ($k in $all) {
    $n = ''
    try { $n = [string]$k.Current.Name } catch { continue }
    if (-not $n -or $n -notlike "*$match*") { continue }
    try { if (-not $k.Current.IsOffscreen) { return $k } } catch { }
    if (-not $fallback) { $fallback = $k }
  }
  return $fallback
}

function Get-UiaInfo($el, [int]$d) {
  $o = [ordered]@{ depth = $d; type = ''; name = ''; aid = ''; x = 0; y = 0; w = 0; h = 0; enabled = $false; offscreen = $false; acts = @(); value = $null }
  try {
    $c = $el.Current
    $o.type = ([string]$c.ControlType.ProgrammaticName) -replace '^ControlType\.', ''
    $o.name = [string]$c.Name
    $o.aid = [string]$c.AutomationId
    $r = $c.BoundingRectangle
    if (-not $r.IsEmpty) { $o.x = [int]$r.X; $o.y = [int]$r.Y; $o.w = [int]$r.Width; $o.h = [int]$r.Height }
    $o.enabled = [bool]$c.IsEnabled
    $o.offscreen = [bool]$c.IsOffscreen
  } catch { }
  $acts = New-Object System.Collections.ArrayList
  foreach ($p in @(
      @{ n = 'click'; t = [System.Windows.Automation.InvokePattern]::Pattern }
      @{ n = 'select'; t = [System.Windows.Automation.SelectionItemPattern]::Pattern }
      @{ n = 'expand'; t = [System.Windows.Automation.ExpandCollapsePattern]::Pattern }
      @{ n = 'toggle'; t = [System.Windows.Automation.TogglePattern]::Pattern }
      @{ n = 'value'; t = [System.Windows.Automation.ValuePattern]::Pattern })) {
    try { $obj = $null; if ($el.TryGetCurrentPattern($p.t, [ref]$obj)) { [void]$acts.Add($p.n) } } catch { }
  }
  $o.acts = @($acts)
  try {
    $vp = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $o.value = [string]$vp.Current.Value }
  } catch { }
  if ($o.name.Length -gt 120) { $o.name = $o.name.Substring(0, 120) + '…' }
  if ($null -ne $o.value -and $o.value.Length -gt 120) { $o.value = $o.value.Substring(0, 120) + '…' }
  return [pscustomobject]$o
}

function Walk-Uia($el, [int]$d, [int]$maxDepth, [int]$cap) {
  if ($script:uiaBag.Count -ge $cap) { return }
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $c = $null
  try { $c = $walker.GetFirstChild($el) } catch { return }
  while ($c) {
    if ($script:uiaBag.Count -ge $cap) { return }
    [void]$script:uiaBag.Add((Get-UiaInfo $c $d))
    if ($d -lt $maxDepth) { Walk-Uia $c ($d + 1) $maxDepth $cap }
    try { $c = $walker.GetNextSibling($c) } catch { $c = $null }
  }
}

function Find-UiaPartial($win, [string]$label, [int]$cap = 900) {
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $stack = New-Object System.Collections.Stack
  $first = New-Object System.Collections.ArrayList
  try {
    $c = $walker.GetFirstChild($win)
    while ($c) { [void]$first.Add($c); $c = $walker.GetNextSibling($c) }
  } catch { return $null }
  for ($i = $first.Count - 1; $i -ge 0; $i--) { $stack.Push($first[$i]) }
  $seen = 0
  while ($stack.Count -gt 0 -and $seen -lt $cap) {
    $e = $stack.Pop(); $seen++
    $n = ''
    try { $n = [string]$e.Current.Name } catch { }
    if ($n -and $n -like "*$label*") { return $e }
    try {
      $kids = New-Object System.Collections.ArrayList
      $c = $walker.GetFirstChild($e)
      while ($c) { [void]$kids.Add($c); $c = $walker.GetNextSibling($c) }
      for ($i = $kids.Count - 1; $i -ge 0; $i--) { $stack.Push($kids[$i]) }
    } catch { }
  }
  return $null
}

function Find-Uia($win, [string]$label, [bool]$allowPartial) {
  $cond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $label)),
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::IsOffscreenProperty, $false)))
  try { $hit = $win.FindFirst([System.Windows.Automation.TreeScope]::Subtree, $cond); if ($hit) { return $hit } } catch { }
  if ($allowPartial) { return (Find-UiaPartial $win $label) }
  return $null
}

function Invoke-UiaElement($el) {
  foreach ($spec in @(
      @{ name = 'Invoke'; pattern = [System.Windows.Automation.InvokePattern]::Pattern }
      @{ name = 'SelectionItem'; pattern = [System.Windows.Automation.SelectionItemPattern]::Pattern }
      @{ name = 'ExpandCollapse'; pattern = [System.Windows.Automation.ExpandCollapsePattern]::Pattern })) {
    try {
      $obj = $null
      if ($el.TryGetCurrentPattern($spec.pattern, [ref]$obj)) {
        switch ($spec.name) {
          'Invoke' { $obj.Invoke() }
          'SelectionItem' { $obj.Select() }
          'ExpandCollapse' { $obj.Expand() }
        }
        return $spec.name
      }
    } catch { }
  }
  return $null
}

function Back-Foreground($winEl) {
  # 鼠标兜底路径必须先把窗口带到前台：窗口被别的窗口盖着时，点是点下去了，
  # 但落在盖在上面的那个窗口上（真的踩过 —— 点在 Edge 上，字没进记事本）。
  # 有 Invoke 的控件不走这里：Invoke 不需要窗口在前台，这是 UIA 最大的好处。
  try {
    $h = [IntPtr]$winEl.Current.NativeWindowHandle
    if ($h -ne [IntPtr]::Zero) {
      if ([W.U]::IsIconic($h)) { [void][W.U]::ShowWindow($h, 9) }
      [void][W.U]::SetForegroundWindow($h)
      Start-Sleep -Milliseconds 220
    }
  } catch { }
}

function Click-Point([int]$x, [int]$y, [bool]$dbl) {
  [void][W.U]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 70
  [W.U]::mouse_event(0x0002, 0, 0, 0, 0); Start-Sleep -Milliseconds 30
  [W.U]::mouse_event(0x0004, 0, 0, 0, 0)
  if ($dbl) { Start-Sleep -Milliseconds 80; [W.U]::mouse_event(0x0002, 0, 0, 0, 0); [W.U]::mouse_event(0x0004, 0, 0, 0, 0) }
}


function Get-WinList {
  $fg = [W.U]::GetForegroundWindow()
  Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object {
    $r = New-Object W.U+RECT
    [void][W.U]::GetWindowRect($_.MainWindowHandle, [ref]$r)
    [pscustomobject]@{
      title  = $_.MainWindowTitle
      proc   = $_.ProcessName
      pid    = $_.Id
      x      = $r.Left; y = $r.Top
      w      = $r.Right - $r.Left; h = $r.Bottom - $r.Top
      active = ($_.MainWindowHandle -eq $fg)
      min    = [W.U]::IsIconic($_.MainWindowHandle)
    }
  } | Where-Object { $_.title -ne '' } | Sort-Object -Property @{ Expression = 'active'; Descending = $true }, proc
}

if ($Windows) { Emit @(Get-WinList); exit 0 }

if ($Screen) {
  Emit @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
      [pscustomobject]@{ device = $_.DeviceName; primary = $_.Primary; w = $_.Bounds.Width; h = $_.Bounds.Height; x = $_.Bounds.X; y = $_.Bounds.Y }
    })
  exit 0
}

if ($Tree) {
  # ⚠ 变量别叫 $win：脚本参数里有 [string]$Win，PowerShell 变量名不分大小写 ⇒
  # 那俩是同一个变量，赋值会被悄悄转成字符串（ToString 成 "System.Windows.Automation.AutomationElement"）。
  # 踩过：-Tree 只吐了一个空元素，查了半天。
  $winEl = Get-UiaWindow $Tree
  if (-not $winEl) { Emit @{ ok = $false; error = "没找到窗口: $Tree" }; exit 1 }
  $script:uiaBag = New-Object System.Collections.ArrayList
  [void]$script:uiaBag.Add((Get-UiaInfo $winEl 0))
  Walk-Uia $winEl 1 ([Math]::Max(1, $Depth)) ([Math]::Max(1, $Max))
  Emit @{ ok = $true; window = $Tree; count = $script:uiaBag.Count; elements = @($script:uiaBag) }
  exit 0
}

if ($ClickLabel) {
  if (-not $Win) { Emit @{ ok = $false; error = '点名字要带上窗口：-Win "窗口标题片段"' }; exit 1 }
  $winEl = Get-UiaWindow $Win
  if (-not $winEl) { Emit @{ ok = $false; error = "没找到窗口: $Win" }; exit 1 }
  $el = Find-Uia $winEl $ClickLabel ([bool]$Partial)
  if (-not $el) { Emit @{ ok = $false; error = "窗口「$Win」里没有叫「$ClickLabel」的控件（可以先 -Tree 看一眼）" }; exit 1 }
  $info = Get-UiaInfo $el 0
  $how = Invoke-UiaElement $el
  if (-not $how) {
    Back-Foreground $winEl
    $r = $el.Current.BoundingRectangle
    if ($r.IsEmpty) { Emit @{ ok = $false; error = '控件没有可点区域（可能被折叠了）'; name = $info.name }; exit 1 }
    Click-Point ([int]($r.X + $r.Width / 2)) ([int]($r.Y + $r.Height / 2)) ([bool]$Double)
    $how = 'mouse'
  }
  Emit @{ ok = $true; window = $Win; label = $info.name; type = $info.type; how = $how; x = $info.x; y = $info.y; w = $info.w; h = $info.h }
  exit 0
}

if ($WaitFor) {
  if (-not $Win) { Emit @{ ok = $false; error = '等控件要带上窗口：-Win "窗口标题片段"' }; exit 1 }
  $deadline = (Get-Date).AddSeconds([Math]::Max(1, $Timeout))
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ((Get-Date) -lt $deadline) {
    $winEl = Get-UiaWindow $Win
    if ($winEl) {
      $el = Find-Uia $winEl $WaitFor ([bool]$Partial)
      if ($el) {
        $info = Get-UiaInfo $el 0
        Emit @{ ok = $true; window = $Win; found = $info.name; type = $info.type; x = $info.x; y = $info.y; w = $info.w; h = $info.h; secs = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        exit 0
      }
    }
    Start-Sleep -Milliseconds ([Math]::Max(100, $Interval))
  }
  Emit @{ ok = $false; error = "等了 $Timeout 秒也没出现: $WaitFor"; window = $Win }
  exit 1
}

if ($Activate) {
  $hit = Get-WinList | Where-Object { $_.title -like "*$Activate*" } | Select-Object -First 1
  if (-not $hit) { Emit @{ ok = $false; error = "没找到窗口: $Activate" }; exit 1 }
  $p = Get-Process -Id $hit.pid
  if ($hit.min) { [void][W.U]::ShowWindow($p.MainWindowHandle, 9) }   # SW_RESTORE
  [void][W.U]::SetForegroundWindow($p.MainWindowHandle)
  Start-Sleep -Milliseconds 250
  Emit @{ ok = $true; activated = $hit.title; pid = $hit.pid }
  exit 0
}

if ($Shot) {
  $dir = Join-Path $here '..\assets\shots'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (-not $Out) { $Out = Join-Path $dir ((Get-Date -Format 'yyMMdd-HHmmss') + '.png') }
  $Out = [System.IO.Path]::GetFullPath($Out)
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
  $g.Dispose()
  $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Emit @{ ok = $true; path = $Out; w = $b.Width; h = $b.Height; bytes = (Get-Item $Out).Length }
  exit 0
}

if ($Click) {
  $parts = $Click -split ','
  $x = [int]$parts[0].Trim(); $y = [int]$parts[1].Trim()
  [void][W.U]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 60
  $down = @{ left = 0x0002; right = 0x0008; middle = 0x0020 }[$Button]
  $up = @{ left = 0x0004; right = 0x0010; middle = 0x0040 }[$Button]
  [W.U]::mouse_event($down, 0, 0, 0, 0); Start-Sleep -Milliseconds 30
  [W.U]::mouse_event($up, 0, 0, 0, 0)
  if ($Double) { Start-Sleep -Milliseconds 80; [W.U]::mouse_event($down, 0, 0, 0, 0); [W.U]::mouse_event($up, 0, 0, 0, 0) }
  Emit @{ ok = $true; clicked = @($x, $y); button = $Button; double = [bool]$Double }
  exit 0
}

if ($Type) {
  # 走剪贴板：中文、换行、标点都不会丢。
  $old = Get-Clipboard -Raw -ErrorAction SilentlyContinue
  Set-Clipboard -Value $Type
  Start-Sleep -Milliseconds 60
  [System.Windows.Forms.SendKeys]::SendWait('^v')
  Start-Sleep -Milliseconds 120
  if ($null -ne $old) { Set-Clipboard -Value $old }
  Emit @{ ok = $true; typed = $Type.Length }
  exit 0
}

if ($Keys) {
  $map = @{ 'ctrl' = '^'; 'control' = '^'; 'alt' = '%'; 'shift' = '+' }
  $seq = ''
  $win = $false
  foreach ($part in ($Keys -split '\+')) {
    $k = $part.Trim().ToLower()
    if ($map.ContainsKey($k)) { $seq += $map[$k] }
    elseif ($k -eq 'enter') { $seq += '{ENTER}' }
    elseif ($k -eq 'tab') { $seq += '{TAB}' }
    elseif ($k -eq 'esc' -or $k -eq 'escape') { $seq += '{ESC}' }
    elseif ($k -eq 'del' -or $k -eq 'delete') { $seq += '{DEL}' }
    elseif ($k -eq 'win') { $seq += '' ; $win = $true }
    elseif ($k.Length -eq 1) { $seq += $k }
    else { $seq += '{' + $k.ToUpper() + '}' }
  }
  if ($win) {
    [void][W.U]::mouse_event(0, 0, 0, 0, 0)
    $sh = New-Object -ComObject WScript.Shell
    $sh.SendKeys('^{ESC}')
    $rest = $seq; if ($rest) { Start-Sleep -Milliseconds 300; [System.Windows.Forms.SendKeys]::SendWait($rest) }
  } else {
    [System.Windows.Forms.SendKeys]::SendWait($seq)
  }
  Emit @{ ok = $true; keys = $Keys; sent = $seq }
  exit 0
}

if ($Open) {
  if ($Open -match '^https?://') { Start-Process $Open }
  elseif (Test-Path $Open) { Start-Process -FilePath $Open }
  else { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "start `"`" `"$Open`"" -WindowStyle Hidden }
  Start-Sleep -Milliseconds 600
  Emit @{ ok = $true; opened = $Open }
  exit 0
}

if ($Procs) {
  $list = Get-Process | Sort-Object -Property WorkingSet64 -Descending
  if ($Name) { $list = $list | Where-Object { $_.ProcessName -like "*$Name*" } }
  Emit @($list | Select-Object -First 30 | ForEach-Object {
      [pscustomobject]@{ proc = $_.ProcessName; pid = $_.Id; mb = [math]::Round($_.WorkingSet64 / 1MB) }
    })
  exit 0
}

if ($Run) {
  $outText = & cmd.exe /c $Run 2>&1 | Out-String
  Emit @{ ok = $true; code = $LASTEXITCODE; out = $outText.Trim() }
  exit 0
}

Emit @{ ok = $false; error = '没说做什么。动词见本脚本头部注释。' }
exit 1
