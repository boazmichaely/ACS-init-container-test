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
log "roxctl image scan against the Dirty init image (gcr.io/distroless/python3-debian12:debug-nonroot):"
roxctl image scan -i gcr.io/distroless/python3-debian12:debug-nonroot -o json --compact-output 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("result",d).get("summary"), indent=2))' | tee -a "$REPORT"
log ""
log "roxctl image scan against the Clean init image (gcr.io/distroless/base-debian12:debug-nonroot):"
roxctl image scan -i gcr.io/distroless/base-debian12:debug-nonroot -o json --compact-output 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("result",d).get("summary"), indent=2))' | tee -a "$REPORT"
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
log "roxctl image check against the Dirty init image (expect Important+ CVE findings, non-zero exit if a BUILD-breaking policy matches):"
roxctl image check -i gcr.io/distroless/python3-debian12:debug-nonroot -o table --categories "Vulnerability Management" 2>&1 | tail -n 5 | tee -a "$REPORT"
IMAGE_CHECK_EXIT="${PIPESTATUS[0]}"
log "(roxctl image check exit code: ${IMAGE_CHECK_EXIT} - non-zero means at least one BUILD-breaking policy matched, i.e. the pipeline would fail the build)"

section "5. Admission control (Red init container)"
log "Temporarily enabling FAIL_DEPLOYMENT_CREATE_ENFORCEMENT on the custom privileged-container policy, then deleting and redeploying red-app from scratch..."
python3 scripts/acs_api.py set-enforcement "EAP-Init-Test: Privileged Container (Blue/Red)" --on | tee -a "$REPORT"
sleep 10

log "Deleting red-app entirely (Deployment + pods)..."
oc delete deployment red-app -n "${TEST_NAMESPACE}" --wait=true >/dev/null

log "Re-applying manifests/04-red.yaml with enforcement ON - expect this apply to be rejected by the admission webhook if enforcement reaches init containers:"
APPLY_OUTPUT=$(oc apply -f manifests/04-red.yaml 2>&1)
APPLY_EXIT=$?
echo "$APPLY_OUTPUT" | tee -a "$REPORT"
if [[ $APPLY_EXIT -ne 0 ]]; then
  log ""
  log "BLOCKED: 'oc apply' was rejected (exit code ${APPLY_EXIT}) - admission control stopped the deployment before it was created."
else
  log ""
  log "NOT BLOCKED: 'oc apply' succeeded - the Deployment (and its privileged init container) was created despite enforcement being enabled."
fi

python3 scripts/acs_api.py set-enforcement "EAP-Init-Test: Privileged Container (Blue/Red)" --off | tee -a "$REPORT"

if [[ $APPLY_EXIT -ne 0 ]]; then
  log ""
  log "Re-applying manifests/04-red.yaml now that enforcement is back off, to restore red-app..."
  oc apply -f manifests/04-red.yaml | tee -a "$REPORT"
fi
oc rollout status deployment/red-app -n "${TEST_NAMESPACE}" --timeout=60s | tee -a "$REPORT"

section "Summary"
log "Full report saved to ${REPORT}"

echo ""
echo "Done. Report: ${REPORT}"
