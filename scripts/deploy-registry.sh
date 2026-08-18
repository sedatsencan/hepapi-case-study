#!/usr/bin/env bash
# Deploys the in-cluster image registry and teaches every node's containerd how
# to reach it.
#
# The two halves are not symmetric. Pods push through cluster DNS, which the
# nodes cannot resolve, so containerd is pointed at the NodePort on its own
# loopback instead. Both refer to the same registry under the same image name.
#
# Usage: ./scripts/deploy-registry.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd kubectl
require_cmd docker

log_step "Registry"
kubectl apply -f "${REPO_ROOT}/kubernetes/registry.yaml" >/dev/null
retry 20 6 kubectl --namespace registry wait \
  --for=condition=available deployment/registry --timeout=60s >/dev/null
log_success "running at ${REGISTRY_HOST}"

log_step "Teaching containerd about the registry"
# The registry serves plain HTTP, so the nodes have to be told to skip TLS for
# this host specifically. Written per node because each runs its own containerd.
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "/etc/containerd/certs.d/${REGISTRY_HOST}"
  docker exec "${node}" sh -c "cat > /etc/containerd/certs.d/${REGISTRY_HOST}/hosts.toml <<'TOML'
server = \"http://${REGISTRY_HOST}\"

[host.\"http://localhost:${REGISTRY_NODE_PORT}\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
TOML"
done
log_success "$(kind get nodes --name "${CLUSTER_NAME}" | wc -l | tr -d ' ') node(s) configured"
