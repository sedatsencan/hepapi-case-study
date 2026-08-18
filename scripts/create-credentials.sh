#!/usr/bin/env bash
# Creates the MongoDB credentials Secret that both releases read from. Must run
# before either of them.
#
# Re-running reuses existing passwords: MongoDB only seeds users on first init,
# so replacing the Secret against an existing volume would lock the application
# out. That guards against accidental rotation and is not deliberate rotation,
# which belongs to an external secret manager.
#
# Usage: ./scripts/create-credentials.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd kubectl
require_cmd openssl

# Length in bytes of every generated credential, so the hex form is twice this.
CREDENTIAL_BYTES=24

# Reads one key out of the Secret, printing nothing unless it is a well-formed
# credential. The format check matters: kubectl reports go-template failures on
# stdout, so a missing key returns error text that would otherwise be stored as
# a password.
read_secret_value() {
  local value
  value="$(kubectl --namespace "${NAMESPACE}" get secret "${DB_CREDENTIALS_SECRET}" \
    -o "go-template={{ index .data \"${1}\" | base64decode }}" 2>/dev/null)" || return 0

  if printf '%s' "${value}" | grep -qE "^[0-9a-f]{$((CREDENTIAL_BYTES * 2))}\$"; then
    printf '%s' "${value}"
  fi
}

# Hex, not base64: kubelet substitutes this into a mongodb:// URI literally, so
# it can never be percent-encoded, and URI-reserved characters would break
# parsing. Hex output contains none of them.
generate_password() { openssl rand -hex "${CREDENTIAL_BYTES}"; }

log_step "Namespace ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log_success "ready"

log_step "Secret ${DB_CREDENTIALS_SECRET}"

existing_root_password="$(read_secret_value mongodb-root-password)"
existing_app_password="$(read_secret_value mongodb-passwords)"
existing_replica_set_key="$(read_secret_value mongodb-replica-set-key)"

if [ -n "${existing_root_password}" ] && [ -n "${existing_app_password}" ] \
  && [ -n "${existing_replica_set_key}" ]; then
  log_info "already present, reusing the stored credentials"
else
  log_info "generating new credentials"
fi

root_password="${existing_root_password:-$(generate_password)}"
app_password="${existing_app_password:-$(generate_password)}"
# Shared by every member to authenticate to each other.
replica_set_key="${existing_replica_set_key:-$(generate_password)}"

# Key names come from the chart's auth.existingSecret contract.
kubectl --namespace "${NAMESPACE}" create secret generic "${DB_CREDENTIALS_SECRET}" \
  --from-literal=mongodb-root-password="${root_password}" \
  --from-literal=mongodb-passwords="${app_password}" \
  --from-literal=mongodb-replica-set-key="${replica_set_key}" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

log_success "applied"
log_info "database user '${DB_APP_USERNAME}' on database '${DB_NAME}'"
