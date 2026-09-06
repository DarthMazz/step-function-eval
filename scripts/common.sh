#!/usr/bin/env bash
# Shared settings and helpers for the sfeval scripts.
set -euo pipefail

STACK_NAME="${STACK_NAME:-sfeval-poc}"
REGION="${AWS_REGION:-$(aws configure get region)}"
export AWS_DEFAULT_REGION="$REGION"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO_ROOT/infra/template.yaml"

# stack_output <OutputKey> -> prints the value
stack_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

require_stack() {
  if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    echo "stack '$STACK_NAME' not found in $REGION -- run scripts/deploy.sh first" >&2
    exit 1
  fi
}
