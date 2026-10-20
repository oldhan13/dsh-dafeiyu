<#
  build-exe.ps1 —— 把「部署界面 + 一键启动」打成一个 exe（可选，不必需）。

  为什么是可选：这套东西本来就是几个 .cmd / .ps1，双击就能跑；打 exe 只是让第一次用的人
  少看一个黑窗口、桌面上多一个能点的图标。**exe 里跑的还是同一套脚本**，不是另写一份。

  做法：用 ps2exe 把 dafeiyu\tools\setup-ui.ps1 编译成 exe，输出到 dist\dafeiyu-setup.exe。
    - 没装 ps2exe 就试着从 PSGallery 装（需要网络）
    - 编译完 exe 自带一个小图标（用 dafeiyu\assets 里那张，有就用）

  用法：
    .\dafeiyu\tools\build-exe.ps1
    .\dafeiyu\tools\build-exe.ps1 -Output C:\Users\me\Desktop\dafeiyu.exe

  注意：exe **不内嵌** node / dsh / NapCat —— 那些还是得你本机装好，
  exe 只是"按一下就开始部署"的那个壳（它自己知道真正的脚本在哪儿）。
#>
param(
    [string]$Output
)

$ErrorActionPreference = 'Stop'
$PROJECT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ENTRY   = Join-Path $PSScriptRoot 'setup-ui.ps1'
$DIST    = Join-Path $PROJECT 'dist'
$ICON    = Join-Path $PROJECT 'dafeiyu\assets\icon.ico'

if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    Write-Host '找不到 ps2exe，试着装一下（需要网络；不想装就继续用 setup.cmd，效果一样）：'
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
        }
        Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
        Import-Module ps2exe
    } catch {
        Write-Host ''
        Write-Host ('装不上 ps2exe：' + $_.Exception.Message)
        Write-Host '那就别打 exe —— 双击 setup.cmd 一样。'
        exit 2
    }
}

if (-not $Output) {
    if (-not (Test-Path $DIST)) { New-Item -ItemType Directory -Path $DIST -Force | Out-Null }
    $Output = Join-Path $DIST 'dafeiyu-setup.exe'
}

$args = @{
    inputFile    = $ENTRY
    outputFile   = $Output
    noConsole    = $true
    title        = '大肥鱼 · 部署'
    description  = 'dafeiyu deploy / one-click start'
    product      = 'dafeiyu'
}
if (Test-Path $ICON) { $args.iconFile = $ICON }

Write-Host ('编译：' + $ENTRY)
Write-Host ('输出：' + $Output)
Invoke-ps2exe @args
if (Test-Path $Output) {
    Write-Host ''
    Write-Host ('好了：' + $Output)
    Write-Host '双击它 = 双击 setup.cmd。脚本升级之后要重新打一次 exe。'
} else {
    Write-Host '没产出 exe，看看上面 ps2exe 的报错。'
    exit 1
}
