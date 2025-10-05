# PowerShell 最小RAG (OpenAI)

Windows PowerShell/PowerShell 7だけで動く、最小構成のRAG実装です。

## 必要条件
- Windows 10/11（PowerShell 7 推奨）
- OpenAI API Key（環境変数 `OPENAI_API_KEY` に設定）

## セットアップ
1) このリポジトリ直下に `data` フォルダを作成し、検索対象の `.txt` または `.md` を入れます。

```
ps-rag/
  rag.ps1
  data/
    sample.txt
```

2) APIキーを設定します（PowerShell）。

```powershell
$Env:OPENAI_API_KEY = "YOUR_OPENAI_API_KEY"
```

## 使い方（最小）

```powershell
pwsh ./rag.ps1 -Query "質問をここに書く"
```

主なパラメータ：
- `-Path` 文書ディレクトリ（既定: `data`）
- `-Model` 回答生成モデル（既定: `gpt-4o-mini`）
- `-EmbeddingModel` 埋め込みモデル（既定: `text-embedding-3-small`）
- `-ChunkChars` チャンク文字数（既定: 800）
- `-ChunkOverlap` チャンクの重なり（既定: 200）
- `-TopK` 取り出すチャンク数（既定: 3）
- `-ShowChunks` 取得した上位チャンクを表示

## ヘルプの見方（PowerShell内蔵ヘルプ）
本スクリプトはコメントベースのヘルプを備えています。以下で詳細が表示されます。

```powershell
Get-Help ./rag.ps1 -Full
```

## 何をしているか
1. `data` 内のテキストを固定長で分割
2. OpenAI Embeddings API で各チャンクをベクトル化
3. クエリもベクトル化し、コサイン類似度で上位 `TopK` を取得
4. そのコンテキストを付けて Chat Completions で回答生成

## よくあるトラブル
- `OPENAI_API_KEY` 未設定 → スクリプトがエラーを出します。設定して再実行。
- 文書が見つからない → `data` に `.txt/.md` を置くか `-Path` を指定。
- レート制限 → 文書量が多い場合は一旦 `-TopK` を下げる、`data` を減らす、または後述のキャッシュ化を検討。

## 補足（簡易キャッシュのヒント）
最小構成のため毎回埋め込みを計算します。速度が気になる場合は、各チャンクのハッシュ＋モデル名でキー化し、`embeddings.cache.json` に保存する実装を追加してください。

## ライセンス
このサンプルは自由に利用・改変して構いません。
