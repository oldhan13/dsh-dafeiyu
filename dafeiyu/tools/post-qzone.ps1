<#
  post-qzone.ps1 —— 以机器人号（<机器人QQ>）的身份发一条 QQ 空间说说，或删掉一条。

  用法：
    .\post-qzone.cmd "今天的事"
    .\post-qzone.cmd "配图的话" -Image "C:\path\a.jpg","C:\path\b.png"
    .\post-qzone.cmd "只给好友看" -Right 4
    .\post-qzone.cmd "只给这几个人看" -Right 16 -TargetUin $env:DAFEIYU_OWNER_QQ
    .\post-qzone.cmd -Delete 5eacd0796fc9d56ad5ef0800

  权限 ugc_right：1 所有人可见 / 4 好友可见 / 16 部分好友可见 / 64 仅自己可见 / 128 部分好友不可见
  （16 和 128 必须给 -TargetUin，否则 NapCat 会拒）

  原理：走 NapCat 自己的扩展接口 send_qzone_msg / delete_qzone_msg ——
  用的是 QQ 客户端**已经登着**的那个号，不需要密码，也不需要网页 cookie。
  接口在 http://127.0.0.1:3000，token 从 ~/.dsh/onebot-token.txt 读。

  退出码：0 成功；1 失败（失败原因原样打印，不吞）
#>
param(
    [string]$Text = '',
    [string[]]$Image = @(),
    [ValidateSet(1, 4, 16, 64, 128)][int]$Right = 1,
    [string[]]$TargetUin = @(),
    [string]$Delete = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$napcat = 'http://127.0.0.1:3000'
$tokenFile = Join-Path $env:USERPROFILE '.dsh\onebot-token.txt'
if (-not (Test-Path $tokenFile)) { Write-Error "找不到 token：$tokenFile"; exit 1 }
$headers = @{ Authorization = "Bearer $((Get-Content $tokenFile -Raw).Trim())" }

function Invoke-NapCat([string]$action, $payload) {
    $json = $payload | ConvertTo-Json -Compress -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri "$napcat/$action" -Method Post -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 60
}

if ($Delete -ne '') {
    $r = Invoke-NapCat 'delete_qzone_msg' @{ tid = $Delete }
    if ($r.retcode -eq 0) { Write-Output "OK deleted $Delete"; exit 0 }
    Write-Output "FAIL $($r | ConvertTo-Json -Compress -Depth 5)"; exit 1
}

if ($Text.Trim() -eq '' -and $Image.Count -eq 0) {
    Write-Error '内容为空：至少给 -Text 或 -Image'; exit 1
}

$payload = @{
    content     = $Text
    images      = @($Image)
    ugc_right   = $Right
    target_uins = @($TargetUin | ForEach-Object { "$_" } | Where-Object { $_ -ne '' })
}
$r = Invoke-NapCat 'send_qzone_msg' $payload
if ($r.retcode -eq 0) {
    $tid = $r.data.tid
    # 顺手把这条记进主页的 data/posts.json（失败也绝不影响发帖）
    try {
        $postsFile = Join-Path $PSScriptRoot '..\homepage\data\posts.json'
        $arr = @()
        if (Test-Path $postsFile) {
            $raw = Get-Content $postsFile -Raw -Encoding UTF8
            if ($raw -and $raw.Trim() -ne '') { $arr = @($raw | ConvertFrom-Json) }
        }
        $entry = [pscustomobject]@{ at = (Get-Date).ToString('o'); content = $Text; tid = $tid }
        $arr = @(@($entry) + @($arr) | Select-Object -First 50)
        $json = '[' + (($arr | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }) -join ',') + ']'
        [System.IO.File]::WriteAllText($postsFile, $json + "`n", [System.Text.UTF8Encoding]::new($false))
    } catch { }
    Write-Output "OK tid=$tid"
    exit 0
}
Write-Output "FAIL $($r | ConvertTo-Json -Compress -Depth 5)"
exit 1
