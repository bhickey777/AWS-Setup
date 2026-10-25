#!/usr/bin/env bash
# push-image.sh - build a service image and push it to ECR with two tags: latest and the git commit SHA.
#
# Usage:
#   ./push-image.sh [-p platform] <region> <source-dir> <repository-name>
#
#   -p   target platform (default linux/amd64, which matches Fargate X86_64 and the Lab 7 default)
#
# Example:
#   ./push-image.sh us-east-1 ~/src/mission-service leap-mission-service
#
# The ECR repository must already exist. The source directory must contain a Dockerfile and be a
# git checkout (the commit SHA becomes the second tag). Prints the exact image URI to give students.

set -euo pipefail

PLATFORM="linux/amd64"
REGION='us-east-1'
SRC='mission-service'
REPO='leap-mission-service'

for tool in aws docker git; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
[ -f "$SRC/Dockerfile" ] || { echo "No Dockerfile in $SRC" >&2; exit 1; }

ACCOUNT_ID=760144414473
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
SHA=$(git -C "$SRC" rev-parse --short=12 HEAD)
if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
  echo "WARNING: uncommitted changes in $SRC. The image will not match commit $SHA exactly." >&2
fi

aws ecr describe-repositories --region "$REGION" --repository-names "$REPO" >/dev/null \
  || { echo "ECR repository $REPO not found in $REGION. Deploy lab06-ecr-repository.yaml first." >&2; exit 1; }

echo "Building $REPO for $PLATFORM from commit $SHA ..."
docker build --platform "$PLATFORM" -t "$REPO:$SHA" "$SRC"
docker tag "$REPO:$SHA" "$REGISTRY/$REPO:$SHA"
docker tag "$REPO:$SHA" "$REGISTRY/$REPO:latest"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
docker push "$REGISTRY/$REPO:$SHA"
docker push "$REGISTRY/$REPO:latest"

echo
echo "Pushed. Give students this image (pinned to the commit, so it never changes under them):"
echo "  $REGISTRY/$REPO:$SHA"
echo "Digest and tags:"
aws ecr describe-images --region "$REGION" --repository-name "$REPO" --image-ids imageTag="$SHA" \
  --query 'imageDetails[0].[imageDigest,imageTags]' --output text
