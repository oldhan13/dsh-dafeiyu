<#
  setup-ui.ps1 —— 大肥鱼的部署界面。

  给第一次用的人看的：一屏之内回答三个问题 ——
    ① 我这台机器够不够格跑（node / dsh / 工作区 / 端口）
    ② 我是谁、她是哪个号（只在本地保存，不进 git）
    ③ 装完到底起没起来（逐项打勾，不靠"应该可以"）

  它不自己发明流程：安装照旧走 install.ps1，启动照旧走 start-dafeiyu.ps1（-Json），
  这个界面只是把它们串起来、把结果画成能看懂的样子。

  入口：
    双击仓库根目录的 setup.cmd
    dafeiyu.cmd 发现还没配过，也会自己把这一屏叫出来

  ASCII-only 不适用：这文件里有中文，必须带 BOM（ACP=936 下没 BOM 会变乱码）。
#>
param(
    [switch]$Close
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Continue'
$PROJECT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # dafeiyu\tools -> 项目根
$TOOLS   = $PSScriptRoot
$MACHINE_FILE = Join-Path $PROJECT 'dafeiyu\state\machine.json'
$LOG_DIR = Join-Path $PROJECT 'dafeiyu\state'

# ---------- 配色 ----------
$BG     = [System.Drawing.Color]::FromArgb(246, 247, 249)
$CARD   = [System.Drawing.Color]::White
$INK    = [System.Drawing.Color]::FromArgb(17, 24, 39)
$MUTED  = [System.Drawing.Color]::FromArgb(107, 114, 128)
$OKC    = [System.Drawing.Color]::FromArgb(21, 128, 61)
$BADC   = [System.Drawing.Color]::FromArgb(185, 28, 28)
$ACCENT = [System.Drawing.Color]::FromArgb(37, 99, 235)
$LINE   = [System.Drawing.Color]::FromArgb(229, 231, 235)

$fTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$fSub   = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fH     = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$fBody  = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fMono  = New-Object System.Drawing.Font('Consolas', 9)

# ---------- 窗 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = '大肥鱼 · 部署'
$form.Size = New-Object System.Drawing.Size(860, 720)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $BG
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $fBody

function New-Card([int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.BackColor = $CARD
    $p.BorderStyle = 'FixedSingle'
    $form.Controls.Add($p)
    return $p
}

function New-Label($parent, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = $font
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($l)
    return $l
}

function New-Button($parent, [string]$text, [int]$x, [int]$y, [int]$w, [switch]$Primary) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 32)
    $b.FlatStyle = 'Flat'
    $b.Font = $fBody
    if ($Primary) {
        $b.BackColor = $ACCENT
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
    } else {
        $b.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
        $b.ForeColor = $INK
        $b.FlatAppearance.BorderColor = $LINE
    }
    $parent.Controls.Add($b)
    return $b
}

# 标题
$title = New-Label $form '大肥鱼 · 部署' 28 18 400 34 $fTitle $INK
$sub   = New-Label $form '一条住在你屏幕右下角的鱼。先检测环境，再填两个号，然后装、起、验收。' 28 54 780 22 $fSub $MUTED

# ---- 卡片 1：环境 ----
$c1 = New-Card 24 86 396 214
New-Label $c1 '① 环境够不够格' 14 10 200 22 $fH $INK | Out-Null
$listEnv = New-Object System.Windows.Forms.ListBox
$listEnv.Location = New-Object System.Drawing.Point(12, 38)
$listEnv.Size = New-Object System.Drawing.Size(370, 116)
$listEnv.BorderStyle = 'None'
$listEnv.Font = $fBody
$listEnv.BackColor = $CARD
$listEnv.DrawMode = 'Normal'
$c1.Controls.Add($listEnv)
$btnCheck = New-Button $c1 '重新检测' 12 162 110
$lblEnvHint = New-Label $c1 '' 130 168 250 20 $fSub $MUTED

# ---- 卡片 2：身份 ----
$c2 = New-Card 440 86 396 214
New-Label $c2 '② 你是谁、她是哪个号' 14 10 300 22 $fH $INK | Out-Null
New-Label $c2 '你的 QQ 号（主人）' 14 40 160 18 $fSub $MUTED | Out-Null
$txtOwner = New-Object System.Windows.Forms.TextBox
$txtOwner.Location = New-Object System.Drawing.Point(14, 60)
$txtOwner.Size = New-Object System.Drawing.Size(170, 26)
$txtOwner.Font = $fBody
$c2.Controls.Add($txtOwner)

New-Label $c2 '她用的 QQ 号（小号，别拿主号）' 200 40 190 18 $fSub $MUTED | Out-Null
$txtBot = New-Object System.Windows.Forms.TextBox
$txtBot.Location = New-Object System.Drawing.Point(200, 60)
$txtBot.Size = New-Object System.Drawing.Size(170, 26)
$txtBot.Font = $fBody
$c2.Controls.Add($txtBot)

$chkQQ = New-Object System.Windows.Forms.CheckBox
$chkQQ.Text = '装 QQ 通道（dsh-onebot-qq）'
$chkQQ.Location = New-Object System.Drawing.Point(14, 96)
$chkQQ.Size = New-Object System.Drawing.Size(240, 22)
$chkQQ.Font = $fBody
$c2.Controls.Add($chkQQ)

$chkVoice = New-Object System.Windows.Forms.CheckBox
$chkVoice.Text = '装语音（dsh-voice-chat）'
$chkVoice.Location = New-Object System.Drawing.Point(14, 120)
$chkVoice.Size = New-Object System.Drawing.Size(240, 22)
$chkVoice.Font = $fBody
$c2.Controls.Add($chkVoice)

New-Label $c2 '两个号只写在本机 dafeiyu\state\machine.json（.gitignore 挡着），不会进 git。' 14 146 370 32 $fSub $MUTED | Out-Null
$btnInstall = New-Button $c2 '开始安装' 14 182 120 -Primary

# ---- 卡片 3：状态 + 日志 ----
$c3 = New-Card 24 310 812 250
New-Label $c3 '③ 起没起来' 14 10 200 22 $fH $INK | Out-Null
$listStatus = New-Object System.Windows.Forms.ListBox
$listStatus.Location = New-Object System.Drawing.Point(12, 38)
$listStatus.Size = New-Object System.Drawing.Size(360, 196)
$listStatus.BorderStyle = 'None'
$listStatus.Font = $fBody
$listStatus.BackColor = $CARD
$c3.Controls.Add($listStatus)

New-Label $c3 '过程' 396 12 60 18 $fH $INK | Out-Null
$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(394, 34)
$log.Size = New-Object System.Drawing.Size(400, 200)
$log.Multiline = $true
$log.ScrollBars = 'Vertical'
$log.ReadOnly = $true
$log.Font = $fMono
$log.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 253)
$log.BorderStyle = 'FixedSingle'
$c3.Controls.Add($log)

$btnStart   = New-Button $form '一键启动' 24 574 120 -Primary
$btnStatus  = New-Button $form '只看状态' 152 574 110
$btnWeb     = New-Button $form '打开网页界面' 270 574 120
$btnHome    = New-Button $form '打开她的主页' 398 574 120
$btnClose   = New-Button $form '关闭' 720 574 116

$lblFoot = New-Label $form '' 24 616 812 22 $fSub $MUTED
$lblFoot.Text = '提示：装完第一次启动会慢一点（她要在读记忆）；端口被占时先看 3077 / 3079 / 3080 谁在用。'

# ---------- 小工具 ----------
function Write-Log([string]$s) {
    if (-not $s) { return }
    $log.AppendText($s + "`r`n")
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# 跑一个 .ps1 子进程，把它的输出实时灌进日志。
#
# 为什么不 RedirectStandardOutput + ReadLine：那是**同步**读，子进程一秒不吐字，
# 界面就一秒不刷新（按钮卡住、窗口像死了）。改成让子进程自己把输出用 UTF-8 写一个临时文件，
# 这边只管按增量读 —— 界面一直是活的，中文也不会按 GBK 乱码。
function Invoke-PsFile([string]$ps1, [string]$extra) {
    $tmp = Join-Path $env:TEMP ('dfy-' + [guid]::NewGuid().ToString('N') + '.log')
    $inner = "& '" + $ps1 + "' " + $extra + " 2>&1 | Out-File -FilePath '" + $tmp + "' -Encoding utf8"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'
    $psi.WorkingDirectory = $PROJECT
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)

    $printed = 0
    $deadline = (Get-Date).AddMinutes(6)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150
        [System.Windows.Forms.Application]::DoEvents()
        $printed = Read-NewLog $tmp $printed
    }
    [void]$p.WaitForExit(5000)
    $printed = Read-NewLog $tmp $printed
    Start-Sleep -Milliseconds 150
    [void](Read-NewLog $tmp $printed)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $p.ExitCode
}

function Read-NewLog([string]$file, [int]$printed) {
    try {
        if (-not (Test-Path $file)) { return $printed }
        $txt = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        if ($txt.Length -gt $printed) {
            Write-Log $txt.Substring($printed).TrimEnd()
            return $txt.Length
        }
    } catch { }
    return $printed
}

function Invoke-StartScript([string]$extra) {
    return Invoke-PsFile (Join-Path $TOOLS 'start-dafeiyu.ps1') $extra
}

function Get-StartSnapshot {
    # -Status -Json 是只读探针：不写任何东西，几秒内返回。
    $ps1 = Join-Path $TOOLS 'start-dafeiyu.ps1'
    $tmp = Join-Path $env:TEMP ('dfy-snap-' + [guid]::NewGuid().ToString('N') + '.json')
    $inner = "& '" + $ps1 + "' -Status -Json | Out-File -FilePath '" + $tmp + "' -Encoding utf8"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'
    $psi.WorkingDirectory = $PROJECT
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $deadline = (Get-Date).AddSeconds(25)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 120
    }
    [void]$p.WaitForExit(3000)
    $snap = $null
    try {
        $raw = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        if ($raw -and $raw.Trim()) { $snap = $raw | ConvertFrom-Json }
    } catch { }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $snap
}

function Show-Status {
    $snap = Get-StartSnapshot
    $listStatus.Items.Clear()
    if (-not $snap) { [void]$listStatus.Items.Add('读不到状态 —— 启动脚本没跑起来'); return }
    foreach ($it in $snap.items) {
        $mark = if ($it.ok) { '✓' } else { '✗' }
        $color = if ($it.ok) { $OKC } else { $BADC }
        # ListBox 不能按行上色（未 owner-draw），所以用字符标记 + 文字说明
        [void]$listStatus.Items.Add(("{0}  {1}" -f $mark, $it.label))
    }
    $sum = if ($snap.ok) { '桌面这条线齐了。' } else { '还缺东西 —— 看上面打 ✗ 的那几行，过程里会有原因。' }
    Write-Log ('—— 状态：' + $sum)
}

function Run-Checks {
    $listEnv.Items.Clear()
    $lblEnvHint.Text = '检查中…'
    [System.Windows.Forms.Application]::DoEvents()

    function Add-Check([string]$text, [bool]$ok, [string]$detail) {
        $mark = if ($ok) { '✓' } else { '✗' }
        $line = if ($detail) { "$mark  $text —— $detail" } else { "$mark  $text" }
        [void]$listEnv.Items.Add($line)
        [System.Windows.Forms.Application]::DoEvents()
    }

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $nv = (& node -v) 2>$null
        $major = 0
        try { $major = [int]((($nv -replace '^v','') -split '\.')[0]) } catch { }
        Add-Check ('Node.js ' + $nv) ($major -ge 22) $(if ($major -ge 22) { '' } else { '需要 22 以上（zstd 要 22.15+）' })
    } else {
        Add-Check 'Node.js' $false '找不到 node，先装 Node.js 22+'
    }

    $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($dshCmd) {
        $dv = (& dsh --version) 2>$null
        Add-Check ('DSH ' + $dv) $true ''
    } else {
        Add-Check 'DSH（dsh 命令）' $false 'npm i -g @deepseek-ai/dsh'
    }

    $inDsh = $PROJECT -like ((Join-Path $env:USERPROFILE '.dsh') + '*')
    Add-Check '工作区不在 ~/.dsh 里面' (-not $inDsh) $PROJECT

    foreach ($pair in @(@(3077, '她的主页'), @(3079, '桌面聊天框'), @(3080, '网页界面'), @(3000, 'NapCat 接口'))) {
        $port = $pair[0]; $what = $pair[1]
        $busy = $false
        try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close(); $busy = $true } catch { }
        Add-Check ("端口 $port（$what）") $true $(if ($busy) { '已在用 —— 如果正是大肥鱼，那是对的' } else { '空着' })
    }

    if (Test-Path $MACHINE_FILE) {
        try { $m = Get-Content $MACHINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($m.botQQ) { $txtBot.Text = [string]$m.botQQ }
            if ($m.ownerQQ) { $txtOwner.Text = [string]$m.ownerQQ }
            Add-Check 'machine.json' $true '已配置过' } catch { Add-Check 'machine.json' $false '读不出来，重新填一次再保存' }
    } else {
        Add-Check 'machine.json' $true '还没配（下面填两个号就会生成）'
    }

    $napcat = @(
        (Join-Path $env:LOCALAPPDATA 'NapCat\NapCatWinBootMain.exe'),
        'D:\Tools\NapCat\onekey\NapCat.52230.Shell\NapCatWinBootMain.exe',
        (Join-Path $env:USERPROFILE 'NapCat\NapCatWinBootMain.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    Add-Check 'NapCat（接 QQ 才需要）' $true $(if ($napcat) { $napcat } else { '没找到 —— 不接 QQ 可以不管' })

    $lblEnvHint.Text = '检测完了。'
}

function Save-Machine {
    $obj = [ordered]@{}
    if ($txtOwner.Text.Trim()) { $obj.ownerQQ = $txtOwner.Text.Trim() }
    if ($txtBot.Text.Trim())   { $obj.botQQ   = $txtBot.Text.Trim() }
    if (Test-Path $MACHINE_FILE) {
        try {
            $old = Get-Content $MACHINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $old.PSObject.Properties) { if (-not ($obj.Contains($p.Name))) { $obj[$p.Name] = $p.Value } }
        } catch { }
    }
    if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
    ($obj | ConvertTo-Json) | Set-Content -Path $MACHINE_FILE -Encoding UTF8
    Write-Log ('已保存身份：' + $MACHINE_FILE)
}

# ---------- 事件 ----------
$btnCheck.Add_Click({ Run-Checks })
$btnStatus.Add_Click({ Show-Status })

$btnInstall.Add_Click({
    $btnInstall.Enabled = $false
    try {
        $q = $txtOwner.Text.Trim(); $b = $txtBot.Text.Trim()
        if (-not $q -or -not $b) { Write-Log '先把两个 QQ 号都填上（只接桌面那条线、暂时不要 QQ，也要填，之后能改）。'; return }
        Save-Machine
        $a = '-OwnerQQ ' + $q + ' -BotQQ ' + $b + ' -Profile web'
        if ($chkQQ.Checked) { $a += ' -WithQQ' }
        if ($chkVoice.Checked) { $a += ' -WithVoice' }
        Write-Log '—— 开始安装（install.ps1）'
        $rc = Invoke-PsFile (Join-Path $PROJECT 'install.ps1') $a
        Write-Log ('—— 安装结束，退出码 ' + $rc)
        if ($rc -eq 0) { Write-Log '装好了。下一步点「一键启动」。' } else { Write-Log '安装有一步没过，看上面最后几行。' }
    } finally { $btnInstall.Enabled = $true }
})

$btnStart.Add_Click({
    $btnStart.Enabled = $false
    try {
        Write-Log '—— 启动中（缺什么补什么；已经在跑的不动）'
        [void](Invoke-StartScript '')
        Show-Status
    } finally { $btnStart.Enabled = $true }
})

$btnWeb.Add_Click({ try { Start-Process 'http://127.0.0.1:3080' } catch { Write-Log '打不开浏览器，自己点 http://127.0.0.1:3080' } })
$btnHome.Add_Click({ try { Start-Process 'http://127.0.0.1:3077/' } catch { Write-Log '打不开浏览器，自己点 http://127.0.0.1:3077/' } })
$btnClose.Add_Click({ $form.Close() })

$form.Add_Shown({
    Write-Log ('工作区：' + $PROJECT)
    Run-Checks
    Show-Status
})

if ($Close) { $form.WindowState = 'Minimized' }
[void]$form.ShowDialog()
