#!/usr/bin/env bash
# Deploys the Clean/Dirty/Blue/Red demo namespace and workloads, and creates
# the two demo Build/Deploy policies in Central. Safe to re-run.
#
# Usage: ./scripts/setup.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.."
# shellcheck disable=SC1091
source scripts/common.sh

echo "Creating namespace and workloads in ${TEST_NAMESPACE}..."
oc apply -f manifests/00-namespace.yaml
oc adm policy add-scc-to-user privileged -z default -n "${TEST_NAMESPACE}"
oc apply -f manifests/01-clean.yaml -f manifests/02-dirty.yaml -f manifests/03-blue.yaml -f manifests/04-red.yaml

echo ""
echo "Waiting for pods to become ready..."
oc rollout status deployment/clean-app -n "${TEST_NAMESPACE}" --timeout=120s
oc rollout status deployment/dirty-app -n "${TEST_NAMESPACE}" --timeout=120s
oc rollout status deployment/blue-app  -n "${TEST_NAMESPACE}" --timeout=120s
oc rollout status deployment/red-app   -n "${TEST_NAMESPACE}" --timeout=120s

echo ""
echo "Creating demo policies in Central..."
python3 scripts/acs_api.py upsert-policy policies/privileged-init-container.json
python3 scripts/acs_api.py upsert-policy policies/fixable-important-cve.json

echo ""
echo "Setup complete. Open Central to explore the ${TEST_NAMESPACE} namespace,"
echo "or run ./scripts/test.sh to validate it via roxctl and the API."
