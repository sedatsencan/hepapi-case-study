#!/usr/bin/env bash
# Deploys MongoDB from the upstream Bitnami chart, pinned by chart version and
# image digest. Ensures the shared credentials Secret exists first.
#
# Usage: ./scripts/deploy-database.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd helm
require_cmd kubectl

# The chart reads the passwords through auth.existingSecret, so the Secret has
# to exist before the release is installed.
"${REPO_ROOT}/scripts/create-credentials.sh"

log_step "MongoDB (chart ${MONGODB_CHART_VERSION})"
helm upgrade --install "${DB_RELEASE}" "${MONGODB_CHART}" \
  --version "${MONGODB_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "${REPO_ROOT}/kubernetes/mongodb-values.yaml" \
  --wait \
  --timeout 10m
log_success "released"

# ---------------------------------------------------------------------------
log_step "Server version"
# ---------------------------------------------------------------------------
# The image is pinned by digest against a version-less tag, so nothing else
# states what is running. Stops the deploy if the digest and the recorded
# version drift apart.
# "|| true" so an exec failure (pod restarting, apiserver blip) falls through
# to the descriptive die below instead of killing the script silently.
running_version="$(kubectl --namespace "${NAMESPACE}" exec "${DB_STATEFULSET}-0" -c mongodb -- \
  mongod --version 2>/dev/null | sed -n 's/^db version v//p' | tr -d '\r' || true)"

if [ "${running_version}" != "${MONGODB_SERVER_VERSION}" ]; then
  die "expected MongoDB ${MONGODB_SERVER_VERSION} but the server reports '${running_version}'; update the image digest and MONGODB_SERVER_VERSION together"
fi
log_success "MongoDB ${running_version}"

# ---------------------------------------------------------------------------
log_step "Replica set membership"
# ---------------------------------------------------------------------------
# The chart leaves members 2 and 3 non-voting, so there is no failover. Fixing
# it needs votes and priority changed together, since MongoDB rejects priority
# without a vote. Idempotent: only reconfigures members that do not match.
root_password="$(kubectl --namespace "${NAMESPACE}" get secret "${DB_CREDENTIALS_SECRET}" \
  -o "go-template={{ index .data \"mongodb-root-password\" | base64decode }}")"

members=""
for ordinal in $(seq 0 $((DB_REPLICA_COUNT - 1))); do
  [ -n "${members}" ] && members="${members},"
  members="${members}${DB_STATEFULSET}-${ordinal}.${DB_HEADLESS_SERVICE}.${NAMESPACE}.svc.cluster.local:27017"
done
# Naming the replica set makes mongosh route to whichever member is primary,
# which is where a reconfiguration has to run.
admin_uri="mongodb://root:${root_password}@${members}/?replicaSet=${DB_REPLICA_SET_NAME}&authSource=admin"

# MongoDB refuses to change the voting membership by more than one member per
# reconfig, so this promotes one and the loop repeats.
promote_one_member='
  const configuration = rs.conf();
  const stale = configuration.members.filter(m => m.votes !== 1 || m.priority !== 1);
  if (stale.length === 0) {
    print("already correct");
  } else {
    stale[0].votes = 1;
    stale[0].priority = 1;
    rs.reconfig(configuration);
    print("promoted " + stale[0].host.split(".")[0]);
  }
'

# One pass per member, plus headroom for a re-election settling in between.
for _ in $(seq 1 $((DB_REPLICA_COUNT * 2))); do
  result="$(retry 15 10 kubectl --namespace "${NAMESPACE}" exec "${DB_STATEFULSET}-0" -c mongodb -- \
    env URI="${admin_uri}" sh -c "mongosh --quiet \"\$URI\" --eval '${promote_one_member}'" | tail -1)" \
    || die "could not reach the replica set to reconfigure it"
  log_info "${result}"
  case "${result}" in
    *"already correct"*) break ;;
  esac
  sleep 5
done
log_success "every member is voting and electable"

log_step "MongoDB is up"
kubectl --namespace "${NAMESPACE}" get pods,pvc -l app.kubernetes.io/name=mongodb
echo
log_info "replica set ${DB_REPLICA_SET_NAME}, ${DB_REPLICA_COUNT} members, reachable in-cluster at"
log_info "  ${DB_STATEFULSET}-N.${DB_HEADLESS_SERVICE}.${NAMESPACE}.svc.cluster.local:27017"
