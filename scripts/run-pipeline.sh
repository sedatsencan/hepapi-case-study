#!/usr/bin/env bash
# Triggers the Jenkins pipeline and follows it to completion, so the whole run
# is visible from the terminal without opening the UI.
#
# Usage: ./scripts/run-pipeline.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd kubectl
require_cmd curl

JOB="taskmanager"
LOCAL_PORT="8090"
# A literal escape byte for sed: \xHH in a regex is a GNU extension, and some
# BSD seds treat it as the literal letters x1b.
ESC="$(printf '\033')"

kubectl --namespace "${JENKINS_NAMESPACE}" get deployment jenkins >/dev/null 2>&1 \
  || die "Jenkins is not deployed; run ./scripts/deploy-jenkins.sh"

password="$(kubectl --namespace "${JENKINS_NAMESPACE}" get secret jenkins-admin \
  -o "go-template={{ index .data \"password\" | base64decode }}")"

# Talking to the controller through a port-forward rather than the ingress keeps
# this working even when the ingress host port is taken.
if port_in_use "${LOCAL_PORT}"; then
  die "local port ${LOCAL_PORT} is already in use; free it and rerun"
fi
crumb_jar="$(mktemp)"
kubectl --namespace "${JENKINS_NAMESPACE}" port-forward svc/jenkins "${LOCAL_PORT}:8080" >/dev/null 2>&1 &
forward_pid=$!
# shellcheck disable=SC2064  # expand the values now, not when the trap fires
trap "kill ${forward_pid} 2>/dev/null || true; rm -f '${crumb_jar}'" EXIT

base="http://localhost:${LOCAL_PORT}"
api() { curl -sS -u "admin:${password}" "$@"; }

retry 15 2 curl -sS -o /dev/null --max-time 3 "${base}/login" || die "Jenkins did not answer"

log_step "Triggering ${JOB}"
previous="$(api -g "${base}/job/${JOB}/api/json?tree=nextBuildNumber" \
  | sed -n 's/.*"nextBuildNumber":\([0-9]*\).*/\1/p')"

crumb="$(api -c "${crumb_jar}" "${base}/crumbIssuer/api/json" \
  | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')"
api -b "${crumb_jar}" -H "Jenkins-Crumb: ${crumb}" -X POST -o /dev/null \
  "${base}/job/${JOB}/build"
log_success "queued build #${previous}"

log_step "Waiting for build #${previous}"
# Poll until the run reports it has stopped building. Following the console
# stream alone is not enough: it returns whatever exists so far and would make
# an unfinished build look finished.
building="true"
for _ in $(seq 1 180); do
  state="$(api -g "${base}/job/${JOB}/${previous}/api/json?tree=building,result" 2>/dev/null || true)"
  case "${state}" in
    *'"building":false'*) building="false"; break ;;
  esac
  sleep 10
done

log_step "Console"
# The console carries Jenkins' own markup, which is noise in a terminal.
api "${base}/job/${JOB}/${previous}/consoleText" \
  | sed -e "s/${ESC}\[8m.*${ESC}\[0m//g" -e "s/${ESC}\[[0-9;]*m//g" \
  | grep -vE '^\[Pipeline\]' \
  | grep -vE '^\s*$' || true

if [ "${building}" != "false" ]; then
  die "build #${previous} did not finish in time"
fi

result="$(api -g "${base}/job/${JOB}/${previous}/api/json?tree=result" \
  | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')"

echo
if [ "${result}" = "SUCCESS" ]; then
  log_success "build #${previous} succeeded"
else
  die "build #${previous} finished as ${result:-UNKNOWN}"
fi
