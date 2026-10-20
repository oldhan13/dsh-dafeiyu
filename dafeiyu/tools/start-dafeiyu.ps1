<#
  start-dafeiyu.ps1 —— 一键把「大肥鱼」拉起来（缺什么补什么，已经在跑的一律跳过）。

  它是这套东西**唯一的启动入口**：dafeiyu.cmd、setup 界面、计划任务都调它。

  管这些：
    1. DSH 宿主（dsh web）—— 网页界面 3080；接了 QQ 的话，它同时是 QQ 通道的服务端（8643）
    2. NapCat（QQ 客户端 + OneBot）—— 以你的小号登录，反向拨 8643，HTTP 接口在 3000
    3. 后台冲动循环 heartbeat.mjs —— 8~13 分钟醒一次，自己决定发不发
    4. 她的主页 serve.mjs —— http://127.0.0.1:3077/
    5. 群聊随听 watch.mjs —— 3078
    6. 桌面聊天框的桥 bridge.mjs —— 3079（双击那条鱼就能说话）
    7. 桌面宠物 pet-wf.ps1 —— 屏幕右下角那只鱼
    8. 台账瘦身的计划任务（每 30 分钟，隐藏窗口，不弹任何框）

  用法：
    双击仓库根目录的 dafeiyu.cmd      ← 一键
    .\start-dafeiyu.cmd -Status       # 只看现在活着没有，一个字节都不写
    .\start-dafeiyu.cmd -NoHost       # 不动宿主（你自己已经开着 dsh web）
    .\start-dafeiyu.cmd -Open         # 起来之后顺手把网页界面打开
    .\start-dafeiyu.cmd -Json         # 给 GUI 用的机器可读结果，不打印人话

  只有一条原则：**缺什么补什么**。已经活着的一律不重复起 ——
  重复起宿主会 EADDRINUSE 当场自杀（2026-10-19 19:29 那次就是这样）。

  关于 TMP：宿主交给 start-dsh-web.cmd 起，那个脚本自己把 TMP/TEMP 指到工作区外面
  （Windows ACL 沙箱要求 temp root 不在 workspace 里，否则会话里的 shell 起不来）。

  机器相关的值（Node 在哪、NapCat 装在哪、机器人 QQ 号）优先从
  dafeiyu/state/machine.json 读，读不到再用环境变量 / PATH 猜。
  那个文件是**你自己机器上的**，仓库里没有（.gitignore 里挡着）。
#>
param(
    [switch]$Status,
    [switch]$NoHost,
    [switch]$Open,
    [switch]$Json,
    [int]$Settle = 20
)

$ErrorActionPreference = 'Continue'
$PROJECT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # dafeiyu\tools -> 项目根

$TOKEN_FILE = Join-Path $env:USERPROFILE '.dsh\onebot-token.txt'
$HB_DIR     = Join-Path $PROJECT 'dafeiyu\heartbeat'
$HOME_DIR   = Join-Path $PROJECT 'dafeiyu\homepage'
$GROUP_DIR  = Join-Path $PROJECT 'dafeiyu\group'
$DESK_DIR   = Join-Path $PROJECT 'dafeiyu\desk'
$PET_FILE   = Join-Path $PROJECT 'dafeiyu\pet\pet-wf.ps1'
$HOST_LAUNCHER = Join-Path $PROJECT 'start-dsh-web.cmd'
$MACHINE_FILE  = Join-Path $PROJECT 'dafeiyu\state\machine.json'

# ---------- 机器相关的值：machine.json > 环境变量 > 猜 ----------
$machine = @{}
if (Test-Path $MACHINE_FILE) {
    try { $machine = Get-Content $MACHINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $machine = @{} }
}
function Pick([string[]]$candidates) {
    foreach ($c in $candidates) { if ($c) { return $c } }
    return $null
}
function Field($name) {
    if ($machine -and ($machine.PSObject.Properties.Name -contains $name)) { return [string]$machine.$name }
    return $null
}

$NODE = Pick @($env:DAFEIYU_NODE, (Field 'nodeExe'), 'node')

$NAPCAT_CANDIDATES = @(
    $env:DAFEIYU_NAPCAT_EXE,
    (Field 'napcatExe'),
    'D:\Tools\NapCat\onekey\NapCat.52230.Shell\NapCatWinBootMain.exe',
    (Join-Path $env:LOCALAPPDATA 'NapCat\NapCatWinBootMain.exe'),
    (Join-Path $env:USERPROFILE 'NapCat\NapCatWinBootMain.exe')
)
$NAPCAT_EXE = $null
foreach ($c in $NAPCAT_CANDIDATES) { if ($c -and (Test-Path $c)) { $NAPCAT_EXE = $c; break } }
if (-not $NAPCAT_EXE) { $NAPCAT_EXE = Pick $NAPCAT_CANDIDATES }   # 报错时也要有路径可打

$BOT_QQ = Pick @($env:DAFEIYU_BOT_QQ, (Field 'botQQ'))

# ---------- 输出 ----------
$console = -not $Json
$script:log = New-Object System.Collections.ArrayList
function Say($msg)  { if ($console) { Write-Host $msg } else { [void]$script:log.Add([string]$msg) } }
function Ok($msg)   { Say "  [ok] $msg" }
function Todo($msg) { Say "  [..] $msg" }
function Bad($msg)  { Say "  [!!] $msg" }
function Dim($msg)  { Say $msg }

function Test-Port([int]$port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $port); $c.Close(); return $true
    } catch { return $false }
}

# 后台启动：完全不创建控制台窗口。
#
# 2026-10-20 他提的：「每次启动后台都要挂特别多的 cmd 窗口」。
# 根因两个：① 原来用 Start-Process -WindowStyle Hidden —— 那是「先建出来、再藏起来」，
# 启动那一瞬间屏幕上还是啪一下；② 起宿主那行压根没加 Hidden，而 dsh web 是常驻的
# ⇒ 那个 cmd 窗口会一直挂着。② 才是"挂"字的意思。
#
# .NET 的 CreateNoWindow 是**根本不创建**控制台，连闪都没有。
# 套一层 cmd.exe 是为了要它那句 `> log 2> log`；用 RedirectStandardOutput 接事件再写文件
# 在 PowerShell 里又慢又容易被缓冲噎住，不值当。
function Start-Bg([string]$CmdLine, [string]$WorkDir) {
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = 'cmd.exe'
    # 整体再包一对引号：cmd 会把 /c 后面的首尾引号剥掉，命令本身以引号开头时不包就散架。
    $si.Arguments = '/c "' + $CmdLine + '"'
    if ($WorkDir) { $si.WorkingDirectory = $WorkDir }
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    # 必须重定向（哪怕没人读）：不重定向时子进程会继承调用者的 stdout/stderr 句柄，
    # 于是管道永远不关、双击起的那个黑窗口也会一直挂到所有服务退出。
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($si)
}

function Get-Nodes {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
}

function Get-ProcByScript([string]$script) {
    # 只认「node.exe <script>」这种真实调用；不要用松散的 .mjs 子串匹配 ——
    # dsh 的 subprocess runner 命令行里会带上整段 PowerShell 文本，会误报。
    $pattern = '(?i)node(\.exe)?"?\s+' + [regex]::Escape($script) + '\s*$'
    Get-Nodes | Where-Object { $_.CommandLine -and $_.CommandLine.Trim() -match $pattern }
}

function Get-PetProc {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*pet-wf.ps1*' -and $_.CommandLine -notlike '*Get-PetProc*' }
}

function NapCat-Online {
    try {
        if (-not (Test-Path $TOKEN_FILE)) { return $false }
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

function Port-Pid([int]$port) {
    try {
        $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($c) { return [int]$c.OwningProcess }
    } catch { }
    return 0
}

# ---------- 开跑 ----------
Say ''
Say '=== 大肥鱼 · 启动检查 ==='
Say ''

# ---- 1. DSH 宿主 ----
# 3080 = 网页界面（宿主活着的判据）
# 8643 = QQ 通道（NapCat 反向拨进来的口子；插件没启用时它本来就不该在听）
Say '1) DSH 宿主（网页 3080 / QQ 通道 8643）'
$p3080 = Test-Port 3080
$p8643 = Test-Port 8643
if ($p3080) {
    Ok ("已在运行（pid {0}）" -f (Port-Pid 3080))
} elseif ($Status) {
    Bad '没在运行 —— 双击 dafeiyu.cmd（或 .\start-dafeiyu.cmd）拉起来'
} elseif ($NoHost) {
    Bad '-NoHost 指定不动宿主，但 3080 没在监听'
} else {
    if (-not (Test-Path $HOST_LAUNCHER)) { Bad "找不到启动器：$HOST_LAUNCHER" }
    else {
        Todo '启动宿主（没窗口；TMP 由 start-dsh-web.cmd 指到工作区外）'
        # 必须写成 /c call "<path>"：cmd 会把 /c 后字符串的首尾引号剥掉，路径带空格时会散架。
        Start-Bg ('call "' + $HOST_LAUNCHER + '"') $PROJECT | Out-Null
        [void](Wait-Until { Test-Port 3080 } 120 '宿主就绪')
        if (Test-Port 3080) {
            Ok '宿主已起（3080 网页）'
        } else {
            # 一键启动最容易卡在这儿，窗口又是隐藏的 —— 必须给他可执行的下一步，别让他对着 [!!] 猜。
            Bad '宿主没起。八成是 dsh 没装、或 3080 被别的进程占着。'
            Dim '     手动跑一次看真实报错（它会带着窗口跑）：'
            Dim ('       ' + $HOST_LAUNCHER)
            Dim '     看端口是谁占的：netstat -ano | findstr "3080 8643"'
        }
    }
}
$p8643 = Test-Port 8643
if ($p3080 -or (Test-Port 3080)) {
    if ($p8643) { Ok 'QQ 通道 8643 在听' }
    else {
        Ok 'QQ 通道没开（8643）—— 宿主本身没问题：装没装 dsh-onebot-qq、插件有没有启用，看 docs/SETUP.md'
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
    if ($napcatProc) {
        Todo '进程在，但还没登进去，等它一下'
    } else {
        if (-not $NAPCAT_EXE -or -not (Test-Path $NAPCAT_EXE)) {
            Bad '找不到 NapCat 的可执行文件。没装就跳过这一步（桌面那条线不需要 QQ）。'
            Dim ('     装的位置写进 ' + $MACHINE_FILE + ' 的 napcatExe，或设环境变量 DAFEIYU_NAPCAT_EXE')
            Dim ('     现在找过：' + (($NAPCAT_CANDIDATES | Where-Object { $_ }) -join ' | '))
        } elseif (-not $BOT_QQ) {
            Bad '不知道用哪个 QQ 号登录。把 botQQ 写进 machine.json，或设环境变量 DAFEIYU_BOT_QQ。'
        } else {
            Todo ("启动 NapCat（QQ {0}）" -f $BOT_QQ)
            Start-Process -FilePath $NAPCAT_EXE -ArgumentList $BOT_QQ -WorkingDirectory (Split-Path $NAPCAT_EXE -Parent)
        }
    }
    [void](Wait-Until { NapCat-Online } 90 'NapCat 登录')
    if (NapCat-Online) {
        Ok '已登录，反向 WS 会自己拨上 8643'
    } else {
        Bad '还是不在线 —— 可能要扫码，或这个号在别处登录被踢了'
        Dim '     扫码头：http://127.0.0.1:6099/webui （token 在 NapCat 的 config\webui.json）'
    }
}

# ---- 3~7. node 四个 + 鱼 ----
function Ensure-NodeApp([string]$label, [string]$script, [string]$dir, [string]$port, [int]$waitSec, [string]$logHint) {
    Say ''
    Say $label
    $proc = Get-ProcByScript $script
    $portUp = if ($port) { Test-Port ([int]$port) } else { $false }
    if ($proc -and ($portUp -or -not $port)) {
        Ok ("在跑（pid {0}）" -f ($proc.ProcessId -join ','))
        return $true
    }
    if ($Status) { Bad '没在跑'; return $false }
    Todo ("启动 {0}" -f $script)
    Start-Bg ('"' + $NODE + '" ' + $script + ' > "' + (Join-Path $dir 'stdout.log') + '" 2> "' + (Join-Path $dir 'stderr.log') + '"') $dir | Out-Null
    if ($port) {
        [void](Wait-Until { Test-Port ([int]$port) } $waitSec ($script + ' 的 ' + $port))
        if (Test-Port ([int]$port)) { Ok '已起'; return $true }
        Bad ("没起来，看 " + $logHint)
        return $false
    }
    Start-Sleep -Seconds 2
    if (Get-ProcByScript $script) { Ok '已起'; return $true }
    Bad ("没起来，看 " + $logHint)
    return $false
}

$loop_ok  = Ensure-NodeApp '3) 后台冲动循环（heartbeat.mjs）' 'heartbeat.mjs' $HB_DIR '' 0 'dafeiyu\heartbeat\stderr.log'
$web_ok   = Ensure-NodeApp '4) 她的主页（serve.mjs @ 3077）' 'serve.mjs' $HOME_DIR '3077' 15 'dafeiyu\homepage\server.err.log'
$group_ok = Ensure-NodeApp '5) 群聊随听（watch.mjs @ 3078）' 'watch.mjs' $GROUP_DIR '3078' 15 'dafeiyu\group\stderr.log'
$desk_ok  = Ensure-NodeApp '6) 桌面聊天框（bridge.mjs @ 3079）' 'bridge.mjs' $DESK_DIR '3079' 15 'dafeiyu\desk\bridge.err.log'

Say ''
Say '7) 桌面宠物（pet-wf.ps1 —— 屏幕右下角那只鱼）'
$pet = Get-PetProc
if ($pet) {
    Ok ("在跑（pid {0}）" -f ($pet.ProcessId -join ','))
    $pet_ok = $true
} elseif ($Status) {
    Bad '没在跑 —— 桌面上看不见她'
    $pet_ok = $false
} else {
    Todo '把桌宠放出来'
    # pet-wf.ps1 是 WinForms：CreateNoWindow 只压住控制台，它自己创建的窗口照样显示。
    Start-Bg ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $PET_FILE + '"') $PROJECT | Out-Null
    [void](Wait-Until { [bool](Get-PetProc) } 10 '桌宠')
    $pet_ok = [bool](Get-PetProc)
    if ($pet_ok) { Ok '已出来' } else { Bad '没出来，看 dafeiyu\pet\pet.log' }
}

# ---- 8. 台账瘦身的计划任务 ----
# 以前是「wscript 跑一个 vbs」：Windows 11 24H2 一启动 wscript.exe 就弹「VBScript 已弃用」，
# 而任务是每 30 分钟一次 ⇒ 他每半小时被弹一下。
# 更早那版是直接跑 .cmd：ShellExecute 打开「Windows 命令脚本」会弹「无法验证发布者。你确定要运行此软件吗？」
# —— 他截图问的就是那个。两条路都别回去：任务只起一个隐藏的 powershell，跑纯 ASCII 的 .ps1，
# 里面用 & 直接调 .cmd（不走 ShellExecute），既不弹 VBScript 提示、也不弹发布者警告。
$tidyPs   = Join-Path $PSScriptRoot 'ledger-tidy-hidden.ps1'
$tidyName = 'DaFeiYu-LedgerTidy'

Say ''
Say '8) 台账瘦身（计划任务，每 30 分钟，不弹窗）'
if ($Status) {
    $tj = $null
    try { $tj = schtasks /Query /TN $tidyName 2>$null } catch { }
    if ($tj) { Ok '已注册' } else { Say '  [--] 没注册' }
} else {
    $exists = $null
    try { $exists = schtasks /Query /TN $tidyName 2>$null } catch { }
    if (-not $exists) {
        schtasks /Create /SC MINUTE /MO 30 /TN $tidyName /TR 'powershell.exe -NoProfile -Command exit' /F | Out-Null
        Ok '已注册（每 30 分钟）'
    }
    try {
        # Set-ScheduledTask 设动作：它能正确给参数里的路径加引号；
        # 而 schtasks /TR 在路径带空格时会被 PowerShell 的引号处理搞散。
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $tidyPs + '"')
        Set-ScheduledTask -TaskName $tidyName -Action $act | Out-Null
        Ok '动作 = 隐藏 PowerShell（不经 wscript，不弹发布者警告）'
    } catch {
        Bad '没能自动设置任务动作。手动把任务动作改成这一行：'
        Dim ('       powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $tidyPs + '"')
    }
}

# ---- 收口：给慢半拍的东西一次机会再判 ----
# 以前是每一步各自等固定秒数就下结论，于是"启动时好时坏"：某一个组件在第 16 秒才起来，
# 而这里第 15 秒已经判它失败了。所以最后整体再探一次，只补不重复起。
if (-not $Status -and $Settle -gt 0) {
    $missing = @()
    if (-not $web_ok)   { $missing += 'serve.mjs' }
    if (-not $group_ok) { $missing += 'watch.mjs' }
    if (-not $desk_ok)  { $missing += 'bridge.mjs' }
    if (-not $loop_ok)  { $missing += 'heartbeat.mjs' }
    if (-not $pet_ok)   { $missing += 'pet-wf.ps1' }
    if ($missing.Count) {
        Say ''
        Todo ("再等 {0} 秒，看这几样会不会自己起来：{1}" -f $Settle, ($missing -join ', '))
        [void](Wait-Until {
            $ok = $true
            if (-not (Test-Port 3077)) { $ok = $false }
            if (-not (Test-Port 3078)) { $ok = $false }
            if (-not (Test-Port 3079)) { $ok = $false }
            if (-not (Get-ProcByScript 'heartbeat.mjs')) { $ok = $false }
            if (-not (Get-PetProc)) { $ok = $false }
            return $ok
        } $Settle '慢半拍的组件')
    }
}

# ---- 汇总 ----
$host_ok  = (Test-Port 3080)
$chan_ok  = (Test-Port 8643)
$qq_ok    = NapCat-Online
$loop_ok  = [bool](Get-ProcByScript 'heartbeat.mjs')
$web_ok   = (Test-Port 3077)
$group_ok = (Test-Port 3078)
$desk_ok  = (Test-Port 3079)
$pet_ok   = [bool](Get-PetProc)

$core_ok = $host_ok -and $loop_ok -and $web_ok -and $desk_ok -and $pet_ok

if ($console) {
    Say ''
    Say '=== 现在 ==='
    Say ("  宿主    : {0}" -f $(if ($host_ok) { '3080 在听（网页界面）' } else { '未启动' }))
    Say ("  QQ 通道 : {0}" -f $(if ($chan_ok) { '8643 在听' } else { '没开（未接 QQ 或插件未启用）' }))
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
}

if ($Open -and $host_ok) {
    try { Start-Process 'http://127.0.0.1:3080' } catch { Bad '打不开浏览器，自己点： http://127.0.0.1:3080' }
}

# 每次跑完留一行摘要 —— 没有它，出问题时只能靠猜（2026-10-19 的教训）。
$summary = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') +
    ("  host={0} chan={1} qq={2} loop={3} web={4} group={5} pet={6} desk={7}" -f $host_ok, $chan_ok, $qq_ok, $loop_ok, $web_ok, $group_ok, $pet_ok, $desk_ok)
if (-not $Status) {
    try { Add-Content -Path (Join-Path $PSScriptRoot 'start-dafeiyu.log') -Value $summary -Encoding UTF8 } catch { }
}

if ($Json) {
    $payload = [ordered]@{
        at      = (Get-Date).ToString('s')
        status  = $Status.IsPresent
        ok      = $core_ok
        items   = @(
            @{ key = 'host';  label = 'DSH 宿主（3080）';      ok = $host_ok },
            @{ key = 'chan';  label = 'QQ 通道（8643）';       ok = $chan_ok },
            @{ key = 'qq';    label = 'NapCat / QQ';          ok = $qq_ok },
            @{ key = 'loop';  label = '后台冲动循环';          ok = $loop_ok },
            @{ key = 'web';   label = '她的主页（3077）';      ok = $web_ok },
            @{ key = 'group'; label = '群聊随听（3078）';      ok = $group_ok },
            @{ key = 'desk';  label = '桌面聊天框（3079）';    ok = $desk_ok },
            @{ key = 'pet';   label = '桌面宠物';             ok = $pet_ok }
        )
        urls    = @{ web = 'http://127.0.0.1:3080'; home = 'http://127.0.0.1:3077/' }
        lines   = $script:log
    }
    $payload | ConvertTo-Json -Depth 6 -Compress
}

# 退出码就是健康度（0 = 桌面这条线起来了，1 = 还缺东西）。
# ⚠️ 不要把 QQ 算进必须项：没接 QQ 的人，一键启动会永远判失败，双击入口每次都停下来。
if ($core_ok) { exit 0 } else { exit 1 }
