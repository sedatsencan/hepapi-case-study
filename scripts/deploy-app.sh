#!/usr/bin/env bash
# Deploys the application chart. Defaults to the local kind values and the image
# tag recorded by build-and-load.sh.
#
# Usage: ./scripts/deploy-app.sh [--values FILE] [--image-tag TAG]

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd helm
require_cmd kubectl

CHART_DIR="${REPO_ROOT}/charts/taskmanager"
VALUES_FILE="${CHART_DIR}/values-local.yaml"
IMAGE_TAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --values)
      VALUES_FILE="$2"
      shift 2
      ;;
    --image-tag)
      IMAGE_TAG="$2"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Falls back to whatever build-and-load.sh last produced.
IMAGE_TAG="${IMAGE_TAG:-$(current_image_tag)}"

log_step "Application (image tag ${IMAGE_TAG})"
helm upgrade --install "${APP_RELEASE}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --set "image.tag=${IMAGE_TAG}" \
  --wait \
  --timeout 5m
log_success "released"

kubectl --namespace "${NAMESPACE}" rollout status "deployment/${APP_RELEASE}" --timeout=180s
