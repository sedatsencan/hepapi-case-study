#!/usr/bin/env bash
# Builds the application image and loads it straight into the kind nodes'
# containerd store, so no registry is involved in the local workflow.
#
# Usage: ./scripts/build-and-load.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd docker
require_cmd kind

cluster_exists || die "cluster ${CLUSTER_NAME} not found (run ./scripts/cluster-up.sh)"

# ---------------------------------------------------------------------------
log_step "Resolving image tag"
# ---------------------------------------------------------------------------
git_sha="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "nogit")"

# A dirty tree gets a unique suffix on purpose. The deployment pins
# imagePullPolicy: IfNotPresent, so reusing a tag would leave the old image
# running after a rebuild, with no visible error.
if [ -n "$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null || true)" ]; then
  IMAGE_TAG="dev-${git_sha}-$(date +%Y%m%d%H%M%S)"
else
  IMAGE_TAG="dev-${git_sha}"
fi

IMAGE_REFERENCE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
log_success "${IMAGE_REFERENCE}"

# ---------------------------------------------------------------------------
log_step "Building"
# ---------------------------------------------------------------------------
docker build --tag "${IMAGE_REFERENCE}" "${REPO_ROOT}"
log_success "built"

# ---------------------------------------------------------------------------
log_step "Loading into ${CLUSTER_NAME}"
# ---------------------------------------------------------------------------
# The image never reaches a registry, so the deployment must not try to pull it.
kind load docker-image "${IMAGE_REFERENCE}" --name "${CLUSTER_NAME}"
log_success "loaded onto all nodes"

printf '%s' "${IMAGE_TAG}" > "${IMAGE_TAG_FILE}"
log_info "tag recorded in .image-tag for the deploy scripts"
