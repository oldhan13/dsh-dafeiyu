<#
  set-profile.ps1 —— 改她自己的 QQ 资料（昵称 / 个性签名 / 头像）

  用法：
    .\set-profile.cmd -Show                        # 看当前昵称和签名
    .\set-profile.cmd -Nickname "大肥鱼"
    .\set-profile.cmd -Signature "在别人的电脑里，学着过日子。"
    .\set-profile.cmd -Nickname "大肥鱼" -Signature "……"
    .\set-profile.cmd -Avatar "C:\pics\me.png"     # 也可以给 URL 或 base64://...

  原理：NapCat 扩展接口 set_qq_profile / set_qq_avatar。
  用的是 QQ 客户端已经登着的那个号 —— 不需要密码，不需要 cookie。
  接口在 http://127.0.0.1:3000，token 从 ~/.dsh/onebot-token.txt 读。

  退出码：0 成功；1 失败（原因原样打印）
#>
param(
    [string]$Nickname = '',
    [string]$Signature = '',
    [string]$Avatar = '',
    [switch]$Show
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$napcat = 'http://127.0.0.1:3000'
$tokenFile = Join-Path $env:USERPROFILE '.dsh\onebot-token.txt'
if (-not (Test-Path $tokenFile)) { Write-Error "找不到 token：$tokenFile"; exit 1 }
$headers = @{ Authorization = "Bearer $((Get-Content $tokenFile -Raw).Trim())" }

function Invoke-NapCat([string]$action, $payload) {
    $json = if ($null -eq $payload) { '{}' } else { $payload | ConvertTo-Json -Compress -Depth 5 }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri "$napcat/$action" -Method Post -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 60
}

function Get-LoginUin {
    $r = Invoke-NapCat 'get_login_info' @{}
    if ($r.retcode -ne 0) { throw "get_login_info 失败：$($r | ConvertTo-Json -Compress -Depth 5)" }
    return $r.data.user_id
}

# 注意：get_login_info 的 nickname 是**登录时的缓存**，改完资料不会刷新。
# 想知道现在的真名，得问 get_stranger_info（服务器值）。这个区别踩过。
function Get-CurrentProfile([object]$uin) {
    $s = Invoke-NapCat 'get_stranger_info' @{ user_id = $uin }
    if ($s.retcode -eq 0) {
        return [pscustomobject]@{ nickname = [string]$s.data.nickname; signature = [string]$s.data.long_nick }
    }
    return $null
}

if ($Show) {
    $uin = Get-LoginUin
    Write-Output "uin      : $uin"
    $p = Get-CurrentProfile $uin
    if ($p) {
        Write-Output "nickname : $($p.nickname)"
        Write-Output "signature: $($p.signature)"
    } else {
        $r = Invoke-NapCat 'get_login_info' @{}
        Write-Output "nickname : $($r.data.nickname)  (登录缓存值，查服务器失败)"
    }
    if ($Nickname -eq '' -and $Signature -eq '' -and $Avatar -eq '') { exit 0 }
}

if ($Nickname -ne '' -or $Signature -ne '') {
    # set_qq_profile 的 nickname 是**必填**：只想改签名时，先把当前昵称取回来一起传
    $nick = $Nickname
    if ($nick -eq '') {
        # 必须拿服务器上的真昵称：缓存值可能是登录时的旧名，回写会把改过的名字顶掉
        $p = Get-CurrentProfile (Get-LoginUin)
        if ($p -and $p.nickname -ne '') { $nick = $p.nickname }
        if ($nick -eq '') { Write-Error '取不到当前昵称，改签名需要它'; exit 1 }
    }
    $payload = @{ nickname = $nick }
    if ($Signature -ne '') { $payload.personal_note = $Signature }
    $r = Invoke-NapCat 'set_qq_profile' $payload
    if ($r.retcode -ne 0) {
        Write-Output "FAIL set_qq_profile $($r | ConvertTo-Json -Compress -Depth 5)"
        exit 1
    }
    Write-Output "OK profile updated nickname=$nick$(if ($Signature -ne '') { " signature=$Signature" })"
}

if ($Avatar -ne '') {
    $r = Invoke-NapCat 'set_qq_avatar' @{ file = $Avatar }
    if ($r.retcode -ne 0) {
        Write-Output "FAIL set_qq_avatar $($r | ConvertTo-Json -Compress -Depth 5)"
        exit 1
    }
    Write-Output "OK avatar updated: $Avatar"
}

if ($Nickname -eq '' -and $Signature -eq '' -and $Avatar -eq '' -and -not $Show) {
    Write-Error '什么都没给：用 -Show / -Nickname / -Signature / -Avatar'
    exit 1
}
exit 0
