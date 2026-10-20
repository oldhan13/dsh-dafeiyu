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
# PS 5.1 默认协议可能还停在 TLS 1.0，测 key 的 https 请求要 1.2
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

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
$form.Size = New-Object System.Drawing.Size(860, 856)
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

# ---- 卡片 3：模型 key（桌面这条线是独立进程，要自己的 key） ----
$ck = New-Card 24 310 812 150
New-Label $ck '③ 模型 key —— 她说话要用的' 14 10 340 22 $fH $INK | Out-Null
New-Label $ck '供应商' 14 40 80 18 $fSub $MUTED | Out-Null

$comboProv = New-Object System.Windows.Forms.ComboBox
$comboProv.Location = New-Object System.Drawing.Point(14, 60)
$comboProv.Size = New-Object System.Drawing.Size(190, 26)
$comboProv.DropDownStyle = 'DropDownList'
$comboProv.Font = $fBody
[void]$comboProv.Items.Add('DeepSeek 官方（推荐）')
[void]$comboProv.Items.Add('硅基流动 SiliconFlow')
$comboProv.SelectedIndex = 0
$ck.Controls.Add($comboProv)

New-Label $ck 'API key（贴进来，不回显）' 216 40 240 18 $fSub $MUTED | Out-Null
$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Location = New-Object System.Drawing.Point(216, 60)
$txtKey.Size = New-Object System.Drawing.Size(320, 26)
$txtKey.Font = $fMono
$txtKey.UseSystemPasswordChar = $true
$ck.Controls.Add($txtKey)

$btnTest    = New-Button $ck '测一下' 548 56 90
$btnSaveKey = New-Button $ck '保存 key' 646 56 140 -Primary

$lblKeyHint  = New-Label $ck '' 14 98 520 46 $fSub $MUTED
$lblKeyState = New-Label $ck '' 548 100 240 22 $fSub $MUTED

# ---- 卡片 4：状态 + 日志 ----
$c3 = New-Card 24 470 812 250
New-Label $c3 '④ 起没起来' 14 10 200 22 $fH $INK | Out-Null
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

$btnStart   = New-Button $form '一键启动' 24 734 120 -Primary
$btnStatus  = New-Button $form '只看状态' 152 734 110
$btnWeb     = New-Button $form '打开网页界面' 270 734 120
$btnHome    = New-Button $form '打开她的主页' 398 734 120
$btnClose   = New-Button $form '关闭' 720 734 116

$lblFoot = New-Label $form '' 24 776 812 22 $fSub $MUTED
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
        (Join-Path $env:USERPROFILE 'NapCat\NapCatWinBootMain.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    Add-Check 'NapCat（接 QQ 才需要）' $true $(if ($napcat) { $napcat } else { '没找到 —— 不接 QQ 可以不管' })

    $cfgNow = Get-ProviderCfg $comboProv.SelectedIndex
    $kk = Read-KeyFile $cfgNow.keyFile
    Add-Check ('模型 key（' + $cfgNow.label + '）') ($kk.Length -gt 10) $(if ($kk.Length -gt 10) { '已有，点「测一下」确认能真用' } else { '还没有 —— 贴到卡片 ③ 里保存' })

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

# ---------- 模型 key ----------
# 面板对话（desk\bridge.mjs）与主动循环（heartbeat\heartbeat.mjs）是独立进程，拿不到宿主
# 进程内的 DSH 账号登录，所以它们需要一把能直连的 key。网页 / QQ 那条线走 DSH 账号，不用这把。
function Get-ProviderCfg([int]$i) {
    if ($i -eq 1) {
        return @{
            provider = 'siliconflow'
            label    = '硅基流动'
            baseUrl  = 'https://api.siliconflow.cn/v1'
            model    = 'deepseek-ai/DeepSeek-V4.1-Flash'
            keyFile  = (Join-Path $env:USERPROFILE '.dsh\siliconflow-key.txt')
        }
    }
    return @{
        provider = 'deepseek'
        label    = 'DeepSeek 官方'
        baseUrl  = 'https://api.deepseek.com/v1'
        model    = 'deepseek-chat'
        keyFile  = (Join-Path $env:USERPROFILE '.dsh\deepseek-key.txt')
    }
}

function Read-KeyFile([string]$file) {
    if (-not (Test-Path $file)) { return '' }
    try { return [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8).Trim() } catch { return '' }
}

# 真的打一次，不靠"应该能用"。四种错翻成人话。
function Test-ApiKey([string]$baseUrl, [string]$model, [string]$key) {
    try {
        $body = @{
            model       = $model
            messages    = @(@{ role = 'user'; content = 'ping' })
            max_tokens  = 8
            temperature = 0
        } | ConvertTo-Json -Depth 6 -Compress
        $r = Invoke-RestMethod -Uri ($baseUrl.TrimEnd('/') + '/chat/completions') `
            -Method Post -TimeoutSec 30 -UseBasicParsing `
            -Headers @{ Authorization = ('Bearer ' + $key) } `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
        $c = ''
        try { $c = [string]$r.choices[0].message.content } catch { }
        if (-not $c) { $c = '(回了个空的，但通了)' }
        return @{ ok = $true; msg = ('通了，它说：' + $c) }
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -eq 401 -or $code -eq 403) { return @{ ok = $false; msg = ('key 被拒（http ' + $code + '）—— 少复制了几位？') } }
        if ($code -eq 402) { return @{ ok = $false; msg = '余额不足（http 402）—— 去后台充一点' } }
        if ($code -eq 429) { return @{ ok = $false; msg = '请求太密（http 429）—— 等会儿再试' } }
        if ($code -eq 0) { return @{ ok = $false; msg = ('没连上：' + $_.Exception.Message) } }
        return @{ ok = $false; msg = ('http ' + $code + '：' + $_.Exception.Message) }
    }
}

function Refresh-KeyHint {
    $cfg = Get-ProviderCfg $comboProv.SelectedIndex
    $k = Read-KeyFile $cfg.keyFile
    $where = if ($k.Length -gt 8) { '已有 ' + $k.Substring(0, 5) + '…' + $k.Substring($k.Length - 4) } elseif ($k) { '文件是空的' } else { '还没有' }
    $lblKeyHint.Text = ('存到 ' + $cfg.keyFile + '（' + $where + '）。面板和心跳是独立进程，得有这一把；网页与 QQ 走 DSH 账号，不需要。语音合成另算，不装语音就不用管。')
}

function Save-ApiKey {
    $cfg = Get-ProviderCfg $comboProv.SelectedIndex
    $k = $txtKey.Text.Trim()
    $dir = Split-Path -Parent $cfg.keyFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ($k) {
        if ($k -match '\s') { Write-Log 'key 里有空格或换行 —— 重新复制一遍再贴'; return $false }
        # 无 BOM：读的一方是按 UTF-8 裸文本拿的，BOM 会跟着进 header
        [System.IO.File]::WriteAllText($cfg.keyFile, $k, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log ('已保存 key：' + $cfg.keyFile)
        $txtKey.Text = ''
    } elseif (Read-KeyFile $cfg.keyFile) {
        Write-Log ('没贴新 key，沿用已有的：' + $cfg.keyFile)
    } else {
        Write-Log '还没贴 key —— 桌面上那只鱼会开不了口。'
        return $false
    }

    # llm.json 是面板与心跳唯一认的端点来源；同样无 BOM，否则 JSON.parse 会栽在头三个字节上
    $lj = Join-Path $PROJECT 'dafeiyu\state\llm.json'
    $obj = [ordered]@{
        provider   = $cfg.provider
        baseUrl    = $cfg.baseUrl
        model      = $cfg.model
        apiKeyFile = ('~/.dsh/' + (Split-Path -Leaf $cfg.keyFile))
    }
    $json = ($obj | ConvertTo-Json) + "`r`n"
    [System.IO.File]::WriteAllText($lj, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log ('模型配置：' + $cfg.label + ' · ' + $cfg.model + ' → ' + $lj)
    return $true
}

function Load-KeyState {
    $lj = Join-Path $PROJECT 'dafeiyu\state\llm.json'
    if (Test-Path $lj) {
        try {
            $o = Get-Content $lj -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($o.provider -eq 'siliconflow') { $comboProv.SelectedIndex = 1 } else { $comboProv.SelectedIndex = 0 }
        } catch { }
    }
    Refresh-KeyHint
}

# ---------- 事件 ----------
$btnCheck.Add_Click({ Run-Checks })
$btnStatus.Add_Click({ Show-Status })

$comboProv.Add_SelectedIndexChanged({ Refresh-KeyHint })

$btnTest.Add_Click({
    $cfg = Get-ProviderCfg $comboProv.SelectedIndex
    $k = $txtKey.Text.Trim()
    if (-not $k) { $k = Read-KeyFile $cfg.keyFile }
    if (-not $k) { $lblKeyState.Text = '先贴 key 再测'; $lblKeyState.ForeColor = $MUTED; return }
    $btnTest.Enabled = $false
    $lblKeyState.Text = '测…'
    $lblKeyState.ForeColor = $MUTED
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $r = Test-ApiKey $cfg.baseUrl $cfg.model $k
        $lblKeyState.Text = $r.msg
        $lblKeyState.ForeColor = if ($r.ok) { $OKC } else { $BADC }
        Write-Log ('—— 测 key（' + $cfg.label + '）：' + $r.msg)
    } finally { $btnTest.Enabled = $true }
})

$btnSaveKey.Add_Click({
    $ok = Save-ApiKey
    Refresh-KeyHint
    if ($ok) { $lblKeyState.Text = '存好了'; $lblKeyState.ForeColor = $OKC }
})

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
    Load-KeyState
    Run-Checks
    Show-Status
})

if ($Close) { $form.WindowState = 'Minimized' }
[void]$form.ShowDialog()
