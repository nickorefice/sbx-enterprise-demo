#!/usr/bin/env bash
# build.sh — build and push the golden sandbox template to nicksdemoorg registry.
#
# Usage:
#   ./build.sh          # build + push docker.io/nicksdemoorg/sbx-golden:v1
#   DRY_RUN=1 ./build.sh    # build only (no push), useful for local validation
#
# Prerequisites:
#   - docker login docker.io (or sbx secret set <sandbox> dockerhub)
#   - replace templates/golden/corp-ca.crt with your real corporate CA cert

set -euo pipefail

IMAGE="docker.io/nicksdemoorg/sbx-golden"
TAG="${TAG:-v1}"
FULL_IMAGE="${IMAGE}:${TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Building ${FULL_IMAGE}"
docker build \
  --platform linux/arm64 \
  --tag "${FULL_IMAGE}" \
  --file "${SCRIPT_DIR}/Dockerfile" \
  "${SCRIPT_DIR}"

echo "==> Build complete: ${FULL_IMAGE}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN=1 — skipping push."
  exit 0
fi

echo "==> Pushing ${FULL_IMAGE}"
docker push "${FULL_IMAGE}"
echo "==> Pushed. Use with:"
echo "    sbx run claude --template ${FULL_IMAGE}"
