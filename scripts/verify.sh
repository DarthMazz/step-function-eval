#!/usr/bin/env bash
# Collect one execution's data and check it against the acceptance criteria.
#
#   scripts/verify.sh                 # newest execution
#   scripts/verify.sh <executionId>   # a specific one (= sanitised SQS messageId)
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_stack

SM_ARN="$(stack_output StateMachineArn)"
TABLE="$(stack_output ResultsTableName)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ $# -ge 1 ]]; then
  EXEC_ARN="$(aws stepfunctions list-executions --state-machine-arn "$SM_ARN" --max-results 100 \
    --query "executions[?name=='$1'].executionArn | [0]" --output text)"
  [[ "$EXEC_ARN" == "None" || -z "$EXEC_ARN" ]] && { echo "execution '$1' not found" >&2; exit 1; }
else
  EXEC_ARN="$(aws stepfunctions list-executions --state-machine-arn "$SM_ARN" --max-results 1 \
    --query 'executions[0].executionArn' --output text)"
  [[ "$EXEC_ARN" == "None" || -z "$EXEC_ARN" ]] && { echo "no executions yet" >&2; exit 1; }
fi

STATUS="$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query status --output text)"
if [[ "$STATUS" == "RUNNING" ]]; then
  echo "execution is still RUNNING -- waiting for it to settle..."
  for _ in $(seq 1 60); do
    STATUS="$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query status --output text)"
    [[ "$STATUS" != "RUNNING" ]] && break
    sleep 2
  done
fi

aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" > "$WORK/execution.json"
aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" --max-results 1000 > "$WORK/history.json"

EXEC_ID="$(jq -r '.name' "$WORK/execution.json")"
aws dynamodb query --table-name "$TABLE" \
  --key-condition-expression 'executionId = :e' \
  --expression-attribute-values "{\":e\":{\"S\":\"$EXEC_ID\"}}" > "$WORK/rows.json"

python3 "$REPO_ROOT/scripts/report.py" "$WORK/execution.json" "$WORK/history.json" "$WORK/rows.json"
