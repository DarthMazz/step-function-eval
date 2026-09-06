#!/usr/bin/env bash
# Delete the PoC stack and wait for it to disappear.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_stack

read -r -p "delete stack '$STACK_NAME' in $REGION? [y/N] " reply
[[ "$reply" == [yY] ]] || { echo "aborted"; exit 1; }

aws cloudformation delete-stack --stack-name "$STACK_NAME"
echo "waiting for delete to complete..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
echo "deleted"
