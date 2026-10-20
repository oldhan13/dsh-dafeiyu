<#
  stop-dafeiyu.ps1 —— 把她身上的东西停掉（宿主不在这里停）。

  停这些：主动循环（heartbeat.mjs）、她自己的主页（serve.mjs）、群随听（watch.mjs）、
  桌面那条聊天线（bridge.mjs）、屏幕右下角那只鱼（pet-wf.ps1）。
  DSH 宿主不归这里管 —— 那是你自己开的窗口，关窗口 / Ctrl+C 就行。

  用法：
    .\stop-dafeiyu.cmd            # 停上面这些
    .\stop-dafeiyu.cmd -Status    # 只看现在谁在跑，一个都不动
#>
param([switch]$Status)

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

Say ''
if ($Status) { Say '  （-Status：只看了看，什么都没动）' }
else { Say '  宿主还开着。要全关，把它那个窗口关掉（或 Ctrl+C）。' }
Say ''
