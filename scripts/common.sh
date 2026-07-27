#!/usr/bin/env bash
# Shared setup for all scripts in this repo: loads config from .env (if
# present), then prompts interactively for anything still missing. Never
# echoes ROX_API_TOKEN to the terminal.
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

acs_curl() {
  # acs_curl <path> [curl-args...]  - talks to the Central REST API.
  local path="$1"; shift
  curl -sk -H "Authorization: Bearer ${ROX_API_TOKEN}" "https://${ROX_CENTRAL_ENDPOINT}${path}" "$@"
}
