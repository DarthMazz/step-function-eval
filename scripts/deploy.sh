#!/usr/bin/env bash
# Deploy (or update) the PoC stack.
#
#   scripts/deploy.sh
#   TRANSFORM_A_SLEEP=1 TRANSFORM_BCD_SLEEP=8 scripts/deploy.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PREPROCESS_SLEEP="${PREPROCESS_SLEEP:-1}"
TRANSFORM_A_SLEEP="${TRANSFORM_A_SLEEP:-1}"
TRANSFORM_BCD_SLEEP="${TRANSFORM_BCD_SLEEP:-8}"

echo "deploying stack '$STACK_NAME' to $REGION"
echo "  preprocess=${PREPROCESS_SLEEP}s  transform-a=${TRANSFORM_A_SLEEP}s  transform-b/c/d=${TRANSFORM_BCD_SLEEP}s"

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "PreprocessSleepSeconds=$PREPROCESS_SLEEP" \
    "TransformASleepSeconds=$TRANSFORM_A_SLEEP" \
    "TransformBcdSleepSeconds=$TRANSFORM_BCD_SLEEP"

echo
echo "outputs:"
aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' --output table
