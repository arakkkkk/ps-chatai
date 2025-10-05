Param()

function Initialize-Tls12IfNeeded {
  try {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
  } catch {}
}

function Invoke-OpenAIChat {
  Param(
    [Parameter(Mandatory=$true)][array]$Messages,
    [string]$Model = $(if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-4o-mini' })
  )

  if (-not $env:OPENAI_API_KEY) {
    throw 'OPENAI_API_KEY が未設定です。環境変数に設定してください。'
  }

  Initialize-Tls12IfNeeded

  $uri = 'https://api.openai.com/v1/chat/completions'
  $headers = @{ 'Authorization' = "Bearer $($env:OPENAI_API_KEY)" }
  $payload = @{ model = $Model; messages = $Messages }
  $json = $payload | ConvertTo-Json -Depth 10 -Compress

  try {
    $res = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body $json
    if ($res.choices -and $res.choices[0].message.content) {
      return [string]$res.choices[0].message.content
    }
    elseif ($res.choices -and $res.choices[0].text) {
      return [string]$res.choices[0].text
    }
    else {
      return ($res | ConvertTo-Json -Depth 10)
    }
  } catch {
    throw "OpenAI API 呼び出しに失敗しました: $($_.Exception.Message)"
  }
}

Export-ModuleMember -Function Invoke-OpenAIChat

