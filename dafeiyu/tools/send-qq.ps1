param(
  [Parameter(Mandatory = $true)][string]$Text,
  [string]$Qq = $env:DAFEIYU_OWNER_QQ
)
$ErrorActionPreference = 'Stop'
$token = (Get-Content (Join-Path $env:USERPROFILE '.dsh\onebot-token.txt') -Raw).Trim()
$body = @{
  user_id     = [int64]$Qq
  message     = @(@{ type = 'text'; data = @{ text = $Text } })
  auto_escape = $false
} | ConvertTo-Json -Depth 6 -Compress
$resp = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/send_private_msg' `
  -Method Post -Headers @{ Authorization = "Bearer $token" } `
  -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15
if ($resp.status -eq 'ok') { "sent message_id=$($resp.data.message_id)" } else { "FAILED: $($resp | ConvertTo-Json -Depth 4)" }
