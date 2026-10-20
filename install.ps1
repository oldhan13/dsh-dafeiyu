<#
    install.ps1 —— 检查环境、设两个身份、装插件、给 profile 补丁腾个位置。

    它**不动**你的记忆、不删任何东西、不覆盖已有的 key。
    真正生效的 profile 配置还是得你自己合并（补丁会放在旁边，改完再拷）。

    用法：
        .\install.ps1 -OwnerQQ 123456 -BotQQ 654321
        .\install.ps1 -OwnerQQ 123456 -BotQQ 654321 -WithQQ -WithVoice
        .\install.ps1 -SkipPlugins          # 只做检查和环境
#>
[CmdletBinding()]
param(
    [string]$OwnerQQ = $env:DAFEIYU_OWNER_QQ,
    [string]$BotQQ   = $env:DAFEIYU_BOT_QQ,
    [string]$Profile = 'web',
    [switch]$WithQQ,
    [switch]$WithVoice,
    [switch]$SkipPlugins
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function Say($m) { Write-Host $m }

Say '── 环境 ──────────────────────────────────'
$node = (Get-Command node -ErrorAction SilentlyContinue)
if (-not $node) { Say '✗ 找不到 node。装 Node.js 22+ 再来。'; exit 1 }
$nodeVersion = (& node -v).TrimStart('v')
$major = [int]($nodeVersion -split '\.')[0]
if ($major -lt 22) { Say "✗ Node.js 是 $nodeVersion，需要 22 以上（zstd 要 22.15+）。"; exit 1 }
Say "✓ node $nodeVersion"

$psv = $PSVersionTable.PSVersion
Say "✓ PowerShell $psv"

$dsh = Get-Command dsh -ErrorAction SilentlyContinue
if ($dsh) { Say "✓ dsh $((& dsh --version) 2>$null)" } else { Say '! 找不到 dsh 命令（先 npm i -g @deepseek-ai/dsh）' }

$cwd = (Get-Location).Path
if ($cwd -like "$env:USERPROFILE\.dsh*") {
    Say "✗ 工作区不能放在 ~/.dsh 里面（Windows 沙箱会让子 shell 起不来）。换个目录。"
    exit 1
}

Say ''
Say '── 身份 ──────────────────────────────────'
if (-not $OwnerQQ) { $OwnerQQ = Read-Host '你的 QQ 号（主人）' }
if (-not $BotQQ)   { $BotQQ   = Read-Host '机器人自己的 QQ 号' }
[void](setx DAFEIYU_OWNER_QQ $OwnerQQ)
[void](setx DAFEIYU_BOT_QQ   $BotQQ)
$env:DAFEIYU_OWNER_QQ = $OwnerQQ
$env:DAFEIYU_BOT_QQ   = $BotQQ
Say "✓ 已写入用户环境变量：DAFEIYU_OWNER_QQ=$OwnerQQ  DAFEIYU_BOT_QQ=$BotQQ"

Say ''
Say '── 密钥文件 ──────────────────────────────'
$dshHome = Join-Path $env:USERPROFILE '.dsh'
if (-not (Test-Path $dshHome)) { New-Item -ItemType Directory -Path $dshHome | Out-Null }
foreach ($f in @('siliconflow-key.txt', 'onebot-token.txt')) {
    $p = Join-Path $dshHome $f
    if (Test-Path $p) { Say "· 已有 $f（没动它）" }
    else { Set-Content -Path $p -Value '' -Encoding ASCII -NoNewline; Say "· 建了空文件 $f —— 有 key 就填进去" }
}

Say ''
Say '── 插件 ──────────────────────────────────'
if ($SkipPlugins -or -not $dsh) {
    Say '· 跳过（要么你说了 Skip，要么没有 dsh）'
} else {
    & dsh plugin --profile $Profile add dsh-ledger-memory
    if ($WithQQ)    { & dsh plugin --profile $Profile add dsh-onebot-qq }
    if ($WithVoice) { & dsh plugin --profile $Profile add dsh-voice-chat }
    Say '· 想刷 B站再说一句：dsh plugin --profile web add github:c1overzz/dsh-bili-scroll'
}

Say ''
Say '── profile 补丁 ──────────────────────────'
$target = Join-Path $dshHome "profiles\$Profile"
if (Test-Path $target) {
    $sample = Join-Path $target 'cordis.patch.dafeiyu.sample.yml'
    Copy-Item (Join-Path $here 'profile\cordis.patch.yml') $sample -Force
    Say "· 模板放好了：$sample"
    Say '· 打开它，把 accessToken / adminUsers / botQQ 三处占位符改成你自己的，再并进 cordis.patch.yml'
} else {
    Say "! 没找到 profile 目录 $target —— 先跑一次 dsh web 让它建出来"
}

Say ''
Say '完了。接着按 docs/SETUP.md 的第 6 步启动：'
Say '  dsh web'
Say '  .\start-dafeiyu.cmd'
