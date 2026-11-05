#!/usr/bin/env bash
# Packages the nested templates to S3 and deploys/updates one environment.
# Intended for AWS CloudShell or any Linux/macOS shell with the AWS CLI v2 and jq.
#
#   ./scripts/deploy.sh sandbox
#   AWS_PROFILE=nls-prod ./scripts/deploy.sh prod
#   VALIDATE_ONLY=1 ./scripts/deploy.sh sandbox
set -euo pipefail

ENVIRONMENT=${1:?usage: deploy.sh <environment>   (name of a file in ./params without .json)}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG="$ROOT/params/$ENVIRONMENT.json"
[[ -f "$CONFIG" ]] || { echo "Parameter file not found: $CONFIG" >&2; exit 1; }

REGION=${REGION:-$(jq -r .Region "$CONFIG")}
STACK_NAME=$(jq -r .StackName "$CONFIG")
export AWS_DEFAULT_REGION=$REGION

echo "Validating templates..."
for t in "$ROOT"/templates/*.yaml; do
  aws cloudformation validate-template --template-body "file://$t" > /dev/null
  echo "  OK  $(basename "$t")"
done
[[ -n "${VALIDATE_ONLY:-}" ]] && exit 0

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=${ARTIFACT_BUCKET:-cfn-artifacts-$ACCOUNT-$REGION}

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Creating artifact bucket $BUCKET"
  aws s3 mb "s3://$BUCKET"
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

mkdir -p "$ROOT/.build"
PACKAGED="$ROOT/.build/$STACK_NAME.packaged.yaml"

echo "Packaging templates to s3://$BUCKET/$STACK_NAME/"
aws cloudformation package \
  --template-file "$ROOT/templates/main.yaml" \
  --s3-bucket "$BUCKET" \
  --s3-prefix "$STACK_NAME" \
  --output-template-file "$PACKAGED" > /dev/null

mapfile -t OVERRIDES < <(jq -r '.Parameters | to_entries[] | "\(.key)=\(.value)"' "$CONFIG")
mapfile -t TAGS < <(jq -r '.Tags | to_entries[] | "\(.key)=\(.value)"' "$CONFIG")

echo "Deploying stack $STACK_NAME to $REGION (this takes ~10-15 min, longer with RDS)..."
aws cloudformation deploy \
  --template-file "$PACKAGED" \
  --stack-name "$STACK_NAME" \
  --s3-bucket "$BUCKET" \
  --s3-prefix "$STACK_NAME" \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides "${OVERRIDES[@]}" \
  --tags "${TAGS[@]}"

aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
