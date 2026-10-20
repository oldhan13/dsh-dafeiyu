# notify-after-restart.ps1 -- wait for the DSH host to come back after a restart,
# then send one private QQ message so the owner knows she is mounted again.
#
# v2 (2026-10-19 23:05): v1 gave up silently when the host did NOT come back
# (happened at 20:29 -- he waited 2.5h with no word). Now every exit path
# reports: the success text, or a "did not come back" text.
#
# Started detached (WMI) BEFORE the restart. Steps:
#   1. wait for port 8643 to go DOWN (the restart kills the host)
#   2. wait for 8643 to come back UP and stay up for 6 s
#   3. POST /send_private_msg to NapCat (port 3000 stays up throughout)
# Every step goes to notify-after-restart.log next to this script.

param(
    [int]$Port = 8643,
    [string]$NapCat = 'http://127.0.0.1:3000',
    [string]$TokenFile = (Join-Path $env:USERPROFILE '.dsh\onebot-token.txt'),
    [string]$MessageFile = '',
    [string]$FailMessageFile = '',
    [long]$UserId = [long]$env:DAFEIYU_OWNER_QQ,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Continue'
$root = Join-Path $PSScriptRoot ''
$log = Join-Path $root 'notify-after-restart.log'
if ($MessageFile -eq '') { $MessageFile = Join-Path $root 'notify-message.txt' }
if ($FailMessageFile -eq '') { $FailMessageFile = Join-Path $root 'notify-failed.txt' }

function W([string]$m) {
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m
    try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch { }
}

function PortUp([int]$p) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $p)
        $c.Close()
        return $true
    } catch { return $false }
}

function Send-Qq([string]$text) {
    if ($text -eq '') { $text = '.' }
    try { $token = (Get-Content $TokenFile -Raw).Trim() } catch { W 'token read failed'; return }
    $payload = [pscustomobject]@{ user_id = $UserId; message = @(@{ type = 'text'; data = @{ text = $text } }) }
    $body = $payload | ConvertTo-Json -Depth 6 -Compress
    $bodyFile = Join-Path $root 'notify-body.json'
    [System.IO.File]::WriteAllText($bodyFile, $body, (New-Object System.Text.UTF8Encoding($false)))
    $resp = & curl.exe -s -X POST ($NapCat + '/send_private_msg') -H ('Authorization: Bearer ' + $token) -H 'Content-Type: application/json' --data-binary ('@' + $bodyFile) 2>&1 | Out-String
    W ('send -> ' + $resp.Trim())
}

function Read-Text([string]$path, [string]$fallback) {
    $t = ''
    try { $t = (Get-Content $path -Raw -Encoding UTF8).Trim() } catch { }
    if ($t -eq '') { $t = $fallback }
    return $t
}

W ('==== notify start (port ' + $Port + ', timeout ' + $TimeoutSeconds + 's) ====')

# 1. wait for the port to drop
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$sawDown = $false
while ((Get-Date) -lt $deadline) {
    if (-not (PortUp $Port)) { $sawDown = $true; break }
    Start-Sleep -Seconds 2
}
W ('port down seen: ' + $sawDown)
if (-not $sawDown) { W 'never went down, abort'; exit 1 }

# 2. wait for it to come back and stay up
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$up = $false
while ((Get-Date) -lt $deadline) {
    if (PortUp $Port) {
        Start-Sleep -Seconds 6
        if (PortUp $Port) { $up = $true; break }
    }
    Start-Sleep -Seconds 2
}

# 3. report either way -- a failed restart must not be silent
if ($up) {
    W ('port up again at ' + (Get-Date).ToString('HH:mm:ss'))
    Send-Qq (Read-Text $MessageFile 'mounted')
} else {
    W 'port never came back -- sending failure notice'
    Send-Qq (Read-Text $FailMessageFile 'restart failed -- host did not come back; needs a manual start')
}
W '==== notify done ===='
