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
    [switch]$Close,
    [switch]$Check      # 自检：只把"它认的项目根"写出来就退出（打出来的 exe 也用它验）
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# PS 5.1 默认协议可能还停在 TLS 1.0，测 key 的 https 请求要 1.2
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$ErrorActionPreference = 'Continue'

# 项目根不能靠"往上两级"硬算：ps2exe 打出来的 exe 里 $PSScriptRoot 是**空的**（实测），
# 摆进 dist\ 时上一版算出来的项目根也不对 —— 整个界面会认错项目（查的环境是别人的、启动的也不是这套）。
# 所以先把自己在哪搞清楚，再往上找标记：谁下面有 dafeiyu\tools\setup-ui.ps1，谁就是项目根。
$SELF_DIR = $PSScriptRoot
if (-not $SELF_DIR) {
    # exe 里没有 $PSScriptRoot：拿当前进程的可执行文件路径
    try { $SELF_DIR = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
}
if (-not $SELF_DIR) {
    try { $SELF_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { }
}
if (-not $SELF_DIR) { $SELF_DIR = (Get-Location).Path }

function Find-Project([string]$start) {
    $d = $start
    for ($i = 0; $i -lt 6; $i++) {
        if ($d -and (Test-Path (Join-Path $d 'dafeiyu\tools\setup-ui.ps1'))) { return $d }
        if (-not $d) { break }
        $d = Split-Path -Parent $d
        if (-not $d) { break }
    }
    return (Split-Path -Parent (Split-Path -Parent $start))   # 找不到就退回老算法
}
$PROJECT = Find-Project $SELF_DIR
$TOOLS   = Join-Path $PROJECT 'dafeiyu\tools'
$MACHINE_FILE = Join-Path $PROJECT 'dafeiyu\state\machine.json'
$LOG_DIR = Join-Path $PROJECT 'dafeiyu\state'

if ($Check) {
    $line = 'PROJECT=' + $PROJECT + "`r`nTOOLS=" + $TOOLS + "`r`nSELF_DIR=" + $SELF_DIR + "`r`nPSScriptRoot=" + $PSScriptRoot
    try { [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'dfy-exe-check.txt'), $line, (New-Object System.Text.UTF8Encoding($true))) } catch { }
    # 这条路不 Write-Output：ps2exe 的 exe 是没有控制台的 WinForms 宿主，
    # 往不存在的 stdout 写会把进程挂住（实测：文件写出来了，进程一直不退，还把 exe 锁死）。
    # 退出用 Environment.Exit —— 光写 exit 0 宿主也不退。
    [System.Environment]::Exit(0)
}

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

# ================================================================
# 找不到项目时：先把仓库拉下来（2026-10-20 深夜他要的）
#   单下一个 exe 什么都做不了 —— 它只是界面，脚本、补丁、记忆模板都在仓库里。
#   所以自己先判断"我在不在一个仓库里"，不在的话先问一句"装到哪"，把 zip 拉下来解开，
#   再从那个新目录里把真正的部署界面叫起来。**这条路上不需要 git**（zip 下载 + Expand-Archive）。
# ================================================================
function Test-ProjectAt([string]$p) {
    if (-not $p) { return $false }
    # 判断"这是不是一个已经装好的大肥鱼"：**只要有 start-dafeiyu.ps1 和这份界面**就算。
    # 2026-10-21 改：原来还要 install.ps1 —— 但**跑起来的那份工作区**（他自己的这台）没有 install.ps1
    # （那份只在仓库 clone 里），结果桌宠右键「打开配置」一按就弹"先把它自己拉下来"，等于没配。
    # install.ps1 只有「开始安装」那一步要用，缺了在那一步说清楚就行。
    return ((Test-Path (Join-Path $p 'dafeiyu\tools\start-dafeiyu.ps1')) -and
        (Test-Path (Join-Path $p 'dafeiyu\tools\setup-ui.ps1')))
}

$ZIP_URL = 'https://codeload.github.com/oldhan13/dsh-dafeiyu/zip/refs/heads/main'

function Show-Bootstrap {
    # 这一屏在 New-Label / New-Button 定义之前就跑了（它们在主窗建完之后才定义），
    # 所以这里自带两个极小的替代，别去调下面那些。
    function BLabel($p, [string]$t, [int]$x, [int]$y, [int]$w, [int]$h, $f, $c) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $t
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, $h)
        $l.Font = $f
        $l.ForeColor = $c
        $l.BackColor = [System.Drawing.Color]::Transparent
        $p.Controls.Add($l)
        return $l
    }
    function BButton($p, [string]$t, [int]$x, [int]$y, [int]$w, [switch]$Primary) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $t
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
        $p.Controls.Add($b)
        return $b
    }

    $bf = New-Object System.Windows.Forms.Form
    $bf.Text = '大肥鱼 · 第一次用'
    $bf.Size = New-Object System.Drawing.Size(560, 380)
    $bf.StartPosition = 'CenterScreen'
    $bf.BackColor = $BG
    $bf.FormBorderStyle = 'FixedSingle'
    $bf.MaximizeBox = $false
    $bf.Font = $fBody

    BLabel $bf '先把它自己拉下来' 24 18 400 30 $fTitle $INK | Out-Null
    BLabel $bf '你现在手里只有这个 exe。它只是界面 —— 脚本、补丁、记忆模板都在仓库里，得先有一份。' 24 52 500 40 $fSub $MUTED | Out-Null
    BLabel $bf '装到哪个目录' 24 100 120 18 $fSub $MUTED | Out-Null

    $txDir = New-Object System.Windows.Forms.TextBox
    $txDir.Location = New-Object System.Drawing.Point(24, 120)
    $txDir.Size = New-Object System.Drawing.Size(390, 26)
    $txDir.Font = $fBody
    $txDir.Text = (Join-Path $env:USERPROFILE 'dafeiyu')
    $bf.Controls.Add($txDir)

    $btnBrowse = BButton $bf '换个位置…' 424 118 100
    $txProxy = New-Object System.Windows.Forms.TextBox
    $txProxy.Location = New-Object System.Drawing.Point(24, 168)
    $txProxy.Size = New-Object System.Drawing.Size(240, 26)
    $txProxy.Font = $fMono
    $bf.Controls.Add($txProxy)
    BLabel $bf '代理（下载不动时填，例如 http://127.0.0.1:7897；留空 = 直连）' 24 148 480 18 $fSub $MUTED | Out-Null

    $btnGo = BButton $bf '下载并继续' 24 206 130 -Primary
    $btnGo.Font = $fBody

    $log = New-Object System.Windows.Forms.TextBox
    $log.Location = New-Object System.Drawing.Point(24, 250)
    $log.Size = New-Object System.Drawing.Size(500, 76)
    $log.Multiline = $true
    $log.ScrollBars = 'Vertical'
    $log.ReadOnly = $true
    $log.Font = $fMono
    $log.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 253)
    $bf.Controls.Add($log)

    function Say2([string]$m) {
        $log.AppendText($m + "`r`n")
        $log.SelectionStart = $log.TextLength
        $log.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    $btnBrowse.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = '选一个空目录（不存在也行，会自动建）'
            if ($dlg.ShowDialog() -eq 'OK') { $txDir.Text = $dlg.SelectedPath }
        })

    $btnGo.Add_Click({
            $btnGo.Enabled = $false
            try {
                $dest = $txDir.Text.Trim()
                if (-not $dest) { Say2 '先选个目录。'; return }
                # 已经有一份完整的仓库，就别重复下载
                if (Test-ProjectAt $dest) {
                    Say2 ('这个目录里已经有一份了，直接接着装：' + $dest)
                    $entry = Join-Path $dest 'dafeiyu\tools\setup-ui.ps1'
                    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entry
                    [System.Environment]::Exit(0)
                }
                if ((Test-Path $dest) -and @(Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue).Count -gt 0) {
                    Say2 '这个目录不是空的 —— 换个空的，免得把里面的东西搅乱。'
                    return
                }
                $proxy = $txProxy.Text.Trim()
                $tmp = Join-Path $env:TEMP ('dfy-repo-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                $zip = Join-Path $tmp 'repo.zip'
                Say2 '下载中…（约 1 MB，慢的话等一会儿）'
                $args2 = @{ Uri = $ZIP_URL; OutFile = $zip; UseBasicParsing = $true; TimeoutSec = 180 }
                if ($proxy) { $args2['Proxy'] = $proxy }
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest @args2
                Say2 ('下载好了：' + [int]((Get-Item $zip).Length / 1024) + ' KB')
                $ex = Join-Path $tmp 'x'
                Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
                $inner = Get-ChildItem -LiteralPath $ex -Directory | Select-Object -First 1
                if (-not $inner) { Say2 '解压出来是空的 —— 下载到的东西不对。'; return }
                Say2 '解开中…'
                if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Force -Recurse -ErrorAction SilentlyContinue }
                $parent = Split-Path -Parent $dest
                if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Move-Item -LiteralPath $inner.FullName -Destination $dest -Force
                Remove-Item -LiteralPath $tmp -Force -Recurse -ErrorAction SilentlyContinue
                if (-not (Test-ProjectAt $dest)) { Say2 '装出来的目录不对：里面没有 install.ps1。'; return }
                Say2 ('好了：' + $dest)
                Say2 '接着开部署界面…'
                Start-Sleep -Milliseconds 300
                $entry = Join-Path $dest 'dafeiyu\tools\setup-ui.ps1'
                Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entry
                [System.Environment]::Exit(0)
            } catch {
                Say2 ('没成：' + $_.Exception.Message)
                Say2 '（也可以自己去 GitHub 下载 zip 解开，再双击里面的 setup.cmd）'
            } finally {
                $btnGo.Enabled = $true
            }
        })

    [void]$bf.ShowDialog()
    [System.Environment]::Exit(0)
}

# 只有"确实不在仓库里"才走这条路；-Check 已经在上头退了，不会再弹窗。
if (-not (Test-ProjectAt $PROJECT)) { Show-Bootstrap }

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
$btnExt     = New-Button $form '拓展模块…' 526 734 150
$btnClose   = New-Button $form '关闭' 720 734 116
# 「检查更新」（2026-10-21 他要的）：放在标题右边那一角 —— 它是个次要动作，
# 不该跟「一键启动」抢底下一整排的位置。
$btnUpd     = New-Button $form '检查更新' 700 14 132 34

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
function Invoke-PsFile([string]$ps1, [string]$extra, [int]$Minutes = 6) {
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
    $deadline = (Get-Date).AddMinutes($Minutes)
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
  try {
    $listEnv.Items.Clear()
    $lblEnvHint.Text = '检查中…'
    [System.Windows.Forms.Application]::DoEvents()

    function Add-Check([string]$text, [bool]$ok, [string]$detail) {
        $mark = if ($ok) { '✓' } else { '✗' }
        $line = if ($detail) { "$mark  $text —— $detail" } else { "$mark  $text" }
        [void]$listEnv.Items.Add($line)
        [System.Windows.Forms.Application]::DoEvents()
    }

    # 第一项就查「我在不在一个项目里」。单独下载的 exe 会算出离奇的 PROJECT（实测裸跑是 C:\），
    # 后面每一行都可能是勾，点「开始安装」才失败 —— 那太晚了，也看不出为什么。
    $okProj = (Test-Path (Join-Path $TOOLS 'start-dafeiyu.ps1'))
    $hasInstall = Test-Path (Join-Path $PROJECT 'install.ps1')
    Add-Check '项目目录' $okProj $(if ($okProj) { $PROJECT } else { '这里不是大肥鱼的工作区：先把这个仓库 clone 下来，再把 exe 放进 dist\ 或根目录（算出来是 ' + $PROJECT + '）' })
    if (-not $hasInstall) { Add-Check 'install.ps1' $true '没有（不是从仓库 clone 的那份）—— 只影响「开始安装」那一步，其余照常用' }
    if ($btnInstall) {
        $btnInstall.Enabled = $okProj
        $btnInstall.Text = if (-not $okProj) { '先放回工作区' } elseif (-not $hasInstall) { '这里装不了（没 install.ps1）' } else { '开始安装' }
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

    # 别直接 `& dsh --version`：npm 装出来的 dsh 是个 .ps1 中间层，
    # 从 exe（ps2exe 宿主跑在 Restricted）里调它会被挡，弹一个「禁止运行脚本」的模态框 —— 第一屏就卡死（实测）。
    # 走 cmd /c 用 dsh.cmd 那一份，跟执行策略无关。
    $dv = ''
    try { $dv = [string](cmd /c 'dsh --version 2>nul') } catch { }
    if ($dv -and $dv.Trim()) {
        Add-Check ('DSH ' + $dv.Trim()) $true ''
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

    # NapCat 装在哪因机器而异：先看 machine.json / 环境变量，再退到两个常见位置。
    $mNapcat = ''
    if (Test-Path $MACHINE_FILE) {
        try { $m2 = Get-Content $MACHINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json; if ($m2.napcatExe) { $mNapcat = [string]$m2.napcatExe } } catch { }
    }
    $napcat = @(
        $env:DAFEIYU_NAPCAT_EXE,
        $mNapcat,
        (Join-Path $env:LOCALAPPDATA 'NapCat\NapCatWinBootMain.exe'),
        (Join-Path $env:USERPROFILE 'NapCat\NapCatWinBootMain.exe')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    Add-Check 'NapCat（接 QQ 才需要）' $true $(if ($napcat) { $napcat } else { '没找到 —— 不接 QQ 可以不管' })

    $cfgNow = Get-ProviderCfg $comboProv.SelectedIndex
    $kk = Read-KeyFile $cfgNow.keyFile
    Add-Check ('模型 key（' + $cfgNow.label + '）') ($kk.Length -gt 10) $(if ($kk.Length -gt 10) { '已有，点「测一下」确认能真用' } else { '还没有 —— 贴到卡片 ③ 里保存' })

  } catch {
    # 某一项检测自己炸了，不该弹模态框把整屏锁住（exe 里真踩过：dsh 那行弹「禁止运行脚本」）
    try { Add-Check '检测中途出错' $false $_.Exception.Message } catch { }
  }
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

# ================================================================
# 拓展模块（2026-10-21 他要的）
#
#   他原话：「给我们配置的 GUI 界面增加一个『拓展模块』选项，里面有包括刷 B 站、生图等在内、
#   需要额外配置的非必须功能」。
#
#   三条设计，改这个面板前先看：
#   ① **模块是一张表**（$EXT_MODULES），加一个模块就往表里加一行，别写成四段胶水。
#   ② 状态**只用本地事实**判断（文件在不在、端口通不通），不发网络请求 ——
#      点开就是准的，也不会因为在墙外卡十秒。
#   ③ 动作全部落在**已有的真实脚本**上，界面里不另写一套逻辑：
#        生图 → tools\comfyui-install.mjs（安装/补齐）+ tools\draw-once.mjs（画一张）
#        B站  → ~\.dsh\bili-duty（日报 / config.json / 扫码图都在那儿）
#        语音 → tools\speak-play.ps1（脱管进程，界面不卡；中文走 UTF-8 文件，不过命令行）
#      ⇒ 以后脚本改了，这个界面不用跟着改。
# ================================================================

$BILI_DIR    = Join-Path $env:USERPROFILE '.dsh\bili-duty'
$COMFY_ROOT  = if ($env:COMFY_ROOT) { $env:COMFY_ROOT } else { 'D:\ComfyUI' }
$SILICON_KEY = Join-Path $env:USERPROFILE '.dsh\siliconflow-key.txt'

# ---- 语音通话（2026-10-26 他要的：把通话的配置和模型选择接进这个界面）----
# ★ 老规矩：界面**不自己发明**——后端有几个、每个后端有哪些参数、耳朵能选哪些模型，
#   全部问 `tools\call\config.py --json`；装/检查/试听/重启耳朵全部调它旁边那几个脚本。
#   所以引擎升级了（比如以后多一个后端），这个界面**不用改**就会多出一个选项。
$CALL_DIR   = Join-Path $TOOLS 'call'
$CALL_CFG   = Join-Path $CALL_DIR 'config.py'
$CALL_BOOT  = Join-Path $CALL_DIR 'bootstrap.py'
$CALL_TEST  = Join-Path $CALL_DIR 'voice-test.py'
$CALL_STATE = Join-Path $PROJECT 'dafeiyu\state\call'
$CALL_CHECK = Join-Path $CALL_STATE 'bootstrap-check.json'

# 跑通话那套用哪个 python。
# ★ 规矩写在 tools\call\bootstrap.py 的 target_python() 里，两边必须一致：
#   有 .venv **且依赖装齐过**（.venv\.deps-ok 记号）就用它，否则用 PATH 里的 python。
#   为什么不是"有 .venv 就用"：这台机器上就留着半个 .venv（只有 numpy），
#   照那条起会让一通本来能用的电话当场 import 失败。
function Get-CallPython {
    $venvPy = Join-Path $CALL_DIR '.venv\Scripts\python.exe'
    $mark = Join-Path $CALL_DIR '.venv\.deps-ok'
    if ((Test-Path $venvPy) -and (Test-Path $mark)) {
        return [pscustomobject]@{ exe = $venvPy; pre = @(); venv = $true }
    }
    $c = Get-Command python -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return [pscustomobject]@{ exe = $c.Source; pre = @(); venv = $false } }
    $p = Get-Command py -ErrorAction SilentlyContinue
    if ($p -and $p.Source) { return [pscustomobject]@{ exe = $p.Source; pre = @('-3'); venv = $false } }
    return $null
}

# 跑一个外部命令，把输出一行行喂给 $Sink（界面不许卡住 —— 装依赖要好几分钟）。
# 和 Invoke-NodeFile 同一个套路，只是不绑死 node。
function Invoke-Stream([string]$exe, [string[]]$argv, [scriptblock]$Sink, [int]$Minutes = 30) {
    $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $all = @((& $q $exe)) + @($argv | ForEach-Object { & $q $_ })
    $tmp = Join-Path $env:TEMP ('dfy-run-' + [guid]::NewGuid().ToString('N') + '.log')
    # ★ 先把这个子 powershell 的「解码外来输出用哪套编码」设成 UTF-8：
    #   不设的话它按 ACP=936 去解码 python / node 吐出来的 UTF-8 字节，中文全成乱码
    #   （这一步比什么都有用 —— 界面里满屏「锟斤拷」的根源就在这儿）。
    $inner = '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & ' + ($all -join ' ') +
        ' 2>&1 | Out-File -FilePath ' + (& $q $tmp) + ' -Encoding utf8'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'
    $psi.WorkingDirectory = $CALL_DIR
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)

    $printed = 0
    $read = {
        param($file, $done)
        try {
            if (-not (Test-Path $file)) { return $done }
            $txt = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
            if ($txt.Length -gt $done) {
                $chunk = $txt.Substring($done).TrimEnd()
                if ($chunk -and $Sink) { & $Sink $chunk }
                return $txt.Length
            }
        } catch { }
        return $done
    }
    $deadline = (Get-Date).AddMinutes($Minutes)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        [System.Windows.Forms.Application]::DoEvents()
        $printed = & $read $tmp $printed
    }
    [void]$p.WaitForExit(8000)
    Start-Sleep -Milliseconds 150
    [void](& $read $tmp $printed)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $p.ExitCode
}

# id / 标题 / 一句话 / 需要什么 / 卡高。加模块只加这一行。
$EXT_MODULES = @(
    [ordered]@{ id = 'bili'; title = '刷 B 站'; h = 124; desc = '她每天谷时自己刷一轮，把值当的挑出来写成日报 —— 她看，不打扰你。'; need = '需要：一个 Python 环境（自动建）+ B 站扫码登录一次' }
    [ordered]@{ id = 'comfy'; title = '生图'; h = 124; desc = '她能用这块显卡画图，说一句就出图，十几秒一张。'; need = '需要：约 24 GB 磁盘、8 GB 以上显存；装完常驻 8188' }
    [ordered]@{ id = 'voice'; title = '语音 · 念一句'; h = 124; desc = '让她把一句话念出来 —— 跟电话里是同一个声音（不是另配一套）。'; need = '需要：跟「语音通话」共用一份设置，音色去那里挑；只有 cloud / openai 才要 key' }
    [ordered]@{ id = 'call'; title = '语音通话 · 真的能聊'; h = 152; desc = '戴上耳机跟她说话：她听得见、答得出，声音从喇叭出来。桌宠和网页两个入口。'; need = '需要：Python 3.10+（装一次）。三步：① 装好它 ② 挑声音（能试听）③ 开通话窗' }
    [ordered]@{ id = 'sing'; title = '唱歌 · 把别人的唱换成她的嗓子'; h = 124; desc = '丢一段清唱进去，只换音色 —— 旋律和换气都留在原唱上，所以听着像真人在唱。'; need = '需要：约 1.2 GB 权重 + 一张能跑 torch 的显卡；不用训练' }
    [ordered]@{ id = 'qq'; title = 'QQ 通道'; h = 124; desc = '手机上也能找她 —— 小号挂在 NapCat 上，QQ 里说话她听得见。'; need = '需要：NapCat + 一个小号（主界面卡片 ② 填）' }
)

function Test-LocalPort([int]$port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(400)) { $c.Close(); return $false }
        $c.EndConnect($ar); $c.Close(); return $true
    } catch { return $false }
}

# 只看本地事实：不联网、不启动任何东西。
function Get-ExtStates {
    $st = @{}

    $py = Join-Path $BILI_DIR '.venv\Scripts\python.exe'
    $cred = Join-Path $BILI_DIR 'bili_credential.json'
    $logged = $false
    if (Test-Path $cred) {
        try {
            $cc = Get-Content $cred -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cc.sessdata -and $cc.bili_jct) { $logged = $true }
        } catch { }
    }
    $st.bili = [ordered]@{
        venv  = [bool](Test-Path $py)
        login = $logged
        today = [bool](Test-Path (Join-Path $BILI_DIR ('out\' + (Get-Date).ToString('yyyy-MM-dd') + '.md')))
    }

    $models = Join-Path $COMFY_ROOT 'app\ComfyUI\models'
    $st.comfy = [ordered]@{
        app    = [bool](Test-Path (Join-Path $COMFY_ROOT 'app\ComfyUI\main.py'))
        models = ([bool](Test-Path (Join-Path $models 'diffusion_models\flux1-schnell-fp8.safetensors'))) -and
                 ([bool](Test-Path (Join-Path $models 'vae\ae.safetensors')))
        up     = (Test-LocalPort 8188)
    }

    $kl = 0
    if (Test-Path $SILICON_KEY) { try { $kl = ([System.IO.File]::ReadAllText($SILICON_KEY)).Trim().Length } catch { } }
    $ol = 0
    $OPENAI_KEY = Join-Path $env:USERPROFILE '.dsh\openai-key.txt'
    if (Test-Path $OPENAI_KEY) { try { $ol = ([System.IO.File]::ReadAllText($OPENAI_KEY)).Trim().Length } catch { } }
    $st.voice = [ordered]@{
        script    = [bool](Test-Path (Join-Path $TOOLS 'speak-play.ps1'))
        key       = [bool]($kl -gt 10)      # 硅基流动（cloud 后端用）
        openaiKey = [bool]($ol -gt 10)      # OpenAI（openai 后端用）
    }

    $nap = ''; $bot = ''
    if (Test-Path $MACHINE_FILE) {
        try {
            $mj = Get-Content $MACHINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($mj.napcatExe) { $nap = [string]$mj.napcatExe }
            if ($mj.botQQ) { $bot = [string]$mj.botQQ }
        } catch { }
    }
    $st.qq = [ordered]@{
        nap = [bool]($nap -and (Test-Path $nap))
        bot = $bot
    }
    $st.napPath = $nap

    # 语音通话。★ 这里只读**本地事实**：配置文件、检查缓存、端口通不通。
    #   不在这里起 python —— 起一个 python 要一秒多，点开模块窗口不该等它。
    #   要真验一遍（import 一下那些包）有专门的按钮，那时才跑。
    $be = 'piper'; $asrModel = 'small'; $sovPort = 9880; $asrPort = 9890
    $cfgj = Join-Path $CALL_STATE 'config.json'
    if (Test-Path $cfgj) {
        try {
            $cj = Get-Content $cfgj -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cj.tts.backend) { $be = [string]$cj.tts.backend }
            if ($cj.asr.model) { $asrModel = [string]$cj.asr.model }
            if ($cj.tts.sovits.port) { $sovPort = [int]$cj.tts.sovits.port }
            if ($cj.asr.port) { $asrPort = [int]$cj.asr.port }
        } catch { }
    }
    # 标签（「她自己的声音」这种）只有 config.py 知道 —— 它上次跑完留了一份在这里。
    $labels = @{}
    $uif = Join-Path $CALL_STATE 'ui-cache.json'
    if (Test-Path $uif) {
        try {
            $uj = Get-Content $uif -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($b in $uj.backends) { $labels[[string]$b.id] = [string]$b.label }
        } catch { }
    }
    $chk = $null
    if (Test-Path $CALL_CHECK) { try { $chk = Get-Content $CALL_CHECK -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $st.call = [ordered]@{
        backend   = $be
        backLabel = $(if ($labels.ContainsKey($be)) { $labels[$be] } else { $be })
        asrModel  = $asrModel
        py        = (Get-CallPython)
        files     = [bool]((Test-Path $CALL_CFG) -and (Test-Path $CALL_BOOT) -and (Test-Path $CALL_TEST))
        check     = $chk
        sovitsUp  = (Test-LocalPort $sovPort)
        asrUp     = (Test-LocalPort $asrPort)
        sovPort   = $sovPort
        asrPort   = $asrPort
    }

    # 唱歌（2026-10-28 加的）：跟通话一样，只读本地事实 —— 文件在不在，绝不在界面里起 python。
    #   设置是 state\call\sing.json；成品路径记在 state\call\sing-last.txt（sing.py 不写这个，
    #   由界面这边在跑完之后自己记，免得 sing.py 为了界面多长一条依赖）。
    $sgRoot = ''; $sgPy = ''; $sgRef = ''; $sgSteps = 30; $sgSemi = 0
    $singCfg = Join-Path $CALL_STATE 'sing.json'
    if (Test-Path $singCfg) {
        try {
            $sj = Get-Content $singCfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($sj.seedvc_root) { $sgRoot = [string]$sj.seedvc_root }
            if ($sj.python) { $sgPy = [string]$sj.python }
            if ($sj.reference) { $sgRef = [string]$sj.reference }
            if ($null -ne $sj.steps) { $sgSteps = [int]$sj.steps }
            if ($null -ne $sj.semitones) { $sgSemi = [int]$sj.semitones }
        } catch { }
    }
    $sgHasModel = $false
    if ($sgRoot) {
        $sgHasModel = Test-Path (Join-Path $sgRoot 'checkpoints\DiT_seed_v2_uvit_whisper_base_f0_44k_bigvgan_pruned_ft_ema_v2.pth')
    }
    $sgLast = ''
    $sgLastFile = Join-Path $CALL_STATE 'sing-last.txt'
    if (Test-Path $sgLastFile) { try { $sgLast = (Get-Content $sgLastFile -Raw -Encoding UTF8).Trim() } catch { } }
    $st.sing = [ordered]@{
        model  = $sgHasModel
        python = [bool]($sgPy -and (Test-Path $sgPy))
        ref    = [bool]($sgRef -and (Test-Path $sgRef))
        root   = $sgRoot
        pyPath = $sgPy
        refPath = $sgRef
        steps  = $sgSteps
        semi   = $sgSemi
        last   = $sgLast
    }
    return $st
}

# 跑一个 .mjs：跟 Invoke-PsFile 一样的临时日志增量读法（同步 ReadLine 会让界面像死了）。
#
# $Sink：这行输出往哪打。拓展模块那个窗口是模态的 —— 它盖住主窗，
# 如果把输出写进主窗的「过程」里，人一个字都看不见（实测：点「画一张」，报错跑到背后去了）。
# 所以调用方传自己的 ELog 进来。
function Invoke-NodeFile([string]$js, [string[]]$argList, [int]$Minutes = 30, [scriptblock]$Sink = $null) {
    $node = 'node'
    try { $nc = Get-Command node -ErrorAction Stop; if ($nc.Source) { $node = $nc.Source } } catch { }
    $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $argv = @((& $q $node), (& $q $js))
    foreach ($a in $argList) { if ($a) { $argv += (& $q $a) } }
    $tmp = Join-Path $env:TEMP ('dfy-node-' + [guid]::NewGuid().ToString('N') + '.log')
    $inner = '& ' + ($argv -join ' ') + ' 2>&1 | Out-File -FilePath ' + (& $q $tmp) + ' -Encoding utf8'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'
    $psi.WorkingDirectory = $PROJECT
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)

    $printed = 0
    $deadline = (Get-Date).AddMinutes($Minutes)
    # 增量读：自己读，不借 Read-NewLog（那个写死在主窗的日志框里）
    $read = {
        param($file, $done)
        try {
            if (-not (Test-Path $file)) { return $done }
            $all = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
            if ($all.Length -gt $done) {
                $chunk = $all.Substring($done).TrimEnd()
                if ($chunk) {
                    if ($Sink) { & $Sink $chunk } else { Write-Log $chunk }
                }
                return $all.Length
            }
        } catch { }
        return $done
    }
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.Application]::DoEvents()
        $printed = & $read $tmp $printed
    }
    [void]$p.WaitForExit(5000)
    $printed = & $read $tmp $printed
    Start-Sleep -Milliseconds 150
    [void](& $read $tmp $printed)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $p.ExitCode
}

# 放一段试听出来的 wav。
# System.Media.SoundPlayer 只吃 PCM wav —— voice-test.py 落的正是 PCM16，所以不用转码。
# ★ 用 Play()（不阻塞）而不是 PlaySync()：念的时候界面还能点别的。
# ★ player 必须存进 script 作用域：局部变量一旦被回收，声音会当场断。
$script:callPlayer = $null
function Play-CallWav([string]$jsonFile) {
    if (-not (Test-Path $jsonFile)) { return $false }
    try { $j = Get-Content $jsonFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $false }
    if (-not $j.wav) { return $false }
    if (-not (Test-Path $j.wav)) { return $false }
    try {
        $script:callPlayer = New-Object System.Media.SoundPlayer -ArgumentList $j.wav
        $script:callPlayer.Play()
    } catch { return $false }
    return $true
}

function Show-Extensions {
    $x = New-Object System.Windows.Forms.Form
    $x.Text = '大肥鱼 · 拓展模块'
    $x.Size = New-Object System.Drawing.Size(880, 780)
    $x.StartPosition = 'CenterParent'
    $x.BackColor = $BG
    $x.FormBorderStyle = 'FixedSingle'
    $x.MaximizeBox = $false
    $x.Font = $fBody

    New-Label $x '拓展模块' 24 12 300 32 $fTitle $INK | Out-Null
    New-Label $x '这些都不是必须的。不装，她只是少一样本事；装了的，各要一份自己的配置。' 24 46 820 20 $fSub $MUTED | Out-Null

    $script:extLbl = @{}
    $script:extLog = $null

    # 卡片区做成**可滚动**（2026-10-26）：模块从四个变成五个，再往上还会多。
    # 窗口高度不该跟着模块数长 —— 它一长，小屏幕上就有一半点不到。
    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Location = New-Object System.Drawing.Point(24, 70)
    $scroll.Size = New-Object System.Drawing.Size(824, 518)
    $scroll.BackColor = $BG
    $scroll.AutoScroll = $true
    $x.Controls.Add($scroll)

    function New-ExtCard([int]$y, [int]$h) {
        $p = New-Object System.Windows.Forms.Panel
        $p.Location = New-Object System.Drawing.Point(0, $y)
        $p.Size = New-Object System.Drawing.Size(800, $h)
        $p.BackColor = $CARD
        $p.BorderStyle = 'FixedSingle'
        $scroll.Controls.Add($p)
        return $p
    }

    function ELog([string]$s) {
        if (-not $s) { return }
        if ($script:extLog) {
            $script:extLog.AppendText($s + "`r`n")
            $script:extLog.SelectionStart = $script:extLog.TextLength
            $script:extLog.ScrollToCaret()
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    function Set-Stat([string]$id, [string]$text, [string]$badge, [string]$color) {
        if ($script:extLbl.ContainsKey($id + 'Stat')) {
            $script:extLbl[$id + 'Stat'].Text = $text
            $script:extLbl[$id + 'Stat'].ForeColor = [System.Drawing.ColorTranslator]::FromHtml($color)
        }
        if ($script:extLbl.ContainsKey($id + 'Badge')) {
            $script:extLbl[$id + 'Badge'].Text = $badge
            $script:extLbl[$id + 'Badge'].ForeColor = [System.Drawing.ColorTranslator]::FromHtml($color)
        }
    }

    function Update-ExtAll {
        $s = Get-ExtStates
        $mk = { param($ok) if ($ok) { '✓' } else { '✗' } }

        # 刷 B 站
        $okB = ($s.bili.venv -and $s.bili.login)
        $txtB = ('环境 ' + (& $mk $s.bili.venv) + ' · 已登录 ' + (& $mk $s.bili.login) + ' · 今天的日报 ' + (& $mk $s.bili.today))
        $colB = if ($okB -and $s.bili.today) { '#15803d' } elseif ($okB) { '#6b7280' } elseif ($s.bili.venv -or $s.bili.login) { '#b91c1c' } else { '#6b7280' }
        $badB = if ($okB) { '已装好' } elseif ($s.bili.venv -or $s.bili.login) { '缺一项' } else { '没装' }
        Set-Stat 'bili' $txtB $badB $colB

        # 生图
        $okC = ($s.comfy.app -and $s.comfy.models)
        # ⚠️ PS 5.1 里 `if` 是语句不是表达式 —— 塞进字符串拼接会报「无法将 if 识别为 cmdlet」，先算进变量。
        $upTxt = '没起'
        if ($s.comfy.up) { $upTxt = '在跑' }
        $txtC = ('程序 ' + (& $mk $s.comfy.app) + ' · 模型 ' + (& $mk $s.comfy.models) + ' · 8188 ' + $upTxt)
        $colC = if ($okC) { '#15803d' } elseif ($s.comfy.app -or $s.comfy.models) { '#b91c1c' } else { '#6b7280' }
        $badC = if ($okC) { '已装好' } elseif ($s.comfy.app -or $s.comfy.models) { '缺一项' } else { '没装' }
        Set-Stat 'comfy' $txtC $badC $colC

        # 语音通话（先算：下面「语音」那一块要借它的结果）
        $c = $s.call
        $okCall = [bool]($c.py -and $c.check -and $c.check.ok)
        $pyTxt = '没有 Python'
        if ($c.py) {
            $pyTxt = '用系统的 python'
            if ($c.py.venv) { $pyTxt = '用 .venv' }
        }
        $chkTxt = '没验过'
        if ($c.check) {
            $chkTxt = '还缺东西'
            if ($c.check.ok) { $chkTxt = '装好了' }
        }
        $sovTxt = '没起'
        if ($c.sovitsUp) { $sovTxt = '在跑' }
        $asrTxt = '没起'
        if ($c.asrUp) { $asrTxt = '在听' }
        $txtCall = ('通话 ' + $pyTxt + ' · 依赖 ' + $chkTxt + ' · 音色 ' + $c.backLabel +
            ' · 耳朵 ' + $c.asrModel + '（' + $asrTxt + '） · 嘴 ' + $c.sovPort + ' ' + $sovTxt)
        $colCall = '#6b7280'
        $badCall = '没装'
        if (-not $c.py) { $badCall = '缺 Python' }
        elseif ($okCall) { $colCall = '#15803d'; $badCall = '已装好' }
        elseif ($c.check) { $colCall = '#b91c1c'; $badCall = '缺东西' }
        elseif ($c.py) { $colCall = '#6b7280'; $badCall = '没验过' }
        Set-Stat 'call' $txtCall $badCall $colCall

        # 唱歌 · 换音色（2026-10-28 他要的：把唱歌并进「配置的拓展」）
        $sg = $s.sing
        $lastLeaf = '没唱过'
        if ($sg.last) { $lastLeaf = Split-Path $sg.last -Leaf }
        $txtSg = ('权重 ' + (& $mk $sg.model) + ' · Python ' + (& $mk $sg.python) +
            ' · 参考音色 ' + (& $mk $sg.ref) + ' · 上次 ' + $lastLeaf)
        $okSg = [bool]($sg.model -and $sg.python -and $sg.ref)
        $colSg = '#6b7280'
        $badSg = '没配'
        if ($okSg) { $colSg = '#15803d'; $badSg = '能唱' }
        elseif ($sg.model -or $sg.python -or $sg.ref) { $colSg = '#b91c1c'; $badSg = '缺一项' }
        Set-Stat 'sing' $txtSg $badSg $colSg

        # 语音（念一句）—— ★ 2026-10-26 改：不再自己另算一套，
        #   跟「语音通话」**共用同一份设置**（音色、依赖都看 state\call\config.json）。
        #   从前它查的是 speak-play.ps1 + 硅基流动 key，和通话那套是两个说法；
        #   现在只补一句「这个音色要不要 key」。所以这两段顺序不能换。
        $needKey = ''
        $keyOk = $true
        if ($s.call.backend -eq 'cloud') { $keyOk = [bool]$s.voice.key; $needKey = ' · 硅基流动 key ' + (& $mk $keyOk) }
        if ($s.call.backend -eq 'openai') { $keyOk = [bool]$s.voice.openaiKey; $needKey = ' · OpenAI key ' + (& $mk $keyOk) }
        $okV = [bool]($s.call.py -and $okCall -and $keyOk)
        $txtV = ('音色 ' + $s.call.backLabel + ' · 依赖 ' + $chkTxt + $needKey)
        $colV = '#6b7280'
        $badV = '没装'
        if (-not $s.call.py) { $badV = '缺 Python' }
        elseif ($okV) { $colV = '#15803d'; $badV = '能用' }
        elseif ($s.call.check) { $colV = '#b91c1c'; $badV = '缺东西' }
        elseif ($s.call.py) { $badV = '没验过' }
        Set-Stat 'voice' $txtV $badV $colV

        # QQ
        $okQ = $s.qq.nap
        $botTxt = ' · 小号还没填'
        if ($s.qq.bot) { $botTxt = ' · 小号 ' + $s.qq.bot }
        $txtQ = ('NapCat ' + (& $mk $s.qq.nap) + $botTxt)
        $colQ = if ($okQ) { '#15803d' } else { '#6b7280' }
        $badQ = if ($okQ) { '在' } else { '没找到' }
        Set-Stat 'qq' $txtQ $badQ $colQ
    }

    # ---- 卡片 ----
    # ⚠️ 循环变量叫 $pnl 不叫 $card：PowerShell 变量名**不分大小写**，$card 就是 $CARD（卡片底色那个颜色），
    #    第二张卡开始 $CARD 变成上一张 Panel ⇒ 每张卡都抛「无法将 …Panel 转换为 …Color」（实测踩过）。
    $y = 0
    foreach ($m in $EXT_MODULES) {
        $h = 124
        if ($m.h) { $h = [int]$m.h }
        $pnl = New-ExtCard $y $h
        New-Label $pnl $m.title 14 8 300 22 $fH $INK | Out-Null
        $bd = New-Label $pnl '' 690 8 106 22 $fSub $MUTED
        $bd.TextAlign = 'MiddleRight'
        $script:extLbl[$m.id + 'Badge'] = $bd
        New-Label $pnl $m.desc 14 28 776 18 $fSub $INK | Out-Null
        New-Label $pnl $m.need 14 46 776 18 $fSub $MUTED | Out-Null
        $stt = New-Label $pnl '' 14 64 776 20 $fSub $MUTED
        $script:extLbl[$m.id + 'Stat'] = $stt

        switch ($m.id) {
            'bili' {
                $b1 = New-Button $pnl '看今天的日报' 14 86 120
                $b2 = New-Button $pnl '打开目录' 142 86 100
                $b3 = New-Button $pnl '打开配置' 250 86 100
                # 「现在跑一轮」（2026-10-21 他要的）：不自己再造一套刷法 ——
                # 插件（dsh-bili-scroll）在宿主 3080 上已经开了 POST /api/bili-duty/run，
                # 它自己 spawn 一个 headless 会话、把 duty.md 交给它。这里只是按一下那个按钮。
                $b4 = New-Button $pnl '现在跑一轮' 358 86 110
                $b1.Add_Click({
                        $today = Join-Path $BILI_DIR ('out\' + (Get-Date).ToString('yyyy-MM-dd') + '.md')
                        if (Test-Path $today) { try { Start-Process $today } catch { } ; ELog '打开今天的日报' ; return }
                        $last = @(Get-ChildItem (Join-Path $BILI_DIR 'out') -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
                        if ($last.Count -gt 0) { try { Start-Process $last[0].FullName } catch { } ; ELog ('今天还没有，打开最近一份：' + $last[0].Name) }
                        else { ELog '一份日报都还没有 —— 她第一轮跑完才会有。' }
                    })
                $b2.Add_Click({ if (Test-Path $BILI_DIR) { Start-Process $BILI_DIR } else { ELog ('没有这个目录：' + $BILI_DIR) } })
                $b3.Add_Click({
                        $cfgp = Join-Path $BILI_DIR 'config.json'
                        if (Test-Path $cfgp) { try { Start-Process notepad.exe $cfgp } catch { } ; ELog '配置：' + $cfgp } else { ELog ('还没有配置文件：' + $cfgp) }
                    })
                $b4.Add_Click({
                        # 这一轮是**真的**：会去搜、会写日报，开着自动评论的话还会真的发到 B 站上。
                        $ask = [System.Windows.Forms.MessageBox]::Show(
                            '现在跑一轮会照设置里那档来 —— 你要是开着自动评论，这一轮就真会发到 B 站上去。' + "`r`n`r`n" + '跑吗？',
                            '跑一轮？',
                            [System.Windows.Forms.MessageBoxButtons]::YesNo,
                            [System.Windows.Forms.MessageBoxIcon]::Question)
                        if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { ELog '—— 嗯，没跑。'; return }
                        ELog '—— 让她现在跑一轮（后台 headless，几分钟；跑完今天的日报就有了）'
                        try {
                            $r = Invoke-RestMethod -Uri 'http://127.0.0.1:3080/api/bili-duty/run' -Method Post -TimeoutSec 20
                            if ($r.started) { ELog ('—— 开跑了 · profile ' + $r.profile + ' · 日志 ' + $r.log) }
                            else { ELog ('—— 没起来：' + $r.error) }
                        } catch {
                            ELog ('—— 宿主（3080）没应：' + $_.Exception.Message + '。先回主界面点「一键启动」')
                        }
                        Update-ExtAll
                    })
            }
            'comfy' {
                $b1 = New-Button $pnl '安装 / 补齐' 14 86 110
                $tp = New-Object System.Windows.Forms.TextBox
                $tp.Location = New-Object System.Drawing.Point(132, 88)
                $tp.Size = New-Object System.Drawing.Size(360, 26)
                $tp.Font = $fBody
                $tp.Text = 'a small orange fish swimming in dark water, soft rim light'
                $pnl.Controls.Add($tp)
                $b2 = New-Button $pnl '画一张' 500 86 90
                $b3 = New-Button $pnl '打开图目录' 598 86 110
                $b1.Add_Click({
                        ELog '—— 安装 / 补齐 ComfyUI（缺什么补什么，断了重跑会接着下；下面会一行一行出）'
                        $rc = Invoke-NodeFile (Join-Path $TOOLS 'comfyui-install.mjs') @() 180 -Sink ${function:ELog}
                        ELog ('—— 结束，退出码 ' + $rc + $(if ($rc -eq 0) { '（装好了）' } else { '（没装完，看上面最后几行）' }))
                        Update-ExtAll
                    })
                $b2.Add_Click({
                        $txt = $tp.Text.Trim()
                        if (-not $txt) { ELog '先写一句想画什么。'; return }
                        $tmp = Join-Path $env:TEMP ('dfy-prompt-' + [guid]::NewGuid().ToString('N') + '.txt')
                        [System.IO.File]::WriteAllText($tmp, $txt, (New-Object System.Text.UTF8Encoding($false)))
                        ELog ('—— 画：' + $txt)
                        $rc = Invoke-NodeFile (Join-Path $TOOLS 'draw-once.mjs') @('--file', $tmp, '--open') 12 -Sink ${function:ELog}
                        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                        if ($rc -ne 0) { ELog '—— 没画出来（看上面那行原因）' }
                        Update-ExtAll
                    })
                $b3.Add_Click({
                        $o = Join-Path $COMFY_ROOT 'output'
                        if (Test-Path $o) { Start-Process $o } else { ELog ('还没有出过图：' + $o) }
                    })
            }
            'voice' {
                # ★ 2026-10-26 改：念一句不再走 speak-play.ps1 那条老路（curl+ffmpeg），
                #   改走通话那套的 voice-test.py —— **跟电话里是同一个声音**。
                #   从前这里念出来的是一个声音、打电话又是另一个，谁也说不清哪个才算她。
                $tv = New-Object System.Windows.Forms.TextBox
                $tv.Location = New-Object System.Drawing.Point(14, 88)
                $tv.Size = New-Object System.Drawing.Size(330, 26)
                $tv.Font = $fBody
                $tv.Text = '我在。今天也在这儿。'
                $pnl.Controls.Add($tv)
                $b1 = New-Button $pnl '念这句' 352 86 90
                $b2 = New-Button $pnl '音色设置…' 450 86 110
                $b3 = New-Button $pnl '打开通话目录' 568 86 120
                $b1.Add_Click({
                        $cp = Get-CallPython
                        if (-not $cp) { ELog '还没有 Python —— 点「音色设置…」看第一步。'; return }
                        if (-not (Test-Path $CALL_TEST)) { ELog ('缺 ' + $CALL_TEST); return }
                        $txt = $tv.Text.Trim()
                        if (-not $txt) { ELog '先写一句要念的话。'; return }
                        # 中文不过命令行（ACP=936）—— 写文件，脚本自己读
                        $tf = Join-Path $env:TEMP ('dfy-saytxt-' + [guid]::NewGuid().ToString('N') + '.txt')
                        [System.IO.File]::WriteAllText($tf, $txt, (New-Object System.Text.UTF8Encoding($false)))
                        $jf = Join-Path $env:TEMP ('dfy-sayres-' + [guid]::NewGuid().ToString('N') + '.json')
                        ELog ('—— 念：' + $txt)
                        $rc = Invoke-Stream $cp.exe (@($cp.pre) + @($CALL_TEST, '--text-file', $tf, '--json-out', $jf)) ${function:ELog} 4
                        Remove-Item $tf -Force -ErrorAction SilentlyContinue
                        if ((Test-Path $jf) -and (Play-CallWav $jf)) {
                            try {
                                $j = Get-Content $jf -Raw -Encoding UTF8 | ConvertFrom-Json
                                ELog ('—— ' + $j.label + ' · ' + $j.dur_s + ' 秒 · 首块 ' + $j.first_ms + 'ms · RMS ' + $j.rms)
                            } catch { }
                        } elseif ($rc -ne 0) {
                            ELog '—— 没念出来（上面那几行是原因）'
                        }
                        Remove-Item $jf -Force -ErrorAction SilentlyContinue
                        Update-ExtAll
                    })
                $b2.Add_Click({ Show-CallSettings; Update-ExtAll })
                $b3.Add_Click({ if (Test-Path $CALL_DIR) { Start-Process $CALL_DIR } else { ELog ('没有这个目录：' + $CALL_DIR) } })
            }
            'call' {
                $b1 = New-Button $pnl '设置…' 14 86 110 -Primary
                $b2 = New-Button $pnl '试听一句' 132 86 100
                $b3 = New-Button $pnl '开通话窗' 240 86 110
                $b4 = New-Button $pnl '打开通话目录' 358 86 120
                New-Label $pnl '第一次用点「设置…」：它会把缺的装上、让你听几句再挑音色。' 14 124 700 20 $fSub $MUTED | Out-Null
                $b1.Add_Click({ Show-CallSettings; Update-ExtAll })
                $b2.Add_Click({
                        $cp = Get-CallPython
                        if (-not $cp) { ELog '还没有 Python —— 点「设置…」看第一步。'; return }
                        ELog '—— 试听（音色 = 配置里现在那个）'
                        $out = Join-Path $env:TEMP ('dfy-say-' + [guid]::NewGuid().ToString('N') + '.json')
                        $rc = Invoke-Stream $cp.exe (@($cp.pre) + @($CALL_TEST, '--json-out', $out)) ${function:ELog} 4
                        Play-CallWav $out
                        Remove-Item $out -Force -ErrorAction SilentlyContinue
                        if ($rc -ne 0) { ELog '—— 没合成出来（上面那几行是原因）' }
                        Update-ExtAll
                    })
                $b3.Add_Click({
                        $cc = Join-Path $PROJECT 'dafeiyu\pet\call.cmd'
                        if (-not (Test-Path $cc)) { ELog ('缺这个入口：' + $cc); return }
                        try { Start-Process -FilePath $cc -WorkingDirectory (Split-Path -Parent $cc); ELog '—— 通话窗开了（第一次开要等它把耳朵装上）' }
                        catch { ELog ('开不了：' + $_.Exception.Message) }
                        Update-ExtAll
                    })
                $b4.Add_Click({ if (Test-Path $CALL_DIR) { Start-Process $CALL_DIR } else { ELog ('没有这个目录：' + $CALL_DIR) } })
            }
            'sing' {
                $b1 = New-Button $pnl '设置…' 14 86 110 -Primary
                $b2 = New-Button $pnl '唱一段试试' 132 86 110
                $b3 = New-Button $pnl '打开上次的成品' 250 86 130
                $b4 = New-Button $pnl '自检' 388 86 80
                New-Label $pnl '第一次用点「设置…」：填 Seed-VC 目录和参考音色，自检过了就能唱。' 14 124 700 20 $fSub $MUTED | Out-Null
                $b1.Add_Click({ Show-SingSettings; Update-ExtAll })
                $b2.Add_Click({ Start-SingPick })
                $b3.Add_Click({
                        $lp = Join-Path $CALL_STATE 'sing-last.txt'
                        if (-not (Test-Path $lp)) { ELog '还没唱过 —— 点「唱一段试试」。' ; return }
                        $p = (Get-Content $lp -Raw -Encoding UTF8).Trim()
                        if ($p -and (Test-Path $p)) { try { Start-Process $p } catch { } ; ELog ('打开：' + $p) }
                        else { ELog ('上次那个文件不在了：' + $p) }
                    })
                $b4.Add_Click({ Show-SingSettings -CheckOnly; Update-ExtAll })
            }
            'qq' {
                $b1 = New-Button $pnl '打开 NapCat 目录' 14 86 140
                $b2 = New-Button $pnl '打开身份配置' 162 86 120
                $b1.Add_Click({
                        $s2 = Get-ExtStates
                        if ($s2.napPath -and (Test-Path $s2.napPath)) { Start-Process (Split-Path -Parent $s2.napPath) }
                        else { ELog '没找到 NapCat —— 不接 QQ 可以不管这一条。' }
                    })
                $b2.Add_Click({ if (Test-Path $MACHINE_FILE) { try { Start-Process notepad.exe $MACHINE_FILE } catch { } ; ELog '身份：' + $MACHINE_FILE } else { ELog '还没生成 machine.json —— 主界面填两个号、点「开始安装」就有了。' } })
            }
        }
        $y += $h + 8
    }

    $script:extLog = New-Object System.Windows.Forms.TextBox
    $script:extLog.Location = New-Object System.Drawing.Point(24, 596)
    $script:extLog.Size = New-Object System.Drawing.Size(812, 84)
    $script:extLog.Multiline = $true
    $script:extLog.ScrollBars = 'Vertical'
    $script:extLog.ReadOnly = $true
    $script:extLog.Font = $fMono
    $script:extLog.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 253)
    $script:extLog.BorderStyle = 'FixedSingle'
    $x.Controls.Add($script:extLog)

    New-Label $x '想加一个模块：往 setup-ui.ps1 的 $EXT_MODULES 里加一行，再给它配几个按钮。' 24 690 560 20 $fSub $MUTED | Out-Null

    $btnRe = New-Button $x '刷新状态' 590 686 110
    $btnXc = New-Button $x '关闭' 720 686 116
    $btnRe.Add_Click({ Update-ExtAll; ELog '—— 状态刷新了' })
    $btnXc.Add_Click({ $x.Close() })

    $x.Add_Shown({
            ELog '状态只看本地：文件在不在、端口通不通。装什么、补什么，按上面卡片里的按钮。'
            Update-ExtAll
        })

    [void]$x.ShowDialog($form)
}

# ================================================================
# 语音通话设置（2026-10-26 他要的：「把通话的配置、模型选择加到拓展里，让其他用户好上手」）
#
#   三条设计，改这一屏之前先看：
#   ① **只有一个数据源**：后端有几个、每个后端有哪些可调参数、耳朵能选哪些模型 ——
#      全部问 `call\config.py --json`，这里只负责把它们画成控件。
#      ⇒ 引擎以后多一个后端 / 多一个参数，这一屏**不用改**就自己多出来一行。
#   ② **动作全落在脚本上**：装 → `bootstrap.py`；试听 → `voice-test.py`；存 → `config.py --set`。
#      界面里不另写一套 —— 写一套就多一个会说谎的地方（本项目栽过：台账和重启清单各写一份名单）。
#   ③ **中文不过命令行**：这台机器 ACP=936，命令行里的中文会被搞坏。
#      要说的话先写 UTF-8 临时文件，脚本用 `--text-file` / `--json-out` 读；回来也走文件。
# ================================================================
# ---- 唱歌（2026-10-28 他要的：「把唱歌功能整合一下」并加一项 GUI）----
# 真源是 tools\call\sing.py（同一份也发在仓库 oldhan13/xibu-call 上）。
#   界面这边只做三件事：读设置、存设置、开一个控制台去跑它。
#   ★ 不在界面里跑长任务 —— 一次转换要 40~90 秒，模态窗会像死了。

function Get-SingPython {
    $cfgj = Join-Path $CALL_STATE 'sing.json'
    if (Test-Path $cfgj) {
        try {
            $sj = Get-Content $cfgj -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($sj.python) { return [string]$sj.python }
        } catch { }
    }
    return ''
}

# 跑 sing.py 用哪个 python：先看唱歌自己的设置，再看通话那个，最后 py 启动器。
function Get-SingRunner {
    $p = Get-SingPython
    if ($p -and (Test-Path $p)) { return $p }
    $cp = Get-CallPython
    if ($cp -and $cp.exe) { return $cp.exe }
    return 'python'
}

function Get-SingScript { return (Join-Path $CALL_DIR 'sing.py') }

# 「唱一段试试」：挑一个源音频 → 开个控制台跑 sing.py → 成了就记下成品路径并打开。
function Start-SingPick {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '挑一段唱（清唱最好；有伴奏也能试，只是会带上伴奏）'
    $dlg.Filter = '音频 (*.wav;*.mp3;*.flac;*.m4a)|*.wav;*.mp3;*.flac;*.m4a|所有文件 (*.*)|*.*'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $src = $dlg.FileName
    $runner = Get-SingRunner
    $script = Get-SingScript
    $outDir = Join-Path $CALL_STATE 'out'
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $stem = [IO.Path]::GetFileNameWithoutExtension($src)
    $out = Join-Path $outDir ($stem + '-sung-' + (Get-Date).ToString('HHmm') + '.mp3')
    $lastFile = Join-Path $CALL_STATE 'sing-last.txt'
    $inner = "& '$runner' '$script' --source '$src' --out '$out' --json; " +
             "if (`$LASTEXITCODE -eq 0) { Set-Content -LiteralPath '$lastFile' -Value '$out' -Encoding UTF8; " +
             "Write-Host ('唱好了：' + '$out') -ForegroundColor Green; Start-Process '$out' } " +
             "else { Write-Host '这次没成 —— 上面那几行就是原因' -ForegroundColor Yellow }"
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner)
        ELog ('正在唱：' + (Split-Path $src -Leaf) + ' → 新开那个窗口里能看到进度')
    } catch { ELog ('起不来：' + $_.Exception.Message) }
}

function Show-SingSettings {
    param([switch]$CheckOnly)

    $runner = Get-SingRunner
    $script = Get-SingScript

    # 现在的值
    $curRoot = ''; $curPy = ''; $curRef = ''; $curSteps = 30; $curSemi = 0
    $cfgj = Join-Path $CALL_STATE 'sing.json'
    if (Test-Path $cfgj) {
        try {
            $sj = Get-Content $cfgj -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($sj.seedvc_root) { $curRoot = [string]$sj.seedvc_root }
            if ($sj.python) { $curPy = [string]$sj.python }
            if ($sj.reference) { $curRef = [string]$sj.reference }
            if ($null -ne $sj.steps) { $curSteps = [int]$sj.steps }
            if ($null -ne $sj.semitones) { $curSemi = [int]$sj.semitones }
        } catch { }
    }

    $sf = New-Object System.Windows.Forms.Form
    $sf.Text = '大肥鱼 · 唱歌'
    $sf.Size = New-Object System.Drawing.Size(824, 620)
    $sf.StartPosition = 'CenterScreen'
    $sf.BackColor = $BG
    $sf.FormBorderStyle = 'FixedSingle'
    $sf.MaximizeBox = $false
    $sf.Font = $fBody

    New-Label $sf '唱歌 · 换音色' 22 12 300 32 $fTitle $INK | Out-Null
    New-Label $sf '旋律和换气都留在原唱上，只换嗓子 —— 所以听着像真人在唱，不是 TTS 在压嗓。' 22 46 760 20 $fSub $MUTED | Out-Null

    function SgBox([int]$y, [string]$label, [string]$value, [switch]$Browse, [string]$filter) {
        New-Label $sf $label 22 ($y - 20) 760 18 $fSub $MUTED | Out-Null
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(22, $y)
        $t.Size = New-Object System.Drawing.Size($(if ($Browse) { 660 } else { 760 }), 26)
        $t.Font = $fMono
        $t.Text = $value
        $sf.Controls.Add($t)
        if ($Browse) {
            $b = New-Button $sf '浏览…' 690 $y 92
            $b.Add_Click({
                    $d = New-Object System.Windows.Forms.OpenFileDialog
                    if ($filter) { $d.Filter = $filter }
                    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $t.Text = $d.FileName }
                }.GetNewClosure())
        }
        return $t
    }

    # ★ 目录要的是文件夹，不是文件 —— 单独一个按钮，别跟 SgBox 的浏览混。
    New-Label $sf 'Seed-VC 的目录（git clone 下来的那份，里面有 inference.py）' 22 76 700 18 $fSub $MUTED | Out-Null
    $txRoot = New-Object System.Windows.Forms.TextBox
    $txRoot.Location = New-Object System.Drawing.Point(22, 96)
    $txRoot.Size = New-Object System.Drawing.Size(660, 26)
    $txRoot.Font = $fMono
    $txRoot.Text = $curRoot
    $sf.Controls.Add($txRoot)
    $bRoot = New-Button $sf '浏览…' 690 96 92
    $bRoot.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txRoot.Text = $d.SelectedPath }
        })

    $txPy = SgBox 156 'Python（装了 torch 的那个；别用正在跑 TTS 的环境）' $curPy -Browse -filter 'python.exe|python.exe|所有文件 (*.*)|*.*'
    $txRef = SgBox 216 '参考音色（你的干净人声，10~25 秒最好）' $curRef -Browse -filter '音频 (*.wav;*.mp3;*.flac)|*.wav;*.mp3;*.flac|所有文件 (*.*)|*.*'

    New-Label $sf '扩散步数（30 = 默认；12~16 更快、差一点点）' 22 256 360 18 $fSub $MUTED | Out-Null
    $txSteps = New-Object System.Windows.Forms.TextBox
    $txSteps.Location = New-Object System.Drawing.Point(22, 276)
    $txSteps.Size = New-Object System.Drawing.Size(80, 26)
    $txSteps.Font = $fMono
    $txSteps.Text = [string]$curSteps
    $sf.Controls.Add($txSteps)

    New-Label $sf '移调（半音，0 = 不动；+2 就是整段升两个半音）' 130 256 360 18 $fSub $MUTED | Out-Null
    $txSemi = New-Object System.Windows.Forms.TextBox
    $txSemi.Location = New-Object System.Drawing.Point(130, 276)
    $txSemi.Size = New-Object System.Drawing.Size(80, 26)
    $txSemi.Font = $fMono
    $txSemi.Text = [string]$curSemi
    $sf.Controls.Add($txSemi)

    $slog = New-Object System.Windows.Forms.TextBox
    $slog.Location = New-Object System.Drawing.Point(22, 372)
    $slog.Size = New-Object System.Drawing.Size(760, 170)
    $slog.Multiline = $true
    $slog.ScrollBars = 'Vertical'
    $slog.ReadOnly = $true
    $slog.BackColor = [System.Drawing.Color]::White
    $slog.Font = $fMono
    $sf.Controls.Add($slog)

    function SLog([string]$s) {
        if (-not $s) { return }
        $slog.AppendText($s + "`r`n")
        $slog.SelectionStart = $slog.TextLength
        $slog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    $bSave = New-Button $sf '保存' 22 322 100 -Primary
    $bSave.Add_Click({
            try {
                $args2 = @(
                    "seedvc_root=$($txRoot.Text.Trim())",
                    "python=$($txPy.Text.Trim())",
                    "reference=$($txRef.Text.Trim())",
                    "steps=$($txSteps.Text.Trim())",
                    "semitones=$($txSemi.Text.Trim())"
                )
                $o = & $runner $script --set @args2 2>&1
                if ($LASTEXITCODE -eq 0) { SLog ('存好了：' + ($o -join ' ')) } else { SLog ('没存上：' + ($o -join ' ')) }
            } catch { SLog ('没存上：' + $_.Exception.Message) }
        })

    $bCheck = New-Button $sf '自检' 130 322 100
    $bCheck.Add_Click({
            SLog '—— 自检（权重 / 显卡 / 参考音色）'
            try {
                $o = & $runner $script --check 2>&1
                SLog ($o -join "`r`n")
            } catch { SLog ('起不来：' + $_.Exception.Message) }
        })

    $bSing = New-Button $sf '唱一段试试' 238 322 120
    $bSing.Add_Click({ Start-SingPick })

    $bClose = New-Button $sf '关上' 366 322 80
    $bClose.Add_Click({ $sf.Close() })

    $sf.Add_Shown({
            if ($CheckOnly) { $bCheck.PerformClick() ; return }
            SLog '第一次用：① 填 Seed-VC 目录 ② 填装了 torch 的 python ③ 填参考音色 → 点「自检」'
            SLog '自检里 problems 是空的就能唱。权重没下齐时，它会把下载地址一起打出来（用 curl -L 下到 <Seed-VC>\checkpoints）。'
        })

    [void]$sf.ShowDialog()
}

function Get-CallSnapshot {
    $cp = Get-CallPython
    if (-not $cp) { return $null }
    if (-not (Test-Path $CALL_CFG)) { return $null }
    $tmp = Join-Path $env:TEMP ('dfy-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $argv = @($cp.pre) + @($CALL_CFG, '--json')
        Start-Process -FilePath $cp.exe -ArgumentList $argv -WorkingDirectory $CALL_DIR `
            -WindowStyle Hidden -RedirectStandardOutput $tmp -PassThru -Wait | Out-Null
        if (-not (Test-Path $tmp)) { return $null }
        $txt = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8).Trim()
        if (-not $txt) { return $null }
        return ($txt | ConvertFrom-Json)
    } catch {
        return $null
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Show-CallSettings {
    $cf = New-Object System.Windows.Forms.Form
    $cf.Text = '大肥鱼 · 语音通话'
    $cf.Size = New-Object System.Drawing.Size(824, 880)
    $cf.StartPosition = 'CenterScreen'
    $cf.BackColor = $BG
    $cf.FormBorderStyle = 'FixedSingle'
    $cf.MaximizeBox = $false
    $cf.Font = $fBody

    New-Label $cf '语音通话' 22 12 300 32 $fTitle $INK | Out-Null
    New-Label $cf '只有这一样要 Python。装一次，以后点「开通话窗」就行；不想要它，别的都照旧。' 22 46 760 20 $fSub $MUTED | Out-Null

    $script:csLog = $null
    $script:csCtl = @{}      # 属性路径 → 控件（耳朵 / 通话手感）
    $script:csOpts = @{}     # 属性路径 → 下拉选项的值（跟显示文字分开）
    $script:csBf = @{}       # 当前音色后端的那几个参数（换后端会清空重画）
    $script:csBOpts = @{}
    $script:csSnap = $null
    $script:csB = 'piper'
    $script:csBusy = $true   # 画的时候别让下拉事件递归

    function CLog([string]$s) {
        if (-not $s) { return }
        if ($script:csLog) {
            $script:csLog.AppendText($s + "`r`n")
            $script:csLog.SelectionStart = $script:csLog.TextLength
            $script:csLog.ScrollToCaret()
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    function New-CSBox([int]$y, [int]$h) {
        $p = New-Object System.Windows.Forms.Panel
        $p.Location = New-Object System.Drawing.Point(22, $y)
        $p.Size = New-Object System.Drawing.Size(780, $h)
        $p.BackColor = $CARD
        $p.BorderStyle = 'FixedSingle'
        $cf.Controls.Add($p)
        return $p
    }

    # 把 config.py 吐出来的字段表画成控件。
    # ★ 列宽可以从字段表里给（`w`）：耳朵那四个参数（模型 / 算在哪 / 精度 / 端口）要挤进一行，
    #   不能都按 244 排 —— 第一版就是这么错的：第四列被面板裁掉，端口只露出半个。
    function Add-CallFields($parent, $fields, $cfg, [string]$prefix, [int]$top, $store, $opts) {
        $cx = 0
        foreach ($f in $fields) {
            $k = [string]$f.key
            $key = $prefix + '.' + $k
            $w = 244
            if ($f.w) { $w = [int]$f.w }
            New-Label $parent ([string]$f.label) $cx $top $w 18 $fSub $MUTED | Out-Null
            $cur = $null
            if ($cfg) {
                if ($cfg.PSObject.Properties.Name -contains $k) { $cur = $cfg.$k }
            }
            $kind = 'text'
            if ($f.kind) { $kind = [string]$f.kind }
            $ctl = $null
            if ($kind -eq 'num' -or $kind -eq 'int') {
                $n = New-Object System.Windows.Forms.NumericUpDown
                $n.Location = New-Object System.Drawing.Point($cx, ($top + 18))
                $n.Size = New-Object System.Drawing.Size($w, 26)
                $n.Font = $fBody
                # ★ 范围先给宽的：NumericUpDown 默认上限是 100，塞 9880 会抛「值超出范围」，
                #   被 catch 一吞就显示成 0 —— 存回去就是 port=0。第一版差点这么交出去。
                if ($kind -eq 'int') {
                    $n.DecimalPlaces = 0
                    $n.Increment = [decimal]1
                    $n.Minimum = [decimal]0
                    $n.Maximum = [decimal]999999
                } else {
                    $n.DecimalPlaces = 2
                    $n.Increment = [decimal]0.05
                    $n.Minimum = [decimal]0
                    $n.Maximum = [decimal]1000
                    if ($f.step) { try { $n.Increment = [decimal][double]$f.step } catch { } }
                }
                $lo = [double]$n.Minimum
                $hi = [double]$n.Maximum
                if ($f.min) { try { $n.Minimum = [decimal][double]$f.min; $lo = [double]$f.min } catch { } }
                if ($f.max) { try { $n.Maximum = [decimal][double]$f.max; $hi = [double]$f.max } catch { } }
                $v = 0.0
                if ($null -ne $cur) { try { $v = [double]$cur } catch { } }
                if ($v -lt $lo) { $v = $lo }
                if ($v -gt $hi) { $v = $hi }
                try { $n.Value = [decimal]$v } catch { }
                $parent.Controls.Add($n)
                $ctl = $n
            } elseif ($kind -eq 'choice') {
                $cbo = New-Object System.Windows.Forms.ComboBox
                $cbo.Location = New-Object System.Drawing.Point($cx, ($top + 18))
                $cbo.Size = New-Object System.Drawing.Size($w, 26)
                $cbo.Font = $fBody
                $cbo.DropDownStyle = 'DropDownList'
                $vals = @()
                foreach ($o in $f.options) {
                    [void]$cbo.Items.Add([string]$o[1])
                    $vals += [string]$o[0]
                }
                $curS = ''
                if ($null -ne $cur) { $curS = [string]$cur }
                $idx = 0
                for ($i = 0; $i -lt $vals.Count; $i++) { if ($vals[$i] -eq $curS) { $idx = $i } }
                $cbo.SelectedIndex = $idx
                $opts[$key] = $vals
                $parent.Controls.Add($cbo)
                $ctl = $cbo
            } else {
                $tb = New-Object System.Windows.Forms.TextBox
                $tb.Location = New-Object System.Drawing.Point($cx, ($top + 18))
                $tb.Size = New-Object System.Drawing.Size($w, 26)
                $tb.Font = $fBody
                if ($null -ne $cur) { $tb.Text = [string]$cur }
                $parent.Controls.Add($tb)
                $ctl = $tb
            }
            $store[$key] = $ctl
            if ($f.hint) { New-Label $parent ([string]$f.hint) $cx ($top + 46) $w 30 $fSub $MUTED | Out-Null }
            $cx += $w + 8
        }
    }

    # 读某个控件现在是啥值（存的时候用它拼 `k=v`）
    function Get-CSValue($ctl, $key, $opts) {
        if ($null -eq $ctl) { return $null }
        if ($ctl -is [System.Windows.Forms.NumericUpDown]) {
            $d = [double]$ctl.Value
            if ($ctl.DecimalPlaces -eq 0) { return ([long]$d).ToString() }
            # 固定两位：double 的默认 ToString 会把 1.00 压成 "1"，存回去 JSON 里就成了整数
            return $d.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        if ($ctl -is [System.Windows.Forms.ComboBox]) {
            $i = $ctl.SelectedIndex
            if ($i -lt 0) { return '' }
            if ($opts -and $opts.ContainsKey($key)) { return [string]($opts[$key][$i]) }
            return [string]$ctl.Text
        }
        return [string]$ctl.Text
    }

    # ---------------- ① 依赖 ----------------
    $p1 = New-CSBox 74 104
    New-Label $p1 '① 装好它（Python 包 + 免费的 piper 音色，装一次）' 14 8 480 22 $fH $INK | Out-Null
    New-Label $p1 '一键装好 = 建 .venv + 装依赖 + 下音色模型；断了重跑会接着来' 500 10 266 20 $fSub $MUTED | Out-Null
    $lblDep = New-Label $p1 '还没验过。点「检查一遍」看这台机器缺什么。' 14 32 750 20 $fSub $MUTED
    $bCheck = New-Button $p1 '检查一遍' 14 60 100
    $bAll = New-Button $p1 '一键装好' 122 60 110 -Primary
    $bPiper = New-Button $p1 '只下音色模型' 240 60 120
    $bPy = New-Button $p1 '去下 Python' 368 60 110
    # 国内网络从 pypi.org 拉这几个包会卡（实测：`pip install --upgrade pip` 卡了半个多小时）。
    # 默认勾上清华镜像 —— 它只是「下载源」，不改任何包的内容。
    $chkMirror = New-Object System.Windows.Forms.CheckBox
    $chkMirror.Text = '下载走清华镜像'
    $chkMirror.Location = New-Object System.Drawing.Point(488, 64)
    $chkMirror.Size = New-Object System.Drawing.Size(140, 22)
    $chkMirror.Font = $fSub
    $chkMirror.Checked = $true
    $p1.Controls.Add($chkMirror)

    # ---------------- ② 音色来源 ----------------
    $p2 = New-CSBox 184 224
    New-Label $p2 '② 她用什么声音（挑一个 → 点「试听这句」→ 听了再定）' 14 8 700 22 $fH $INK | Out-Null
    $cboB = New-Object System.Windows.Forms.ComboBox
    $cboB.Location = New-Object System.Drawing.Point(14, 30)
    $cboB.Size = New-Object System.Drawing.Size(380, 26)
    $cboB.Font = $fBody
    $cboB.DropDownStyle = 'DropDownList'
    $p2.Controls.Add($cboB)
    $lblNote = New-Label $p2 '' 404 28 362 44 $fSub $MUTED
    $fldBack = New-Object System.Windows.Forms.Panel
    $fldBack.Location = New-Object System.Drawing.Point(14, 98)
    $fldBack.Size = New-Object System.Drawing.Size(752, 78)
    $p2.Controls.Add($fldBack)
    $txtSay = New-Object System.Windows.Forms.TextBox
    $txtSay.Location = New-Object System.Drawing.Point(14, 184)
    $txtSay.Size = New-Object System.Drawing.Size(430, 26)
    $txtSay.Font = $fBody
    $txtSay.Text = '嗯，我在呢。你说吧，今天过得怎么样？'
    $p2.Controls.Add($txtSay)
    $bSay = New-Button $p2 '试听这句' 452 182 100
    $lblSay = New-Label $p2 '' 560 188 200 20 $fSub $MUTED

    # ---------------- ③ 耳朵 ----------------
    $p3 = New-CSBox 416 196
    New-Label $p3 '③ 你怎么被听清（耳朵 = 你说的话转成字）' 14 8 330 22 $fH $INK | Out-Null
    $lblEar = New-Label $p3 '' 350 10 416 20 $fSub $MUTED
    $lblEar.TextAlign = 'MiddleRight'
    $fldEar = New-Object System.Windows.Forms.Panel
    $fldEar.Location = New-Object System.Drawing.Point(14, 30)
    $fldEar.Size = New-Object System.Drawing.Size(752, 72)
    $p3.Controls.Add($fldEar)
    $bWarm = New-Button $p3 '预先下模型' 14 138 110
    $bEar = New-Button $p3 '重启耳朵' 132 138 100
    New-Label $p3 '换过模型要重启耳朵才生效（它是个常驻进程，模型装一次一直待着）。' 240 144 530 20 $fSub $MUTED | Out-Null

    # ---------------- ④ 通话手感 ----------------
    $p4 = New-CSBox 620 88
    $fldCall = New-Object System.Windows.Forms.Panel
    $fldCall.Location = New-Object System.Drawing.Point(14, 6)
    $fldCall.Size = New-Object System.Drawing.Size(752, 78)
    $p4.Controls.Add($fldCall)

    # ---------------- 日志 + 底部按钮 ----------------
    $script:csLog = New-Object System.Windows.Forms.TextBox
    $script:csLog.Location = New-Object System.Drawing.Point(22, 716)
    $script:csLog.Size = New-Object System.Drawing.Size(780, 78)
    $script:csLog.Multiline = $true
    $script:csLog.ScrollBars = 'Vertical'
    $script:csLog.ReadOnly = $true
    $script:csLog.Font = $fMono
    $script:csLog.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 253)
    $script:csLog.BorderStyle = 'FixedSingle'
    $cf.Controls.Add($script:csLog)

    $bSave = New-Button $cf '保存' 22 802 120 -Primary
    $bClose = New-Button $cf '关闭' 682 802 120
    $lblSaved = New-Label $cf '' 152 808 520 20 $fSub $MUTED

    # ---------------- 干活 ----------------
    # 把「现在这台机器」的状态写进 ①。先读缓存（界面不该为了一行字起进程）。
    function Refresh-Dep {
        $c = $null
        if (Test-Path $CALL_CHECK) { try { $c = Get-Content $CALL_CHECK -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
        if (-not $c) {
            $lblDep.Text = '还没验过。点「检查一遍」看这台机器缺什么。'
            $lblDep.ForeColor = $MUTED
            return
        }
        if ($c.ok) {
            $lblDep.Text = ('装好了 · python ' + $c.ver + ' · 音色模型在 · 音色 ' + $c.backend + ' · 耳朵 ' + $c.asr_model + '（查于 ' + $c.at + '）')
            $lblDep.ForeColor = $OKC
        } else {
            $miss = ''
            if ($c.missing) { $miss = ' · 缺包：' + (@($c.missing) -join ', ') }
            $lblDep.Text = ('还缺东西 · 跑用 ' + $c.python + $miss)
            $lblDep.ForeColor = $BADC
        }
    }

    # 换了音色来源：重画它那几个参数（参数表也来自 config.py）
    function Select-Backend([int]$idx) {
        if (-not $script:csSnap) { return }
        $bs = @($script:csSnap.backends)
        if ($idx -lt 0 -or $idx -ge $bs.Count) { return }
        $b = $bs[$idx]
        $script:csB = [string]$b.id
        $note = ''
        if ($b.note) { $note = [string]$b.note }
        $lblNote.Text = $note
        if (-not $b.paid) { $lblNote.ForeColor = $OKC } else { $lblNote.ForeColor = $MUTED }
        # 参数
        $script:csBf = @{}
        $script:csBOpts = @{}
        $fldBack.Controls.Clear()
        $cfg = $null
        if ($script:csSnap.config.tts) {
            if ($script:csSnap.config.tts.PSObject.Properties.Name -contains $script:csB) {
                $cfg = $script:csSnap.config.tts.($script:csB)
            }
        }
        if ($b.fields) { Add-CallFields $fldBack @($b.fields) $cfg ('tts.' + $script:csB) 0 $script:csBf $script:csBOpts }
    }

    function Load-Snapshot {
        $script:csSnap = Get-CallSnapshot
        if (-not $script:csSnap) {
            $lblDep.Text = '找不到 call\config.py，或者这台机器上没有 Python —— 先点「去下 Python」装一个（3.10 以上）。'
            $lblDep.ForeColor = $BADC
            $cboB.Enabled = $false; $bSay.Enabled = $false; $bSave.Enabled = $false
            $bAll.Enabled = $false; $bCheck.Enabled = $false; $bPiper.Enabled = $false
            $bWarm.Enabled = $false; $bEar.Enabled = $false
            return
        }
        $bs = @($script:csSnap.backends)
        $cboB.Items.Clear()
        foreach ($b in $bs) {
            # 标签自己已经写了「免费·离线」「按量计费」—— 只在花钱那份补一个「花钱」，
            # 免费的不再重复（第一版是「本地 piper（免费·离线）（免费）」，读着像结巴）。
            $tag = ''
            if ($b.paid) { $tag = '　· 花钱' }
            [void]$cboB.Items.Add([string]$b.label + $tag)
        }
        $bi = 0
        for ($i = 0; $i -lt $bs.Count; $i++) { if ([string]$bs[$i].id -eq [string]$script:csSnap.backend) { $bi = $i } }
        $script:csBusy = $true
        $cboB.SelectedIndex = $bi
        Select-Backend $bi
        $script:csBusy = $false
        # 耳朵 + 通话手感（这两组跟后端无关，只画一次）
        $fldEar.Controls.Clear()
        $script:csCtl = @{}
        $script:csOpts = @{}
        if ($script:csSnap.asr_fields) { Add-CallFields $fldEar @($script:csSnap.asr_fields) $script:csSnap.config.asr 'asr' 0 $script:csCtl $script:csOpts }
        $fldCall.Controls.Clear()
        if ($script:csSnap.call_fields) { Add-CallFields $fldCall @($script:csSnap.call_fields) $script:csSnap.config.call 'call' 0 $script:csCtl $script:csOpts }
        # 耳朵现在的实际状态：服务在跑就问它一句（它自己说用了哪个模型、在哪个设备上）。
        # ★ 还要**对一下**：常驻进程里的模型和配置里选的是不是同一个 ——
        #   不是的话「我明明选了 medium」这种疑惑就会冒出来，所以直接写在脸上。
        $pt = [int]($script:csSnap.config.asr.port)
        if (-not $pt) { $pt = 9890 }
        $earTxt = '耳朵没起（打电话时它自己会起）'
        $earCol = $MUTED
        try {
            $h = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $pt + '/health') -TimeoutSec 2
            if ($h.ok) {
                $runModel = [string]$h.model
                $saved = ''
                if ($script:csCtl.ContainsKey('asr.model')) {
                    $saved = Get-CSValue $script:csCtl['asr.model'] 'asr.model' $script:csOpts
                }
                if ($runModel -and $saved -and ($runModel -ne $saved)) {
                    $earTxt = ('耳朵里还是 ' + $runModel + '，你选了 ' + $saved + ' —— 点「重启耳朵」才换')
                    $earCol = $BADC
                } else {
                    if (-not $runModel) { $runModel = '?' }
                    $earTxt = ('在听 · ' + $runModel + ' · ' + $h.device + '/' + $h.compute + ' · 加载 ' + $h.load_ms + 'ms')
                    $earCol = $OKC
                }
            }
        } catch { }
        $lblEar.Text = $earTxt
        $lblEar.ForeColor = $earCol
        Refresh-Dep
    }

    # ---- 事件 ----
    $cboB.Add_SelectedIndexChanged({
            if ($script:csBusy) { return }
            Select-Backend $cboB.SelectedIndex
            $lblSaved.Text = ''
        })

    $bCheck.Add_Click({
            $cp = Get-CallPython
            if (-not $cp -or -not (Test-Path $CALL_BOOT)) { CLog '找不到 bootstrap.py，或者没有 Python。'; return }
            CLog '—— 检查（真的 import 一遍那些包，几秒）'
            $rc = Invoke-Stream $cp.exe (@($cp.pre) + @($CALL_BOOT, '--check')) ${function:CLog} 5
            CLog ('—— 退出码 ' + $rc)
            Refresh-Dep
        })

    $bAll.Add_Click({
            $cp = Get-CallPython
            if (-not $cp -or -not (Test-Path $CALL_BOOT)) { CLog '找不到 bootstrap.py，或者没有 Python。'; return }
            $ask = [System.Windows.Forms.MessageBox]::Show(
                '会建一个 .venv、装 numpy / faster-whisper / piper 这些包，再下 63MB 的 piper 音色模型。' + "`r`n`r`n" + '第一次几分钟，占约 1.5GB。装吗？',
                '装依赖？', [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { CLog '—— 嗯，没装。'; return }
            CLog '—— 开装（下面会一行一行出；这期间窗口不会卡住）'
            $argv = @($cp.pre) + @($CALL_BOOT, '--all')
            if ($chkMirror.Checked) { $argv += @('--mirror', 'tuna'); CLog '   下载源：清华镜像' }
            $rc = Invoke-Stream $cp.exe $argv ${function:CLog} 40
            CLog ('—— 退出码 ' + $rc)
            # 装完 python 可能换了（.venv 里那份），整屏重读一遍
            Load-Snapshot
        })

    $bPiper.Add_Click({
            $cp = Get-CallPython
            if (-not $cp -or -not (Test-Path $CALL_BOOT)) { CLog '找不到 bootstrap.py，或者没有 Python。'; return }
            CLog '—— 下 piper 音色模型（63MB）'
            $rc = Invoke-Stream $cp.exe (@($cp.pre) + @($CALL_BOOT, '--piper')) ${function:CLog} 20
            CLog ('—— 退出码 ' + $rc)
            Refresh-Dep
        })

    $bPy.Add_Click({
            try { Start-Process 'https://www.python.org/downloads/' } catch { }
            CLog '—— 装 Python 时记得勾上「Add python.exe to PATH」，装完回来点「检查一遍」。'
        })

    $bSay.Add_Click({
            $cp = Get-CallPython
            if (-not $cp -or -not (Test-Path $CALL_TEST)) { CLog '找不到 voice-test.py，或者没有 Python。'; return }
            $txt = $txtSay.Text.Trim()
            if (-not $txt) { $txt = '嗯，我在呢。' }
            # 中文不过命令行（ACP=936）—— 写文件，脚本自己读
            $tf = Join-Path $env:TEMP ('dfy-saytxt-' + [guid]::NewGuid().ToString('N') + '.txt')
            [System.IO.File]::WriteAllText($tf, $txt, (New-Object System.Text.UTF8Encoding($false)))
            $jf = Join-Path $env:TEMP ('dfy-sayres-' + [guid]::NewGuid().ToString('N') + '.json')
            $lblSay.Text = '合成中…'
            $lblSay.ForeColor = $MUTED
            [System.Windows.Forms.Application]::DoEvents()
            CLog ('—— 试听 [' + $script:csB + ']：' + $txt)
            $argv = @($cp.pre) + @($CALL_TEST, '--backend', $script:csB, '--text-file', $tf, '--json-out', $jf)
            $rc = Invoke-Stream $cp.exe $argv ${function:CLog} 4
            Remove-Item $tf -Force -ErrorAction SilentlyContinue
            if ((Test-Path $jf) -and (Play-CallWav $jf)) {
                try {
                    $j = Get-Content $jf -Raw -Encoding UTF8 | ConvertFrom-Json
                    $lblSay.Text = ('听过没？' + $j.dur_s + 's · 首块 ' + $j.first_ms + 'ms')
                    $lblSay.ForeColor = $INK
                    CLog ('—— ' + $j.dur_s + ' 秒 · 首块 ' + $j.first_ms + 'ms · RMS ' + $j.rms + ' · 削波 ' + $j.clipped_pct + '%')
                } catch { }
            } else {
                $lblSay.Text = '没合成出来'
                $lblSay.ForeColor = $BADC
                CLog ('—— 没合成出来（退出码 ' + $rc + '；上面那几行是原因）')
            }
            Remove-Item $jf -Force -ErrorAction SilentlyContinue
        })

    $bWarm.Add_Click({
            $cp = Get-CallPython
            if (-not $cp -or -not (Test-Path $CALL_BOOT)) { CLog '找不到 bootstrap.py，或者没有 Python。'; return }
            $m = 'small'
            if ($script:csCtl.ContainsKey('asr.model')) {
                $m = Get-CSValue $script:csCtl['asr.model'] 'asr.model' $script:csOpts
            }
            CLog ('—— 预先下耳朵模型：' + $m + '（几百 MB，下过一次就不再下）')
            $rc = Invoke-Stream $cp.exe (@($cp.pre) + @($CALL_BOOT, '--whisper', $m)) ${function:CLog} 30
            CLog ('—— 退出码 ' + $rc)
        })

    $bEar.Add_Click({
            $cp = Get-CallPython
            if (-not $cp -or -not (Test-Path $CALL_BOOT)) { CLog '找不到 bootstrap.py，或者没有 Python。'; return }
            CLog '—— 重启耳朵（先收掉在跑的那个，再按配置拉起）'
            $rc = Invoke-Stream $cp.exe (@($cp.pre) + @($CALL_BOOT, '--asr-restart')) ${function:CLog} 6
            CLog ('—— 退出码 ' + $rc)
            Load-Snapshot
        })

    $bSave.Add_Click({
            $cp = Get-CallPython
            if (-not $cp -or -not (Test-Path $CALL_CFG)) { CLog '找不到 config.py，或者没有 Python。'; return }
            $pairs = @()
            $pairs += ('tts.backend=' + $script:csB)
            foreach ($k in @($script:csBf.Keys)) {
                $v = Get-CSValue $script:csBf[$k] $k $script:csBOpts
                if ($null -ne $v) { $pairs += ($k + '=' + $v) }
            }
            foreach ($k in @($script:csCtl.Keys)) {
                $v = Get-CSValue $script:csCtl[$k] $k $script:csOpts
                if ($null -ne $v) { $pairs += ($k + '=' + $v) }
            }
            $argv = @($cp.pre) + @($CALL_CFG, '--set') + $pairs
            $rc = Invoke-Stream $cp.exe $argv ${function:CLog} 2
            if ($rc -eq 0) {
                $lblSaved.Text = '存好了 —— 音色：' + $script:csB
                $lblSaved.ForeColor = $OKC
                # 界面标签（「她自己的声音」这种）也在这一份里，留给模块列表用
                try {
                    $script:csSnap | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $CALL_STATE 'ui-cache.json') -Encoding UTF8
                } catch { }
                Load-Snapshot
            } else {
                $lblSaved.Text = '没存上（看下面）'
                $lblSaved.ForeColor = $BADC
            }
        })

    $bClose.Add_Click({ $cf.Close() })

    $cf.Add_Shown({
            CLog '这一屏只改一样东西：state\call\config.json。后端和参数都是 call\config.py 报上来的。'
            Load-Snapshot
        })

    [void]$cf.ShowDialog($form)
}

# ================================================================
# 更新（2026-10-21 他要的：「配置界面加一个检查更新，直接从网上拉、下载、替换」）
#   三条底线，改之前先看：
#     ① **数据一律不碰** —— people / memory / state / assets / voice / group / relay / bili /
#        homepage\data / desk\history.jsonl / 桌宠那几个 state 文件。更新只换代码和文档。
#     ② 换之前**先备份**到 `dafeiyu\state\backup\update-<时间>\`，真出问题能退回去。
#     ③ 只从**仓库 main 的 zip** 拿（codeload，**不需要 git**），和 Show-Bootstrap 同一个地址。
#   还要记住：换完 `setup-ui.ps1` 自己也变了，**当前进程跑的还是旧代码** —— 必须提示重开窗口。
# ================================================================
$API_COMMIT = 'https://api.github.com/repos/oldhan13/dsh-dafeiyu/commits/main'
$ZIP_MAIN   = 'https://codeload.github.com/oldhan13/dsh-dafeiyu/zip/refs/heads/main'
$VER_FILE   = Join-Path $PROJECT 'dafeiyu\state\version.json'

# 目录名（相对 dafeiyu\）—— 整棵不碰
$NO_TOUCH_DIRS = @('people', 'memory', 'state', 'assets', 'voice', 'group', 'relay', 'bili', 'homepage\data')
# 单个文件（相对项目根）—— 不碰
$NO_TOUCH_FILES = @(
    'dafeiyu\desk\history.jsonl',
    'dafeiyu\pet\state.json',
    'dafeiyu\pet\panel-state.json',
    'dafeiyu\pet\say.txt',
    'dafeiyu\pet\activity.json',
    'dafeiyu\pet\pet.log'
)
# 只换这些扩展名的东西（二进制、图片一律不碰）
$CODE_EXT = @('.ps1', '.psm1', '.mjs', '.js', '.cmd', '.bat', '.md', '.html', '.css', '.json')

function Get-LocalVersion {
    if (-not (Test-Path $VER_FILE)) { return '' }
    try {
        $txt = [System.IO.File]::ReadAllText($VER_FILE, [System.Text.Encoding]::UTF8)
        $j = $txt | ConvertFrom-Json
        if ($j.sha) { return [string]$j.sha }
        return ''
    } catch { return '' }
}

function Get-RemoteVersion {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $hdr = @{ 'User-Agent' = 'dafeiyu-setup'; 'Accept' = 'application/vnd.github+json' }
    $r = Invoke-RestMethod -Uri $API_COMMIT -Headers $hdr -TimeoutSec 25
    $sha = [string]$r.sha
    $short = $sha
    if ($sha.Length -ge 7) { $short = $sha.Substring(0, 7) }
    $when = ''
    try { $when = ([datetime]$r.commit.committer.date).ToLocalTime().ToString('MM-dd HH:mm') } catch { }
    $msg = ''
    try { $msg = (([string]$r.commit.message) -split "`n")[0] } catch { }
    return @{ sha = $sha; short = $short; when = $when; msg = $msg }
}

function Invoke-UpdateZip($Sink) {
    $say = { param($t) if ($Sink) { & $Sink $t } }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $tmp = Join-Path $env:TEMP ('dfy-upd-' + (Get-Date).ToString('yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $zpath = Join-Path $tmp 'repo.zip'
        & $say '下载中…'
        Invoke-WebRequest -Uri $ZIP_MAIN -OutFile $zpath -UseBasicParsing -TimeoutSec 180
        $kb = [int]((Get-Item $zpath).Length / 1024)
        & $say ('下载好了：' + $kb + ' KB')

        $ex = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zpath -DestinationPath $ex -Force
        $dirs = @(Get-ChildItem -Path $ex -Directory)
        if ($dirs.Count -lt 1) { throw '解开的包里没有目录' }
        $zipRoot = $dirs[0].FullName
        & $say ('解开：' + $dirs[0].Name)

        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $bak = Join-Path $PROJECT ('dafeiyu\state\backup\update-' + $stamp)
        $copied = 0
        $backs = 0
        $locked = @()

        $srcFiles = @(Get-ChildItem -Path $zipRoot -Recurse -File -ErrorAction SilentlyContinue)
        foreach ($sf in $srcFiles) {
            $rel = $sf.FullName.Substring($zipRoot.Length).TrimStart('\')
            if (-not $rel.StartsWith('dafeiyu\')) {
                if ($rel -notmatch '^(setup\.cmd|start-dsh-web\.cmd|stop-dafeiyu\.cmd|dafeiyu\.cmd|install\.ps1|README\.md)$') { continue }
            }
            $ext = [System.IO.Path]::GetExtension($rel).ToLower()
            if ($CODE_EXT -notcontains $ext) { continue }

            $sub = $rel
            if ($rel.StartsWith('dafeiyu\')) { $sub = $rel.Substring(8) }
            $blocked = $false
            foreach ($nd in $NO_TOUCH_DIRS) {
                if ($sub.StartsWith($nd + '\') -or $sub -eq $nd) { $blocked = $true; break }
            }
            if ($NO_TOUCH_FILES -contains $rel) { $blocked = $true }
            if ($blocked) { continue }

            $dst = Join-Path $PROJECT $rel
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }

            $same = $false
            if (Test-Path $dst) {
                try {
                    $h1 = (Get-FileHash -LiteralPath $sf.FullName -Algorithm MD5).Hash
                    $h2 = (Get-FileHash -LiteralPath $dst -Algorithm MD5).Hash
                    if ($h1 -eq $h2) { $same = $true }
                } catch { }
            }
            if ($same) { continue }

            if (Test-Path $dst) {
                $bd = Split-Path -Parent (Join-Path $bak $rel)
                if (-not (Test-Path $bd)) { New-Item -ItemType Directory -Path $bd -Force | Out-Null }
                try { Copy-Item -LiteralPath $dst -Destination (Join-Path $bak $rel) -Force; $backs++ } catch { }
            }
            try {
                Copy-Item -LiteralPath $sf.FullName -Destination $dst -Force -ErrorAction Stop
                $copied++
            } catch {
                $locked += $rel
            }
        }

        $bakTxt = ''
        if ($backs -gt 0) { $bakTxt = '（备份了 ' + $backs + ' 个旧的到 state\backup）' }
        & $say ('换掉了 ' + $copied + ' 个文件' + $bakTxt)

        $sha = ''
        try { $sha = (Get-RemoteVersion).sha } catch { }
        $rec = @{
            sha    = $sha
            at     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            source = 'zip-main'
            files  = $copied
            backup = $bak
        }
        $json = $rec | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($VER_FILE, $json, (New-Object System.Text.UTF8Encoding($false)))
        & $say ('版本记下了：' + $sha.Substring(0, [Math]::Min(7, $sha.Length)))

        if ($locked.Count -gt 0) {
            & $say ('⚠ 有 ' + $locked.Count + ' 个文件正在被用，这次没换成：')
            foreach ($l in $locked) { & $say ('   ' + $l) }
            & $say '   把桌宠 / 宿主关掉，再点一次更新。'
        }
        & $say '完成。'
        return $true
    } finally {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Show-Update {
    $u = New-Object System.Windows.Forms.Form
    $u.Text = '大肥鱼 · 检查更新'
    $u.Size = New-Object System.Drawing.Size(680, 470)
    $u.StartPosition = 'CenterParent'
    $u.BackColor = $BG
    $u.FormBorderStyle = 'FixedSingle'
    $u.MaximizeBox = $false
    $u.Font = $fBody

    New-Label $u '检查更新' 24 12 300 32 $fTitle $INK | Out-Null
    New-Label $u '从 GitHub 拉这份仓库最新的代码，换掉本地的脚本。只换代码和文档 —— 记忆、档案、图片、设置一样都不碰。' 24 46 632 20 $fSub $MUTED | Out-Null

    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Location = New-Object System.Drawing.Point(24, 74)
    $pnl.Size = New-Object System.Drawing.Size(632, 130)
    $pnl.BackColor = $CARD
    $pnl.BorderStyle = 'FixedSingle'
    $u.Controls.Add($pnl)

    New-Label $pnl '现在这份' 14 10 120 20 $fSub $MUTED | Out-Null
    $lblNow = New-Label $pnl '' 14 30 604 22 $fH $INK
    New-Label $pnl '网上最新' 14 58 120 20 $fSub $MUTED | Out-Null
    $lblNew = New-Label $pnl '' 14 78 604 22 $fH $INK
    $lblMsg = New-Label $pnl '' 14 104 604 20 $fSub $MUTED

    $lv0 = Get-LocalVersion
    if ($lv0) { $lblNow.Text = $lv0.Substring(0, [Math]::Min(7, $lv0.Length)) + '  ·  ' + $lv0 }
    else { $lblNow.Text = '还没记过（第一次更新会记下来）' }

    $logU = New-Object System.Windows.Forms.TextBox
    $logU.Location = New-Object System.Drawing.Point(24, 216)
    $logU.Size = New-Object System.Drawing.Size(632, 150)
    $logU.Multiline = $true
    $logU.ScrollBars = 'Vertical'
    $logU.ReadOnly = $true
    $logU.Font = $fMono
    $logU.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 253)
    $logU.BorderStyle = 'FixedSingle'
    $u.Controls.Add($logU)

    function ULog([string]$s) {
        if (-not $s) { return }
        $logU.AppendText($s + "`r`n")
        $logU.SelectionStart = $logU.TextLength
        $logU.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    $btnGo = New-Button $u '检查' 24 386 110 -Primary
    $btnUp = New-Button $u '更新到最新' 150 386 140
    $btnCl = New-Button $u '关闭' 556 386 100

    $btnGo.Add_Click({
            $btnGo.Enabled = $false
            $lblNew.Text = '查…'
            $lblMsg.Text = ''
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $rv = Get-RemoteVersion
                $lblNew.Text = $rv.short + '  ·  ' + $rv.when + ' 提交'
                $lblMsg.Text = $rv.msg
                $lv2 = Get-LocalVersion
                $lvShort = ''
                if ($lv2) { $lvShort = $lv2.Substring(0, [Math]::Min(7, $lv2.Length)) }
                if (-not $lvShort) {
                    ULog '本地还没记过版本 —— 不知道差多少，点「更新到最新」就对齐了。'
                } elseif ($lvShort -eq $rv.short) {
                    ULog '已经是最新的（' + $lvShort + '）。'
                } else {
                    ULog ('本地 ' + $lvShort + ' → 网上 ' + $rv.short + '，可以更新。')
                }
            } catch {
                $lblNew.Text = '查不到'
                $lblMsg.Text = $_.Exception.Message
                ULog ('检查失败：' + $_.Exception.Message)
                ULog '网络不通，或者这会儿连不上 GitHub。'
            } finally {
                $btnGo.Enabled = $true
            }
        })

    $btnUp.Add_Click({
            $btnUp.Enabled = $false
            $btnGo.Enabled = $false
            try {
                ULog '—— 开始更新'
                $ok = Invoke-UpdateZip ${function:ULog}
                if ($ok) {
                    $lv3 = Get-LocalVersion
                    if ($lv3) { $lblNow.Text = $lv3.Substring(0, [Math]::Min(7, $lv3.Length)) + '  ·  ' + $lv3 }
                    ULog ''
                    ULog '要把这个窗口关掉再开一次，新脚本才进来。'
                    ULog '桌宠和宿主如果开着，也重开一下。'
                }
            } catch {
                ULog ('更新失败：' + $_.Exception.Message)
            } finally {
                $btnUp.Enabled = $true
                $btnGo.Enabled = $true
            }
        })

    $btnCl.Add_Click({ $u.Close() })

    $u.Add_Shown({
            ULog '「检查」只问一下版本，不动任何文件。'
            ULog '「更新到最新」会先备份、再换；数据目录一律跳过。'
        })

    [void]$u.ShowDialog($form)
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
        # 这份工作区没有 install.ps1（不是从仓库 clone 的那份）⇒ 装不了，但别弹出难看的东西。
        if (-not (Test-Path (Join-Path $PROJECT 'install.ps1'))) {
            Write-Log '这里没有 install.ps1 —— 不是从仓库 clone 的那份，安装那一步跳过。启动、状态、拓展模块照常用。'
            return
        }
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
$btnExt.Add_Click({ Show-Extensions })
$btnUpd.Add_Click({ Show-Update })
$btnClose.Add_Click({ $form.Close() })

$form.Add_Shown({
    Write-Log ('工作区：' + $PROJECT)
    Load-KeyState
    Run-Checks
    Show-Status
})

if ($Close) { $form.WindowState = 'Minimized' }
[void]$form.ShowDialog()
