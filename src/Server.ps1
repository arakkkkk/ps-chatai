Param()

function Get-PresetsDirectory {
  if ($global:Chatai -and $global:Chatai.Root) { return Join-Path $global:Chatai.Root 'prompts' }
  return (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'prompts')
}

function Parse-SimpleYamlConfig {
  Param([string]$Path)
  $result = @{ }
  $meta = @()
  $inMeta = $false
  foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*$') { continue }
    if ($line -match '^\s*meta-prompts\s*:') { $inMeta = $true; continue }
    if ($inMeta) {
      if ($line -match '^\s*-\s*(.+)$') { $meta += $Matches[1].Trim() } else { $inMeta = $false }
    }
    if (-not $inMeta -and $line -match '^\s*([^:]+)\s*:\s*(.+)$') {
      $key = $Matches[1].Trim()
      $val = $Matches[2].Trim()
      $result[$key] = $val
    }
  }
  if ($meta.Count -gt 0) { $result['meta-prompts'] = $meta }
  return $result
}

function Get-PresetObjects {
  $presetsRoot = Get-PresetsDirectory
  if (-not (Test-Path -LiteralPath $presetsRoot)) { return @() }
  $dirs = Get-ChildItem -LiteralPath $presetsRoot -Directory -ErrorAction SilentlyContinue
  $list = @()
  foreach ($d in $dirs) {
    $cfgPath = Join-Path $d.FullName 'config.yml'
    if (-not (Test-Path -LiteralPath $cfgPath)) { continue }
    $cfg = Parse-SimpleYamlConfig -Path $cfgPath
    $promptFile = if ($cfg['prompt']) { $cfg['prompt'] } else { 'prompt.txt' }
    $promptPath = Join-Path $d.FullName $promptFile
    $promptText = if (Test-Path -LiteralPath $promptPath) { [IO.File]::ReadAllText($promptPath, [Text.Encoding]::UTF8) } else { '' }
    $obj = [pscustomobject]@{
      id = $d.Name
      title = ($cfg['title'] ?? $d.Name)
      message = ($cfg['message'] ?? '')
      prompt = $promptText
      metaPromptFiles = @($cfg['meta-prompts'])
      dir = $d.FullName
    }
    $list += $obj
  }
  return $list
}

function Run-PresetChain {
  Param(
    [Parameter(Mandatory=$true)][pscustomobject]$Preset,
    [Parameter(Mandatory=$true)][string]$Input,
    [string]$Model
  )

  $current = $Input
  $steps = @()
  foreach ($file in $Preset.metaPromptFiles) {
    if (-not $file) { continue }
    $mpath = Join-Path $Preset.dir $file
    if (-not (Test-Path -LiteralPath $mpath)) { continue }
    $tpl = [IO.File]::ReadAllText($mpath, [Text.Encoding]::UTF8)
    $sys = $tpl -replace '{{\s*parameter\s*}}', [System.Text.RegularExpressions.Regex]::Escape($current).Replace('\\','\\\\')
    # メッセージは system のみ（最小実装）
    $messages = @(@{ role = 'system'; content = $tpl -replace '{{\s*parameter\s*}}', $current })
    $out = Invoke-OpenAIChat -Messages $messages -Model $Model
    $steps += [pscustomobject]@{ metaPrompt = $file; output = $out }
    $current = $out
  }
  return [pscustomobject]@{ final = $current; steps = $steps }
}

function Start-MinimalHttpServer {
  Param([int]$Port = 8080, [string]$Root)

  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
  $listener.Start()
  try {
    while ($true) {
      $client = $listener.AcceptTcpClient()
      try {
        $req = Read-HttpRequest -Client $client
        if (-not $req) { $client.Close(); continue }

        switch ($req.Path) {
          '/' {
            $idx = Join-Path $Root 'public/index.html'
            if (Test-Path -LiteralPath $idx) {
              $bytes = [IO.File]::ReadAllBytes($idx)
              Write-HttpResponse -Client $client -Body $bytes -ContentType (Get-ContentTypeByPath $idx)
            } else {
              $body = [Text.Encoding]::UTF8.GetBytes('<h1>ps-chatai</h1>')
              Write-HttpResponse -Client $client -Body $body -ContentType 'text/html; charset=utf-8'
            }
          }
          '/presets' {
            $list = Get-PresetObjects | Select-Object id,title,message,prompt
            Write-HttpJson -Client $client -Object $list
          }
          '/chat' {
            if ($req.Method -ne 'POST') {
              Write-HttpResponse -Client $client -Status 405 -StatusText 'Method Not Allowed' -Body ([Text.Encoding]::UTF8.GetBytes('Method Not Allowed'))
              break
            }
            $bodyObj = $null
            try { $bodyObj = $req.BodyText | ConvertFrom-Json } catch {}
            if (-not $bodyObj) {
              Write-HttpResponse -Client $client -Status 400 -StatusText 'Bad Request' -Body ([Text.Encoding]::UTF8.GetBytes('invalid json'))
              break
            }
            $presetId = [string]$bodyObj.presetId
            $input = [string]$bodyObj.input
            $model = if ($bodyObj.model) { [string]$bodyObj.model } else { $null }
            $preset = (Get-PresetObjects | Where-Object { $_.id -eq $presetId })
            if (-not $preset) {
              Write-HttpResponse -Client $client -Status 404 -StatusText 'Not Found' -Body ([Text.Encoding]::UTF8.GetBytes('preset not found'))
              break
            }
            try {
              $res = Run-PresetChain -Preset $preset -Input $input -Model $model
              Write-HttpJson -Client $client -Object @{ result = $res.final; steps = $res.steps }
            } catch {
              $msg = "error: $($_.Exception.Message)"
              Write-HttpResponse -Client $client -Status 500 -StatusText 'Internal Server Error' -Body ([Text.Encoding]::UTF8.GetBytes($msg))
            }
          }
          default {
            # 静的ファイル: /public 以下
            $staticPath = Join-Path $Root ('public' + $req.Path.Replace('/','\'))
            if (Test-Path -LiteralPath $staticPath) {
              $bytes = [IO.File]::ReadAllBytes($staticPath)
              Write-HttpResponse -Client $client -Body $bytes -ContentType (Get-ContentTypeByPath $staticPath)
            } else {
              Write-HttpResponse -Client $client -Status 404 -StatusText 'Not Found' -Body ([Text.Encoding]::UTF8.GetBytes('Not Found'))
            }
          }
        }
      } catch {
        try { Write-HttpResponse -Client $client -Status 500 -StatusText 'Internal Server Error' -Body ([Text.Encoding]::UTF8.GetBytes('Internal Error')) } catch {}
      }
    }
  } finally {
    $listener.Stop()
  }
}

Export-ModuleMember -Function *

