#!/usr/bin/env bash
# Drives the HorizontalPodAutoscaler through a full cycle: generate load for a
# minute, stop, and keep watching until the replicas come back down. Prints the
# replica count and measured CPU throughout, so both directions are observable.
#
# Usage: ./scripts/scale-demo.sh [--load-seconds N]

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd kubectl

LOAD_SECONDS=60
while [ $# -gt 0 ]; do
  case "$1" in
    --load-seconds)
      LOAD_SECONDS="$2"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

LOAD_JOB="taskmanager-load"

kubectl --namespace "${NAMESPACE}" get hpa "${APP_RELEASE}" >/dev/null 2>&1 \
  || die "no HorizontalPodAutoscaler found; deploy with values-local.yaml, which enables it"

# Without the metrics API the HPA reports <unknown> and never acts, which would
# look like the demo failing rather than the cluster missing a component.
kubectl top pods --namespace "${NAMESPACE}" >/dev/null 2>&1 \
  || die "the metrics API is not answering; run ./scripts/cluster-up.sh to install metrics-server"

# Prints one line of current state: desired replicas, ready pods and the CPU the
# HPA is acting on.
print_state() {
  local label="$1" replicas ready cpu
  replicas="$(kubectl --namespace "${NAMESPACE}" get deployment "${APP_RELEASE}" \
    -o jsonpath='{.spec.replicas}')"
  ready="$(kubectl --namespace "${NAMESPACE}" get deployment "${APP_RELEASE}" \
    -o jsonpath='{.status.readyReplicas}')"
  cpu="$(kubectl --namespace "${NAMESPACE}" get hpa "${APP_RELEASE}" \
    -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')"
  printf '    %-9s replicas=%-2s ready=%-2s cpu=%s%%\n' \
    "${label}" "${replicas}" "${ready:-0}" "${cpu:-?}"
}

cleanup() {
  kubectl --namespace "${NAMESPACE}" delete job "${LOAD_JOB}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_step "Starting state"
cleanup
print_state "now"

# ---------------------------------------------------------------------------
log_step "Generating load for ${LOAD_SECONDS}s"
# ---------------------------------------------------------------------------
# Four parallel pods hammering the Service. activeDeadlineSeconds is the safety
# net: even if this script is interrupted, Kubernetes stops the job on its own
# rather than leaving load running against the cluster.
kubectl --namespace "${NAMESPACE}" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${LOAD_JOB}
  labels:
    app.kubernetes.io/component: test
spec:
  parallelism: 4
  completions: 4
  activeDeadlineSeconds: $((LOAD_SECONDS + 30))
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/component: test
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl:8.11.1
          command:
            - /bin/sh
            - -c
            - |
              end=\$(( \$(date +%s) + ${LOAD_SECONDS} ))
              while [ \$(date +%s) -lt \$end ]; do
                curl -s -o /dev/null --max-time 5 http://${APP_RELEASE}/
              done
EOF

deadline=$(($(date +%s) + LOAD_SECONDS))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  print_state "$(( deadline - $(date +%s) ))s left"
  sleep 10
done

# ---------------------------------------------------------------------------
log_step "Load stopped, waiting for scale-down"
# ---------------------------------------------------------------------------
cleanup

minimum="$(kubectl --namespace "${NAMESPACE}" get hpa "${APP_RELEASE}" -o jsonpath='{.spec.minReplicas}')"
for _ in $(seq 1 24); do
  print_state "cooling"
  current="$(kubectl --namespace "${NAMESPACE}" get deployment "${APP_RELEASE}" -o jsonpath='{.spec.replicas}')"
  if [ "${current}" = "${minimum}" ]; then
    log_success "back to ${minimum} replicas"
    exit 0
  fi
  sleep 10
done

log_warn "still above ${minimum} replicas; scale-down can take longer under sustained load"
