# Lambda を呼び出せなかったときの Retry

- 実施日: 2026-10-12
- 目的: Step Functions から Lambda の**呼び出し自体**が失敗したとき（関数のコードが1行も動かないとき）の扱いを決める
- 環境: `ap-northeast-1` / スタック `sfeval-poc`（STANDARD）/ スリープ設定は [results.md](./results.md) と同じ

関数の中で起きた失敗（例外・関数タイムアウト）は対象外。そちらは `Catch` で扱う別の論点。
呼び出しが失敗した場合は Lambda 側では何もできないので、**ステートマシン側で処理するしかない**。

## 結論

**一時的な失敗だけを、1秒固定の間隔で最大2回呼び直す。直らない失敗は即座に失敗させる。**

```yaml
Retry:
  - ErrorEquals:
      - Lambda.TooManyRequestsException
      - Lambda.ServiceException
      - Lambda.SdkClientException
    IntervalSeconds: 1
    MaxAttempts: 2
    BackoffRate: 1
```

- Lambda を呼ぶ6つの Task すべて（Preprocess / TransformA〜D / MarkComplete）に同じものを置く
- **IAM の変更は不要。** `Retry` は定義の機能で、呼び直しも既存の `lambda:InvokeFunction` で行われる
- フローの定義なので、テンプレートが持つのは「フローだけ」という方針（[requirements.md 6.4](./requirements.md)）に収まる

決定に効いた発見は2つ。

1. **権限エラーは `Lambda.AWSLambdaException` で届く。** AWS が推奨する Retry 対象に含まれる名前なので、
   推奨どおりに書くと直らない失敗まで呼び直して SLA の時間を浪費する
2. **`JitterStrategy: FULL` は1秒間隔だと「約0秒か約1秒」の2値になった。** 2回とも約0秒になると
   リトライ2回を 0.3秒で使い切り、スロットリングが解ける前に終わる

## 1. Retry が無いときに届くエラー

Retry も Catch も無い定義のまま、呼び出しの失敗を3種類起こした。どれも最初の Preprocess で起きる。

| ケース | 起こし方 | エラー名 | HTTP | 失敗まで |
|---|---|---|---|---|
| スロットリング | worker の予約同時実行数を 0 | `Lambda.TooManyRequestsException` | 429 | 約0.16秒 |
| 権限なし | ステートマシンロールから `invoke-worker` ポリシーを削除 | **`Lambda.AWSLambdaException`** | 403 | 約0.15秒 |
| 関数なし | Preprocess の呼び出し先を `sfeval-worker:nonexistent` に差し替え | `Lambda.ResourceNotFoundException` | 404 | 約0.17秒 |

- どれも `TaskFailed` として Step Functions に届き、エラー名だけで種類を区別できる
- Retry が無いので、1回の失敗で即座に実行全体が `FAILED` になった。後続の分岐は1つも動いていない
- 権限なしのエラー原因欄の中身は `AccessDeniedException`。
  `Retry` が判定に使うのはエラー名だけで、原因欄の文字列では分岐できない

エラー原因欄（アカウント ID などは伏せた）:

```
Lambda.TooManyRequestsException
  Rate Exceeded. (Service: AWSLambda; Status Code: 429; Error Code: TooManyRequestsException; ...)

Lambda.AWSLambdaException
  User: arn:aws:sts::<ACCOUNT>:assumed-role/sfeval-workflow-role/<SESSION> is not authorized to perform:
  lambda:InvokeFunction on resource: arn:aws:lambda:ap-northeast-1:<ACCOUNT>:function:sfeval-worker
  because no identity-based policy allows the lambda:InvokeFunction action
  (Service: AWSLambda; Status Code: 403; Error Code: AccessDeniedException; ...)

Lambda.ResourceNotFoundException
  Function not found: arn:aws:lambda:ap-northeast-1:<ACCOUNT>:function:sfeval-worker:nonexistent
  (Service: AWSLambda; Status Code: 404; Error Code: ResourceNotFoundException; ...)
```

### 再現方法

どれもスタックの外で設定を変えるので、**`deploy.sh` では元に戻らない**
（テンプレートに差分が無いと CloudFormation は何も更新しない）。退避した内容で直接書き戻し、
元と一致することと、正常な実行が通ることを確認する。

```bash
# スロットリング
aws lambda put-function-concurrency --function-name sfeval-worker --reserved-concurrent-executions 0
aws lambda delete-function-concurrency --function-name sfeval-worker          # 戻す

# 権限なし（削除後、反映まで30秒ほど待ってから投入する）
aws iam get-role-policy --role-name sfeval-workflow-role --policy-name invoke-worker \
  --query PolicyDocument --output json > invoke-worker.json                   # 退避
aws iam delete-role-policy --role-name sfeval-workflow-role --policy-name invoke-worker
aws iam put-role-policy --role-name sfeval-workflow-role --policy-name invoke-worker \
  --policy-document file://invoke-worker.json                                 # 戻す

# 関数なし（ロールは sfeval-worker:* への呼び出しを許可しているので、権限エラーに化けない）
aws stepfunctions describe-state-machine --state-machine-arn <ARN> \
  --query definition --output text > definition.json                          # 退避
jq '.States.Preprocess.Arguments.FunctionName += ":nonexistent"' definition.json > notfound.json
aws stepfunctions update-state-machine --state-machine-arn <ARN> --definition file://notfound.json
aws stepfunctions update-state-machine --state-machine-arn <ARN> --definition file://definition.json  # 戻す
```

## 2. リトライ対象と間隔の決め方

### 対象のエラー

| エラー名 | 対象 | 理由 |
|---|---|---|
| `Lambda.TooManyRequestsException` | ○ | スロットリング。時間を置けば直る |
| `Lambda.ServiceException` | ○ | Lambda 側の 5xx |
| `Lambda.SdkClientException` | ○ | 通信エラー |
| `Lambda.AWSLambdaException` | × | **権限エラーがこの名前で届く**（実測）。直らないので待つだけ無駄 |
| `Lambda.ResourceNotFoundException` | × | 関数・エイリアスが無い。直らない |

`AWSLambdaException` には一時的な失敗も含まれうるが、基本的には発生しない想定なので対象から外した。
外した場合の代償は「このエラー名で届く一時的な失敗は即座に失敗する」こと。

### 間隔と回数

どの経路も Lambda を呼ぶステートを2つ通る（Preprocess + 各分岐）。両方でリトライを使い切った最悪のケース:

| 経路 | 通常の到達 | 最悪の上乗せ | 合計 | SLA |
|---|---|---|---|---|
| 加工A | 2.3秒 | 約4.8秒 | 約7.1秒 | 10秒 |
| 加工B/C/D | 9.3秒 | 約4.8秒 | 約14.1秒 | 15秒 |

上乗せは実測値から見積もった。失敗1回あたり約0.1秒、待ち1回あたり約1.06秒で、
1ステートあたり約2.4秒（失敗2回分 + 待ち2回分）。それが2ステート分で約4.8秒。

- `BackoffRate: 2`（1秒 → 2秒）にすると加工B/C/D が15秒を超えるので、間隔は**固定**にした
- 加工B/C/D の余裕は約0.9秒しか残らない。スタブのスリープ8秒を前提にした数字で、
  実処理を載せるときは見直しが要る

## 3. Retry を入れた後の挙動

### ジッターあり（`JitterStrategy: FULL`）— 不採用

最初は `JitterStrategy: FULL` を付けた。間隔1秒なら「0〜1秒のランダム」になる想定だった。

**実際の待ちは2値だった。** 13回のリトライの待ち時間（`TaskFailed` から次の `TaskScheduled` まで）:

| 待ち | 回数 | 実測値 |
|---|---|---|
| 約0秒 | 9 | 14〜24ms |
| 約1秒 | 4 | 1053〜1068ms |

中間の値は1度も出ていない。秒単位に丸められているように見えるが、仕組みは確認していない（13回のみの観測）。

その結果、スロットリングを投入直後に解除するケースでは**3回中1回しか回復しなかった**。
回復しなかった2回は、待ちが2回とも約0秒で、リトライ2回を約0.3秒で使い切っていた。

```
   25ms  TaskScheduled   Preprocess
  107ms  TaskFailed      TooManyRequestsException
  122ms  TaskScheduled   ← 15ms 後に即リトライ
  200ms  TaskFailed      TooManyRequestsException
  216ms  TaskScheduled   ← 16ms 後に即リトライ
  308ms  TaskFailed      TooManyRequestsException
  347ms  ExecutionFailed
```

ジッターの本来の目的は、同時に失敗した大量の実行が一斉に呼び直すのを分散させること。
間隔が1秒しか無いこの構成では、効果より「待たずに呼び直す」副作用の方が大きく出た。

### ジッターなし — 採用

| ケース | 回数 | 結果 |
|---|---|---|
| 正常 | 1 | `SUCCEEDED`（10.4秒）。Retry を足しても変化なし |
| スロットリングのまま | 3 | 毎回3回呼び出して `FAILED`。待ちは 1047〜1114ms、失敗までの合計は 2.5〜2.7秒で一定 |
| 投入直後にスロットリングを解除 | 3 | **3回とも回復して `SUCCEEDED`**（ジッターありのときは3回中1回） |
| 関数なし | 1 | 呼び出し1回、0.17秒で `FAILED`。**リトライされない**（ジッターありの定義で確認。エラー名の判定には差が無い） |

回復したときの流れ（3回とも同じ形）:

```
     30ms  TaskScheduled   Preprocess
    112ms  TaskFailed      TooManyRequestsException
   1234ms  TaskScheduled   ← 1.1秒待ってリトライ
   2353ms  TaskSucceeded
  10710ms  ExecutionSucceeded   （正常時より約0.3〜0.4秒長い程度）
```

## 今回の対象外

- **Task の `TimeoutSeconds`**: 呼び出しが「固まる」場合の対策。今回の「呼べない」とは別の失敗で、
  リトライすると二重実行の論点も出るので別に扱う
- **応答だけが失われたときの二重実行**: `ServiceException` が Lambda の実行後に返ると、リトライで同じ処理が
  2回走りうる。worker の書き込みは同一キーへの `PutItem` なので上書きになるだけのはずだが、
  この状況は意図して再現できず、**未検証**
- **`Catch` による失敗の封じ込め**: リトライで直らなかった失敗の扱いは [task-failure-notify.md](./task-failure-notify.md) で対応した
- **高負荷時のスロットリング**: 多数の実行が同時に失敗したとき、ジッターなしだと全員が1秒後に揃って呼び直す。
  同時実行数の検証と合わせて確認する
