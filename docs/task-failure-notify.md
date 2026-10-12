# タスク失敗時のステータス更新

- 実施日: 2026-10-12
- 目的: Task が失敗したとき、DynamoDB の該当する行のステータスを `ERROR` に更新する
- 環境: `ap-northeast-1` / スタック `sfeval-poc`（STANDARD）/ スリープ設定は [results.md](./results.md) と同じ
- 前提: [Lambda 呼び出し失敗の Retry](./invoke-failure-retry.md) を入れた後の定義に追加した

Retry で直らなかった失敗は、これまで実行を `FAILED` にするだけだった。SQS のメッセージは
`StartExecution` の時点で削除済みなので、再配信も DLQ も働かない。呼び出し元は DynamoDB の行が
揃わないまま待ち続け、失敗を知る手段がなかった。

## 結論

**失敗した Task を `Catch` で受け、どこで失敗したかを DLQ に送る。DLQ Lambda が、
失敗した場所に応じて `ERROR` にする行を選ぶ。**

| 失敗した場所 | `ERROR` になる行 | 実行の最終状態 |
|---|---|---|
| Preprocess | 全部（transform-a〜d、zz-complete） | `FAILED` |
| 加工A〜D のどれか | **その行だけ**。ほかの分岐は完走して `SUCCEEDED` を書く | `FAILED`（`sfeval.BranchFailed`） |
| MarkComplete | zz-complete だけ | `FAILED` |
| 受付（`StartExecution` が失敗して SQS が DLQ へ移した） | 全部 | 実行なし |

4ケースを実機で起こし、すべてこの表どおりになった（受付時の失敗はローカルでのみ確認）。
`ERROR` は、失敗してから1秒以内に書かれた。

## 構成

```
Preprocess ── Catch(States.ALL) → NotifyFailure → Failed
FanOut (Parallel)
  ├─ TransformA ── Catch → NotifyA → 分岐を正常終了
  ├─ TransformB ── Catch → NotifyB → 〃
  ├─ TransformC ── Catch → NotifyC → 〃
  └─ TransformD ── Catch → NotifyD → 〃
MarkComplete ── Catch → NotifyFailure → Failed
   ↓
CheckBranches ─ 失敗した分岐あり → BranchesFailed（FAILED）
              └ なし → Done（SUCCEEDED）

Notify* ──(sqs:sendMessage)──→ sfeval-intake-dlq ──→ sfeval-dlq（Lambda）──→ DynamoDB を ERROR に
                                    ↑
             受付で失敗したメッセージ（SQS の maxReceiveCount 超過）
```

### 役割の分担

| 場所 | 持つもの |
|---|---|
| ステートマシン | **どこで失敗したか**（`failedStage`）と、どの実行か（`messageId` / `executionId` / `enqueuedAt`）、エラー名と原因 |
| DLQ Lambda | **どの行を `ERROR` にするか**と、書き込む属性 |

ステートマシン定義はフローだけを持ち、出力の仕様は Lambda に置くという方針
（[requirements.md 6.4](./requirements.md)）をそのまま当てはめた。`sqs:sendMessage` はステートマシンが直接
呼ぶ SDK 統合だが、送るのは身元の情報だけで、ステータスの書き方は持たない。

### 通知の本文

```json
{
  "messageId": "…",
  "executionId": "…",
  "enqueuedAt": 1791769777000,
  "failedStage": "transform-b",
  "error": "Lambda.ResourceNotFoundException",
  "cause": "Function not found: …"
}
```

DLQ Lambda は**本文の中の値**をキーにする。新しく送ったメッセージは SQS の `messageId` が別物になるため、
レコードの `messageId` は使えない。

`failedStage` が無いメッセージは、受付で失敗したメッセージを SQS がそのまま DLQ へ移したもの。
この場合は SQS が元の `messageId` を保つので、レコードの `messageId` から実行名を組み立て、全行を `ERROR` にする。
**既存の DLQ の用途と同じキューで共存できる。**

### 設計上の判断

**なぜ DLQ Lambda を直接呼ばず、キューに送るのか。** Retry を使い切る典型は「Lambda を呼べない」状況
（スロットリング、Lambda の障害）。通知まで Lambda の直接呼び出しにすると、一緒に失敗しうる。
SQS への送信は Lambda に依存せず、送ったメッセージは Lambda が回復するまでキューに残る。

**なぜ加工の失敗で分岐を止めないのか。** Parallel は1つの分岐が失敗すると、ほかの分岐を打ち切る。
さらに Parallel の `Catch` が受け取るエラーには、どの分岐で失敗したかが含まれない。
「その行だけ `ERROR`」にするには、各 Transform で `Catch` して分岐を正常に終わらせ、
ほかの分岐を完走させる必要がある。

**なぜ加工が失敗しても MarkComplete を実行するのか。** 呼び出し元は zz-complete の行で処理の終了を判断している。
加工が1つ失敗しただけで zz-complete を書かないと、呼び出し元が待ち続ける。
呼び出し元は「zz-complete が揃った → 各行の `status` を見て `ERROR` の行を知る」という順に読む。

**なぜ最後に `FAILED` にするのか。** 通知した後で `SUCCEEDED` のまま終わると、コンソールの実行一覧で失敗が見えない。
全分岐が終わるのを待ってから `CheckBranches` で `BranchesFailed`（Fail ステート）に進める。

**変数ではなく実行時の入力から読む箇所。** Preprocess が失敗した時点では、Preprocess の `Assign`
（`$messageId` / `$enqueuedAt`）がまだ実行されていない。そのため NotifyFailure は
`$states.context.Execution.Input` から読む。

### 追加・変更したリソース

| 対象 | 内容 |
|---|---|
| ステートマシン | `Catch` と Notify ステート、`CheckBranches` / `BranchesFailed` / `Done` / `Failed` を追加 |
| ステートマシンロール | DLQ への `sqs:SendMessage` を追加 |
| `sfeval-dlq`（新規 Lambda） | 実システムの DLQ Lambda の代役。`sfeval-intake-dlq` を受けて `UpdateItem` で `ERROR` を書く |
| `sfeval-dlq-role`（新規） | DLQ の受信と、対象テーブルへの `dynamodb:UpdateItem` だけ |
| worker | 成功時の行に `status: SUCCEEDED` を追加 |

## 検証結果

### 起こし方

| # | ケース | 起こし方 |
|---|---|---|
| 1 | 正常 | — |
| 2 | Preprocess の失敗 | worker の予約同時実行数を 0（Retry を使い切らせる） |
| 3 | 加工B の失敗 | TransformB の呼び出し先を `sfeval-worker:nonexistent` に差し替え |
| 4 | MarkComplete の失敗 | MarkComplete の呼び出し先を同様に差し替え |

差し替えは `update-state-machine` で行い、退避した定義で書き戻した
（手順は [invoke-failure-retry.md](./invoke-failure-retry.md#再現方法) と同じ）。
DLQ Lambda は worker とは別の関数なので、#2 で worker を止めても影響を受けない。

### 結果

| # | 実行の状態 | 通ったステート | DynamoDB |
|---|---|---|---|
| 1 | `SUCCEEDED` | … → MarkComplete → CheckBranches → Done | 5行すべて `SUCCEEDED` |
| 2 | `FAILED`（`Lambda.TooManyRequestsException`） | Preprocess → NotifyFailure → Failed | **5行すべて `ERROR`** |
| 3 | `FAILED`（`sfeval.BranchFailed`、原因 `failed: transform-b`） | … → NotifyB → MarkComplete → CheckBranches → BranchesFailed | **B だけ `ERROR`**。A/C/D と zz-complete は `SUCCEEDED` |
| 4 | `FAILED`（`Lambda.ResourceNotFoundException`） | … → MarkComplete → NotifyFailure → Failed | **zz-complete だけ `ERROR`**。A〜D は `SUCCEEDED` |

#3 の DynamoDB:

```
transform-a  SUCCEEDED
transform-b  ERROR      failedStage=transform-b  Lambda.ResourceNotFoundException
transform-c  SUCCEEDED
transform-d  SUCCEEDED
zz-complete  SUCCEEDED
```

加工B が失敗しても、A/C/D は打ち切られずに完走した。

### `ERROR` が書かれるまで

`ERROR` 行の `updatedAt` と、実行の終了時刻（`stopDate`）の差。

| # | 差 | 説明 |
|---|---|---|
| 2 | 終了の 0.58〜0.75秒後 | 5行を順に書くので、行ごとに少しずつずれる |
| 3 | 終了の **約8秒前** | B が失敗した時点で通知が送られる。C/D の完走（8秒）を待たない |
| 4 | 終了とほぼ同時（31ms 前） | |

DLQ を経由しても、失敗から1秒以内に反映された。検証後の DLQ の残りは0件だった。

## 未確認・対象外

- **受付時の失敗の実機確認**: 再現には受付 Lambda の IAM 権限を外す必要があるので、DynamoDB を偽物に差し替えて
  ローカルで振り分けだけを確認した
- **Redrive**: `Catch` → Fail ステートで終わった実行を Redrive したとき、どこから再開するか
- **DLQ Lambda 自体が失敗し続けた場合**: メッセージは DLQ の保持期間（4日）のあいだ再試行され続ける。
  その先にもう1段 DLQ を置くかは実システム側の設計
- **実行全体のタイムアウト（300秒）と手動停止**: `Catch` が働かないので通知されない。
  EventBridge で実行の終了イベントを受ける方式を、取りこぼしを補う安全網として後から足せる
- **成功の後に `ERROR` が上書きする可能性**: worker が結果を書いた後に応答だけが失われ、そのあと Retry も尽きると
  `Catch` に入り、成功した行が `ERROR` で上書きされうる（[invoke-failure-retry.md](./invoke-failure-retry.md) の二重実行と同じ状況で、未検証）
