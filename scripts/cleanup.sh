#!/usr/bin/env bash
# Tears down everything setup.sh created: the test namespace (and all
# workloads in it), the two custom demo policies, and the privileged SCC
# grant. Safe to run multiple times.
#
# Usage: ./scripts/cleanup.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.."
# shellcheck disable=SC1091
source scripts/common.sh

echo "Deleting namespace ${TEST_NAMESPACE} (and everything in it)..."
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found=true

echo "Removing privileged SCC grant from default SA in ${TEST_NAMESPACE} (namespace deletion above already handles this, this is belt-and-suspenders)..."
oc adm policy remove-scc-from-user privileged -z default -n "${TEST_NAMESPACE}" 2>/dev/null || true

echo "Deleting custom demo policies from Central..."
python3 scripts/acs_api.py delete-policy "EAP-Init-Test: Privileged Container (Blue/Red)"
python3 scripts/acs_api.py delete-policy "EAP-Init-Test: Fixable Important+ CVE (Dirty/Red)"

echo ""
echo "Cleanup complete. Remember to revoke the RHACS API token in Central once you're done using this repo (see docs/CREDENTIALS.md)."
