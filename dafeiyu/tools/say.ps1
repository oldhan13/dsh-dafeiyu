<#
  把一句话合成成语音文件（SiliconFlow / CosyVoice2）。

  用法（在自己的 shell 里直接调，不要走 cmd）：
    & "<WORKSPACE>\dafeiyu\tools\say.ps1" -Text "今天有点累"

  产出：dafeiyu\voice\<时间>.mp3 —— 路径会打在最后一行。
  想发出去就下一步用 qq_send_voice（NapCat 自己转码），别用别的通道。

  实现：走 curl.exe，不用 Invoke-WebRequest —— 本机 PowerShell 5.1 的 TLS 默认太老，
  直连 SiliconFlow 会报「Unable to connect to the remote server」。

  参数：
    -Text   要说的话（必填）
    -Out    指定输出文件（默认 dafeiyu\voice\日期-时间.mp3）
    -Voice  音色（默认 anna；可换 alex / bella / benjamin / charles / claire / david / diana）
    -Speed  语速（1.0 正常，1.1 略快）
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Text,
  [string]$Out,
  [string]$Voice = 'FunAudioLLM/CosyVoice2-0.5B:anna',
  [double]$Speed = 1.0
)

$ErrorActionPreference = 'Stop'
$root = '<WORKSPACE>'
$key = (Get-Content (Join-Path $env:USERPROFILE '.dsh\siliconflow-key.txt') -Raw).Trim()

$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $curl)) { $curl = 'curl.exe' }

if (-not $Out) {
  $dir = Join-Path $root 'dafeiyu\voice'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $Out = Join-Path $dir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp3')
}

$body = @{
  model           = 'FunAudioLLM/CosyVoice2-0.5B'
  voice           = $Voice
  input           = $Text
  response_format = 'mp3'
  speed           = $Speed
} | ConvertTo-Json -Compress

$tmp = $Out + '.req.json'
try {
  [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($false)))
  & $curl -sS --max-time 60 -X POST 'https://api.siliconflow.cn/v1/audio/speech' `
    -H "Authorization: Bearer $key" `
    -H 'Content-Type: application/json' `
    --data-binary "@$tmp" -o $Out
  if ($LASTEXITCODE -ne 0) { throw "curl 退出码 $LASTEXITCODE" }
}
catch {
  [Console]::Error.WriteLine('TTS 失败：' + $_.Exception.Message)
  exit 1
}
finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$size = (Get-Item $Out).Length
if ($size -lt 1000) {
  [Console]::Error.WriteLine("TTS 失败：音频只有 $size 字节（是不是被接口拒了）")
  exit 1
}

Write-Output $Out
