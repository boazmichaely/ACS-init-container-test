#!/usr/bin/env bash
# Validates init-container security coverage against a live Central, using
# roxctl and the Central REST API. Requires ./scripts/setup.sh to have been
# run first. Prints a report to stdout and saves it (plus raw JSON) under
# results/ (gitignored).
#
# Usage: ./scripts/test.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.."
# shellcheck disable=SC1091
source scripts/common.sh

if ! oc get deployment/red-app -n "${TEST_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: ${TEST_NAMESPACE} deployments not found. Run ./scripts/setup.sh first." >&2
  exit 1
fi

RESULTS_DIR="results"
mkdir -p "$RESULTS_DIR"
REPORT="$RESULTS_DIR/report.md"
: > "$REPORT"

log() { echo "$@" | tee -a "$REPORT"; }
section() { log ""; log "## $1"; log ""; }

log "# ACS Init Container Test Report"
log ""
log "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Cluster: $(oc whoami --show-server 2>/dev/null)"
log "Namespace: ${TEST_NAMESPACE}"
log "Central: ${ROX_CENTRAL_ENDPOINT}"
CENTRAL_VERSION=$(acs_curl "/v1/metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version","unknown"))' 2>/dev/null)
log "Central version: ${CENTRAL_VERSION}"

section "1. Configuration Management - Container Type: INIT"
DEPLOYMENT_COUNT=$(acs_curl "/v1/deployments" --data-urlencode "query=Namespace:${TEST_NAMESPACE}" -G | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("deployments",[])))')
INIT_FILTERED_COUNT=$(acs_curl "/v1/deployments" --data-urlencode "query=Namespace:${TEST_NAMESPACE}+Container Type:INIT" -G | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("deployments",[])))')
log "Deployments in namespace (no filter): ${DEPLOYMENT_COUNT} (expect 4: clean-app, dirty-app, blue-app, red-app)"
log "Deployments matching 'Container Type: INIT' filter: ${INIT_FILTERED_COUNT}"

log ""
log "Raw deployment container list (via /v1/deployments/{id}) for blue-app, to show what Sensor reports:"
BLUE_ID=$(acs_curl "/v1/deployments" --data-urlencode "query=Namespace:${TEST_NAMESPACE}+Deployment:blue-app" -G | python3 -c 'import json,sys; d=json.load(sys.stdin)["deployments"]; print(d[0]["id"] if d else "")')
if [[ -n "$BLUE_ID" ]]; then
  acs_curl "/v1/deployments/${BLUE_ID}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([{"name":c["name"],"type":c.get("type"),"image":c.get("image",{}).get("name",{}).get("fullName")} for c in d.get("containers",[])], indent=2))' | tee -a "$REPORT"
  log "(Look for both 'main' and 'blue-init' here - that confirms Sensor is reporting init containers to Central.)"
fi

section "2. Init container image scanning (Clean vs Dirty)"
log "roxctl image scan against the Dirty init-only image (registry.access.redhat.com/ubi8/ubi-minimal:8.4):"
roxctl image scan -i registry.access.redhat.com/ubi8/ubi-minimal:8.4 -o json --compact-output 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("result",d).get("summary"), indent=2))' | tee -a "$REPORT"
log ""
log "roxctl image scan against the Clean init image (registry.access.redhat.com/ubi9/ubi-micro:latest):"
roxctl image scan -i registry.access.redhat.com/ubi9/ubi-micro:latest -o json --compact-output 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("result",d).get("summary"), indent=2))' | tee -a "$REPORT"
log ""
log "(Ad hoc roxctl image scan of an image works independently of deployment attribution - it always reflects image content directly.)"

section "3. Policy behavior (Blue / Red)"
log "Live violations for this namespace (from /v1/alerts):"
python3 scripts/acs_api.py violations --namespace "${TEST_NAMESPACE}" | tee -a "$REPORT"
log ""
log "roxctl deployment check against the Red deployment manifest (manifests/04-red.yaml):"
roxctl deployment check -f manifests/04-red.yaml -o table 2>&1 | tee -a "$REPORT" || true
log ""
BLUE_HIT=$(python3 scripts/acs_api.py violations --namespace "${TEST_NAMESPACE}" | python3 -c 'import json,sys; a=json.load(sys.stdin); print("yes" if any(x["deployment"]=="blue-app" and "Privileged" in x["policy"] for x in a) else "no")')
RED_HIT=$(python3 scripts/acs_api.py violations --namespace "${TEST_NAMESPACE}" | python3 -c 'import json,sys; a=json.load(sys.stdin); print("yes" if any(x["deployment"]=="red-app" and "Privileged" in x["policy"] for x in a) else "no")')
log "Custom 'EAP-Init-Test: Privileged Container' fired on blue-app: ${BLUE_HIT}"
log "Custom 'EAP-Init-Test: Privileged Container' fired on red-app: ${RED_HIT}"

section "4. Pipeline (roxctl image check against Dirty)"
log "roxctl image check against the Dirty init-only image (expect Important+ CVE findings, non-zero exit if a BUILD-breaking policy matches):"
roxctl image check -i registry.access.redhat.com/ubi8/ubi-minimal:8.4 -o table --categories "Vulnerability Management" 2>&1 | tail -n 5 | tee -a "$REPORT"
IMAGE_CHECK_EXIT="${PIPESTATUS[0]}"
log "(roxctl image check exit code: ${IMAGE_CHECK_EXIT} - non-zero means at least one BUILD-breaking policy matched, i.e. the pipeline would fail the build)"

section "5. Admission control (Red init container)"
log "Temporarily enabling FAIL_DEPLOYMENT_CREATE_ENFORCEMENT on the custom privileged-container policy, then recreating the red-app pod..."
python3 scripts/acs_api.py set-enforcement "EAP-Init-Test: Privileged Container (Blue/Red)" --on | tee -a "$REPORT"
sleep 10
OLD_POD=$(oc get pod -n "${TEST_NAMESPACE}" -l app=red-app -o jsonpath='{.items[0].metadata.name}')
oc delete pod -n "${TEST_NAMESPACE}" -l app=red-app >/dev/null
sleep 10
NEW_POD_STATUS=$(oc get pod -n "${TEST_NAMESPACE}" -l app=red-app -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "MISSING")
log "Old pod: ${OLD_POD} -> new red-app pod phase after enforcement was enabled: ${NEW_POD_STATUS}"
python3 scripts/acs_api.py set-enforcement "EAP-Init-Test: Privileged Container (Blue/Red)" --off | tee -a "$REPORT"

section "Summary"
log "Full report saved to ${REPORT}"

echo ""
echo "Done. Report: ${REPORT}"
