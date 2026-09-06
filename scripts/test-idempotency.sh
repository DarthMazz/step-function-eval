#!/usr/bin/env bash
# AC-8: replaying the same SQS messageId must not start a second execution.
# SQS assigns a fresh messageId on every send, so we replay the event straight
# into the intake Lambda instead.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_stack

SM_ARN="$(stack_output StateMachineArn)"
FN="$(stack_output IntakeFunctionName)"
QUEUE_ARN="$(stack_output QueueArn)"
MESSAGE_ID="dup-test-$(date +%s)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/event.json" <<JSON
{"Records":[{"messageId":"$MESSAGE_ID",
  "body":"{\"command\":\"process\",\"orderId\":\"$MESSAGE_ID\"}",
  "attributes":{"SentTimestamp":"$(( $(date +%s) * 1000 ))"},
  "eventSource":"aws:sqs","eventSourceARN":"$QUEUE_ARN"}]}
JSON

for attempt in 1 2; do
  echo "--- invoke #$attempt (messageId=$MESSAGE_ID) ---"
  aws lambda invoke --function-name "$FN" \
    --payload "fileb://$WORK/event.json" \
    --log-type Tail --query LogResult --output text "$WORK/out.json" \
    | base64 --decode | grep -E 'execution\.(started|duplicate|failed)' || true
done

COUNT="$(aws stepfunctions list-executions --state-machine-arn "$SM_ARN" --max-results 100 \
  --query "length(executions[?name=='$MESSAGE_ID'])" --output text)"

echo
if [[ "$COUNT" == "1" ]]; then
  echo -e "\033[32mPASS\033[0m  AC-8 冪等化: 2回呼んでも実行は $COUNT 件"
else
  echo -e "\033[31mFAIL\033[0m  AC-8 冪等化: 実行が $COUNT 件 (期待 1)"
  exit 1
fi
