ps-chatai (Minimal PowerShell Web Chat)
======================================

要件を満たす最小モックです:
- Windows PowerShell と PowerShell (Core) の両方で動作
- OpenAI API でチャット
- `prompts/` のテキストファイルをシステムプロンプトとして利用

準備
----
- OpenAI API キーを環境変数に設定:
  - Windows: `setx OPENAI_API_KEY "sk-..."`
  - Linux/macOS: `export OPENAI_API_KEY="sk-..."`

使い方
------
```
pwsh ./ps-chatai.ps1 -Port 8080
# もしくは Windows PowerShell:
powershell -File .\ps-chatai.ps1 -Port 8080
```
ブラウザで `http://127.0.0.1:8080/` を開きます。

プロンプト作成方法
---------
- `prompts/create_minus/` を参考に作成してください。
- `config.yml`のパラメータについて
    - `message`: 入力欄上部の説明欄に記載されるメッセージを設定します
    - `prompt`: プロンプト選択時に入力欄に自動的に挿入されるプロンプトが記載されたファイル名を設定します
    - `meta-prompt`: AIのAPIリクエスト時に利用されるメタプロンプトです。リスト形式で複数設定することができます。
        - 1つ目のメタプロンプトはユーザ入力とともにAPIリクエストを実行されます。(メタプロンプトにて`{{parameter}}`と記載した箇所にユーザー入力が挿入されます。)
        - 2つ目のメタプロンプトはそのレスポンスとともに再度APIリクエストを実行するためのものです。(メタプロンプトにて`{{parameter}}`と記載した箇所に１回目のリクエストが挿入されます。)
        - そのレスポンスに対して、3つ目のメタプロンプトとともにAPIリクエストを実行して。。という流れになります。(メタプロンプトにて`{{parameter}}`と記載した箇所にリクエストが挿入されます。)

メモ
----
- 最小実装のため簡易HTTP実装（TcpListener）です。実運用では Pode/Polaris などのWebフレームワーク利用を推奨します。
- Windows PowerShell 5.1 では TLS1.2 を有効化して OpenAI に接続します。

構成
----
- `main.ps1` … エントリー（`src/Main.ps1`を呼び出すラッパ）
- `src/Main.ps1` … 起動引数処理・プロンプト読込・サーバ起動
- `src/Server.ps1` … ルーティングと応答処理
- `src/Http.ps1` … 簡易HTTPリクエスト/レスポンス処理
- `src/OpenAI.ps1` … OpenAI Chat API 呼び出し
- `public/index.html` … 最小UI（静的HTML）。サーバは `/` で配信、`/presets` でプリセットJSONを返します。

