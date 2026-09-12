# AWS Step Functions 入門と本リポジトリの解説

Step Functions の予備知識がない状態から、このリポジトリの成果物を読めるようになることを目的とした解説。

- [Part 1: Step Functions の概要](#part-1-step-functions-の概要)
- [Part 2: 成果物の解説](#part-2-成果物の解説)

関連: [要件定義書](./requirements.md) / [タスク分解](./tasks.md) / [検証結果](./results.md)

---

# Part 1: Step Functions の概要

## 何を解決するサービスか

Lambda を3つ順番に動かしたいとき、素直に書くと「Lambda A が Lambda B を呼び、B が C を呼ぶ」になる。すると:

- **フローがコードに埋まる** — 全体像を知るには3つの関数を読む必要がある
- **リトライを自分で書く** — 各関数に try/except とバックオフを実装する
- **どこで落ちたか分からない** — ログを串刺しで追う
- **待ち時間に課金される** — A が B の完了を待つ間も Lambda は動いている

Step Functions は **「処理の順番・条件・リトライ」を設定として外に出す**サービス。
フローは JSON の定義になり、AWS がそれを解釈して実行し、**1ステップずつ全部記録**する。

## 中心となる4つの言葉

| 用語 | 意味 |
|---|---|
| **ステートマシン** (State Machine) | ワークフローの**定義**。料理でいうレシピ |
| **ステート** (State) | フローを構成する箱1つ。レシピの1工程 |
| **実行** (Execution) | 定義を1回走らせたもの。レシピで実際に作った1皿。実行ごとに ID と履歴が残る |
| **ASL** (Amazon States Language) | ステートマシンを記述する JSON の言語 |

「ステートマシンを1個作る」と「それを1000回実行する」は別の話。
本リポジトリの `sfeval-workflow` がステートマシンで、SQS にメッセージを投げるたびに実行が1件生まれる。

## ステートの種類は8つだけ

| Type | 役割 |
|---|---|
| **Task** | 実際の仕事をする。Lambda 呼び出しや AWS API 呼び出し |
| **Choice** | 条件分岐（if / else） |
| **Parallel** | **決め打ちの**複数分岐を同時実行 |
| **Map** | **配列の各要素**に同じ処理を繰り返す（同時実行数を制限できる） |
| **Wait** | 指定秒数 / 指定時刻まで待つ（待機中は課金されない） |
| **Pass** | 何もしない。入力を加工して次へ渡すだけ。スタブやデータ整形に便利 |
| **Succeed** | 成功で終了 |
| **Fail** | 失敗で終了 |

本リポジトリで使っているのは **Task と Parallel の2つだけ**。

`Parallel` と `Map` の違いは重要。**Parallel は「A と B と C を同時に」と分岐を書き並べるもの**、
**Map は「この配列の全要素に同じ処理を」**というもの。
今回の4つの加工はそれぞれ中身が違う想定なので Parallel を選んでいる。

## Task の2つの呼び出し方 — ここが最重要

Task ステートの `Resource` に何を書くかで、2つのやり方がある。

**1. Lambda 統合** — 自分のコードを呼ぶ

```yaml
Resource: arn:aws:states:::lambda:invoke
```

**2. AWS SDK 統合** — **Lambda を書かずに AWS の API を直接叩く**

```yaml
Resource: arn:aws:states:::aws-sdk:dynamodb:putItem
```

2つ目が Step Functions の大きな武器。
「DynamoDB に1行書く」「SNS に通知する」「S3 に置く」といった **AWS を呼ぶだけの処理に、Lambda を1つも書かなくていい**。
200以上のサービスに対応している。

本リポジトリも当初は結果書き込みを全部これでやっていた。今は Lambda 側に移してあるが、
理由は速度でも機能でもなく**責務の置き場所**の話。詳しくは後述の「なぜ SDK 統合をやめたか」。

## 入出力 — バケツリレー

各ステートは **入力 JSON を受け取り、出力 JSON を次のステートに渡す**、それだけ。

この受け渡しを制御する書き方に2つの流派がある。

| | **JSONPath**（従来） | **JSONata**（2024年11月〜、本リポジトリで採用） |
|---|---|---|
| 値の取り出し | `$.foo.bar` | `{% $states.input.foo.bar %}` |
| 使うフィールド | `InputPath` / `Parameters` / `ResultSelector` / `OutputPath` の4つを使い分け | `Arguments`（入力）と `Output`（出力）の2つだけ |
| 計算 | **できない** | できる（`$millis() - $enqueuedAt` など） |

JSONata を選んだのは、**経過ミリ秒の引き算が必要だった**から。JSONPath では書けない。

## 変数 (Variables)

バケツリレーだけだと、10ステート先で使う値を全ステートで持ち回る羽目になる。

`Assign` で値を変数に置くと、**以降のステートから `$変数名` で直接参照**できる。
本リポジトリの `$enqueuedAt`（SQS 到着時刻）がこれで、Parallel の中の8ステートすべてから参照している。

## Standard と Express

|  | **Standard**（本リポジトリ） | Express |
|---|---|---|
| 最大実行時間 | 1年 | 5分 |
| 実行履歴 | **サービス側に全件保存、API で取得可能** | CloudWatch Logs のみ |
| 課金 | 状態遷移の回数 | 実行時間 × メモリ |
| 同期呼び出し | 不可 | 可能 |

Standard を選んだ決め手は **実行履歴が API で取れる**こと。
今回の検証は「どのステートが何時何分何秒に始まって終わったか」を測るのが目的だったので、これが必須だった。

課金は状態遷移1000回あたり約 $0.025（リージョンにより異なる）。
本リポジトリのワークフローは1実行あたり約11遷移なので、1000実行しても $0.3 程度。

---

# Part 2: 成果物の解説

## ファイル構成

```
infra/template.yaml   521行  全リソース定義（Lambda のコードもここに入っている）
scripts/
  common.sh            25行  スタック出力の取得など共通処理
  deploy.sh            28行  デプロイ
  send-message.sh      18行  SQS にテスト送信
  verify.sh            42行  実行データを集めて report.py に渡す
  test-idempotency.sh  51行  冪等化テスト
  teardown.sh          12行  削除
  report.py           184行  受け入れ基準の判定
docs/                        要件定義・タスク分解・結果・本ガイド
```

## template.yaml の全体構造

CloudFormation テンプレートは3ブロック。

| ブロック | 行 | 内容 |
|---|---|---|
| `Parameters` | [7-27](../infra/template.yaml#L7) | デプロイ時に変えられる値（スリープ秒数など） |
| `Resources` | [29-502](../infra/template.yaml#L29) | 作るもの13個 |
| `Outputs` | [504-521](../infra/template.yaml#L504) | 作った後に知りたい値（キューURL、テーブル名など） |

`Resources` の13個は、役割で4グループに分かれる。

```
【土台】       ResultsTable(DynamoDB) / IntakeQueue + IntakeDlq(SQS)
【スタブ】     WorkerFunction + WorkerRole + WorkerLogGroup
【中核】       StateMachine + StateMachineRole + StateMachineLogGroup
【入口】       IntakeFunction + IntakeRole + IntakeLogGroup + EventSourceMapping
```

各リソースが **「本体 + IAM ロール + ロググループ」の3点セット**になっているのがポイント。
AWS では「誰が何をしてよいか」を必ず IAM ロールで宣言する必要があり、Lambda もステートマシンも例外ではない。

## ステートマシン定義を1行ずつ読む

[template.yaml:267-282](../infra/template.yaml#L267) の前処理ステート。

```yaml
Preprocess:
  Type: Task                                    # 仕事をするステート
  Resource: arn:aws:states:::lambda:invoke      # Lambda を呼ぶ
  Arguments:                                    # Lambda に渡す内容
    FunctionName: '${WorkerArn}'
    Payload:
      stage: preprocess
      sleepSeconds: '${PreprocessSleep}'
      input: '{% $states.input.body %}'
  Assign:                                       # 変数に保存（以降ずっと使える）
    enqueuedAt: '{% $states.input.enqueuedAt %}'
    messageId: '{% $states.input.messageId %}'
  Output: '{% { "preprocessed": $states.result.Payload.result } %}'
  Next: FanOut                                  # 次はここへ
```

**2種類の `${...}` と `{% %}` が混在しているので注意。**

| 記法 | 誰が処理するか | いつ |
|---|---|---|
| `${WorkerArn}` | **CloudFormation** | デプロイ時に1回だけ置換 |
| `{% $states.input.body %}` | **Step Functions** | 実行のたびに毎回評価 |

前者は `DefinitionSubstitutions`（[template.yaml:251-256](../infra/template.yaml#L251)）で値を渡している。
Lambda の ARN はデプロイするまで確定しないので、この仕組みが必要。

`$states` は Step Functions の予約変数。

| 式 | 意味 |
|---|---|
| `$states.input` | このステートへの入力 |
| `$states.result` | Task の実行結果 |
| `$states.context.Execution.Name` | 実行名（本リポジトリでは SQS の messageId） |

## Parallel の書き方

[template.yaml:284-288](../infra/template.yaml#L284)

```yaml
FanOut:
  Type: Parallel
  Next: MarkComplete      # 4分岐が「全部」終わったら次へ
  Branches:
    - StartAt: TransformA
      States: { ... }     # 分岐は独立した小さなステートマシン
    - StartAt: TransformB
      ...
```

**各分岐は独立した小さなステートマシン**で、それぞれ `StartAt` と `States` を持つ。
分岐には `Next` がなく、`End: true` で終わる。

4分岐すべてに **Parallel への入力がそのままコピーされて**渡る。
「同じデータを4通りに加工する」という要件にそのまま合致する。

## 結果の書き込み — ステートマシンではなく Lambda で

[template.yaml:291-305](../infra/template.yaml#L291) の加工A。**ステートは1つだけ**で、
「worker を呼ぶ」以上のことは書いていない。

```yaml
TransformA:
  Type: Task
  Resource: arn:aws:states:::lambda:invoke
  Arguments:
    FunctionName: '${WorkerArn}'
    Payload:
      stage: transform-a
      sleepSeconds: '${TransformASleep}'
      input: '{% $states.input.preprocessed %}'
      emit:                                              # ← 「結果を残せ」の指示
        executionId: '{% $states.context.Execution.Name %}'
        enqueuedAt: '{% $enqueuedAt %}'
  Output: '{% { "taskName": "transform-a", "elapsedMs": $states.result.Payload.writtenAt - $enqueuedAt } %}'
  End: true
```

`emit` は**行の中身ではなく、行の身元だけ**を渡す。どのテーブルに、どんな属性で、
どの時刻を刻んで書くかは worker 側 ([template.yaml:157-183](../infra/template.yaml#L157)) が決める。

```python
def put_result(stage, result, emit):
    enqueued_at = int(emit["enqueuedAt"])
    written_at = int(time.time() * 1000)

    item = {
        "executionId": {"S": emit["executionId"]},
        "taskName": {"S": stage},
        "enqueuedAt": {"N": str(enqueued_at)},
        "writtenAt": {"N": str(written_at)},
        "elapsedMs": {"N": str(written_at - enqueued_at)},   # ← ただの引き算
        "result": {"S": result},
        "expireAt": {"N": str(written_at // 1000 + TTL_SECONDS)},
    }
    dynamodb.put_item(TableName=RESULTS_TABLE, Item=item)
    return written_at
```

`S:` `N:` は **DynamoDB の型付き表記**。`S` = 文字列、`N` = 数値。
低レベル API がこの形式を要求するため、Python から呼ぶときも同じ形で書く。

`emit` を渡さなければ書き込みは起きない。前処理ステートには `emit` が無いので、
同じ worker を使いながら何も残さない。

**この書き込みが設計の核心。** ここで書くから、加工A は他の分岐を待たずに結果を外に出せる。

### なぜ SDK 統合をやめたか

以前はこの書き込みを Step Functions の **AWS SDK 統合**（`arn:aws:states:::aws-sdk:dynamodb:putItem`）
という別ステートで行っていた。Lambda を経由せず Step Functions が直接 AWS API を叩ける機能で、
`elapsedMs` は JSONata の算術（`$millis() - $enqueuedAt`）で出していた。

やめた理由は**責務の置き場所**。テンプレートは「どういう順序で何が動くか」だけを持ち、
「結果をどう残すか」はアプリケーション側（Lambda）に置きたい。
出力仕様を変えるたびに IaC を触るのは、変更の単位として大きすぎる。

トレードオフも書いておく。

| | SDK 統合（旧） | Lambda 内で書く（新） |
|---|---|---|
| 書き込み完了時刻 | **実行履歴に専用ステートとして残る** | Lambda の中。行の `writtenAt` で見る |
| 出力仕様の変更 | テンプレート修正＋再デプロイ | Lambda コードのみ |
| DynamoDB 権限 | ステートマシンロール | worker ロール |
| ステート数 | 分岐あたり2 | 分岐あたり1 |
| 失敗の切り分け | 「加工が失敗」と「書き込みが失敗」が別ステート | 同じ Task に混ざる |
| 書き込み1回のコスト | 約 90〜160ms（ステート遷移込み） | **5〜8ms**（`put_item` 単体） |
| コールドスタート | — | **+約800ms 悪化**（boto3 の初期化） |

実測は [検証結果](./results.md) にある。**ウォーム時は新構成が速く、コールド時は旧構成が速い。**
常時トラフィックがあるなら新構成が有利で、散発的な起動が多いならコールドスタート対策が要る。

コンソールのグラフビューは、旧構成では分岐ごとに箱が2つ並んでいた。
新構成では1つになり、**書き込みの所要時間はグラフからは読めなくなる**。
代わりに worker の CloudWatch Logs（`stage.end` 行の `writtenAt`）と
DynamoDB の行そのものを見ることになる。

## なぜこの設計だったか

```
【素朴な設計 — 失敗する】
  Parallel の出力に4つの結果を載せて、後段で返す
    → Parallel は全分岐の完了を待つ
    → 加工A(1秒) の結果も、加工B/C/D(8秒) に引きずられて 9.6秒後にしか出てこない
    → 10秒目標に対して余裕がほぼゼロ

【採用した設計】
  各分岐の加工 Lambda が、返る前に自分の結果を DynamoDB に書く
    → 加工A は自分が終わった 2.4秒後に書き込み完了
    → 実測で Parallel 完了より 7.1秒早い
```

Step Functions の出力経路は使わず、**副作用として外に出す**。
これが「並列の一部だけ早く返す」の定石。

## Lambda のコードがテンプレートに埋まっている理由

[template.yaml:105-183](../infra/template.yaml#L105) を見ると、Python のコードが YAML の中に直接書かれている。

```yaml
Code:
  ZipFile: |
    import json
    import time
    def handler(event, context):
        ...
```

これは `Code.ZipFile` という機能で、**短いコードならテンプレートに直接書ける**というもの。

通常 Lambda をデプロイするには「コードを zip → S3 にアップロード → その場所をテンプレートで指定」という手順が要る。
そのために S3 バケットを用意し、ビルドスクリプトを書くことになる。
今回はスタブが30行程度だったので、`ZipFile` で **S3 もビルド手順も不要**にした。
`aws cloudformation deploy` 一発で完結する。

制限は約4096文字で、外部ライブラリも入れられない（boto3 だけは標準で使える）。
実処理を書く段階になったら S3 方式か、SAM/CDK のようなツールに移行することになる。

## IAM の考え方

3つのロールがあるが、いずれも**必要最小限だけを許可**している。
たとえばステートマシンのロール（[template.yaml:201-237](../infra/template.yaml#L201)）は、
**Lambda を呼ぶ権限しか持っていない**。

```yaml
- Effect: Allow
  Action: lambda:InvokeFunction
  Resource:
    - !GetAtt WorkerFunction.Arn      # この関数だけ。他の Lambda は呼べない
```

DynamoDB への書き込み権限は worker のロール（[template.yaml:81-103](../infra/template.yaml#L81)）にある。

```yaml
- Effect: Allow
  Action: dynamodb:PutItem            # 書き込みのみ。読み取りも削除もできない
  Resource: !GetAtt ResultsTable.Arn  # このテーブルだけ
```

**書き込みを実際に行う主体に権限を置く**、という当たり前の形。
SDK 統合を使っていた頃はステートマシン側に付いていた。

1箇所だけ `Resource: '*'` がある（[template.yaml:222-237](../infra/template.yaml#L222)）。
これは Step Functions のログ配信設定に必要なもので、**AWS の仕様上リソースを絞れない**ため。
テンプレート内にコメントで明記してある。

## 受付 Lambda の冪等化

[template.yaml:479-500](../infra/template.yaml#L479)

```python
name = re.sub(r"[^0-9a-zA-Z_-]", "-", message_id)[:80]
started = sfn.start_execution(stateMachineArn=..., name=name, input=...)
```

**実行名に SQS の messageId を使う**のがポイント。
Step Functions は同じ実行名を90日間受け付けないため、SQS が同じメッセージを再配信しても実行が二重に走らない。
「重複排除の仕組みを自前で作らなくていい」という、地味だが大きな利点。

`re.sub` は、実行名に使える文字が限られている（英数字・ハイフン・アンダースコアのみ、80文字以内）ための整形。

なおこの API には落とし穴が2つある（[検証結果](./results.md)にも記載）。

| 条件 | 挙動 |
|---|---|
| 同じ名前 + **同じ入力** | 例外を出さず、**既存の実行をそのまま返す** |
| 同じ名前 + **違う入力** | `ExecutionAlreadyExists` 例外 |

前者は例外にならないので、素朴に書くと「新規に開始した」とログしてしまう。
戻り値の `startDate` を呼び出し時刻と比べて判別している。

## SQS と Lambda の繋ぎ方

[template.yaml:522-530](../infra/template.yaml#L522)

```yaml
IntakeEventSourceMapping:
  Type: AWS::Lambda::EventSourceMapping
  Properties:
    EventSourceArn: !GetAtt IntakeQueue.Arn
    FunctionName: !GetAtt IntakeFunction.Arn
    BatchSize: 1
    FunctionResponseTypes:
      - ReportBatchItemFailures
```

**イベントソースマッピング**は「SQS を勝手にポーリングして、メッセージが来たら Lambda を呼ぶ」という AWS 管理の仕組み。
ポーリングのコードを書く必要はない。

`ReportBatchItemFailures` は、Lambda が「このメッセージだけ失敗した」と返せるようにする設定
（[template.yaml:520](../infra/template.yaml#L520) の `return {"batchItemFailures": failures}` がそれ）。
これがないと、バッチ内の1件が失敗したときに**成功した分まで再配信**されてしまう。

## スクリプト群

| ファイル | 役割 |
|---|---|
| [common.sh](../scripts/common.sh) | `stack_output QueueUrl` のように、スタックの Outputs を名前で引く関数。他の全スクリプトが読み込む |
| [deploy.sh](../scripts/deploy.sh) | `aws cloudformation deploy` のラッパー。スリープ秒数を環境変数で上書きできる |
| [send-message.sh](../scripts/send-message.sh) | SQS に1件送信し、messageId と対応する実行名を表示 |
| [verify.sh](../scripts/verify.sh) | 実行データ3種を AWS から取得し、`report.py` に渡す |
| [report.py](../scripts/report.py) | 判定ロジック本体 |

**なぜ verify だけ2ファイルに分かれているか**: 時刻の計算（ISO8601 のパース、ミリ秒の差分、テーブル整形）は
bash + jq では非常に書きづらいため。
`verify.sh` は AWS からデータを取ってくるだけ、`report.py` は受け取った JSON を判定するだけ、と役割を分けている。
`report.py` は **boto3 を使わず標準ライブラリのみ**なので、pip install なしで動く。

## report.py が見ているデータ

3つの JSON を突き合わせている。

| ソース | 取れるもの |
|---|---|
| `describe-execution` | ステータス、開始/終了時刻 |
| `get-execution-history` | **全ステートの EnteredTime / ExitedTime** |
| DynamoDB の `query` | 各分岐が書いた `elapsedMs` |

2番目が Standard ワークフローの真価。
`state_times()`（[report.py:35-48](../scripts/report.py#L35)）が `TaskStateEntered` / `TaskStateExited` といったイベントを拾って
「ステート名 → 開始/終了時刻」の表を作り、これで AC-2（順序）、AC-3（同時開始）、AC-6（先行）を判定している。

**AC-6 の判定**（[report.py:166-173](../scripts/report.py#L166)）が検証全体の要。

```python
a_exit = times["TransformA"]["exit"]  # 加工A（書き込み込み）が終わった時刻
fan_exit = times["FanOut"]["exit"]    # Parallel 全体が終わった時刻
ok = a_exit < fan_exit                # 前者が先なら、設計が効いている
```

書き込みが Lambda の中に入ったので、**ステート `TransformA` の退出時刻が「行が確実に読める最初の時刻」**になる。
より正確な書き込み時刻は行の `writtenAt` に入っていて、report.py は
「DynamoDB 書き込み結果」の欄にその差も併記する。

実測で平均7.1秒の差がついた。

---

## 最初に読むならこの順番

1. [要件定義書](./requirements.md) の「6. 設計方針と根拠」 — なぜこの形なのか
2. [template.yaml:256-373](../infra/template.yaml#L256) の `Definition:` ブロック — ワークフロー定義そのもの
3. [検証結果](./results.md) — 実測値
