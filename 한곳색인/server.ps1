# 한곳 색인 - 로컬 서버 (Windows PowerShell 기본 기능만 사용, 별도 설치 불필요)
# 같은 와이파이의 휴대폰에서도 접속할 수 있도록 모든 네트워크 주소에서 요청을 받는다.
param([int]$Port = 8787, [switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
$root     = $PSScriptRoot
$dataFile = Join-Path $root 'data.json'
$seedFile = Join-Path $root 'seed.json'
$utf8     = New-Object System.Text.UTF8Encoding($false)

# 첫 실행이면 시연용 샘플 데이터로 시작
if (-not (Test-Path $dataFile)) {
    if (Test-Path $seedFile) { Copy-Item $seedFile $dataFile } else { [IO.File]::WriteAllText($dataFile, '[]', $utf8) }
}

function Read-Items {
    $text = [IO.File]::ReadAllText($dataFile, $utf8)
    if ([string]::IsNullOrWhiteSpace($text)) { return ,@() }
    $parsed = $text | ConvertFrom-Json
    $list = New-Object System.Collections.ArrayList
    foreach ($p in @($parsed)) { if ($null -ne $p) { [void]$list.Add($p) } }
    return ,$list
}

function Save-Items($list) {
    $json = ConvertTo-Json -InputObject @($list) -Depth 5
    if ($list.Count -eq 0) { $json = '[]' }
    $tmp = "$dataFile.tmp"
    [IO.File]::WriteAllText($tmp, $json, $utf8)
    Move-Item -Force $tmp $dataFile
}

function Clean([object]$v, [int]$max) {
    if ($null -eq $v) { return '' }
    $s = ([string]$v).Trim()
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) }
    return $s
}

$Locations = @('노션','카톡','메신저','수첩','출력본','PC 폴더','인터넷','기타')

function To-Item($body, $existing) {
    $title = Clean $body.title 200
    $loc   = Clean $body.location 20
    if (-not $title) { throw 'title required' }
    if ($Locations -notcontains $loc) { $loc = '기타' }
    $now = (Get-Date).ToString('o')
    [pscustomobject]@{
        id        = if ($existing) { $existing.id } else { [guid]::NewGuid().ToString('N') }
        title     = $title
        location  = $loc
        detail    = Clean $body.detail 500
        summary   = Clean $body.summary 2000
        createdAt = if ($existing) { $existing.createdAt } else { $now }
        updatedAt = $now
    }
}

function Send($stream, [int]$code, [string]$type, [byte[]]$bytes) {
    $reason = @{200='OK';201='Created';204='No Content';400='Bad Request';404='Not Found';500='Server Error'}[$code]
    $head = "HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    if ($bytes.Length) { $stream.Write($bytes, 0, $bytes.Length) }
}

function Send-Json($stream, [int]$code, $obj) {
    $json = if ($obj -is [string]) { $obj } else { ConvertTo-Json -InputObject $obj -Depth 5 -Compress }
    Send $stream $code 'application/json; charset=utf-8' $utf8.GetBytes($json)
}

function Read-Request($client) {
    $stream = $client.GetStream()
    $buf = New-Object byte[] 65536
    $ms  = New-Object System.IO.MemoryStream
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
        $all = $ms.ToArray()
        for ($i = 3; $i -lt $all.Length; $i++) {
            if ($all[$i-3] -eq 13 -and $all[$i-2] -eq 10 -and $all[$i-1] -eq 13 -and $all[$i] -eq 10) { $headerEnd = $i + 1; break }
        }
        if ($ms.Length -gt 1MB) { return $null }
    }
    $all = $ms.ToArray()
    $headerText = [Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    $parts = $lines[0] -split ' '
    $len = 0
    foreach ($l in $lines) { if ($l -match '^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] } }
    if ($len -gt 1MB) { return $null }
    $body = New-Object System.IO.MemoryStream
    $body.Write($all, $headerEnd, $all.Length - $headerEnd)
    while ($body.Length -lt $len) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $body.Write($buf, 0, $n)
    }
    [pscustomobject]@{
        Method = $parts[0]
        Path   = ($parts[1] -split '\?')[0]
        Body   = $utf8.GetString($body.ToArray())
        Stream = $stream
    }
}

function Handle($req) {
    $s = $req.Stream
    $m = $req.Method
    $p = $req.Path

    if ($m -eq 'GET' -and ($p -eq '/' -or $p -eq '/index.html')) {
        Send $s 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $root 'index.html')))
        return
    }
    if ($p -eq '/api/items' -and $m -eq 'GET') {
        Send-Json $s 200 ([IO.File]::ReadAllText($dataFile, $utf8))
        return
    }
    if ($p -eq '/api/items' -and $m -eq 'POST') {
        $items = Read-Items
        $item = To-Item ($req.Body | ConvertFrom-Json) $null
        [void]$items.Add($item)
        Save-Items $items
        Send-Json $s 201 $item
        return
    }
    if ($p -match '^/api/items/([0-9a-zA-Z]+)$') {
        $id = $Matches[1]
        $items = Read-Items
        $idx = -1
        for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].id -eq $id) { $idx = $i; break } }
        if ($idx -lt 0) { Send-Json $s 404 @{ error = 'not found' }; return }
        if ($m -eq 'PUT') {
            $item = To-Item ($req.Body | ConvertFrom-Json) $items[$idx]
            $items[$idx] = $item
            Save-Items $items
            Send-Json $s 200 $item
            return
        }
        if ($m -eq 'DELETE') {
            $items.RemoveAt($idx)
            Save-Items $items
            Send $s 204 'text/plain' (New-Object byte[] 0)
            return
        }
    }
    Send-Json $s 404 @{ error = 'not found' }
}

# 접속 주소 안내
$ips = @()
try {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Select-Object -ExpandProperty IPAddress
} catch {}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
try { $listener.Start() } catch {
    Write-Host ""
    Write-Host "  [오류] $Port 포트를 열 수 없습니다. 이미 실행 중인 창이 있는지 확인하세요." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  ==== 한곳 색인 실행 중 ====" -ForegroundColor Cyan
Write-Host "  PC에서 열기    : http://localhost:$Port" -ForegroundColor Green
foreach ($ip in $ips) { Write-Host "  휴대폰에서 열기: http://${ip}:$Port  (같은 와이파이)" -ForegroundColor Yellow }
Write-Host "  데이터 파일    : $dataFile"
Write-Host "  종료하려면 이 창을 닫거나 Ctrl+C 를 누르세요."
Write-Host ""

if (-not $NoBrowser) { Start-Process "http://localhost:$Port" -ErrorAction SilentlyContinue }

try {
    while ($true) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 30; continue }
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 3000
        $client.SendTimeout = 3000
        try {
            $req = Read-Request $client
            if ($req) {
                try { Handle $req }
                catch {
                    Write-Host "  [요청 오류] $($req.Method) $($req.Path): $($_.Exception.Message)" -ForegroundColor Red
                    try { Send-Json $req.Stream 400 @{ error = $_.Exception.Message } } catch {}
                }
            }
        } catch {
            # 연결만 열고 요청을 보내지 않은 경우 등은 무시
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
