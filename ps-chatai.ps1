Param(
  [int]$Port = 8080
)

$ErrorActionPreference = 'Stop'

# エントリー: src/Main.ps1 を呼び出す
. "$PSScriptRoot/src/Main.ps1"
Start-ChataiServer -Port $Port -Root $PSScriptRoot

