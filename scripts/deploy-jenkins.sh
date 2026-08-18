#!/usr/bin/env bash
# Deploys the in-cluster Jenkins: RBAC, configuration as code, the pipeline
# definition and the controller itself.
#
# Re-running reuses the existing admin password rather than rotating it, for the
# same reason the database credentials do.
#
# Usage: ./scripts/deploy-jenkins.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd kubectl
require_cmd openssl

log_step "Namespace and permissions"
kubectl apply -f "${REPO_ROOT}/kubernetes/jenkins/rbac.yaml" >/dev/null
log_success "applied"

log_step "Admin credentials"
existing="$(kubectl --namespace "${JENKINS_NAMESPACE}" get secret jenkins-admin \
  -o "go-template={{ index .data \"password\" | base64decode }}" 2>/dev/null || true)"
password="${existing:-$(openssl rand -hex 16)}"

kubectl --namespace "${JENKINS_NAMESPACE}" create secret generic jenkins-admin \
  --from-literal=username=admin \
  --from-literal=password="${password}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if [ -n "${existing}" ]; then
  log_info "reusing the stored password"
else
  log_info "generated a new password"
fi
log_success "applied"

log_step "Configuration and pipeline"
kubectl apply -f "${REPO_ROOT}/kubernetes/jenkins/casc.yaml" >/dev/null
# The Jenkinsfile is repository content; it is carried into the controller as a
# ConfigMap so the job definition can read it without a Git remote.
kubectl --namespace "${JENKINS_NAMESPACE}" create configmap jenkins-pipeline \
  --from-file=Jenkinsfile="${REPO_ROOT}/Jenkinsfile" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log_success "applied"

log_step "Controller"
kubectl apply -f "${REPO_ROOT}/kubernetes/jenkins/jenkins.yaml" >/dev/null
# The job definition is built from the mounted files at startup, so a changed
# Jenkinsfile or configuration only takes effect after a restart.
if kubectl --namespace "${JENKINS_NAMESPACE}" get deployment jenkins \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]'; then
  log_info "restarting to pick up the current configuration"
  kubectl --namespace "${JENKINS_NAMESPACE}" rollout restart deployment/jenkins >/dev/null
fi
# Plugin installation on first start takes a while, so the wait is generous.
log_info "waiting for Jenkins to come up (first start installs plugins)"
retry 30 20 kubectl --namespace "${JENKINS_NAMESPACE}" wait \
  --for=condition=available deployment/jenkins --timeout=60s >/dev/null
log_success "ready"

echo
log_info "Jenkins:   http://${JENKINS_HOST}:${INGRESS_HTTP_PORT}/"
log_info "user:      admin"
log_info "password:  ${password}"
log_info "run the pipeline with: make ci"
