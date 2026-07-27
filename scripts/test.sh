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

# Colors for the terminal only - the report file always stays plain text.
# Script narration is cyan, section banners are bold magenta, raw command
# output (oc/roxctl/API responses) is left uncolored so it visually stands
# apart from the script's own commentary. Disabled for non-tty output or
# when NO_COLOR is set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_TEXT=$'\033[0;36m'    # cyan - script narration
  C_BANNER=$'\033[1;35m'  # bold magenta - section banners
  C_OK=$'\033[1;32m'      # bold green - expected/success result
  C_BAD=$'\033[1;31m'     # bold red - unexpected/failure result
  C_RESET=$'\033[0m'
else
  C_TEXT=""; C_BANNER=""; C_OK=""; C_BAD=""; C_RESET=""
fi

# Script narration: plain in the report file, colored on the terminal.
log() {
  echo "$@" >> "$REPORT"
  echo "${C_TEXT}$*${C_RESET}"
}

# Section banner: makes the start of a new test step obvious on the terminal.
section() {
  {
    echo ""
    echo "## $1"
    echo ""
  } >> "$REPORT"
  echo ""
  echo "${C_BANNER}────────────────────────────────────────────────────────${C_RESET}"
  echo "${C_BANNER}  $1${C_RESET}"
  echo "${C_BANNER}────────────────────────────────────────────────────────${C_RESET}"
  echo ""
}

# Highlighted one-line result: plain in the report file, bold green/red on
# the terminal depending on whether the outcome was the expected one.
result() {
  local color=$C_OK
  [[ "${2:-ok}" == "bad" ]] && color=$C_BAD
  echo "$1" >> "$REPORT"
  echo "${color}$1${C_RESET}"
}

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

section "2. Policy behavior (Blue / Red)"
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

section "3. Admission control (Red init container)"
log "Enabling enforcement on the custom privileged-container policy..."
python3 scripts/acs_api.py set-enforcement "EAP-Init-Test: Privileged Container (Blue/Red)" --on | tee -a "$REPORT"
sleep 15  # allow the setting to propagate from Central to the admission controller

log ""
log "Deleting red-app..."
oc delete deployment red-app -n "${TEST_NAMESPACE}" --wait=true | tee -a "$REPORT"

log ""
log "Redeploying red-app - expect this to be rejected by the admission webhook:"
oc apply -f manifests/04-red.yaml 2>&1 | tee -a "$REPORT"
APPLY_EXIT="${PIPESTATUS[0]}"

python3 scripts/acs_api.py set-enforcement "EAP-Init-Test: Privileged Container (Blue/Red)" --off | tee -a "$REPORT"

log ""
if [[ $APPLY_EXIT -ne 0 ]]; then
  result "BLOCKED as expected."
  log "Restoring red-app now that enforcement is off..."
  oc apply -f manifests/04-red.yaml | tee -a "$REPORT"
else
  result "NOT BLOCKED - the deployment was created despite enforcement being enabled." bad
fi
oc rollout status deployment/red-app -n "${TEST_NAMESPACE}" --timeout=60s | tee -a "$REPORT"

section "Summary"
log "Full report saved to ${REPORT}"

echo ""
echo "Done. Report: ${REPORT}"
