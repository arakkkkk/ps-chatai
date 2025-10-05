Param()

function Read-HttpRequest {
  Param([System.Net.Sockets.TcpClient]$Client)

  $stream = $Client.GetStream()
  $buffer = New-Object byte[] 8192
  $mem = New-Object System.IO.MemoryStream
  $headerEnd = -1

  while ($true) {
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { break }
    $mem.Write($buffer, 0, $read) | Out-Null
    $bytes = $mem.ToArray()
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $idx = $text.IndexOf("`r`n`r`n")
    if ($idx -ge 0) { $headerEnd = $idx + 4; break }
  }

  if ($headerEnd -lt 0) { return $null }

  $allBytes = $mem.ToArray()
  $headerText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
  $lines = $headerText -split "`r`n"
  $requestLine = $lines[0]
  $parts = $requestLine -split ' '
  $method = $parts[0]
  $rawPath = $parts[1]
  $path = [System.Uri]::UnescapeDataString(($rawPath -split '\?')[0])

  $headers = @{}
  for ($i=1; $i -lt $lines.Length; $i++) {
    if (-not $lines[$i]) { break }
    $kv = $lines[$i].Split(':',2)
    if ($kv.Count -eq 2) { $headers[$kv[0].Trim()] = $kv[1].Trim() }
  }

  $contentLength = 0
  if ($headers['Content-Length']) {
    [int]::TryParse($headers['Content-Length'], [ref]$contentLength) | Out-Null
  }

  $alreadyBodyCount = $allBytes.Length - $headerEnd
  $bodyBytes = New-Object byte[] $contentLength
  if ($alreadyBodyCount -gt 0) {
    [Array]::Copy($allBytes, $headerEnd, $bodyBytes, 0, [Math]::Min($alreadyBodyCount, $contentLength))
  }
  $pos = [Math]::Min($alreadyBodyCount, $contentLength)
  while ($pos -lt $contentLength) {
    $n = $stream.Read($bodyBytes, $pos, $contentLength - $pos)
    if ($n -le 0) { break }
    $pos += $n
  }

  $contentType = $headers['Content-Type']
  $utf8 = [System.Text.Encoding]::UTF8
  $bodyText = if ($contentLength -gt 0) { $utf8.GetString($bodyBytes, 0, $contentLength) } else { '' }

  return [pscustomobject]@{
    Method = $method
    Path = $path
    Headers = $headers
    BodyText = $bodyText
    Client = $Client
    Stream = $stream
  }
}

function Write-HttpResponse {
  Param(
    [System.Net.Sockets.TcpClient]$Client,
    [int]$Status = 200,
    [string]$StatusText = 'OK',
    [byte[]]$Body = $(,[byte[]]@()),
    [string]$ContentType = 'text/plain; charset=utf-8',
    [hashtable]$Headers
  )

  $stream = $Client.GetStream()
  $utf8 = [System.Text.Encoding]::UTF8
  $headerSb = New-Object System.Text.StringBuilder
  [void]$headerSb.Append("HTTP/1.1 $Status $StatusText`r`n")
  [void]$headerSb.Append("Content-Type: $ContentType`r`n")
  [void]$headerSb.Append("Content-Length: " + $Body.Length + "`r`n")
  [void]$headerSb.Append("Connection: close`r`n")
  if ($Headers) {
    foreach ($k in $Headers.Keys) {
      [void]$headerSb.Append("$k: $($Headers[$k])`r`n")
    }
  }
  [void]$headerSb.Append("`r`n")

  $headerBytes = [Text.Encoding]::ASCII.GetBytes($headerSb.ToString())
  $stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($Body.Length -gt 0) { $stream.Write($Body, 0, $Body.Length) }
  $stream.Flush()
  $Client.Close()
}

function Write-HttpJson {
  Param([System.Net.Sockets.TcpClient]$Client, [object]$Object, [int]$Status = 200)
  $json = ($Object | ConvertTo-Json -Depth 10 -Compress)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  Write-HttpResponse -Client $Client -Status $Status -StatusText 'OK' -Body $bytes -ContentType 'application/json; charset=utf-8' -Headers @{ 'Cache-Control' = 'no-store' }
}

function Get-ContentTypeByPath {
  Param([string]$Path)
  switch -Regex ($Path) {
    '\\.html$' { 'text/html; charset=utf-8'; break }
    '\\.js$'   { 'application/javascript; charset=utf-8'; break }
    '\\.css$'  { 'text/css; charset=utf-8'; break }
    '\\.json$' { 'application/json; charset=utf-8'; break }
    default { 'text/plain; charset=utf-8' }
  }
}

Export-ModuleMember -Function *

