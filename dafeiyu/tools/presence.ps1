# presence.ps1 —— 他此刻在不在、忙不忙。写 dafeiyu/state/presence.json。
#
#   presence.ps1               算一次、写一次（给别人现查）
#   presence.ps1 -Loop         每 60 秒写一次（给心跳那种没有工具的进程看）
#
# 字段：at / idleSec（键盘鼠标空闲秒数）/ locked（屏幕锁没锁）/ fgTitle / fgProc / busy
# 只有事实，没有判断 —— 该不该开口，谁看谁自己判。

param(
  [switch]$Loop,
  [switch]$Ensure,
  [int]$IntervalSeconds = 60
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class Pres
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    // DESKTOP_SWITCHDESKTOP = 0x0100
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseDesktop(IntPtr hDesktop);

    public static int IdleSeconds()
    {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(li);
        if (!GetLastInputInfo(ref li)) return -1;
        uint now = (uint)Environment.TickCount;
        uint d = now - li.dwTime;          // uint 减法自己会绕回来
        return (int)(d / 1000);
    }

    public static bool Locked()
    {
        IntPtr h = OpenInputDesktop(0, false, 0x0100);
        if (h == IntPtr.Zero) return true;  // 打不开输入桌面 = 锁屏 / 切到了别的会话
        CloseDesktop(h);
        return false;
    }

    public static string FgTitle()
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return "";
        StringBuilder sb = new StringBuilder(512);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static int FgPid()
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return 0;
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return (int)pid;
    }

    public delegate bool EnumWinProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWinProc cb, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    // 他开着哪些窗口（"进程名|标题"）—— 给心跳那句「提意见」一个具体的着力点。
    // 只看有标题的顶层窗口，没有标题的都是系统件，对他没用。
    public static string[] Windows()
    {
        System.Collections.Generic.List<string> list = new System.Collections.Generic.List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(512);
            GetWindowTextW(h, sb, sb.Capacity);
            string t = sb.ToString().Trim();
            if (t.Length == 0) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            string pname = "";
            try { pname = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
            list.Add(pname + "|" + t);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
'@

$stateDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$out = Join-Path $stateDir 'presence.json'
$enc = New-Object System.Text.UTF8Encoding($false)
$pidFile = Join-Path $stateDir 'presence.pid'

function Write-Presence {
  $idle = [Pres]::IdleSeconds()
  $locked = [Pres]::Locked()
  $fgPid = [Pres]::FgPid()
  $fgProc = ''
  if ($fgPid -gt 0) {
    $p = Get-Process -Id $fgPid -ErrorAction SilentlyContinue
    if ($p) { $fgProc = $p.ProcessName }
  }
  $wins = @()
  try {
    $seen = @{}
    foreach ($w in [Pres]::Windows()) {
      $i = $w.IndexOf('|')
      if ($i -lt 0) { continue }
      $proc2 = $w.Substring(0, $i)
      $title = $w.Substring($i + 1)
      # 系统壳、输入法、我自己 —— 对他没意义，占地方
      if ($title -eq 'Program Manager' -or $title -eq 'Default IME' -or $title -eq '大肥鱼') { continue }
      # 有些进程（实测 SmartEngineHostN64）的标题读出来是「字节被当 UTF-16 解码」的乱码，
      # 特征是会落到 CJK 扩展A / 私用区。这种标题对判断他在干什么毫无用处，直接丢。
      if ($title -match '[\u3400-\u4DBF\uE000-\uF8FF\uFFFD]') { continue }
      # 托盘/桌面组件的窗口标题常常是 GUID 或包名（实测 XLSmartTray、clouddrive_desktop_widget），
      # 一个字符的信息量都没有 —— 留着只会挤掉真正能看出他在干什么的窗口。
      if ($title -match '^\{[0-9A-Fa-f\-]+\}$') { continue }
      if ($title -match '^[a-z0-9._\-]{18,}$') { continue }
      $key = $proc2 + '|' + $title
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      $wins += [ordered]@{ proc = $proc2; title = $title }
      if ($wins.Count -ge 6) { break }
    }
  } catch { }
  $obj = [ordered]@{
    at      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    idleSec = $idle
    locked  = $locked
    # 「在电脑前」：没锁屏，且最近 5 分钟内有键鼠动作
    here    = ((-not $locked) -and ($idle -ge 0) -and ($idle -lt 300))
    fgTitle = [Pres]::FgTitle()
    fgProc  = $fgProc
    windows = $wins
  }
  [IO.File]::WriteAllText($out, ($obj | ConvertTo-Json -Compress), $enc)
  return $obj
}

if ($Ensure) {
  $alive = $false
  $old = ''
  if (Test-Path $pidFile) {
    $old = (Get-Content $pidFile -Raw).Trim()
    if ($old -match '^\d+$') { $alive = [bool](Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue) }
  }
  if ($alive) { Write-Output "presence already running (pid $old)"; exit 0 }
  $cmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Loop'
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
  Write-Output ("presence started rc=" + $r.ReturnValue + " pid=" + $r.ProcessId)
  exit 0
}

if ($Loop) {
  [IO.File]::WriteAllText($pidFile, "$PID", $enc)
  while ($true) {
    try { [void](Write-Presence) } catch { }
    Start-Sleep -Seconds ([Math]::Max(10, $IntervalSeconds))
  }
} else {
  $r = Write-Presence
  Write-Output ($r | ConvertTo-Json -Compress)
}
