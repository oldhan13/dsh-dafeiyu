# speak.ps1 —— 有语气地说话：同一段话里换速度、插停顿，最后拼成一条音频。
#
# 为什么不是 say.ps1：say.ps1 一次合成一句话、一个语速 ⇒ 整段一个调。
# 语气来自**局部差异**：这一句快、那句慢、中间停半秒。所以这里把文本切段，
# 逐段给不同 speed，段间塞静音，最后用 ffmpeg 拼成一条 —— 仍是一条 mp3，不是碎片。
#
# 写法（标记会被吃掉，不会念出来）：
#   [[slow]] … [[/slow]]    这段慢（×0.80）
#   [[fast]] … [[/fast]]    这段快（×1.18）
#   [[s]] 短停 0.15s   [[p]] 停 0.35s   [[pp]] 停 0.7s
#
# 例：
#   .\speak.ps1 "嗯。[[pp]][[slow]]我在这。[[/slow]][[s]]我没走。"
#
# 产出：dafeiyu\voice\<时间>-prosody.mp3（路径打在最后一行）
# 依赖：curl（系统自带）、ffmpeg（已装）、SiliconFlow key
#
# ── 2026-10-20 上午修的「卡顿」（他说合成的音频有卡顿）─────────────────
# 实测每一段 TTS 自带的首尾静音长短不一，而且**段尾常常一点静音都没有**：
#   嗯。    0.72s → 头 76ms / 尾 45ms
#   我在这。 0.68s → 头 258ms / 尾 0ms
#   我没走。 0.48s → 头 83ms / 尾 0ms
# 两处后果，就是"卡顿"的来源：
#   ① 停顿不可控：设 0.7s，那一段自带 258ms ⇒ 实际停 0.958s，节奏一顿一顿
#   ② 硬拼跳变：段尾 0ms 静音就接下一段 ⇒ 波形从半高直接跳到 0，出声是"咔"
# 修法：① 直接要 wav（跳过 mp3→wav 那次二次有损转码）
#       ② 每段裁掉自带首尾静音，各留 MarginMs 的边 → 拼接处天然是 0 对 0
#       ③ 停顿只用 anullsrc 生成，长度 = 标记写的长度，不再被叠成别的

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Text,
  [string]$Out,
  [string]$Voice = 'FunAudioLLM/CosyVoice2-0.5B:anna',
  [double]$BaseSpeed = 1.0,
  # 裁剪时每段首尾保留多少毫秒静音。留一点是给拼接用的缓冲：
  # 两边都是 0，接起来才不会有咔声；完全裁干净反而容易吃到起音。
  [int]$MarginMs = 30
)

$ErrorActionPreference = 'Stop'
$root = '<WORKSPACE>'
$key = (Get-Content (Join-Path $env:USERPROFILE '.dsh\siliconflow-key.txt') -Raw).Trim()

$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
$fp = (Get-Command ffprobe -ErrorAction SilentlyContinue).Source
if (-not $ff) { throw 'ffmpeg 不在 PATH 上' }

if (-not $Out) {
  $dir = Join-Path $root 'dafeiyu\voice'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $Out = Join-Path $dir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-prosody.mp3')
}

# ---- 1. 切段：文本 / 速度 / 停顿 ----
$pattern = '(\[\[(?:s|p|pp|slow|/slow|fast|/fast)\]\])'
$items = New-Object System.Collections.ArrayList
$speed = $BaseSpeed

foreach ($tok in [regex]::Split($Text, $pattern)) {
  if ($tok -match '^\[\[(.+?)\]\]$') {
    switch ($Matches[1]) {
      's' { [void]$items.Add([pscustomobject]@{ kind = 'pause'; ms = 150; text = ''; speed = 0 }) }
      'p' { [void]$items.Add([pscustomobject]@{ kind = 'pause'; ms = 350; text = ''; speed = 0 }) }
      'pp' { [void]$items.Add([pscustomobject]@{ kind = 'pause'; ms = 700; text = ''; speed = 0 }) }
      'slow' { $speed = [math]::Round($BaseSpeed * 0.80, 2) }
      '/slow' { $speed = $BaseSpeed }
      'fast' { $speed = [math]::Round($BaseSpeed * 1.18, 2) }
      '/fast' { $speed = $BaseSpeed }
    }
    continue
  }
  if ($tok -and $tok.Trim()) {
    [void]$items.Add([pscustomobject]@{ kind = 'say'; ms = 0; text = $tok.Trim(); speed = $speed })
  }
}

if ($items.Count -eq 0) { throw '没有可念的内容' }

# ---- 2. 逐段合成，统一成 44.1k 单声道 wav ----
$work = Join-Path $env:TEMP ('speak-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$margin = [math]::Round($MarginMs / 1000.0, 3)
# 首尾各裁掉自带静音、只留 margin。两边都归零以后，拼接处不会跳变。
# areverse 一趟把尾巴变成头，同一套参数裁两次。
$trim = ('silenceremove=start_periods=1:start_threshold=-45dB:start_silence={0}' -f $margin) +
        ',areverse,' +
        ('silenceremove=start_periods=1:start_threshold=-45dB:start_silence={0}' -f $margin) +
        ',areverse'

$wavs = New-Object System.Collections.ArrayList
$report = New-Object System.Collections.ArrayList
$n = 0
try {
  foreach ($it in $items) {
    $n++
    $stem = '{0:d3}' -f $n
    if ($it.kind -eq 'pause') {
      $wav = Join-Path $work "$stem-pause.wav"
      $sec = [math]::Round($it.ms / 1000.0, 3)
      & $ff -hide_banner -loglevel error -y -f lavfi -i 'anullsrc=r=44100:cl=mono' -t $sec -c:a pcm_s16le $wav
      if (-not (Test-Path $wav)) { throw "静音生成失败（$sec s）" }
      [void]$report.Add(('  停顿 {0}ms' -f $it.ms))
    }
    else {
      # 直接要 wav：省掉 mp3 → wav 那次二次有损转码（那也是杂音的来源之一）
      $raw = Join-Path $work "$stem-raw.wav"
      $req = Join-Path $work "$stem.req.json"
      $body = @{
        model           = 'FunAudioLLM/CosyVoice2-0.5B'
        voice           = $Voice
        input           = $it.text
        response_format = 'wav'
        speed           = $it.speed
      } | ConvertTo-Json -Compress
      [IO.File]::WriteAllText($req, $body, (New-Object Text.UTF8Encoding($false)))
      & $curl -sS --max-time 60 -X POST 'https://api.siliconflow.cn/v1/audio/speech' `
        -H "Authorization: Bearer $key" `
        -H 'Content-Type: application/json' `
        --data-binary "@$req" -o $raw
      if ($LASTEXITCODE -ne 0) { throw "curl 退出码 $LASTEXITCODE（第 $n 段）" }
      if ((Get-Item $raw).Length -lt 1000) { throw "第 $n 段音频只有 $((Get-Item $raw).Length) 字节，接口拒了" }

      $wav = Join-Path $work "$stem.wav"
      & $ff -hide_banner -loglevel error -y -i $raw -af $trim -ar 44100 -ac 1 -c:a pcm_s16le $wav
      if (-not (Test-Path $wav)) { throw "第 $n 段处理失败" }
      $rawSec = [double](& $fp -v error -show_entries format=duration -of csv=p=0 $raw)
      $newSec = [double](& $fp -v error -show_entries format=duration -of csv=p=0 $wav)
      [void]$report.Add(('  「{0}」{1:N2}s → {2:N2}s（speed {3}，裁掉 {4:N0}ms 自带静音）' -f `
            $it.text, $rawSec, $newSec, $it.speed, (($rawSec - $newSec) * 1000)))
    }
    [void]$wavs.Add($wav)
  }

  # ---- 3. 拼 ----
  $listFile = Join-Path $work 'list.txt'
  $lines = $wavs | ForEach-Object { "file '" + ($_ -replace '\\', '/') + "'" }
  [IO.File]::WriteAllLines($listFile, $lines, (New-Object Text.UTF8Encoding($false)))

  & $ff -hide_banner -loglevel error -y -f concat -safe 0 -i $listFile -c:a libmp3lame -b:a 64k -ar 44100 -ac 1 $Out
  if ($LASTEXITCODE -ne 0) { throw "拼接失败（ffmpeg 退出码 $LASTEXITCODE）" }
  if ((Get-Item $Out).Length -lt 1000) { throw "输出只有 $((Get-Item $Out).Length) 字节" }

  foreach ($line in $report) { Write-Verbose $line }
  Write-Output $Out
}
finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
