<#
  stop-dafeiyu.ps1 —— 把她身上的东西停掉（宿主不在这里停）。

  停这些：主动循环（heartbeat.mjs）、她自己的主页（serve.mjs）、群随听（watch.mjs）、
  桌面那条聊天线（bridge.mjs）、屏幕右下角那只鱼（pet-wf.ps1）。
  DSH 宿主默认**不动** —— 它是网页界面（3080）本身，你可能还在用它。真要把宿主也一起停，加 -WithHost。

  用法：
    .\stop-dafeiyu.cmd              # 停上面这些，宿主留着
    .\stop-dafeiyu.cmd -Status      # 只看现在谁在跑，一个都不动
    .\stop-dafeiyu.cmd -WithHost    # 连宿主一起停（网页界面也会断）
#>
param([switch]$Status, [switch]$WithHost)

$ErrorActionPreference = 'Continue'
function Say($m) { Write-Host $m }

function Get-Nodes {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
}

# 只认「node.exe <script>」这种真实调用，别用松散的 .mjs 子串匹配 ——
# dsh 的 subprocess runner 命令行里会带上整段 PowerShell 文本，会误报。
function Get-ProcByScript([string]$script) {
    $pattern = '(?i)node(\.exe)?"?\s+' + [regex]::Escape($script) + '\s*$'
    Get-Nodes | Where-Object { $_.CommandLine -and $_.CommandLine.Trim() -match $pattern }
}

$targets = @(
    @{ Name = '主动循环 heartbeat'; Script = 'heartbeat.mjs' },
    @{ Name = '她的主页 serve'; Script = 'serve.mjs' },
    @{ Name = '群随听 watch'; Script = 'watch.mjs' },
    @{ Name = '桌面 bridge'; Script = 'bridge.mjs' }
)

Say ''
Say '=== 大肥鱼 · 收工 ==='
Say ''

foreach ($t in $targets) {
    $p = @(Get-ProcByScript $t.Script)
    if ($p.Count -eq 0) { Say ("  [--] {0}：没在跑" -f $t.Name); continue }
    if ($Status) { Say ("  [ok] {0}：在跑（pid {1}）" -f $t.Name, ($p.ProcessId -join ',')); continue }
    foreach ($x in $p) {
        try {
            Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop
            Say ("  [ok] {0}：已停（pid {1}）" -f $t.Name, $x.ProcessId)
        } catch {
            Say ("  [!!] {0}：停不掉 pid {1} —— {2}" -f $t.Name, $x.ProcessId, $_.Exception.Message)
        }
    }
}

# 桌宠是 WinForms：进程是 powershell.exe 在跑 pet-wf.ps1
$pet = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*pet-wf.ps1*' })
if ($pet.Count -eq 0) { Say '  [--] 桌宠：没在屏幕上' }
elseif ($Status) { Say ("  [ok] 桌宠：在屏幕上（pid {0}）" -f ($pet.ProcessId -join ',')) }
else {
    foreach ($x in $pet) {
        try {
            Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop
            Say ("  [ok] 桌宠：已收起来（pid {0}）" -f $x.ProcessId)
        } catch {
            Say ("  [!!] 桌宠：停不掉 pid {0} —— {1}" -f $x.ProcessId, $_.Exception.Message)
        }
    }
}

# 宿主：node 跑 @deepseek-ai/dsh 的 bin 带 web，或者 npx 那层壳。
# ⚠️ 必须排除 subprocess-local —— 它的命令行里塞着整段 PowerShell 文本，松散匹配会误杀。
$reHost = '(?i)(?:@deepseek-ai[\\/]dsh[\\/][^\s"]*\.js"?\s+web\s*$)|(?:npx-cli\.js"?\s+@deepseek-ai/dsh\s+web\s*$)'
$hostProcs = @(Get-Nodes | Where-Object {
    $_.CommandLine -and $_.CommandLine -notmatch 'subprocess-local' -and $_.CommandLine -match $reHost
})
if ($hostProcs.Count -eq 0) {
    Say '  [--] 宿主：没在跑'
} elseif ($Status) {
    Say ("  [ok] 宿主：在跑（pid {0}）" -f ($hostProcs.ProcessId -join ','))
} elseif (-not $WithHost) {
    Say ("  [--] 宿主：在跑（pid {0}），这次不动它" -f ($hostProcs.ProcessId -join ','))
} else {
    foreach ($x in $hostProcs) {
        try {
            Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop
            Say ("  [ok] 宿主：已停（pid {0}）" -f $x.ProcessId)
        } catch {
            Say ("  [!!] 宿主：停不掉 pid {0} —— {1}" -f $x.ProcessId, $_.Exception.Message)
        }
    }
}

Say ''
if ($Status) { Say '  （-Status：只看了看，什么都没动）' }
elseif ($WithHost) { Say '  全停了。' }
else { Say '  宿主还开着（网页界面 3080 还在）。要连它一起停：-WithHost' }
Say ''
