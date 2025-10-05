<#
.SYNOPSIS
  最小構成のRAG（Retrieval-Augmented Generation）をPowerShellだけで実行するスクリプト。

.DESCRIPTION
  指定したフォルダ（既定: data）内のテキスト（.txt/.md）を読み込み、
  一定文字数で分割（チャンク化）→ OpenAI Embeddings API でベクトル化 →
  質問文もベクトル化してコサイン類似度で上位チャンクを検索 →
  それらをコンテキストに Chat Completions で回答を生成します。

.NOTES
  事前に環境変数 OPENAI_API_KEY を設定してください。
  例: PowerShell  `$Env:OPENAI_API_KEY = "YOUR_OPENAI_API_KEY"`

.PARAMETER Query
  回答してほしい質問文（必須）。

.PARAMETER Path
  文書フォルダのパス。既定は `data`。

.PARAMETER Model
  回答生成に使うChatモデル。既定は `gpt-4o-mini`。

.PARAMETER EmbeddingModel
  埋め込み生成に使うモデル。既定は `text-embedding-3-small`。

.PARAMETER ChunkChars
  チャンク（分割片）の最大文字数。既定は 800。

.PARAMETER ChunkOverlap
  隣接チャンク間の重なり文字数。既定は 200。

.PARAMETER TopK
  類似検索で取り出す上位チャンク数。既定は 3。

.PARAMETER ShowChunks
  取得した上位チャンクの中身を表示するスイッチ。

.EXAMPLE
  pwsh .\rag.ps1 -Query "このプロジェクトの要件は？"
  読み込んだ文書から関連箇所を検索し、それに基づいた回答を表示します。

.LINK
  README.md
#>

Param(
  [Parameter(Mandatory = $true)]
  [string]$Query,
  [string]$Path = "data",
  [string]$Model = "gpt-4o-mini",
  [string]$EmbeddingModel = "text-embedding-3-small",
  [int]$ChunkChars = 800,
  [int]$ChunkOverlap = 200,
  [int]$TopK = 3,
  [switch]$ShowChunks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  長いテキストを固定長のチャンクに分割します。
.DESCRIPTION
  オーバーラップ（重なり）を設けて分割することで、文がチャンク境界で切れても
  前後の文脈を保持しやすくします。
#>
function Split-Text {
  Param(
    [Parameter(Mandatory=$true)][string]$Text,
    [int]$ChunkChars = 800,
    [int]$OverlapChars = 200
  )
  if ($ChunkChars -le 0) { throw "ChunkChars must be > 0" }
  if ($OverlapChars -ge $ChunkChars) { $OverlapChars = [Math]::Max(0, [int]($ChunkChars/4)) }
  $segments = @()
  $len = $Text.Length
  $step = $ChunkChars - $OverlapChars
  # $step ずつずらしながら切り出す
  for ($i = 0; $i -lt $len; $i += $step) {
    $size = [Math]::Min($ChunkChars, $len - $i)
    $segments += $Text.Substring($i, $size)
  }
  return $segments
}

<#
.SYNOPSIS
  OpenAI Embeddings API を呼び出し、ベクトル表現を取得します。
.PARAMETER Text
  埋め込みを取りたいテキスト（単一チャンク推奨）。
.PARAMETER ApiKey
  OpenAI API キー。
.PARAMETER Model
  例: text-embedding-3-small / text-embedding-3-large
#>
function Get-OpenAIEmbedding {
  Param(
    [Parameter(Mandatory=$true)][string]$Text,
    [Parameter(Mandatory=$true)][string]$ApiKey,
    [string]$Model = "text-embedding-3-small"
  )
  $uri = "https://api.openai.com/v1/embeddings"
  $headers = @{ 'Authorization' = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
  $body = @{ input = $Text; model = $Model } | ConvertTo-Json -Depth 5
  # REST呼び出しで埋め込み（数百～数千次元の数値配列）を取得
  $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body
  return ,($resp.data[0].embedding)
}

<#
.SYNOPSIS
  2つのベクトル間のコサイン類似度を計算します。
.DESCRIPTION
  1 に近いほど類似、0 は無相関、-1 は反対方向。
#>
function Get-CosineSimilarity {
  Param(
    [Parameter(Mandatory=$true)][double[]]$A,
    [Parameter(Mandatory=$true)][double[]]$B
  )
  if ($A.Count -ne $B.Count) { throw "Vector size mismatch: $($A.Count) vs $($B.Count)" }
  [double]$dot = 0; [double]$na = 0; [double]$nb = 0
  for ($i = 0; $i -lt $A.Count; $i++) {
    $dot += $A[$i] * $B[$i]
    $na += $A[$i] * $A[$i]
    $nb += $B[$i] * $B[$i]
  }
  if ($na -eq 0 -or $nb -eq 0) { return 0 }
  return $dot / ([Math]::Sqrt($na) * [Math]::Sqrt($nb))
}

<#
.SYNOPSIS
  OpenAI Chat Completions API を呼び出して回答文を生成します。
.PARAMETER Messages
  Chat形式のメッセージ配列（system/user/assistant）。
.PARAMETER ApiKey
  OpenAI API キー。
.PARAMETER Model
  例: gpt-4o-mini, gpt-4o
#>
function Get-OpenAIChatCompletion {
  Param(
    [Parameter(Mandatory=$true)][hashtable[]]$Messages,
    [Parameter(Mandatory=$true)][string]$ApiKey,
    [string]$Model = "gpt-4o-mini",
    [double]$Temperature = 0.1
  )
  $uri = "https://api.openai.com/v1/chat/completions"
  $headers = @{ 'Authorization' = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
  $body = @{ model = $Model; temperature = $Temperature; messages = $Messages } | ConvertTo-Json -Depth 8
  # モデルにコンテキストを渡して回答文（assistant）を生成
  $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body
  return $resp.choices[0].message.content
}

<#
.SYNOPSIS
  RAGの一連の処理（分割→埋め込み→検索→回答）を実行します。
.DESCRIPTION
  初めての方でも追えるよう、各ステップで進捗を表示します。
#>
function Invoke-Rag {
  Param(
    [Parameter(Mandatory=$true)][string]$Query,
    [string]$Path = "data",
    [string]$Model = "gpt-4o-mini",
    [string]$EmbeddingModel = "text-embedding-3-small",
    [int]$ChunkChars = 800,
    [int]$ChunkOverlap = 200,
    [int]$TopK = 3,
    [switch]$ShowChunks
  )

  $apiKey = $Env:OPENAI_API_KEY
  if (-not $apiKey) { throw "環境変数 OPENAI_API_KEY が設定されていません。`n例) PowerShell: `$Env:OPENAI_API_KEY = 'YOUR_KEY'" }

  if (-not (Test-Path -Path $Path)) { throw "データフォルダ '$Path' が見つかりません。" }

  # 1) 文書ファイル（.txt/.md）を収集
  $files = Get-ChildItem -Path $Path -Include *.txt,*.md -Recurse -File -ErrorAction SilentlyContinue
  if (-not $files -or $files.Count -eq 0) { throw "'$Path' に .txt か .md ファイルがありません。" }

  Write-Host "[1/4] 文書を読み込み・分割中..." -ForegroundColor Cyan
  $chunks = @()
  foreach ($f in $files) {
    $raw = Get-Content -Path $f.FullName -Raw
    if (-not $raw) { continue }
    # 固定長＋オーバーラップで分割
    $segs = Split-Text -Text $raw -ChunkChars $ChunkChars -OverlapChars $ChunkOverlap
    foreach ($s in $segs) {
      $chunks += [pscustomobject]@{ Text = $s; Source = $f.FullName }
    }
  }
  if ($chunks.Count -eq 0) { throw "分割後のチャンクが0件でした。チャンクサイズを見直してください。" }

  Write-Host "[2/4] チャンクの埋め込みを計算中 ($($chunks.Count))..." -ForegroundColor Cyan
  $i = 0
  foreach ($c in $chunks) {
    $i++
    if ($i % 10 -eq 0) { Write-Host ("  - {0}/{1}" -f $i, $chunks.Count) }
    # 各チャンクをAPIでベクトル化
    $c | Add-Member -NotePropertyName Embedding -NotePropertyValue (Get-OpenAIEmbedding -Text $c.Text -ApiKey $apiKey -Model $EmbeddingModel)
  }

  Write-Host "[3/4] 問い合わせをベクトル化..." -ForegroundColor Cyan
  $qEmbedding = Get-OpenAIEmbedding -Text $Query -ApiKey $apiKey -Model $EmbeddingModel

  Write-Host "[4/4] 類似検索して回答生成..." -ForegroundColor Cyan
  # クエリと各チャンクの類似度（コサイン類似度）を計算
  $scored = foreach ($c in $chunks) {
    $score = Get-CosineSimilarity -A $c.Embedding -B $qEmbedding
    [pscustomobject]@{ Text = $c.Text; Source = $c.Source; Score = [math]::Round($score,6) }
  }

  $top = $scored | Sort-Object -Property Score -Descending | Select-Object -First $TopK
  if ($ShowChunks) {
    Write-Host "--- TopK チャンク ---" -ForegroundColor Yellow
    $top | ForEach-Object { Write-Host ("[Score {0}] {1}" -f $_.Score, $_.Source) -ForegroundColor Yellow; Write-Host $_.Text; Write-Host "-----" }
  }

  # Chatモデルに渡すためのコンテキスト文字列を組み立て
  $context = ($top | ForEach-Object { "Source: $($_.Source)`n$($_.Text)" }) -join "`n`n---`n`n"

  $messages = @(
    @{ role = 'system'; content = 'You are a helpful assistant. Answer the user concisely using only the provided context. If the answer is not contained in the context, say you do not know.' }
    @{ role = 'user'; content = "Context:\n$context\n---\nQuestion: $Query" }
  )

  # Chat Completions API で最終回答を生成
  $answer = Get-OpenAIChatCompletion -Messages $messages -ApiKey $apiKey -Model $Model -Temperature 0.1

  $sources = ($top.Source | Select-Object -Unique)
  [pscustomobject]@{
    Answer  = $answer
    Sources = $sources
  }
}

# エントリーポイント（スクリプトとして実行された場合）
if ($MyInvocation.PSScriptRoot -ne $null -and $MyInvocation.InvocationName -ne '.') {
  try {
    $result = Invoke-Rag -Query $Query -Path $Path -Model $Model -EmbeddingModel $EmbeddingModel -ChunkChars $ChunkChars -ChunkOverlap $ChunkOverlap -TopK $TopK -ShowChunks:$ShowChunks
    Write-Host "\n=== 回答 ===" -ForegroundColor Green
    Write-Output $result.Answer
    Write-Host "\n=== 参照元 ===" -ForegroundColor Green
    $result.Sources | ForEach-Object { Write-Output $_ }
  }
  catch {
    Write-Error $_
    exit 1
  }
}
