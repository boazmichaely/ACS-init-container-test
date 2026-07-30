#!/usr/bin/env bash
# Shared setup for all scripts in this repo: loads config from .env (if
# present), prompts interactively for anything still missing, then shows the
# resolved OCP/ACS environment and requires confirmation before continuing -
# so a stale .env (e.g. after switching `oc login` to a different cluster
# without updating .env) never gets used silently against the wrong Central.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# 1. Load .env if it exists (never committed - see .gitignore).
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

# 2. Fall back to defaults / interactive prompts for anything missing.
if [[ -z "${ROX_CENTRAL_ENDPOINT:-}" ]]; then
  read -r -p "RHACS Central endpoint (e.g. acs-xxxx.acs.rhcloud.com, no https://): " ROX_CENTRAL_ENDPOINT
fi

if [[ -z "${ROX_API_TOKEN:-}" ]]; then
  read -r -s -p "RHACS API token (input hidden): " ROX_API_TOKEN
  echo
fi

if [[ -z "${TEST_NAMESPACE:-}" ]]; then
  TEST_NAMESPACE="acs-init-container-test"
fi

if [[ -z "${ROX_CENTRAL_ENDPOINT}" || -z "${ROX_API_TOKEN}" ]]; then
  echo "ERROR: ROX_CENTRAL_ENDPOINT and ROX_API_TOKEN are required (set them in .env, as env vars, or answer the prompts)." >&2
  exit 1
fi

export ROX_CENTRAL_ENDPOINT ROX_API_TOKEN TEST_NAMESPACE
export ROX_ENDPOINT="${ROX_CENTRAL_ENDPOINT}:443"

acs_curl() {
  # acs_curl <path> [curl-args...]  - talks to the Central REST API.
  local path="$1"; shift
  curl -sk -H "Authorization: Bearer ${ROX_API_TOKEN}" "https://${ROX_CENTRAL_ENDPOINT}${path}" "$@"
}

# 3. Sanity check tooling + cluster login (oc). roxctl auth is verified by the
#    caller since not every script needs it immediately.
for bin in oc roxctl curl python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: required tool '$bin' not found on PATH." >&2
    exit 1
  fi
done

if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: not logged in to an OpenShift cluster. Run 'oc login ...' first." >&2
  exit 1
fi

# 4. Show exactly which OCP cluster and ACS Central this run resolved to, and
#    require confirmation. Skipped (banner still printed) when stdin isn't a
#    terminal, so automation isn't blocked.
CREDS_CHANGED=false
while true; do
  CENTRAL_VERSION=$(acs_curl "/v1/metadata" 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("version", "(unreachable)"))
except Exception:
    print("(unreachable - check endpoint/token)")
' 2>/dev/null)
  CLUSTER_NAMES=$(acs_curl "/v1/clusters" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(", ".join(c["name"] for c in d.get("clusters", [])) or "(none)")
except Exception:
    print("(unreachable)")
' 2>/dev/null)

  echo ""
  echo "Environment for this run:"
  echo "  OCP cluster  : $(oc whoami --show-server 2>/dev/null) (logged in as $(oc whoami 2>/dev/null))"
  echo "  ACS Central  : https://${ROX_CENTRAL_ENDPOINT} (version ${CENTRAL_VERSION})"
  echo "  Secured clusters known to that Central: ${CLUSTER_NAMES}"
  echo "  Namespace    : ${TEST_NAMESPACE}"
  echo ""

  if [[ ! -t 0 ]]; then
    echo "(stdin is not a terminal - continuing without confirmation)"
    break
  fi

  read -r -p "Continue with this environment? [Y/n] " CONFIRM
  if [[ -z "${CONFIRM}" || "${CONFIRM}" =~ ^[Yy] ]]; then
    break
  fi

  read -r -p "New RHACS Central endpoint (no https://): " ROX_CENTRAL_ENDPOINT
  read -r -s -p "New RHACS API token (input hidden): " ROX_API_TOKEN
  echo
  export ROX_CENTRAL_ENDPOINT ROX_API_TOKEN
  export ROX_ENDPOINT="${ROX_CENTRAL_ENDPOINT}:443"
  CREDS_CHANGED=true
done

if [[ "${CREDS_CHANGED}" == "true" && -t 0 ]]; then
  read -r -p "Save this Central endpoint/token to .env for next time? [y/N] " SAVE_ENV
  if [[ "${SAVE_ENV}" =~ ^[Yy] ]]; then
    cat > "${REPO_ROOT}/.env" <<EOF_ENV
ROX_CENTRAL_ENDPOINT=${ROX_CENTRAL_ENDPOINT}
ROX_API_TOKEN=${ROX_API_TOKEN}
TEST_NAMESPACE=${TEST_NAMESPACE}
EOF_ENV
    echo "Saved to ${REPO_ROOT}/.env"
  fi
fi
