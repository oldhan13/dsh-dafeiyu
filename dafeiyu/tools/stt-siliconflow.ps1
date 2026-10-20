<#
  QQ 语音转写（SiliconFlow / SenseVoice）。

  这是给 dsh-onebot-qq 的 sttEngine=custom 用的桥：插件把语音转成 16k 单声道 WAV 后，
  用 `-Audio <wav> -Out <工作目录>\out` 调它；它把转写文本写进 `<out>.txt`（UTF-8 无 BOM），
  由插件读回、拼成「（语音转写：…）」塞进会话。

  插件这边要求：异常要非零退出（它会记 warn，退回 [语音] 占位），不要让整条消息挂掉。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Audio,
  [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Stop'
$logFile = ((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) + '\dafeiyu\tools\stt.log')
function Note($msg) {
  try { [IO.File]::AppendAllText($logFile, ((Get-Date -Format 'HH:mm:ss') + ' ' + $msg + "`r`n"), (New-Object Text.UTF8Encoding($false))) } catch { }
}

try {
  Note ("called audio=$Audio")
  if (-not (Test-Path $Audio)) { throw "找不到音频：$Audio" }
  $key = (Get-Content (Join-Path $env:USERPROFILE '.dsh\siliconflow-key.txt') -Raw).Trim()

  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  if (-not (Test-Path $curl)) { $curl = 'curl.exe' }

  # ⚠️ 必须让 curl 把正文**写进文件**，再用 UTF-8 读回来。
  # 之前是 `& $curl ... | Out-String`：PowerShell 5.1 用控制台代码页（这台是 GBK）
  # 去解码子进程的 stdout ⇒ UTF-8 的中文全变乱码（"你能听到我说话吗" → "浣犺兘鍚垜…"），
  # 乱码里还可能带上引号/反斜杠，直接把 JSON 弄坏 ⇒ ConvertFrom-Json 报
  # 「传入的对象无效，应为":"或"}"」。pwsh 7 默认 UTF-8，所以在 7 里测是通的，一到 5.1 就炸。
  $tmp = Join-Path $env:TEMP ('stt-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    $errOut = & $curl -sS --max-time 40 -o $tmp -w '%{http_code}' -X POST 'https://api.siliconflow.cn/v1/audio/transcriptions' `
      -H "Authorization: Bearer $key" `
      -F 'model=FunAudioLLM/SenseVoiceSmall' `
      -F "file=@$Audio" 2>&1 | Out-String
    $code = -1
    if ($LASTEXITCODE -ne 0) { throw "curl 退出码 $LASTEXITCODE：$($errOut.Trim())" }
    $code = [int]($errOut.Trim() -split "`r?`n" | Select-Object -Last 1)
    if (-not (Test-Path $tmp)) { throw "curl 没留下响应文件" }
    $raw = [IO.File]::ReadAllText($tmp, (New-Object Text.UTF8Encoding($false)))
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  }

  if (-not $raw) { throw "接口空响应（HTTP $code）" }
  $obj = $raw | ConvertFrom-Json
  if ($null -eq $obj.text) { throw "接口没有返回 text（HTTP $code）：$($raw.Trim())" }

  $text = ([string]$obj.text).Trim()
  [IO.File]::WriteAllText(($Out + '.txt'), $text, (New-Object Text.UTF8Encoding($false)))
  Note ("ok len=$($text.Length) text=$text")
  Write-Output $text
}
catch {
  Note ('fail: ' + $_.Exception.Message)
  [Console]::Error.WriteLine('STT 失败：' + $_.Exception.Message)
  exit 1
}
