#!/usr/bin/env bash
# Creates the local kind cluster and installs the ingress controller.
# Idempotent: re-running against an existing cluster is a no-op.
#
# Usage: ./scripts/cluster-up.sh [--recreate]

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECREATE="false"
for arg in "$@"; do
  case "$arg" in
    --recreate) RECREATE="true" ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

require_cmd kind
require_cmd kubectl

# ---------------------------------------------------------------------------
log_step "Cluster ${CLUSTER_NAME}"
# ---------------------------------------------------------------------------
if cluster_exists && [ "${RECREATE}" = "true" ]; then
  log_info "--recreate given, deleting the existing cluster"
  kind delete cluster --name "${CLUSTER_NAME}"
fi

if cluster_exists; then
  log_success "already exists, skipping creation"
else
  log_info "creating from kind/cluster.yaml (this takes a minute)"
  # The config carries a placeholder for the repository path, because kind
  # needs an absolute host path and that differs per machine.
  rendered_config="$(mktemp)"
  # shellcheck disable=SC2064  # expand now, not when the trap fires
  trap "rm -f '${rendered_config}'" EXIT
  sed "s|__REPO_ROOT__|${REPO_ROOT}|" "${REPO_ROOT}/kind/cluster.yaml" > "${rendered_config}"
  kind create cluster --config "${rendered_config}" --wait 120s
  rm -f "${rendered_config}"
  log_success "created"
fi

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null
log_success "kubectl context set to ${KUBE_CONTEXT}"

# ---------------------------------------------------------------------------
log_step "Ingress controller (${INGRESS_NGINX_VERSION})"
# ---------------------------------------------------------------------------
# Pinned to a release tag, never a branch: the manifest defines the controller
# image, RBAC and admission webhook, and it must not change under us.
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

kubectl apply -f "${INGRESS_MANIFEST}"

log_info "waiting for the controller to become ready"
# The controller pod is created by a Deployment that itself takes a moment to
# appear, so tolerate an initial "no matching resources" from kubectl wait.
retry 10 6 kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=60s
log_success "ingress controller ready"

# ---------------------------------------------------------------------------
log_step "metrics-server (${METRICS_SERVER_VERSION})"
# ---------------------------------------------------------------------------
# The HorizontalPodAutoscaler reads CPU from the metrics.k8s.io API, which this
# provides. kind's kubelets serve their metrics endpoint with a self-signed
# certificate, so verification has to be relaxed or every scrape fails.
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

log_info "waiting for the metrics API to answer"
retry 20 6 kubectl wait --namespace kube-system \
  --for=condition=available deployment/metrics-server --timeout=60s
retry 20 6 kubectl top nodes >/dev/null 2>&1 \
  || die "the metrics API did not become ready"
log_success "metrics-server ready"

# ---------------------------------------------------------------------------
"${REPO_ROOT}/scripts/deploy-registry.sh"

# ---------------------------------------------------------------------------
log_step "Namespace ${NAMESPACE}"
# ---------------------------------------------------------------------------
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
log_success "namespace ready"

# ---------------------------------------------------------------------------
log_step "Cluster is up"
# ---------------------------------------------------------------------------
kubectl get nodes -o wide
echo
log_info "once the app is deployed it will be reachable at:"
log_info "  http://${INGRESS_HOST}:${INGRESS_HTTP_PORT}/"
