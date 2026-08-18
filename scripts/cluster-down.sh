#!/usr/bin/env bash
# Deletes the local kind cluster. Everything in it, including the MongoDB
# volume, is destroyed with it.
#
# Usage: ./scripts/cluster-down.sh [--purge]
#   --purge  also remove locally built application images

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PURGE="false"
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE="true" ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

require_cmd kind

log_step "Cluster ${CLUSTER_NAME}"
if cluster_exists; then
  kind delete cluster --name "${CLUSTER_NAME}"
  log_success "deleted"
else
  log_info "not found, nothing to do"
fi

if [ "${PURGE}" = "true" ]; then
  log_step "Purging locally built images"
  # Only images built by build-and-load.sh, identified by the dev- tag prefix.
  images="$(docker images "${IMAGE_REPOSITORY}" --format '{{.Repository}}:{{.Tag}}' | grep ':dev-' || true)"
  if [ -n "${images}" ]; then
    # shellcheck disable=SC2086  # intentional word splitting over the image list
    docker rmi ${images} >/dev/null
    log_success "removed $(printf '%s\n' "${images}" | wc -l | tr -d ' ') image(s)"
  else
    log_info "no locally built images found"
  fi
  rm -f "${IMAGE_TAG_FILE}"
fi
