# タスク分解

要件定義書: [requirements.md](./requirements.md)

各タスクは独立してコミット可能な粒度で分割している。T1〜T3 は並行不可（依存関係あり）、T5 以降は検証フェーズ。

---

## Phase 0: 準備

### T0-1. リポジトリ初期化
- `.gitignore`, `README.md` を作成
- `docs/requirements.md`, `docs/tasks.md` を含めて初回コミット & push
- 完了条件: `gh repo view` でファイルが確認できる

---

## Phase 1: インフラ定義（CloudFormation）

すべて `infra/template.yaml` 1ファイルに記述する。パラメータでスリープ秒数を外出しする。

### T1-1. 土台リソース
- DynamoDB テーブル `sfeval-results`（PK `executionId` / SK `taskName` / オンデマンド / TTL）
- SQS キュー `sfeval-intake` + DLQ `sfeval-intake-dlq`
- CloudWatch Logs グループ（SFN 用、保持7日）
- 完了条件: `aws cloudformation validate-template` が通る

### T1-2. 汎用スタブ Lambda `sfeval-worker`
- `Code.ZipFile` に Python 3.12 でインライン実装
- 入力 `{stage, sleepSeconds, input}` を受け、指定秒スリープして `{stage, result, startedAt, finishedAt}` を返す
- 実行ロールは `AWSLambdaBasicExecutionRole` 相当のみ
- 完了条件: デプロイ後 `aws lambda invoke` で単体動作する

### T1-3. ステートマシン `sfeval-workflow`
- `QueryLanguage: JSONata` / Type `STANDARD`
- 構成: `Preprocess` → `FanOut`(Parallel × 4) → `MarkComplete`
- 各分岐: `Transform{A|B|C|D}`（worker 呼び出し）→ `PutResult{A|B|C|D}`（`aws-sdk:dynamodb:putItem`）
- 書き込み項目: `executionId` / `taskName` / `enqueuedAt` / `writtenAt`(`$millis()`) / `elapsedMs` / `expireAt`
- ログ設定 `ALL` + `includeExecutionData: true`
- IAM ロール: `lambda:InvokeFunction`（worker のみ）/ `dynamodb:PutItem`（対象テーブルのみ）/ ログ配信権限
- 完了条件: 手動 `start-execution` で最後まで通り `SUCCEEDED` になる

### T1-4. 受付 Lambda `sfeval-intake` と SQS 連携
- SQS イベントソースマッピング（`BatchSize: 1`, `FunctionResponseTypes: ReportBatchItemFailures`）
- 各レコードから `messageId` と `attributes.SentTimestamp` を取り出し、
  `StartExecution(name = messageId, input = {messageId, enqueuedAt, body})` を呼ぶ
- `ExecutionAlreadyExists` は成功として扱う（FR-4 の冪等化）
- IAM ロール: `states:StartExecution`（対象ステートマシンのみ）/ SQS 受信権限 / ログ
- 完了条件: SQS 投入で実行が自動的に開始される

---

## Phase 2: 運用スクリプト

### T2-1. `scripts/deploy.sh`
- `aws cloudformation deploy --stack-name sfeval-poc --capabilities CAPABILITY_IAM` のラッパー
- スリープ秒数をパラメータで上書きできるようにする
- デプロイ後に Outputs（キュー URL / テーブル名 / ステートマシン ARN）を表示

### T2-2. `scripts/send-message.sh`
- SQS へテストメッセージを1件送信し、`MessageId` を表示

### T2-3. `scripts/verify.sh`
- 直近の実行を `ListExecutions` で特定
- `DescribeExecution` でステータスと所要時間を取得
- `GetExecutionHistory` から各ステートの `EnteredTime` / `ExitedTime` を抽出
- DynamoDB を `Query` して `elapsedMs` を一覧表示
- 受け入れ基準 AC-1〜AC-8 を判定し PASS/FAIL を出力

### T2-4. `scripts/teardown.sh`
- `delete-stack` + 完了待ち

---

## Phase 3: デプロイと検証

### T3-1. 初回デプロイ
- `deploy.sh` 実行、全リソース作成を確認
- 完了条件: スタックが `CREATE_COMPLETE`

### T3-2. ウォームアップ実行
- 1件投入してコールドスタート込みの実行を通す
- 失敗した場合はログを見て修正（Phase 1 に戻る）

### T3-3. 本計測
- 連続で3〜5件投入し、`verify.sh` で AC-1〜AC-8 を判定
- 完了条件: 全 AC が PASS

### T3-4. 結果レポート
- 各処理の到達時刻・経過時間を表にまとめ `docs/results.md` に記録
- 特に「加工A が Parallel 完了より前に書き込めているか」を明示
- オーバーヘッド内訳（SQS→Lambda / Lambda→SFN開始 / SFN内部）を分解して記載

---

## Phase 4: 追加要望の受け入れ

Phase 3 完了後、未提示の制限事項をヒアリングして追加検証項目を定義する。
現時点で候補として認識しているもの:

- 分岐単位の `Catch` による失敗の封じ込め（Parallel の巻き添えキャンセル対策）
- Retry / タイムアウト / Redrive の挙動確認
- `Map` + `MaxConcurrency` による同時実行数制御
- Express との比較
