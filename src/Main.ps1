Param()

function Start-ChataiServer {
  Param(
    [Parameter(Mandatory=$true)][int]$Port,
    [Parameter(Mandatory=$true)][string]$Root
  )

  $global:Chatai = @{ Root = $Root; Port = $Port }

  . "$Root/src/Http.ps1"
  . "$Root/src/OpenAI.ps1"
  . "$Root/src/Server.ps1"

  Write-Host "ps-chatai starting on http://127.0.0.1:$Port/"
  Start-MinimalHttpServer -Port $Port -Root $Root
}

Export-ModuleMember -Function Start-ChataiServer

