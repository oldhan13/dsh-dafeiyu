<#
  start-dafeiyu.ps1 —— 一键把「大肥鱼」的四件套拉起来（已在跑的会跳过）。

  四件套：
    1. DSH 宿主（dsh web）——它同时是 QQ 通道的服务端（反向 WS 监听 8643）和网页界面（3080）
    2. NapCat（QQ 客户端 + OneBot）—— 以 <机器人QQ> 登录，反向拨 8643，HTTP 在 3000
    3. 后台冲动循环 heartbeat.mjs —— 8~13 分钟醒一次，自己决定发不发（间隔在 heartbeat.mjs 里改）
    4. 她的主页 serve.mjs —— http://127.0.0.1:3077/

  用法（两种，效果一样）：
    双击仓库根目录的 dafeiyu.cmd   ← 一键：宿主没起就自己起，然后把鱼放出来
    .\start-dafeiyu.cmd            # 同一个东西；-Status 只看不动；-NoHost 不动宿主
    .\start-dafeiyu.cmd -Open      # 起来之后再帮你把网页界面打开

  只有一条原则：**缺什么补什么**。已经活着的一律不重复起 —— 重复起宿主会 EADDRINUSE 当场自杀。

  关于 TMP：宿主交给 start-dsh-web.cmd 起，那个脚本自己把 TMP/TEMP 指到工作区外面
  （Windows ACL 沙箱要求 temp root 不在 workspace 里，否则会话里的 shell 起不来）。
#>
param(
    [switch]$Status,
    [switch]$NoHost,
    [switch]$Open
)

$ErrorActionPreference = 'Continue'
$PROJECT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # dafeiyu\tools -> 项目根
$NODE = 'node'
$NAPCAT_EXE = if ($env:DAFEIYU_NAPCAT_EXE) { $env:DAFEIYU_NAPCAT_EXE } else { 'D:\Tools\NapCat\onekey\NapCat.52230.Shell\NapCatWinBootMain.exe' }  # 用 -e DAFEIYU_NAPCAT_EXE 指你自己的
$BOT_QQ = $env:DAFEIYU_BOT_QQ
$TOKEN_FILE = Join-Path $env:USERPROFILE '.dsh\onebot-token.txt'
$HB_DIR = Join-Path $PROJECT 'dafeiyu\heartbeat'
$HOME_DIR = Join-Path $PROJECT 'dafeiyu\homepage'
$HOST_LAUNCHER = Join-Path $PROJECT 'start-dsh-web.cmd'

function Say($msg) { Write-Host $msg }
function Ok($msg)   { Write-Host "  [ok] $msg"   -ForegroundColor Green }
function Todo($msg) { Write-Host "  [..] $msg"   -ForegroundColor Yellow }
function Bad($msg)  { Write-Host "  [!!] $msg"   -ForegroundColor Red }

function Test-Port([int]$port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $port); $c.Close(); return $true
    } catch { return $false }
}

# 后台启动：完全不创建控制台窗口。
#
# 2026-10-20 上午他提的：「每次启动后台都要挂特别多的 cmd 窗口」。
# 根因有两个：① 这里原来用 Start-Process -WindowStyle Hidden —— 那是「先把窗口建出来、再藏起来」，
# 启动那一瞬间屏幕上还是啪一下，五六个 node/powershell 串起来就是一片黑框；
# ② 起宿主机那行压根没加 Hidden，`cmd /c call start-dsh-web.cmd` 而 dsh web 是常驻的
# ⇒ 那个 cmd 窗口会**一直挂在那儿**关不掉。② 才是"挂"字的意思。
#
# .NET 的 CreateNoWindow 是**根本不创建**控制台，连闪都没有。
# 套一层 cmd.exe 是为了要它那句 `> log 2>&1` —— 用 RedirectStandardOutput 接事件再写文件，
# 在 PowerShell 里又慢又容易被缓冲噎住，不值当。cmd 自己也被 CreateNoWindow 压住了。
function Start-Bg([string]$CmdLine, [string]$WorkDir) {
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = 'cmd.exe'
    # 整体再包一对引号：cmd 会把 /c 后面的首尾引号剥掉，命令本身以引号开头时
    # 不包就会散架（2026-10-19 23:00 restart-host.ps1 栽过一次）。
    $si.Arguments = '/c "' + $CmdLine + '"'
    if ($WorkDir) { $si.WorkingDirectory = $WorkDir }
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    # 必须重定向，哪怕没人读。不重定向的话子进程会**继承调用者的 stdout/stderr 句柄**：
    # 于是 `start-dafeiyu.ps1 | ...` 这种管道永远不关，双击 .cmd 起的那个黑窗口也会
    # 一直挂到所有服务退出 —— 这是「挂特别多的 cmd 窗口」的另一半根因（2026-10-20 实测）。
    # 这里不读也不怕：命令自己已经 >log 2>log 了，cmd 本身几乎没有输出。
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($si)
}

function Get-Nodes {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
}

function Get-ProcByScript([string]$script) {
    # 只认「node.exe <script>」这种真实调用；不要用松散的 .mjs 子串匹配 ——
    # dsh 的 subprocess runner 命令行里会带上整段 PowerShell 文本，会误报出别的进程。
    $pattern = '(?i)node(\.exe)?"?\s+' + [regex]::Escape($script) + '\s*$'
    Get-Nodes | Where-Object { $_.CommandLine -and $_.CommandLine.Trim() -match $pattern }
}

function NapCat-Online {
    try {
        $token = (Get-Content $TOKEN_FILE -Raw).Trim()
        $h = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        $r = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/get_status' -Method Post -Headers $h -Body '{}' -TimeoutSec 5
        return [bool]$r.data.online
    } catch { return $false }
}

function Wait-Until($condition, [int]$seconds, [string]$what) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 800
    }
    Bad "等 $what 超时（$seconds 秒）"
    return $false
}

Say ''
Say '=== 大肥鱼 · 启动检查 ==='
Say ''

# ---- 1. DSH 宿主 ----
Say '1) DSH 宿主（QQ 通道 8643 + 网页 3080）'
$p8643 = Test-Port 8643
$p3080 = Test-Port 3080
$hostUp = $p8643 -and $p3080
if ($hostUp) {
    Ok '已在运行'
} elseif ($p8643 -or $p3080) {
    # 只有一个端口在听：多半是上一个实例还在起、或者残留的监听。
    # 这时候再叠一个实例上去，新实例会 listen EADDRINUSE 当场自杀
    # （2026-10-19 19:29 那次就是这样，日志在 ~/.dsh/logs/startup-*.log）。
    Todo ("端口只有一半在听（8643={0} 3080={1}）—— 等 40 秒看它自己走完" -f $p8643, $p3080)
    [void](Wait-Until { (Test-Port 8643) -and (Test-Port 3080) } 40 '半个宿主起来')
    if ((Test-Port 8643) -and (Test-Port 3080)) { Ok '起来了' }
    else { Bad '端口被占着但没起全。别重复启动（会 EADDRINUSE），先查是谁占的。' }
} elseif ($Status) {
    Bad '没在运行 —— 双击 dafeiyu.cmd（或 .\start-dafeiyu.cmd）拉起来'
} elseif ($NoHost) {
    Bad '-NoHost 指定不动宿主，但 8643/3080 没在监听'
} else {
    if (-not (Test-Path $HOST_LAUNCHER)) { Bad "找不到启动器：$HOST_LAUNCHER"; }
    else {
        Todo '启动宿主（没窗口；TMP 由 start-dsh-web.cmd 指到工作区外）'
        # 必须写成 /c call "<path>"：cmd 会把 /c 后面字符串的首尾引号剥掉，
        # 路径里有空格时命令就散了 —— restart-host.ps1 第一版栽的就是这个（2026-10-19 23:00）。
        # 2026-10-20：改成 Start-Bg —— 原来这行没加 Hidden，dsh web 又是常驻进程，
        # 那个 cmd 窗口会一直挂在桌面/任务栏上，就是他说「挂特别多的 cmd 窗口」的那个。
        Start-Bg ('call "' + $HOST_LAUNCHER + '"') $PROJECT | Out-Null
        [void](Wait-Until { (Test-Port 8643) -and (Test-Port 3080) } 120 '宿主就绪')
        if ((Test-Port 8643) -and (Test-Port 3080)) {
            Ok '宿主已起（3080 网页 / 8643 QQ 通道）'
        } else {
            # 一键启动最容易卡在这儿，而且窗口是隐藏的 —— 必须给他可执行的下一步，
            # 别让他对着一行 [!!] 猜。
            Bad '宿主没起全。八成是 dsh 没装、或 3080/8643 被别的进程占着。'
            Say '     手动跑一次看真实报错（它会带着窗口跑）：'
            Say ('       ' + $HOST_LAUNCHER)
            Say '     看端口是谁占的：netstat -ano | findstr "3080 8643"'
        }
    }
}

# ---- 2. NapCat ----
Say ''
Say '2) NapCat（QQ 客户端）'
$napcatProc = Get-CimInstance Win32_Process -Filter "Name='NapCatWinBootMain.exe'" -ErrorAction SilentlyContinue
if (NapCat-Online) {
    Ok '在线（HTTP 3000 有响应，online=true）'
} elseif ($Status) {
    Bad '不在线'
} else {
    if ($napcatProc) { Todo '进程在，但还没登进去，等它一下' }
    else {
        Todo "启动 NapCat（QQ $BOT_QQ）"
        if (-not (Test-Path $NAPCAT_EXE)) { Bad "找不到：$NAPCAT_EXE" }
        else { Start-Process -FilePath $NAPCAT_EXE -ArgumentList $BOT_QQ -WorkingDirectory (Split-Path $NAPCAT_EXE -Parent) }
    }
    [void](Wait-Until { NapCat-Online } 120 'NapCat 登录')
    if (NapCat-Online) { Ok '已登录，反向 WS 会自己拨上 8643' } else { Bad '还是不在线 —— 可能要扫码，或小号在别处登录把它踢了' }
}

# ---- 3. 后台冲动循环 ----
Say ''
Say '3) 后台冲动循环（heartbeat.mjs）'
$hb = Get-ProcByScript 'heartbeat.mjs'
if ($hb) { Ok "在跑（pid $($hb.ProcessId -join ','))" }
elseif ($Status) { Bad '没在跑' }
else {
    Todo '启动 heartbeat'
    Start-Bg ('"' + $NODE + '" heartbeat.mjs > "' + (Join-Path $HB_DIR 'stdout.log') + '" 2> "' + (Join-Path $HB_DIR 'stderr.log') + '"') $HB_DIR | Out-Null
    Start-Sleep -Seconds 2
    $hb2 = Get-ProcByScript 'heartbeat.mjs'
    if ($hb2) { Ok "已起（pid $($hb2.ProcessId -join ',')）" } else { Bad '没起来，看 dafeiyu\heartbeat\stderr.log' }
}

# ---- 4. 她的主页 ----
Say ''
Say '4) 她的主页（serve.mjs @ 3077）'
$web = Get-ProcByScript 'serve.mjs'
if ($web -and (Test-Port 3077)) { Ok "在跑（pid $($web.ProcessId -join ',')）" }
elseif ($Status) { Bad '没在跑' }
else {
    Todo '启动主页服务'
    Start-Bg ('"' + $NODE + '" serve.mjs > "' + (Join-Path $HOME_DIR 'server.out.log') + '" 2> "' + (Join-Path $HOME_DIR 'server.err.log') + '"') $HOME_DIR | Out-Null
    [void](Wait-Until { Test-Port 3077 } 15 '主页服务')
    if (Test-Port 3077) { Ok '已起' } else { Bad '没起来' }
}

# ---- 5. 群聊随听 ----
Say ''
Say '5) 群聊随听（watch.mjs @ 3078，NapCat 把群里每条消息都推给它）'
$gw = Get-ProcByScript 'watch.mjs'
if ($gw -and (Test-Port 3078)) { Ok "在跑（pid $($gw.ProcessId -join ',')）" }
elseif ($Status) { Bad '没在跑 —— 群里她就不说话了' }
else {
    Todo '启动群聊随听'
    $gwDir = Join-Path $PROJECT 'dafeiyu\group'
    Start-Bg ('"' + $NODE + '" watch.mjs > "' + (Join-Path $gwDir 'stdout.log') + '" 2> "' + (Join-Path $gwDir 'stderr.log') + '"') $gwDir | Out-Null
    [void](Wait-Until { Test-Port 3078 } 15 '群聊随听')
    if (Test-Port 3078) { Ok '已起' } else { Bad '没起来，看 dafeiyu\group\stderr.log' }
}

# ---- 6. 桌面她的聊天框 ----
Say ''
Say '6) 桌面聊天框（desk\bridge.mjs @ 3079 —— 双击她就能打字说话）'
$deskUp = (Test-Port 3079)
if ($deskUp) { Ok '在跑（3079 在听）' }
elseif ($Status) { Bad '没在跑 —— 双击她只能退回开网页' }
else {
    Todo '启动桌面聊天框的桥'
    $deskDir = Join-Path $PROJECT 'dafeiyu\desk'
    Start-Bg ('"' + $NODE + '" bridge.mjs > "' + (Join-Path $deskDir 'bridge.out.log') + '" 2> "' + (Join-Path $deskDir 'bridge.err.log') + '"') $deskDir | Out-Null
    [void](Wait-Until { Test-Port 3079 } 15 '桌面聊天桥')
    if (Test-Port 3079) { Ok '已起' } else { Bad '没起来，看 dafeiyu\desk\bridge.err.log' }
}

# ---- 7. 桌面宠物 ----
Say ''
Say '7) 桌面宠物（pet-wf.ps1 —— 屏幕右下角那只鱼）'
function Get-PetProc {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*pet-wf.ps1*' }
}
$pet = Get-PetProc
if ($pet) { Ok "在跑（pid $($pet.ProcessId -join ',')）" }
elseif ($Status) { Bad '没在跑 —— 桌面上看不见她' }
else {
    Todo '把桌宠放出来'
    # pet-wf.ps1 是 WinForms：CreateNoWindow 只压住控制台，它自己创建的窗口照样显示。
    Start-Bg ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PROJECT 'dafeiyu\pet\pet-wf.ps1') + '"') $PROJECT | Out-Null
    [void](Wait-Until { [bool](Get-PetProc) } 10 '桌宠')
    if (Get-PetProc) { Ok '已出来' } else { Bad '没出来，看 dafeiyu\pet\pet.log' }
}

# ---- 台账自动瘦身（计划任务）----
# 这条以前是「wscript 跑一个 vbs」：Windows 11 24H2 现在**一启动 wscript.exe 就弹
# 「VBScript 已弃用」的确认框**，而任务是每 30 分钟一次 ⇒ 他每半小时被弹一下
# （应用日志 provider VBScriptDeprecationAlert / EventID 4096 里能查到那条 vbs）。
# 现在改成「任务直接起一个隐藏的 powershell 跑纯 ASCII 的 .ps1」：不经过 wscript，也不建窗口。
# 别改回 S4U / session 0 —— presence.ps1 靠 GetLastInputInfo 判断他在不在键盘前，session 0 会读错。
$tidyPs   = Join-Path $PSScriptRoot 'ledger-tidy-hidden.ps1'
$tidyName = 'DaFeiYu-LedgerTidy'

if ($Status) {
    # -Status 说好"只看看"，那就一个字节都不写。
    $tj = $null
    try { $tj = schtasks /Query /TN $tidyName 2>$null } catch { }
    if ($tj) { Say '  [ok] 台账瘦身任务：已注册' } else { Say '  [--] 台账瘦身任务：没注册' }
}

if (-not $Status) {
    $exists = $null
    try { $exists = schtasks /Query /TN $tidyName 2>$null } catch { }
    if (-not $exists) {
        # 先把「每 30 分钟」这个节奏建出来（动作先给个占位，下面立刻换成真的）
        schtasks /Create /SC MINUTE /MO 30 /TN $tidyName /TR 'powershell.exe -NoProfile -Command exit' /F | Out-Null
        Say '  [ok] 已注册台账自动瘦身任务（每 30 分钟）'
    }
    try {
        # 用 Set-ScheduledTask 设动作：它能正确给参数里的路径加引号，
        # 而 schtasks /TR 在路径带空格时会被 PowerShell 的引号处理搞散。
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $tidyPs + '"')
        Set-ScheduledTask -TaskName $tidyName -Action $act | Out-Null
        Say '  [ok] 任务动作 = 隐藏 PowerShell（不经 wscript，不弹窗）'
    } catch {
        Say '  [!!] 没能自动设置任务动作。手动把 DaFeiYu-LedgerTidy 的动作改成这一行：'
        Say ('       powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $tidyPs + '"')
    }
}

# ---- 汇总 ----
$host_ok = (Test-Port 8643)
$qq_ok = NapCat-Online
$loop_ok = [bool](Get-ProcByScript 'heartbeat.mjs')
$web_ok = (Test-Port 3077)
$group_ok = (Test-Port 3078)
$pet_ok = [bool](Get-PetProc)
$desk_ok = (Test-Port 3079)

Say ''
Say '=== 现在 ==='
Say ("  宿主    : {0}" -f $(if ($host_ok) { '8643 在听 (3080 网页)' } else { '未启动' }))
Say ("  QQ      : {0}" -f $(if ($qq_ok) { '在线' } else { '离线' }))
Say ("  循环    : {0}" -f $(if ($loop_ok) { '在跑' } else { '停着' }))
Say ("  主页    : {0}" -f $(if ($web_ok) { 'http://127.0.0.1:3077/' } else { '未启动' }))
Say ("  群随听  : {0}" -f $(if ($group_ok) { '在听（3078）' } else { '未启动' }))
Say ("  桌宠    : {0}" -f $(if ($pet_ok) { '在屏幕上' } else { '没出来' }))
Say ("  聊天框  : {0}" -f $(if ($desk_ok) { '3079 在听' } else { '没起' }))
Say ''
Say '  网页界面  : http://127.0.0.1:3080'
Say '  她的主页  : http://127.0.0.1:3077/'
Say ''

if ($Open -and $host_ok) {
    try { Start-Process 'http://127.0.0.1:3080' } catch { Say '  [!!] 打不开浏览器，自己点： http://127.0.0.1:3080' }
}

# 每次跑完留一行摘要 —— 没有它，出问题时只能靠猜（2026-10-19 的教训）。
$summary = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') +
    ("  host={0} qq={1} loop={2} web={3} group={4} pet={5} desk={6}" -f $host_ok, $qq_ok, $loop_ok, $web_ok, $group_ok, $pet_ok, $desk_ok)
try { Add-Content -Path (Join-Path $PSScriptRoot 'start-dafeiyu.log') -Value $summary -Encoding UTF8 } catch { }

# 退出码就是健康度（0 = 起来了，1 = 还缺东西）——双击入口靠它决定"关窗口还是停住让你看"。
# 只算**桌面这条线**：宿主 + 循环 + 主页 + 桌面桥 + 鱼。
# ⚠️ 不要把 QQ 算进必须项：没接 QQ 的人，一键启动会永远判失败，窗口每次都停下来。
$core_ok = $host_ok -and $loop_ok -and $web_ok -and $desk_ok -and $pet_ok
if ($core_ok) { exit 0 } else { exit 1 }
