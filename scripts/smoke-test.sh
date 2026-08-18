#!/usr/bin/env bash
# End-to-end check against a deployed release: the chart's own test hook, then a
# request from outside the cluster.
#
# Usage: ./scripts/smoke-test.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd helm
require_cmd kubectl
require_cmd curl

log_step "Chart test hook"
helm test "${APP_RELEASE}" --namespace "${NAMESPACE}" --logs
log_success "passed"

# The page is fetched into a variable rather than piped, so that curl failing
# is seen as a failure rather than being masked by grep closing the pipe.
serves_application() {
  local body
  body="$(curl -fsS --max-time 10 "${1}" 2>/dev/null)" || return 1
  grep -q "SIMPLE TASK MANAGER" <<<"${body}"
}

log_step "Request from outside the cluster"
ingress_url="http://${INGRESS_HOST}:${INGRESS_HTTP_PORT}/"

if serves_application "${ingress_url}"; then
  log_success "${ingress_url} served the application"
  exit 0
fi

# The ingress is the preferred path but not the only one: its host port may be
# taken, or DNS rebinding protection may refuse to resolve the test domain. A
# port-forward proves the deployment itself regardless, so falling back keeps a
# healthy cluster from failing the check.
log_warn "${ingress_url} did not respond, falling back to a port-forward"

if port_in_use 8081; then
  die "fallback port 8081 is already in use (make port-forward?); free it and rerun"
fi
kubectl --namespace "${NAMESPACE}" port-forward "svc/${APP_RELEASE}" 8081:80 >/dev/null 2>&1 &
forward_pid=$!
# shellcheck disable=SC2064  # expand the pid now, not when the trap fires
trap "kill ${forward_pid} 2>/dev/null || true" EXIT

if retry 10 2 serves_application "http://localhost:8081/"; then
  log_success "port-forward served the application"
  log_info "the ingress did not answer; check that port ${INGRESS_HTTP_PORT} is free"
else
  die "the application did not respond through the ingress or a port-forward"
fi
