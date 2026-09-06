#!/usr/bin/env bash
# AC-8: replaying the same SQS messageId must not start a second execution.
# SQS assigns a fresh messageId on every send, so we replay the event straight
# into the intake Lambda instead.
#
# Two duplicate paths exist and both are exercised here:
#   #2 same name + same input  -> StartExecution returns the original execution
#   #3 same name + other input -> StartExecution raises ExecutionAlreadyExists
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_stack

SM_ARN="$(stack_output StateMachineArn)"
FN="$(stack_output IntakeFunctionName)"
QUEUE_ARN="$(stack_output QueueArn)"
MESSAGE_ID="dup-test-$(date +%s)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_event() {  # $1 = body marker
  cat > "$WORK/event-$1.json" <<JSON
{"Records":[{"messageId":"$MESSAGE_ID",
  "body":"{\"command\":\"process\",\"orderId\":\"$MESSAGE_ID\",\"variant\":\"$1\"}",
  "attributes":{"SentTimestamp":"$(( $(date +%s) * 1000 ))"},
  "eventSource":"aws:sqs","eventSourceARN":"$QUEUE_ARN"}]}
JSON
}
make_event same
make_event other

invoke() {  # $1 = label, $2 = event file marker
  echo "--- $1 ---"
  aws lambda invoke --function-name "$FN" \
    --payload "fileb://$WORK/event-$2.json" \
    --log-type Tail --query LogResult --output text "$WORK/out.json" \
    | base64 --decode | grep -E 'execution\.(started|deduplicated|duplicate|failed)' || true
}

invoke "#1 初回 (name=$MESSAGE_ID)"            same
invoke "#2 同名・同一入力 -> 既存実行を返す"      same
invoke "#3 同名・入力違い -> ExecutionAlreadyExists" other

COUNT="$(aws stepfunctions list-executions --state-machine-arn "$SM_ARN" --max-results 100 \
  --query "length(executions[?name=='$MESSAGE_ID'])" --output text)"

echo
if [[ "$COUNT" == "1" ]]; then
  echo -e "\033[32mPASS\033[0m  AC-8 冪等化: 3回呼んでも実行は $COUNT 件"
else
  echo -e "\033[31mFAIL\033[0m  AC-8 冪等化: 実行が $COUNT 件 (期待 1)"
  exit 1
fi
