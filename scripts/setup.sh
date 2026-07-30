#!/usr/bin/env bash
# Applies the Clean/Dirty/Blue/Red demo workloads and creates the two demo
# Build/Deploy policies in Central. Safe to re-run. No cluster-admin needed:
# RHACS evaluates a Deployment's spec directly, so blue-app/red-app's
# privileged init container triggers policy evaluation whether or not a
# cluster-admin has ever granted the "privileged" SCC for it to actually run.
#
# Usage: ./scripts/setup.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.."
# shellcheck disable=SC1091
source scripts/common.sh

echo "Creating namespace ${TEST_NAMESPACE}..."
oc get namespace "${TEST_NAMESPACE}" >/dev/null 2>&1 || oc new-project "${TEST_NAMESPACE}" --display-name="ACS init-container EAP test"

echo ""
echo "Applying workloads..."
oc apply -f manifests/01-clean.yaml -f manifests/02-dirty.yaml -f manifests/03-blue.yaml -f manifests/04-red.yaml

echo ""
echo "Waiting for clean-app/dirty-app to become ready (blue-app/red-app's"
echo "privileged init container may stay Pending without the 'privileged'"
echo "SCC - that's fine, see manifests/03-blue.yaml)..."
oc rollout status deployment/clean-app -n "${TEST_NAMESPACE}" --timeout=120s
oc rollout status deployment/dirty-app -n "${TEST_NAMESPACE}" --timeout=120s

echo ""
echo "Deployment status:"
oc get deployments -n "${TEST_NAMESPACE}" -l acs-eap-test=init-container

echo ""
echo "Creating demo policies in Central..."
python3 scripts/acs_api.py upsert-policy policies/privileged-init-container.json
python3 scripts/acs_api.py upsert-policy policies/fixable-important-cve.json

echo ""
echo "Setup complete. Open Central to explore the ${TEST_NAMESPACE} namespace,"
echo "or run ./scripts/test.sh to validate it via roxctl and the API."
