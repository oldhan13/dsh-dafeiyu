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

# id / 标题 / 一句话 / 需要什么。加模块只加这一行。
$EXT_MODULES = @(
    [ordered]@{ id = 'bili'; title = '刷 B 站'; desc = '她每天谷时自己刷一轮，把值当的挑出来写成日报 —— 她看，不打扰你。'; need = '需要：一个 Python 环境（自动建）+ B 站扫码登录一次' }
    [ordered]@{ id = 'comfy'; title = '生图'; desc = '她能用这块显卡画图，说一句就出图，十几秒一张。'; need = '需要：约 24 GB 磁盘、8 GB 以上显存；装完常驻 8188' }
    [ordered]@{ id = 'voice'; title = '语音'; desc = '她能出声，用带语气的合成念一句（跟她的文字是同一个人）。'; need = '需要：一把硅基流动 key（卡片 ③ 选「硅基流动」再存一次）' }
    [ordered]@{ id = 'qq'; title = 'QQ 通道'; desc = '手机上也能找她 —— 小号挂在 NapCat 上，QQ 里说话她听得见。'; need = '需要：NapCat + 一个小号（主界面卡片 ② 填）' }
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
    $st.voice = [ordered]@{
        script = [bool](Test-Path (Join-Path $TOOLS 'speak-play.ps1'))
        key    = [bool]($kl -gt 10)
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

    function New-ExtCard([int]$y) {
        $p = New-Object System.Windows.Forms.Panel
        $p.Location = New-Object System.Drawing.Point(24, $y)
        $p.Size = New-Object System.Drawing.Size(812, 124)
        $p.BackColor = $CARD
        $p.BorderStyle = 'FixedSingle'
        $x.Controls.Add($p)
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

        # 语音
        $okV = ($s.voice.script -and $s.voice.key)
        $txtV = ('合成脚本 ' + (& $mk $s.voice.script) + ' · 硅基流动 key ' + (& $mk $s.voice.key))
        $colV = if ($okV) { '#15803d' } elseif ($s.voice.script -or $s.voice.key) { '#b91c1c' } else { '#6b7280' }
        $badV = if ($okV) { '能用' } elseif ($s.voice.script -or $s.voice.key) { '缺一项' } else { '没装' }
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

    # ---- 四张卡 ----
    # ⚠️ 循环变量叫 $pnl 不叫 $card：PowerShell 变量名**不分大小写**，$card 就是 $CARD（卡片底色那个颜色），
    #    第二张卡开始 $CARD 变成上一张 Panel ⇒ 每张卡都抛「无法将 …Panel 转换为 …Color」（实测踩过）。
    $y = 74
    foreach ($m in $EXT_MODULES) {
        $pnl = New-ExtCard $y
        New-Label $pnl $m.title 14 8 300 22 $fH $INK | Out-Null
        $bd = New-Label $pnl '' 690 8 106 22 $fSub $MUTED
        $bd.TextAlign = 'MiddleRight'
        $script:extLbl[$m.id + 'Badge'] = $bd
        New-Label $pnl $m.desc 14 28 800 18 $fSub $INK | Out-Null
        New-Label $pnl $m.need 14 46 800 18 $fSub $MUTED | Out-Null
        $stt = New-Label $pnl '' 14 64 800 20 $fSub $MUTED
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
                $tv = New-Object System.Windows.Forms.TextBox
                $tv.Location = New-Object System.Drawing.Point(14, 88)
                $tv.Size = New-Object System.Drawing.Size(420, 26)
                $tv.Font = $fBody
                $tv.Text = '我在。今天也在这儿。'
                $pnl.Controls.Add($tv)
                $b1 = New-Button $pnl '念出来' 442 86 90
                $b1.Add_Click({
                        $txt = $tv.Text.Trim()
                        if (-not $txt) { ELog '先写一句要念的话。'; return }
                        if (-not (Test-Path (Join-Path $TOOLS 'speak-play.ps1'))) { ELog '缺 tools\speak-play.ps1'; return }
                        $tmp = Join-Path $env:TEMP ('dfy-tts-' + [guid]::NewGuid().ToString('N') + '.txt')
                        [System.IO.File]::WriteAllText($tmp, $txt, (New-Object System.Text.UTF8Encoding($false)))
                        try {
                            # 脱管：合成 + 播放交给子进程，界面不卡（中文走文件，不过命令行 —— ACP=936）
                            Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $TOOLS 'speak-play.ps1'), '-TextFile', $tmp
                            ELog ('—— 念：' + $txt)
                        } catch { ELog ('没念出来：' + $_.Exception.Message) }
                        Update-ExtAll
                    })
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
        $y += 130
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
