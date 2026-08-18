#!/usr/bin/env bash
# Verifies the local toolchain and installs the pinned versions of anything
# missing into ./.bin. Safe to re-run.
#
# Usage: ./scripts/preflight.sh [--yes]

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASSUME_YES="false"
for arg in "$@"; do
  case "$arg" in
    --yes | -y) ASSUME_YES="true" ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

confirm() {
  [ "${ASSUME_YES}" = "true" ] && return 0
  local answer
  read -r -p "    ${1} [y/N] " answer
  [[ "${answer}" =~ ^[Yy]$ ]]
}

OS="$(host_os)"
ARCH="$(host_arch)"
mkdir -p "${LOCAL_BIN}"

# ---------------------------------------------------------------------------
log_step "Checking Docker"
# ---------------------------------------------------------------------------
require_cmd docker
docker info >/dev/null 2>&1 || die "the Docker daemon is not responding, start Docker Desktop"
log_success "docker $(docker version --format '{{.Server.Version}}')"

memory_bytes="$(docker info --format '{{.MemTotal}}')"
memory_gb=$((memory_bytes / 1024 / 1024 / 1024))
if [ "${memory_gb}" -lt 6 ]; then
  log_warn "Docker has ${memory_gb}GB of memory; a 3-node cluster plus MongoDB wants at least 6GB"
else
  log_success "docker memory ${memory_gb}GB"
fi

# ---------------------------------------------------------------------------
log_step "Checking kubectl"
# ---------------------------------------------------------------------------
require_cmd kubectl
log_success "kubectl $(kubectl version --client -o json | grep -o '"gitVersion": *"[^"]*"' | head -1 | cut -d'"' -f4)"

# ---------------------------------------------------------------------------
log_step "Checking kind (${KIND_VERSION})"
# ---------------------------------------------------------------------------
install_kind() {
  local url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${OS}-${ARCH}"
  log_info "downloading kind ${KIND_VERSION} for ${OS}/${ARCH}"
  download_verified "${url}" "${url}.sha256sum" "${LOCAL_BIN}/kind"
  chmod +x "${LOCAL_BIN}/kind"
  log_success "kind installed to .bin/kind"
}

if command -v kind >/dev/null 2>&1 && [ "$(kind version -q 2>/dev/null || true)" = "${KIND_VERSION#v}" ]; then
  log_success "kind ${KIND_VERSION} already present"
elif confirm "install kind ${KIND_VERSION} into ./.bin?"; then
  install_kind
else
  die "kind ${KIND_VERSION} is required"
fi

# ---------------------------------------------------------------------------
log_step "Checking Helm (${HELM_VERSION})"
# ---------------------------------------------------------------------------
install_helm() {
  local archive="helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  local url="https://get.helm.sh/${archive}"
  local workdir
  workdir="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand workdir now, not at trap time
  # EXIT rather than RETURN: die() exits the script, and RETURN traps do not
  # fire on exit, which would leak the download directory.
  trap "rm -rf '${workdir}'" EXIT

  log_info "downloading Helm ${HELM_VERSION} for ${OS}/${ARCH}"
  download_verified "${url}" "${url}.sha256sum" "${workdir}/${archive}"
  tar -xzf "${workdir}/${archive}" -C "${workdir}"
  mv "${workdir}/${OS}-${ARCH}/helm" "${LOCAL_BIN}/helm"
  chmod +x "${LOCAL_BIN}/helm"
  log_success "helm installed to .bin/helm"
}

if command -v helm >/dev/null 2>&1 \
  && helm version --short 2>/dev/null | grep -qE "^${HELM_VERSION//./\\.}(\+|$)"; then
  log_success "helm ${HELM_VERSION} already present"
elif confirm "install Helm ${HELM_VERSION} into ./.bin?"; then
  install_helm
else
  die "Helm ${HELM_VERSION} is required"
fi

# ---------------------------------------------------------------------------
log_step "Checking host ports"
# ---------------------------------------------------------------------------
for port in "${INGRESS_HTTP_PORT}" 8443; do
  # Captured through || so that a non-zero result is not treated as a failed
  # command by set -e; here it is an answer, not an error.
  port_status=0
  port_in_use "${port}" || port_status=$?
  case "${port_status}" in
    0) log_warn "port ${port} is already in use; ingress will not bind. Reach the app with 'make port-forward' instead" ;;
    1) log_success "port ${port} available" ;;
    *) log_warn "cannot check port ${port}: no lsof, ss or netstat on this machine" ;;
  esac
done

log_step "Preflight complete"
