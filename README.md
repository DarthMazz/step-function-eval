# step-function-eval

AWS Step Functions の検証用リポジトリ。

SQS を起点とした非同期パイプラインで、**並列処理のうち一部だけを早く返せるか**を実機で確認する。

- **[Step Functions 入門と本リポジトリの解説](docs/step-functions-guide.md)** — 予備知識なしで読める解説。ここから
- [要件定義書](docs/requirements.md)
- [タスク分解](docs/tasks.md)
- [検証結果](docs/results.md)
- [STANDARD と EXPRESS のコンソール比較](docs/console-comparison.md) — 障害解析のしやすさを実機で比較

## 検証するフロー

```
SQS → ① 受付Lambda → StartExecution
                        │
   ┌────────────────────┴─────────────────────┐
   │ Step Functions (Standard / JSONata)       │
   │   ② 前処理                                │
   │       ↓                                   │
   │   ③ Parallel                              │
   │      ├─ 加工A → DynamoDB   ← 10秒以内      │
   │      ├─ 加工B → DynamoDB   ← 15秒以内      │
   │      ├─ 加工C → DynamoDB   ← 15秒以内      │
   │      └─ 加工D → DynamoDB   ← 15秒以内      │
   │       ↓                                   │
   │   ④ 完了マーク → DynamoDB                  │
   └───────────────────────────────────────────┘
```

各処理の中身はスタブ（指定秒数スリープするだけ）。計測起点は **SQS へのメッセージ到着時刻**。

**設計の要点**: Parallel は全ブランチの完了を待つため、ステートマシンの出力経路に結果を載せると
加工A も最も遅い分岐に引きずられる。そこで**各分岐の加工 Lambda が、返る前に自分の結果を DynamoDB に書き込む**。
これで加工A は他分岐を待たずに読み出せる。

ステートマシン定義は**フローの順序だけ**を持ち、結果の出力仕様（テーブル・属性・TTL）は worker Lambda 側にある。

## 前提

- AWS CLI v2 で認証済み（`aws login` など）、リージョン `ap-northeast-1`
- `jq`, `python3` (3.11+)
- IaC は**生の CloudFormation + AWS CLI** のみ。CDK / SAM / Terraform は使わない

## 使い方

```bash
scripts/deploy.sh              # スタック sfeval-poc をデプロイ
scripts/send-message.sh        # SQS にテストメッセージを1件送信
scripts/verify.sh              # 直近の実行を受け入れ基準 AC-2..AC-7 で判定
scripts/test-idempotency.sh    # AC-8: 同一 messageId の再配信で二重実行しないこと
scripts/teardown.sh            # スタック削除
```

スリープ秒数はデプロイ時に変更できる。

```bash
TRANSFORM_A_SLEEP=1 TRANSFORM_BCD_SLEEP=12 scripts/deploy.sh
```

## 構成

| パス | 内容 |
|---|---|
| `infra/template.yaml` | 全リソースの CloudFormation テンプレート（Lambda コードもインライン）。ステートマシン定義はフローのみ |
| `scripts/common.sh` | スタック出力の取得など共通処理 |
| `scripts/report.py` | 実行履歴と DynamoDB から受け入れ基準を判定（標準ライブラリのみ） |
| `docs/` | 解説・要件定義・タスク分解・検証結果 |

## 作成されるリソース

すべて `sfeval-` プレフィクス、CloudFormation スタック `sfeval-poc` に含まれる。

`sfeval-intake`（SQS + DLQ）/ `sfeval-intake`（Lambda）/ `sfeval-worker`（Lambda）/
`sfeval-workflow`（ステートマシン）/ `sfeval-results`（DynamoDB）/ 各 IAM ロール・ロググループ
