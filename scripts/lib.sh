#!/usr/bin/env bash
# Shared configuration and helpers, sourced by every script in this directory.
# Not executable on its own.
#
# shellcheck disable=SC2034  # the constants below are consumed by the sourcing scripts

set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_BIN="${REPO_ROOT}/.bin"
IMAGE_TAG_FILE="${REPO_ROOT}/.image-tag"

# ---------------------------------------------------------------------------
# Pinned toolchain. Every version here is bumped deliberately, never implicitly.
# ---------------------------------------------------------------------------
KIND_VERSION="v0.32.0"
# Helm is pinned to a 3.x release because Homebrew now ships Helm 4, and a
# local/CI major version split is a class of bug not worth debugging.
HELM_VERSION="v3.19.5"
INGRESS_NGINX_VERSION="controller-v1.15.1"
# Provides the resource metrics API the HorizontalPodAutoscaler reads from.
METRICS_SERVER_VERSION="v0.9.0"
MONGODB_CHART="oci://registry-1.docker.io/bitnamicharts/mongodb"
MONGODB_CHART_VERSION="19.1.30"
# The server version behind the image digest pinned in
# kubernetes/mongodb-values.yaml. Both are bumped together, and the deploy
# checks the running server against this so the two cannot drift apart.
MONGODB_SERVER_VERSION="8.3.8"
# The Kubernetes version is pinned in kind/cluster.yaml, by tag and digest, and
# is deliberately not duplicated here: cluster-up.sh reads that file directly,
# so it stays the single source of truth.

# ---------------------------------------------------------------------------
# Project identifiers, shared by scripts, charts and CI.
# ---------------------------------------------------------------------------
CLUSTER_NAME="hepapi-case-study"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="taskmanager"
APP_RELEASE="taskmanager"
DB_RELEASE="taskmanager-db"
# Shared by both releases, so it is created before either of them.
DB_CREDENTIALS_SECRET="taskmanager-db-credentials"
DB_APP_USERNAME="taskmanager"
# In replicaset mode the chart exposes a headless Service, which is what the
# client needs: connecting through a load-balancing ClusterIP would send writes
# to whichever member answered, and only the primary accepts them.
DB_STATEFULSET="${DB_RELEASE}-mongodb"
DB_HEADLESS_SERVICE="${DB_RELEASE}-mongodb-headless"
DB_REPLICA_SET_NAME="rs0"
DB_REPLICA_COUNT="3"
# Fixed by run.py, which selects the database with client.TaskManager.
DB_NAME="TaskManager"
# The in-cluster registry. Pods reach it through cluster DNS; the nodes reach
# the same registry through the NodePort below.
REGISTRY_HOST="registry.registry.svc.cluster.local:5000"
REGISTRY_NODE_PORT="30500"
IMAGE_REPOSITORY="${REGISTRY_HOST}/hepapi-case-study"
# localtest.me resolves to 127.0.0.1 from public DNS, so no /etc/hosts edit
# and no sudo are needed to reach the ingress.
INGRESS_HOST="taskmanager.localtest.me"
JENKINS_NAMESPACE="jenkins"
JENKINS_HOST="jenkins.localtest.me"
INGRESS_HTTP_PORT="8080"

# Anything installed by preflight.sh takes precedence over what is already
# on PATH, so the pinned versions above are the ones actually used.
export PATH="${LOCAL_BIN}:${PATH}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

log_step()    { printf '%s\n' "${C_BLUE}==> ${*}${C_RESET}"; }
log_info()    { printf '%s\n' "    ${*}"; }
log_success() { printf '%s\n' "${C_GREEN}  ✓ ${*}${C_RESET}"; }
log_warn()    { printf '%s\n' "${C_YELLOW}  ! ${*}${C_RESET}" >&2; }
log_error()   { printf '%s\n' "${C_RED}  ✗ ${*}${C_RESET}" >&2; }

die() { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || die "required command not found: $1 (run ./scripts/preflight.sh)"
}

host_os() { uname -s | tr '[:upper:]' '[:lower:]'; }

host_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo "amd64" ;;
    arm64 | aarch64) echo "arm64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Downloads a file alongside its vendor-published .sha256sum and refuses to
# continue on a mismatch.
download_verified() {
  local url="$1" checksum_url="$2" destination="$3"
  curl -fsSL "$url" -o "$destination"

  local expected actual
  expected="$(curl -fsSL "$checksum_url" | awk '{print $1}')"
  actual="$(sha256_of "$destination")"

  if [ "$expected" != "$actual" ]; then
    rm -f "$destination"
    die "checksum mismatch for ${url} (expected ${expected}, got ${actual})"
  fi
}

# Reports whether something is already listening on a TCP port. Tools differ by
# platform: macOS ships lsof, most Linux distributions ship ss from iproute2,
# and older ones only have netstat. Returns 2 when none of them is available, so
# the caller can say "unknown" rather than claim the port is free.
port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  else
    return 2
  fi
}

retry() {
  local attempts="$1" delay="$2"
  shift 2
  local attempt=1
  until "$@"; do
    if [ "$attempt" -ge "$attempts" ]; then
      return 1
    fi
    attempt=$((attempt + 1))
    sleep "$delay"
  done
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

# Resolves the image tag written by build-and-load.sh, so deploy scripts and
# the build stay in sync without recomputing it.
current_image_tag() {
  if [ -f "${IMAGE_TAG_FILE}" ]; then
    cat "${IMAGE_TAG_FILE}"
  else
    die "no image tag recorded, run ./scripts/build-and-load.sh first"
  fi
}
