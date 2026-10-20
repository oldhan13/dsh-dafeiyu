# restart-host.ps1 -- restart the DSH host (Web GUI on 3080, QQ channel on 8643)
# and bring the rest of the stack back with start-dafeiyu.ps1.
#
# WHY THIS IS A SEPARATE DETACHED PROCESS:
#   the host IS the process running the agent session that wants the restart.
#   Killing it from inside that session kills the session mid-turn. So we launch
#   this script detached (via Win32_Process.Create, i.e. not in our process tree),
#   give the caller a few seconds to finish its turn, and only then kill.
#
# USAGE:
#   powershell -NoProfile -ExecutionPolicy Bypass -File restart-host.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File restart-host.ps1 -DelaySeconds 40
#
# CHANGELOG
#   2026-10-19 23:10  v2 -- the v1 relaunch step never actually ran. It did:
#                       Start-Process cmd.exe -ArgumentList '/c', '"<path>.cmd" >> "<log>" 2>&1'
#                     cmd strips the first and last quote of a /c string, so the
#                     command arrived broken: exit code 1, nothing written to the
#                     log, no host started. Every "restart" since 17:49 was really
#                     just "kill" -- the host stayed dead until someone started it
#                     by hand. v2 fixes it and, more importantly, makes the script
#                     PROVE the launcher works BEFORE it kills anything:
#                       step 0  preflight the launcher (-Status) and abort if it cannot run
#                       step 2  abort if 8643/3080 are still held (a second bind = EADDRINUSE suicide)
#                       step 3  launch via powershell.exe -File with native redirection
#                       step 3b one retry, then a loud verdict + a FAILED marker file
#                     Every step is appended to restart-host.log next to this script.

param(
    [int]$DelaySeconds = 0,
    [string]$Project = '<WORKSPACE>'
)

$ErrorActionPreference = 'Continue'
$log       = Join-Path $PSScriptRoot 'restart-host.log'
$launcher  = Join-Path $Project 'dafeiyu\tools\start-dafeiyu.ps1'
$outLog    = Join-Path $PSScriptRoot 'start-dafeiyu.out.log'
$errLog    = Join-Path $PSScriptRoot 'start-dafeiyu.err.log'
$failMark  = Join-Path $PSScriptRoot 'restart-host.FAILED.txt'

function W([string]$m) {
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m
    try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch { }
}

function PortUp([int]$port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $port)
        $c.Close()
        return $true
    } catch { return $false }
}

function Start-Stack {
    # Launch the launcher as its own hidden PowerShell process.
    # No cmd.exe in the path -- that is what broke v1.
    # -Status is NOT passed here; this starts the real stack.
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $launcher + '"'))
    return Start-Process -FilePath 'powershell.exe' -ArgumentList $a `
        -WorkingDirectory $Project -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
}

function Tail([string]$path, [int]$n) {
    # these two files are raw console output of powershell.exe -> ANSI/OEM, not UTF-8
    if (-not (Test-Path $path)) { return '(missing)' }
    try { return ((Get-Content $path -Tail $n -Encoding Default -ErrorAction Stop) -join ' | ') } catch { return '(unreadable)' }
}

W ('==== restart-host v2 start (delay ' + $DelaySeconds + 's) ====')

# ---- 0. preflight: never kill unless the launcher demonstrably runs ----
if (-not (Test-Path $launcher)) { W ('ABORT: launcher missing: ' + $launcher); exit 2 }
$pre = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Status 2>&1 | Out-String
$preCode = $LASTEXITCODE
$preNonEmpty = @($pre -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
W ('preflight -Status exit=' + $preCode + ' chars=' + $pre.Length + ' lines=' + $preNonEmpty.Count)
if ($preNonEmpty.Count -gt 0) {
    W ('preflight tail: ' + (($preNonEmpty | Select-Object -Last 6) -join ' | '))
}
if ($pre.Length -lt 40) {
    W 'ABORT: launcher produced no output -- the relaunch would not work. Host left untouched.'
    W '==== restart-host done (aborted before kill) ===='
    exit 2
}

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

# ---- 1. find the host processes: the real node host and its npx wrapper ----
$targets = @()
$procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
foreach ($proc in $procs) {
    $cl = $proc.CommandLine
    if (-not $cl) { continue }
    if (($cl -match 'lib\\bin\.js') -and ($cl -match '\sweb\s*$')) { $targets += $proc.ProcessId }
    elseif (($cl -match 'npx-cli\.js') -and ($cl -match '@deepseek-ai/dsh\s+web')) { $targets += $proc.ProcessId }
}
$targets = @($targets | Sort-Object -Unique)
W ('host pids: ' + ($targets -join ','))

foreach ($targetPid in $targets) {
    if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
        W ('taskkill ' + $targetPid + ' -> already gone')
        continue
    }
    $r = & taskkill.exe /F /T /PID $targetPid 2>&1 | Out-String
    W ('taskkill ' + $targetPid + ' -> ' + ($r -replace "`r?`n", ' ').Trim())
}

# ---- 2. wait for the ports to be released. If they are not, do NOT launch. ----
$freed = $false
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
    if ((-not (PortUp 8643)) -and (-not (PortUp 3080))) { $freed = $true; break }
    Start-Sleep -Milliseconds 500
}
W ('ports after kill: 8643=' + (PortUp 8643) + ' 3080=' + (PortUp 3080) + ' freed=' + $freed)
if (-not $freed) {
    W 'ABORT: a port is still held by something. Launching now would die with EADDRINUSE.'
    W '==== restart-host done (aborted, host not relaunched) ===='
    exit 3
}

# ---- 3. bring the stack back up (idempotent; only fills what is missing) ----
if (Test-Path $failMark) { Remove-Item $failMark -ErrorAction SilentlyContinue }
Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

$sp = Start-Stack
W ('launcher started (pid ' + $sp.Id + '), waiting up to 240s for 8643+3080')
$deadline = (Get-Date).AddSeconds(240)
$up = $false
while ((Get-Date) -lt $deadline) {
    if ((PortUp 8643) -and (PortUp 3080)) { $up = $true; break }
    Start-Sleep -Seconds 2
}

if (-not $up) {
    W ('not up after 240s (launcher exited=' + $sp.HasExited + '). Retrying once.')
    W ('launcher stdout tail: ' + (Tail $outLog 12))
    W ('launcher stderr tail: ' + (Tail $errLog 12))
    $sp = Start-Stack
    W ('retry launcher started (pid ' + $sp.Id + ')')
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        if ((PortUp 8643) -and (PortUp 3080)) { $up = $true; break }
        Start-Sleep -Seconds 2
    }
}

if ($sp.HasExited) {
    $code = 'unknown'
    try { $sp.Refresh(); $code = [string]$sp.ExitCode } catch { }
    W ('launcher exit code: ' + $code)
} else { W 'launcher still running' }

# ---- 4. verdict ----
$v = 'final: 8643=' + (PortUp 8643) + ' 3080=' + (PortUp 3080) + ' 3077=' + (PortUp 3077) + ' 3078=' + (PortUp 3078) + ' 3000=' + (PortUp 3000)
W $v
W ('launcher stdout tail: ' + (Tail $outLog 15))
W ('launcher stderr tail: ' + (Tail $errLog 10))

if ((PortUp 8643) -and (PortUp 3080)) {
    W 'RESULT OK -- host is back'
} else {
    W 'RESULT FAILED -- host did NOT come back. Run start-dafeiyu.cmd by hand.'
    $msg = @(
        'restart-host failed at ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),
        '',
        $v,
        '',
        'Launcher stdout tail:',
        (Tail $outLog 30),
        '',
        'Launcher stderr tail:',
        (Tail $errLog 30),
        '',
        'Recovery: run start-dafeiyu.cmd at the project root, then refresh http://127.0.0.1:3080'
    ) -join "`r`n"
    try { [System.IO.File]::WriteAllText($failMark, $msg, (New-Object System.Text.UTF8Encoding($false))) } catch { }
}
W '==== restart-host done ===='
