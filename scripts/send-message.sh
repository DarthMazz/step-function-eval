#!/usr/bin/env bash
# Put one test message on the intake queue.
#
#   scripts/send-message.sh              # default payload
#   scripts/send-message.sh '{"foo":1}'  # custom payload
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_stack

QUEUE_URL="$(stack_output QueueUrl)"
BODY="${1:-{\"command\":\"process\",\"orderId\":\"test-$(date +%s)\"}}"

RESP="$(aws sqs send-message --queue-url "$QUEUE_URL" --message-body "$BODY")"
MESSAGE_ID="$(jq -r '.MessageId' <<<"$RESP")"

echo "queue      : $QUEUE_URL"
echo "body       : $BODY"
echo "messageId  : $MESSAGE_ID"
echo "executionId: ${MESSAGE_ID//[^0-9a-zA-Z_-]/-}"
