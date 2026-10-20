# relay.ps1 -- 两个「你」之间的字条（只追加，不覆盖）
#
#   -From web -Say "一句话"        往 web.md 追加一条（QQ 侧用 -From qq）
#   -Read -From web [-Last 3]      读 web.md 最后几条
#
# 谁写的进谁那份：网页会话写 web.md，QQ 侧会话写 qq.md。
# 规矩见 dafeiyu/relay/README.md。

param(
  [ValidateSet('web', 'qq')]
  [string]$From = 'web',

  [string]$Say,

  [switch]$Read,

  [int]$Last = 3
)

$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding($false)
$dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'relay'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

function Get-Blocks([string]$text) {
  $parts = [regex]::Split($text, '(?m)^(?=## )')
  # 只算「真的条目」：以 ## 开头的块；文件顶部那个 # 标题不算
  @($parts | Where-Object { $_.TrimStart().StartsWith('## ') })
}

if ($Read -or [string]::IsNullOrWhiteSpace($Say)) {
  # -From 一律指「那一份文件」：写就写进它，读就读它。
  # 所以网页侧读她那份 = -Read -From qq；QQ 侧读这份 = -Read -From web。
  $p = Join-Path $dir "$From.md"
  if (-not (Test-Path $p)) {
    Write-Output "($From.md 还不存在 -- 这侧还没写过。)"
    exit 0
  }
  $blocks = Get-Blocks ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))
  $take = @($blocks | Select-Object -Last ([Math]::Max(1, $Last)))
  Write-Output "---- $From.md 最后 $($take.Count) 条 ----"
  foreach ($b in $take) { Write-Output $b.TrimEnd() }
  exit 0
}

$me = Join-Path $dir "$From.md"
if (-not (Test-Path $me)) {
  [IO.File]::WriteAllText($me, "# $From 写的`r`n`r`n> 只追加，别覆盖。规矩见 README.md。`r`n", $enc)
}

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
$body = $Say.Trim()
$block = "`r`n## $stamp · $From`r`n`r`n$body`r`n"
[IO.File]::AppendAllText($me, $block, $enc)

$n = (Get-Blocks ([IO.File]::ReadAllText($me, [Text.Encoding]::UTF8))).Count
Write-Output "ok $From.md <- $stamp (now $n entries)"
